// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalCore

public struct MCPServerInfo: Sendable, Hashable {
    public var name: String
    public var version: String
    public var protocolVersion: String
    public init(name: String, version: String, protocolVersion: String) {
        self.name = name
        self.version = version
        self.protocolVersion = protocolVersion
    }
}

public struct MCPTool: Sendable, Hashable {
    public var name: String
    public var description: String
    /// Raw JSON schema (object form).
    public var inputSchema: JSONValue
    /// Declared `execution.taskSupport` (MCP 2025-11-25 tasks). Absent or
    /// unrecognised in `tools/list` maps to `.forbidden` (plain calls).
    public var taskSupport: MCPTaskSupport
    public init(name: String, description: String, inputSchema: JSONValue, taskSupport: MCPTaskSupport = .forbidden) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.taskSupport = taskSupport
    }
}

public struct MCPToolCallResult: Sendable, Hashable {
    public var content: [MCPContent]
    public var isError: Bool
    public init(content: [MCPContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }
}

public enum MCPContent: Sendable, Hashable {
    case text(String)
    case image(base64: String, mimeType: String)
    case resource(uri: String, text: String?)
}

public enum MCPClientError: Error, Sendable, Equatable {
    case notInitialized
    case rpcError(code: Int, message: String)
    case unexpectedResult
    case transportClosed
    case taskDeadlineExceeded(taskId: String)
    case resourceTooLarge(uri: String)
}

extension MCPClientError: LocalizedError {
    /// Without this, `error.localizedDescription` at the tool-runner's
    /// catch-all collapses to "The operation couldn't be completed…" and the
    /// server's actual message never reaches the user.
    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "MCP client is not initialised"
        case .rpcError(let code, let message):
            return "MCP error \(code): \(message)"
        case .unexpectedResult:
            return "MCP server returned an unexpected result"
        case .transportClosed:
            return "MCP transport closed"
        case .taskDeadlineExceeded(let taskId):
            return "MCP task '\(taskId)' did not complete before the client-side deadline"
        case .resourceTooLarge(let uri):
            return "MCP resource '\(uri)' exceeds the size limit"
        }
    }
}

