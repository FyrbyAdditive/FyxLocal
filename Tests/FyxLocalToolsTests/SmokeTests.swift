// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FyxLocalCore
import FyxLocalProviders
@testable import FyxLocalTools

@Suite("ToolRegistry")
struct ToolRegistryTests {
    @Test func registerAndListsAlphabetical() async {
        let r = ToolRegistry()
        await r.register(EchoTool(name: "b_tool"))
        await r.register(EchoTool(name: "a_tool"))
        let names = await r.allNames()
        #expect(names == ["a_tool", "b_tool"])
        let defs = await r.definitions(for: .english)
        #expect(defs.map(\.name) == ["a_tool", "b_tool"])
    }

    @Test func unknownToolYieldsErrorOutput() async {
        let r = ToolRegistry()
        let results = await r.runInvocations([ToolInvocation(callID: "1", name: "missing", arguments: "{}")])
        #expect(results.count == 1)
        #expect(results[0].1.isError == true)
        #expect(results[0].1.outputJSON.contains("unknown tool"))
    }

    @Test func resultsPreserveSubmissionOrder() async {
        let r = ToolRegistry()
        await r.register(EchoTool(name: "fast"))
        await r.register(SlowEchoTool(name: "slow", milliseconds: 50))
        let invocations = [
            ToolInvocation(callID: "a", name: "slow", arguments: #"{"v":"A"}"#),
            ToolInvocation(callID: "b", name: "fast", arguments: #"{"v":"B"}"#),
            ToolInvocation(callID: "c", name: "slow", arguments: #"{"v":"C"}"#),
        ]
        let results = await r.runInvocations(invocations, perToolTimeout: .seconds(5))
        #expect(results.map { $0.0.callID } == ["a", "b", "c"])
    }

    @Test func toolTimeoutSurfaces() async {
        let r = ToolRegistry()
        await r.register(SlowEchoTool(name: "slow", milliseconds: 500))
        let results = await r.runInvocations(
            [ToolInvocation(callID: "x", name: "slow", arguments: "{}")],
            perToolTimeout: .milliseconds(50)
        )
        #expect(results.first?.1.isError == true)
        #expect(results.first?.1.outputJSON.contains("timedOut") == true)
    }

    @Test func preferredTimeoutOverridesShorterDefault() async {
        // A task-style tool with a long preferredTimeout must survive a
        // registry default shorter than its runtime.
        let r = ToolRegistry()
        await r.register(SlowEchoTool(name: "patient", milliseconds: 200, preferredTimeout: .seconds(5)))
        let results = await r.runInvocations(
            [ToolInvocation(callID: "x", name: "patient", arguments: #"{"v":"ok"}"#)],
            perToolTimeout: .milliseconds(50)
        )
        #expect(results.first?.1.isError == false)
    }

    @Test func shortPreferredTimeoutTrumpsLongDefault() async {
        let r = ToolRegistry()
        await r.register(SlowEchoTool(name: "impatient", milliseconds: 500, preferredTimeout: .milliseconds(50)))
        let results = await r.runInvocations(
            [ToolInvocation(callID: "x", name: "impatient", arguments: "{}")],
            perToolTimeout: .seconds(5)
        )
        #expect(results.first?.1.isError == true)
        #expect(results.first?.1.outputJSON.contains("timedOut") == true)
    }

    @Test func progressForwardingTagsCallID() async {
        let r = ToolRegistry()
        await r.register(ProgressEchoTool(name: "progressy", messages: ["step 1", nil, "step 2"]))
        let box = ProgressBox()
        let results = await r.runInvocations(
            [ToolInvocation(callID: "call_9", name: "progressy", arguments: "{}")],
            onProgress: { callID, message in box.append(callID: callID, message: message) }
        )
        #expect(results.first?.1.isError == false)
        #expect(box.snapshot().map(\.callID) == ["call_9", "call_9", "call_9"])
        #expect(box.snapshot().map(\.message) == ["step 1", nil, "step 2"])
    }

    @Test func progressReportingToolWorksWithoutCallback() async {
        // No onProgress supplied → the plain Tool entry point must be used
        // and the call still succeeds.
        let r = ToolRegistry()
        await r.register(ProgressEchoTool(name: "progressy", messages: ["ignored"]))
        let results = await r.runInvocations(
            [ToolInvocation(callID: "x", name: "progressy", arguments: "{}")]
        )
        #expect(results.first?.1.isError == false)
    }
}

/// Thread-safe collector for progress callbacks (they arrive synchronously
/// from inside the registry's task group).
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(callID: String, message: String?)] = []
    func append(callID: String, message: String?) {
        lock.lock()
        defer { lock.unlock() }
        items.append((callID, message))
    }
    func snapshot() -> [(callID: String, message: String?)] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

struct ProgressEchoTool: ProgressReportingTool {
    let name: String
    let messages: [String?]
    func definition(for language: PromptLanguage) -> ToolDefinition {
        ToolDefinition(name: name, description: "emits progress", parametersSchema: .emptyObject)
    }
    func invoke(arguments: String, onProgress: @escaping ToolProgressHandler) async throws -> ToolOutput {
        for message in messages {
            onProgress(message)
        }
        return ToolOutput(outputJSON: #"{"ok":true}"#)
    }
}

struct EchoTool: Tool {
    let name: String
    func definition(for language: PromptLanguage) -> ToolDefinition {
        ToolDefinition(name: name, description: "echo", parametersSchema: .emptyObject)
    }
    func invoke(arguments: String) async throws -> ToolOutput {
        ToolOutput(outputJSON: arguments, display: .json)
    }
}

struct SlowEchoTool: Tool {
    let name: String
    let milliseconds: Int
    var preferredTimeout: Duration?
    init(name: String, milliseconds: Int, preferredTimeout: Duration? = nil) {
        self.name = name
        self.milliseconds = milliseconds
        self.preferredTimeout = preferredTimeout
    }
    func definition(for language: PromptLanguage) -> ToolDefinition {
        ToolDefinition(name: name, description: "slow echo", parametersSchema: .emptyObject)
    }
    func invoke(arguments: String) async throws -> ToolOutput {
        try await Task.sleep(for: .milliseconds(milliseconds))
        return ToolOutput(outputJSON: arguments)
    }
}
