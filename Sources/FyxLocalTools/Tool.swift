// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalCore
import FyxLocalProviders

public struct ToolInvocation: Sendable, Hashable {
    public let callID: String
    public let name: String
    public let arguments: String

    public init(callID: String, name: String, arguments: String) {
        self.callID = callID
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolOutput: Sendable, Hashable {
    public var outputJSON: String
    public var isError: Bool
    public var display: ToolDisplayHint?

    public init(outputJSON: String, isError: Bool = false, display: ToolDisplayHint? = nil) {
        self.outputJSON = outputJSON
        self.isError = isError
        self.display = display
    }
}

/// Live status line for a running tool ("Analyzing content…"). nil means
/// alive-but-no-detail; the UI substitutes a localized "Working…".
public typealias ToolProgressHandler = @Sendable (String?) -> Void

public protocol Tool: Sendable {
    var name: String { get }
    /// Per-tool override of the registry's default invocation timeout.
    /// nil = use the caller's default. Long-running MCP task-augmented
    /// tools raise this; everything else leaves it alone.
    var preferredTimeout: Duration? { get }
    func definition(for language: PromptLanguage) -> ToolDefinition
    func invoke(arguments: String) async throws -> ToolOutput
}

public extension Tool {
    var preferredTimeout: Duration? { nil }
}

/// Tools that can stream live status while running (e.g. MCP task-augmented
/// calls). The registry prefers this entry point when a progress callback is
/// available; conformers get the plain `invoke` for free.
public protocol ProgressReportingTool: Tool {
    func invoke(arguments: String, onProgress: @escaping ToolProgressHandler) async throws -> ToolOutput
}

public extension ProgressReportingTool {
    func invoke(arguments: String) async throws -> ToolOutput {
        try await invoke(arguments: arguments, onProgress: { _ in })
    }
}

public extension Tool {
    /// Standard error result: a single-line `{"error":"…"}` JSON payload with
    /// `isError` set and a markdown display hint. Every built-in tool surfaces
    /// failures this way; the default lives here so they don't each re-declare
    /// it. `message` is JSON-string-escaped (newlines collapsed for inline JSON).
    func errorOutput(_ message: String) -> ToolOutput {
        ToolOutput(
            outputJSON: #"{"error":"\#(message.escapedForJSONInline())"}"#,
            isError: true,
            display: .markdown
        )
    }
}

public enum ToolInvocationError: Error, Sendable, Equatable {
    case timedOut
    case badArguments(String)
    case providerFailure(String)
}