public actor MCPClient {
    public let clientName: String
    public let clientVersion: String
    public let protocolVersion: String

    private let transport: any MCPTransport
    private var nextID: Int = 0
    private var pending: [JSONRPCID: CheckedContinuation<JSONRPCResponse, Error>] = [:]
    /// IDs whose call was cancelled before the continuation registered
    /// (cancellation raced ahead of `withCheckedThrowingContinuation`). The
    /// registration path consumes these. A response-then-cancel race can
    /// strand an entry; IDs are never reused, so a stale entry is a few
    /// bytes of noise, not a correctness hazard.
    private var cancelledIDs: Set<JSONRPCID> = []
    private var receiveTask: Task<Void, Never>?
    private var notificationContinuation: AsyncStream<JSONRPCNotification>.Continuation?
    private var notificationStream: AsyncStream<JSONRPCNotification>?
    public private(set) var serverInfo: MCPServerInfo?
    public private(set) var serverCapabilities: MCPServerCapabilities = .none

    /// `tools/list` cache of each tool's declared taskSupport, so `callTool`
    /// can pick the task path without a signature change for callers.
    private var toolTaskSupport: [String: MCPTaskSupport] = [:]

    /// Per in-flight task: status handler plus last-emitted state for dedup
    /// (poll results and `notifications/tasks/status` funnel through the
    /// same gate).
    private struct ActiveTaskContext {
        var handler: MCPTaskStatusHandler?
        var lastStatus: MCPTaskState?
        var lastMessage: String?
    }
    private var activeTasks: [String: ActiveTaskContext] = [:]

    private var elicitationHandler: MCPElicitationHandler?
    /// Serializes concurrent elicitation requests (one at a time, FIFO).
    private var elicitationChain: Task<Void, Never>?
    private var queuedElicitations: Int = 0

    private enum TaskDefaults {
        /// ttl requested on task-augmented calls; comfortably above the app
        /// layer's 10-minute task-tool timeout so results outlive the caller.
        static let requestedTTLMS = 1_200_000
        static let defaultPollIntervalMS = 500
        /// Floor guards against a hostile `pollInterval: 0` hot loop.
        static let minPollIntervalMS = 100
        static let maxPollIntervalMS = 10_000
        static let maxQueuedElicitations = 8
    }

    public init(
        transport: any MCPTransport,
        clientName: String = "FyxLocal",
        clientVersion: String = FyxLocal.version,
        protocolVersion: String = "2025-11-25"
    ) {
        self.transport = transport
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.protocolVersion = protocolVersion

        let (stream, continuation) = AsyncStream<JSONRPCNotification>.makeStream()
        self.notificationStream = stream
        self.notificationContinuation = continuation
    }

    public func start() async throws {
        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }
        try await initializeHandshake()
    }

    public func shutdown() async {
        receiveTask?.cancel()
        receiveTask = nil
        await transport.close()
        notificationContinuation?.finish()
        for (_, cont) in pending { cont.resume(throwing: MCPClientError.transportClosed) }
        pending.removeAll()
        cancelledIDs.removeAll()
    }

    /// Server-initiated notifications (list_changed and friends). The stream
    /// is SINGLE-CONSUMER: in the app, MCPRegistry's notification listener
    /// owns it — nothing else should call this on a registry-managed client.
    public func notifications() -> AsyncStream<JSONRPCNotification> {
        notificationStream ?? AsyncStream { _ in }
    }

    /// Install the app's form-mode elicitation handler. Must be called
    /// before `start()`: the `elicitation` client capability is only
    /// declared in the `initialize` handshake when a handler is present.
    public func setElicitationHandler(_ handler: @escaping MCPElicitationHandler) {
        elicitationHandler = handler
    }

    public func listTools() async throws -> [MCPTool] {
        // An MCP server is untrusted: bound the tool count and per-field lengths
        // so a hostile/buggy server can't exhaust memory or flood the prompt.
        let maxTools = 1000
        let maxNameLen = 256
        let maxDescLen = 8_192
        var output: [MCPTool] = []
        var taskSupportCache: [String: MCPTaskSupport] = [:]
        try await paginatedList(method: "tools/list", itemsKey: "tools", itemCap: maxTools) { tool in
            guard let name = tool["name"]?.stringValue, !name.isEmpty else { return }
            let description = tool["description"]?.stringValue ?? ""
            let schema = tool["inputSchema"] ?? .object([:])
            let taskSupport = tool["execution"]?["taskSupport"]?.stringValue
                .flatMap { MCPTaskSupport(rawValue: $0) } ?? .forbidden
            let boundedName = String(name.prefix(maxNameLen))
            taskSupportCache[boundedName] = taskSupport
            output.append(MCPTool(
                name: boundedName,
                description: String(description.prefix(maxDescLen)),
                inputSchema: schema,
                taskSupport: taskSupport
            ))
        }
        toolTaskSupport = taskSupportCache
        return output
    }

    // MARK: - Resources & prompts

    /// Lists the server's resources (paginated). Field lengths and item
    /// count are bounded — the server is untrusted.
    public func listResources() async throws -> [MCPResource] {
        let maxResources = 1000
        var output: [MCPResource] = []
        try await paginatedList(method: "resources/list", itemsKey: "resources", itemCap: maxResources) { item in
            guard let uri = item["uri"]?.stringValue, !uri.isEmpty, uri.count <= 2048 else { return }
            output.append(MCPResource(
                uri: uri,
                name: String((item["name"]?.stringValue ?? uri).prefix(256)),
                title: item["title"]?.stringValue.map { String($0.prefix(256)) },
                description: item["description"]?.stringValue.map { String($0.prefix(8_192)) },
                mimeType: item["mimeType"]?.stringValue.map { String($0.prefix(256)) },
                size: item["size"]?.intValue
            ))
        }
        return output
    }

    /// Reads one resource. Content sizes are bounded (text ≈4 MB, blob
    /// base64 ≈24 MB → ~16 MB decoded); anything larger throws
    /// `.resourceTooLarge` rather than ballooning memory.
    public func readResource(uri: String) async throws -> [MCPResourceContents] {
        let maxEntries = 32
        let maxTextChars = 4_000_000
        let maxBlobChars = 24_000_000
        let response = try await call(method: "resources/read", params: .object(["uri": .string(uri)]))
        guard case .success(let value) = response.result else {
            if case .failure(let e) = response.result { throw MCPClientError.rpcError(code: e.code, message: e.message) }
            throw MCPClientError.unexpectedResult
        }
        guard let contents = value["contents"]?.arrayValue else { throw MCPClientError.unexpectedResult }
        var output: [MCPResourceContents] = []
        for entry in contents.prefix(maxEntries) {
            let entryURI = entry["uri"]?.stringValue ?? uri
            let mimeType = entry["mimeType"]?.stringValue
            if let text = entry["text"]?.stringValue {
                guard text.count <= maxTextChars else { throw MCPClientError.resourceTooLarge(uri: entryURI) }
                output.append(.text(uri: entryURI, mimeType: mimeType, text: text))
            } else if let blob = entry["blob"]?.stringValue {
                guard blob.count <= maxBlobChars else { throw MCPClientError.resourceTooLarge(uri: entryURI) }
                output.append(.blob(uri: entryURI, mimeType: mimeType, base64: blob))
            }
        }
        return output
    }

    /// Lists the server's prompt templates (paginated, bounded).
    public func listPrompts() async throws -> [MCPPrompt] {
        let maxPrompts = 500
        let maxArguments = 64
        var output: [MCPPrompt] = []
        try await paginatedList(method: "prompts/list", itemsKey: "prompts", itemCap: maxPrompts) { item in
            guard let name = item["name"]?.stringValue, !name.isEmpty else { return }
            let arguments = (item["arguments"]?.arrayValue ?? []).prefix(maxArguments).compactMap { argument -> MCPPromptArgument? in
                guard let argumentName = argument["name"]?.stringValue, !argumentName.isEmpty else { return nil }
                return MCPPromptArgument(
                    name: String(argumentName.prefix(256)),
                    title: argument["title"]?.stringValue.map { String($0.prefix(256)) },
                    description: argument["description"]?.stringValue.map { String($0.prefix(2_048)) },
                    required: argument["required"]?.boolValue ?? false
                )
            }
            output.append(MCPPrompt(
                name: String(name.prefix(256)),
                title: item["title"]?.stringValue.map { String($0.prefix(256)) },
                description: item["description"]?.stringValue.map { String($0.prefix(8_192)) },
                arguments: Array(arguments)
            ))
        }
        return output
    }

    /// Materializes a prompt template with the given arguments.
    public func getPrompt(name: String, arguments: [String: String]) async throws -> MCPPromptResult {
        let maxMessages = 64
        var params: [String: JSONValue] = ["name": .string(name)]
        if !arguments.isEmpty {
            params["arguments"] = .object(arguments.mapValues { .string($0) })
        }
        let response = try await call(method: "prompts/get", params: .object(params))
        guard case .success(let value) = response.result else {
            if case .failure(let e) = response.result { throw MCPClientError.rpcError(code: e.code, message: e.message) }
            throw MCPClientError.unexpectedResult
        }
        let messages = (value["messages"]?.arrayValue ?? []).prefix(maxMessages).compactMap { message -> MCPPromptMessage? in
            guard let role = message["role"]?.stringValue,
                  let contentValue = message["content"],
                  let content = decodeContent(contentValue) else { return nil }
            return MCPPromptMessage(role: role, content: content)
        }
        return MCPPromptResult(
            description: value["description"]?.stringValue,
            messages: Array(messages)
        )
    }

    /// Drives a cursor-paginated list method (`tools/list`, `resources/list`,
    /// `prompts/list`), invoking `handle` per raw item across pages. Bounded
    /// by `itemCap` total items and a page cap that guards against a hostile
    /// server feeding an endless (or circular) cursor chain.
    private func paginatedList(
        method: String,
        itemsKey: String,
        itemCap: Int,
        handle: (JSONValue) -> Void
    ) async throws {
        let maxPages = 50
        var cursor: String?
        var pages = 0
        var seen = 0
        repeat {
            let params: JSONValue? = cursor.map { .object(["cursor": .string($0)]) }
            let response = try await call(method: method, params: params)
            guard case .success(let value) = response.result else {
                if case .failure(let e) = response.result {
                    throw MCPClientError.rpcError(code: e.code, message: e.message)
                }
                throw MCPClientError.unexpectedResult
            }
            guard let items = value[itemsKey]?.arrayValue else { throw MCPClientError.unexpectedResult }
            for item in items {
                guard seen < itemCap else { return }
                seen += 1
                handle(item)
            }
            cursor = value["nextCursor"]?.stringValue
            pages += 1
        } while cursor != nil && pages < maxPages
    }

    public func callTool(
        name: String,
        arguments: JSONValue,
        onTaskStatus: MCPTaskStatusHandler? = nil
    ) async throws -> MCPToolCallResult {
        // Task-augment whenever the server and tool allow it — `.optional`
        // tools gain live progress + server-side cancellation for free.
        let support = toolTaskSupport[name] ?? .forbidden
        let useTaskPath = serverCapabilities.supportsTaskAugmentedToolCalls
            && support != .forbidden
        guard useTaskPath else {
            // Plain call. A task-required tool on a server without the tasks
            // capability lands here too; the server's error (e.g. "requires
            // task augmentation") surfaces verbatim via LocalizedError.
            let params: JSONValue = .object([
                "name": .string(name),
                "arguments": arguments,
            ])
            let response = try await call(method: "tools/call", params: params)
            switch response.result {
            case .success(let value):
                return decodeCallResult(value)
            case .failure(let e):
                throw MCPClientError.rpcError(code: e.code, message: e.message)
            }
        }
        return try await runTaskAugmentedCall(name: name, arguments: arguments, onTaskStatus: onTaskStatus)
    }

    // MARK: - Task-augmented calls (MCP 2025-11-25 tasks)

    private func runTaskAugmentedCall(
        name: String,
        arguments: JSONValue,
        onTaskStatus: MCPTaskStatusHandler?
    ) async throws -> MCPToolCallResult {
        let params: JSONValue = .object([
            "name": .string(name),
            "arguments": arguments,
            "task": .object(["ttl": .int(TaskDefaults.requestedTTLMS)]),
        ])
        let response = try await call(method: "tools/call", params: params)
        guard case .success(let value) = response.result else {
            if case .failure(let e) = response.result { throw MCPClientError.rpcError(code: e.code, message: e.message) }
            throw MCPClientError.unexpectedResult
        }
        guard let taskValue = value["task"] else { throw MCPClientError.unexpectedResult }
        var snapshot = try MCPTaskSnapshot.parse(taskValue)
        let taskId = snapshot.taskId

        activeTasks[taskId] = ActiveTaskContext(handler: onTaskStatus)
        defer { activeTasks[taskId] = nil }

        do {
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(TaskDefaults.requestedTTLMS))
            await emitTaskUpdate(snapshot)
            var retriedResultFetch = false
            while true {
                snapshot = try await pollUntilActionable(taskId: taskId, from: snapshot, deadline: deadline)
                do {
                    // Terminal, or input_required — in the latter case this
                    // blocks server-side while elicitation/create arrives via
                    // the receive loop, and keeps blocking until terminal.
                    return try await fetchTaskResult(taskId: taskId)
                } catch let error where !retriedResultFetch
                    && !(error is MCPClientError) && !(error is CancellationError) {
                    // Transport-level hiccup (e.g. HTTP idle timeout while
                    // tasks/result blocked). If the task is still retrievable,
                    // resume polling and retry once; otherwise surface the
                    // tasks/get error.
                    retriedResultFetch = true
                    snapshot = try await taskSnapshot(taskId: taskId)
                    await emitTaskUpdate(snapshot)
                }
            }
        } catch is CancellationError {
            // Caller abandoned the call (tool timeout / user stop): tell the
            // server to stop work, best-effort, if it supports cancellation.
            if serverCapabilities.supportsTaskCancel {
                sendBestEffortCancel(taskId: taskId)
            }
            throw CancellationError()
        }
    }

    /// Polls `tasks/get` until the task is terminal or needs input,
    /// emitting deduped status updates along the way.
    private func pollUntilActionable(
        taskId: String,
        from initial: MCPTaskSnapshot,
        deadline: ContinuousClock.Instant
    ) async throws -> MCPTaskSnapshot {
        var snapshot = initial
        while !snapshot.status.isTerminal && snapshot.status != .inputRequired {
            let interval = min(
                max(snapshot.pollIntervalMS ?? TaskDefaults.defaultPollIntervalMS, TaskDefaults.minPollIntervalMS),
                TaskDefaults.maxPollIntervalMS
            )
            try await Task.sleep(for: .milliseconds(interval))
            guard ContinuousClock.now < deadline else {
                throw MCPClientError.taskDeadlineExceeded(taskId: taskId)
            }
            snapshot = try await taskSnapshot(taskId: taskId)
            await emitTaskUpdate(snapshot)
        }
        return snapshot
    }

    private func taskSnapshot(taskId: String) async throws -> MCPTaskSnapshot {
        let response = try await call(method: "tasks/get", params: .object(["taskId": .string(taskId)]))
        guard case .success(let value) = response.result else {
            if case .failure(let e) = response.result { throw MCPClientError.rpcError(code: e.code, message: e.message) }
            throw MCPClientError.unexpectedResult
        }
        var snapshot = try MCPTaskSnapshot.parse(value)
        // The server must echo our taskId; pin it so a confused server can't
        // detach the dedup gate mid-call.
        snapshot.taskId = taskId
        return snapshot
    }

    private func fetchTaskResult(taskId: String) async throws -> MCPToolCallResult {
        // Per spec, tasks/get|result|cancel requests must NOT carry the
        // related-task _meta (taskId in params is the source of truth) —
        // the reference TS SDK routes a request bearing that _meta into the
        // task's message queue and never answers it. Only the RESPONSE
        // carries the metadata, and the server adds it.
        let params: JSONValue = .object(["taskId": .string(taskId)])
        let response = try await call(method: "tasks/result", params: params)
        switch response.result {
        case .success(let value):
            // A `failed` task whose underlying tool result had isError:true
            // comes back here as a normal result — returned, not thrown.
            return decodeCallResult(value)
        case .failure(let e):
            throw MCPClientError.rpcError(code: e.code, message: e.message)
        }
    }

    /// Dedup gate for status updates. Stored state is advanced BEFORE the
    /// handler is awaited so an interleaved emission (actor reentrancy across
    /// the await) can't deliver duplicates; residual reordering is cosmetic.
    private func emitTaskUpdate(_ snapshot: MCPTaskSnapshot) async {
        guard var context = activeTasks[snapshot.taskId] else { return }
        guard context.lastStatus != snapshot.status || context.lastMessage != snapshot.statusMessage else { return }
        context.lastStatus = snapshot.status
        context.lastMessage = snapshot.statusMessage
        activeTasks[snapshot.taskId] = context
        if let handler = context.handler {
            await handler(MCPTaskStatusUpdate(
                taskId: snapshot.taskId,
                status: snapshot.status,
                statusMessage: snapshot.statusMessage
            ))
        }
    }

    private func sendBestEffortCancel(taskId: String) {
        // Unstructured so it survives the caller's cancellation; errors are
        // irrelevant (the task may already be terminal or the server gone).
        Task { [weak self] in
            _ = try? await self?.call(method: "tasks/cancel", params: .object(["taskId": .string(taskId)]))
        }
    }

    private func relatedTaskMeta(_ taskId: String) -> JSONValue {
        .object(["io.modelcontextprotocol/related-task": .object(["taskId": .string(taskId)])])
    }

    // MARK: - Result decoding

    private func decodeCallResult(_ value: JSONValue) -> MCPToolCallResult {
        let contentArray = value["content"]?.arrayValue ?? []
        let isError = value["isError"]?.boolValue ?? false
        let content = contentArray.compactMap { decodeContent($0) }
        return MCPToolCallResult(content: content, isError: isError)
    }

    private func decodeContent(_ value: JSONValue) -> MCPContent? {
        guard let type = value["type"]?.stringValue else { return nil }
        switch type {
        case "text":
            return value["text"]?.stringValue.map { .text($0) }
        case "image":
            if let b64 = value["data"]?.stringValue, let mt = value["mimeType"]?.stringValue {
                return .image(base64: b64, mimeType: mt)
            }
        case "resource":
            if let res = value["resource"], let uri = res["uri"]?.stringValue {
                return .resource(uri: uri, text: res["text"]?.stringValue)
            }
        default: break
        }
        return nil
    }

    // MARK: - Handshake

    private func initializeHandshake() async throws {
        // Only declare the elicitation capability when the app installed a
        // handler (setElicitationHandler must precede start()). No client
        // `tasks` capability: that would advertise accepting task-augmented
        // server→client requests, which we don't.
        let capabilities: JSONValue = elicitationHandler != nil
            ? .object(["elicitation": .object(["form": .object([:])])])
            : .object([:])
        let params: JSONValue = .object([
            "protocolVersion": .string(protocolVersion),
            "capabilities": capabilities,
            "clientInfo": .object([
                "name": .string(clientName),
                "version": .string(clientVersion),
            ]),
        ])
        let response = try await call(method: "initialize", params: params)
        guard case .success(let value) = response.result else {
            if case .failure(let e) = response.result {
                throw MCPClientError.rpcError(code: e.code, message: e.message)
            }
            throw MCPClientError.unexpectedResult
        }
        let info = value["serverInfo"]
        let name = info?["name"]?.stringValue ?? "unknown"
        let version = info?["version"]?.stringValue ?? "?"
        let proto = value["protocolVersion"]?.stringValue ?? protocolVersion
        self.serverInfo = MCPServerInfo(name: name, version: version, protocolVersion: proto)
        self.serverCapabilities = MCPServerCapabilities(raw: value["capabilities"] ?? .object([:]))

        try await transport.send(.notification(.init(method: "notifications/initialized")))
    }

    // MARK: - JSON-RPC plumbing

    private func call(method: String, params: JSONValue?) async throws -> JSONRPCResponse {
        nextID += 1
        let id = JSONRPCID.int(nextID)
        let frame = JSONRPCFrame.request(.init(id: id, method: method, params: params))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONRPCResponse, Error>) in
                // Runs actor-isolated (inherited via #isolation). Cancellation
                // may have raced ahead of registration — consume the marker.
                if Task.isCancelled || cancelledIDs.remove(id) != nil {
                    cont.resume(throwing: CancellationError())
                    return
                }
                pending[id] = cont
                Task {
                    do { try await transport.send(frame) }
                    catch {
                        if let removed = pending.removeValue(forKey: id) {
                            removed.resume(throwing: error)
                        }
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelPending(id: id) }
        }
    }

    /// Every resume path funnels through `pending.removeValue` on the actor,
    /// so exactly one site wins — no double resume.
    private func cancelPending(id: JSONRPCID) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: CancellationError())
        } else {
            cancelledIDs.insert(id)
        }
    }

    private func runReceiveLoop() async {
        do {
            for try await frame in transport.incoming() {
                switch frame {
                case .response(let response):
                    cancelledIDs.remove(response.id)
                    if let cont = pending.removeValue(forKey: response.id) {
                        cont.resume(returning: response)
                    }
                case .notification(let n):
                    if n.method == "notifications/tasks/status",
                       let params = n.params,
                       let snapshot = try? MCPTaskSnapshot.parse(params) {
                        // Accelerates UI updates only; polling remains the
                        // source of truth for control flow.
                        Task { await self.emitTaskUpdate(snapshot) }
                    }
                    notificationContinuation?.yield(n)
                case .request(let req):
                    handleServerRequest(req)
                }
            }
        } catch {
            for (_, cont) in pending { cont.resume(throwing: error) }
            pending.removeAll()
        }
        // The stream can also end by completing normally (server closed the
        // connection cleanly, no throw). Drain any still-pending requests so
        // their callers don't hang forever waiting for a reply that can't come.
        // In the catch path `pending` was already emptied, so this is a no-op.
        for (_, cont) in pending { cont.resume(throwing: MCPClientError.transportClosed) }
        pending.removeAll()
        notificationContinuation?.finish()
    }

    // MARK: - Server→client requests

    /// Dispatches without ever blocking the receive loop. Before tasks and
    /// elicitation existed we dropped these frames on the floor, which per
    /// spec hangs a server awaiting any reply — now everything gets one.
    private func handleServerRequest(_ req: JSONRPCRequest) {
        switch req.method {
        case "elicitation/create":
            guard queuedElicitations < TaskDefaults.maxQueuedElicitations else {
                respondAsync(id: req.id, result: .failure(JSONRPCError(
                    code: -32603, message: "too many concurrent elicitation requests"
                )))
                return
            }
            queuedElicitations += 1
            let previous = elicitationChain
            elicitationChain = Task { [weak self] in
                await previous?.value
                await self?.processElicitation(req)
            }
        default:
            respondAsync(id: req.id, result: .failure(.methodNotFound))
        }
    }

    private func processElicitation(_ req: JSONRPCRequest) async {
        defer { queuedElicitations -= 1 }
        guard let handler = elicitationHandler else {
            await respond(id: req.id, result: .failure(.methodNotFound))
            return
        }
        if let mode = req.params?["mode"]?.stringValue, mode != "form" {
            // We only declare the `form` capability; per spec undeclared
            // modes get Invalid params.
            await respond(id: req.id, result: .failure(JSONRPCError(
                code: -32602, message: "unsupported elicitation mode '\(String(mode.prefix(64)))'"
            )))
            return
        }
        switch MCPElicitationParser.parse(params: req.params) {
        case .failure(let error):
            await respond(id: req.id, result: .failure(error))
        case .success(let request):
            let result = await handler(request)
            var payload: [String: JSONValue] = ["action": .string(result.action.rawValue)]
            if result.action == .accept, let content = result.content, case .object = content {
                payload["content"] = content
            }
            if let taskId = request.relatedTaskId {
                // Task-related messages must echo the related-task _meta.
                payload["_meta"] = relatedTaskMeta(taskId)
            }
            await respond(id: req.id, result: .success(.object(payload)))
        }
    }

    private func respondAsync(id: JSONRPCID, result: Result<JSONValue, JSONRPCError>) {
        Task { [weak self] in
            await self?.respond(id: id, result: result)
        }
    }

    private func respond(id: JSONRPCID, result: Result<JSONValue, JSONRPCError>) async {
        // Best-effort: the transport may have closed while the user pondered
        // an elicitation form; the server tolerates a missing reply then.
        try? await transport.send(.response(JSONRPCResponse(id: id, result: result)))
    }
}
