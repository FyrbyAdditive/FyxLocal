// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

#if canImport(Darwin)
public actor StdioMCPTransport: MCPTransport {
    private let command: String
    private let arguments: [String]
    private let environment: [String: String]
    private let workingDirectory: String?
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var inboundContinuation: AsyncThrowingStream<JSONRPCFrame, Error>.Continuation?
    private var readerTask: Task<Void, Never>?

    public init(
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil
    ) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    public func start() throws {
        // Build the child environment with a usable PATH. A GUI app launched
        // from Finder inherits a bare PATH (often just /usr/bin:/bin:/usr/sbin:
        // /sbin), so a child like `npx` — a `#!/usr/bin/env node` script —
        // can't find `node` and dies instantly. Prepend the common tool dirs
        // so interpreters resolve. User-supplied env still wins.
        var env = ProcessInfo.processInfo.environment
        let toolPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let existing = (env["PATH"]?.split(separator: ":").map(String.init)) ?? []
        var seen = Set<String>()
        env["PATH"] = (toolPaths + existing).filter { seen.insert($0).inserted }.joined(separator: ":")
        for (k, v) in environment { env[k] = v }
        // Never propagate dylib-injection vectors to child processes. The app
        // itself may legitimately run with relaxed library validation (MLX
        // Metal JIT, relocatable Python), but an MCP server inheriting
        // DYLD_INSERT_LIBRARIES & co. would execute arbitrary injected code.
        // Stripped last so user-supplied overrides can't reintroduce them.
        env = Self.strippingDynamicLinkerVariables(from: env)

        // Resolve the command: an absolute/relative path is used as-is; a bare
        // name (e.g. "npx") is looked up against the child PATH. Then verify it
        // is actually executable BEFORE launching, so a bad path becomes a
        // clear thrown error instead of a launch that limps and then SIGPIPEs.
        let resolved = Self.resolveExecutable(command, path: env["PATH"] ?? "")
        guard let resolved else {
            throw MCPTransportError.ioError("MCP command not found or not executable: \(command)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = arguments
        process.environment = env
        if let wd = workingDirectory {
            // Canonicalize (resolves symlinks + relative components) and
            // require an existing directory, so a bad config string fails
            // with a clear error here instead of a confusing child crash.
            let canonical = URL(fileURLWithPath: wd).resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw MCPTransportError.ioError("MCP working directory does not exist or is not a directory: \(wd)")
            }
            process.currentDirectoryURL = canonical
        }
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw MCPTransportError.ioError("failed to launch \(resolved): \(error.localizedDescription)")
        }
        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting
        self.stdoutHandle = stdout.fileHandleForReading
        self.stderrHandle = stderr.fileHandleForReading
    }

    /// Resolve a command to an executable path. Absolute/relative paths (those
    /// containing "/") are checked directly; a bare name is searched across the
    /// PATH entries. Returns nil if nothing executable is found.
    private static func resolveExecutable(_ command: String, path: String) -> String? {
        let fm = FileManager.default
        if command.contains("/") {
            return fm.isExecutableFile(atPath: command) ? command : nil
        }
        for dir in path.split(separator: ":") {
            let candidate = dir + "/" + command
            if fm.isExecutableFile(atPath: String(candidate)) { return String(candidate) }
        }
        return nil
    }

    /// Drop every dynamic-linker injection variable (`DYLD_*` on macOS plus
    /// `LD_*` for portability) from a child environment. These allow arbitrary
    /// code execution inside the launched MCP server; nothing legitimate
    /// requires forwarding them.
    static func strippingDynamicLinkerVariables(from env: [String: String]) -> [String: String] {
        env.filter { !($0.key.hasPrefix("DYLD_") || $0.key.hasPrefix("LD_")) }
    }

    /// Best-effort read of any bytes the child wrote to stderr (e.g.
    /// "env: node: No such file or directory"), for surfacing on early exit.
    /// Non-blocking: returns whatever is buffered now.
    public func drainStderr() -> String? {
        guard let stderrHandle else { return nil }
        let data = stderrHandle.availableData
        guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func send(_ frame: JSONRPCFrame) async throws {
        guard let stdinHandle else { throw MCPTransportError.closed }
        var data = try JSONRPCCodec.encode(frame)
        data.append(0x0A) // newline
        try stdinHandle.write(contentsOf: data)
    }

    nonisolated public func incoming() -> AsyncThrowingStream<JSONRPCFrame, Error> {
        AsyncThrowingStream(JSONRPCFrame.self) { continuation in
            let task = Task { await self.startReading(into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func startReading(into continuation: AsyncThrowingStream<JSONRPCFrame, Error>.Continuation) async {
        self.inboundContinuation = continuation
        guard let stdoutHandle else {
            continuation.finish(throwing: MCPTransportError.closed)
            return
        }
        readerTask?.cancel()
        readerTask = Task { [weak self] in
            await self?.readLoop(handle: stdoutHandle)
        }
    }

    private func readLoop(handle: FileHandle) async {
        var buffer = Data()
        for await chunk in handle.bytes {
            if Task.isCancelled { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.isEmpty { continue }
                do {
                    let frame = try JSONRPCCodec.decode(Data(line))
                    inboundContinuation?.yield(frame)
                } catch {
                    inboundContinuation?.finish(throwing: MCPTransportError.protocolError("decode: \(error)"))
                    return
                }
            }
        }
        inboundContinuation?.finish()
    }

    public func close() async {
        readerTask?.cancel()
        readerTask = nil
        try? stdinHandle?.close()
        process?.terminate()
        process?.waitUntilExit()
        inboundContinuation?.finish()
    }
}

extension FileHandle {
    fileprivate var bytes: AsyncStream<UInt8> {
        AsyncStream<UInt8>(bufferingPolicy: .unbounded) { continuation in
            let handle = self
            let queue = DispatchQueue(label: "fchat.mcp.stdio.reader")
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                if data.isEmpty {
                    continuation.finish()
                    handle.readabilityHandler = nil
                    return
                }
                queue.async {
                    for byte in data { continuation.yield(byte) }
                }
            }
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
            }
        }
    }
}
#endif
