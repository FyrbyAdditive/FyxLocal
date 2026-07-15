// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalMCP

/// Collects task status updates delivered across actor hops.
private actor StatusCollector {
    private(set) var updates: [MCPTaskStatusUpdate] = []
    func add(_ update: MCPTaskStatusUpdate) { updates.append(update) }
}

private func researchTool(_ taskSupport: MCPTaskSupport = .required) -> MCPTool {
    MCPTool(
        name: "research",
        description: "simulated long-running research",
        inputSchema: .object(["type": .string("object")]),
        taskSupport: taskSupport
    )
}

/// Polls an async condition until it holds or the timeout elapses.
private func eventually(
    timeout: Duration = .seconds(5),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

@Suite("MCPClient tasks", .serialized)
struct MCPTaskTests {
    private func makeClientServer(
        tools: [MCPTool],
        taskScripts: [String: [MockMCPServer.TaskStep]] = [:],
        capabilities: JSONValue = MockMCPServer.defaultCapabilities,
        elicitationHandler: MCPElicitationHandler? = nil
    ) async throws -> (MCPClient, MockMCPServer) {
        let (clientTransport, serverTransport) = await makeInMemoryTransportPair()
        let server = MockMCPServer(
            transport: serverTransport,
            tools: tools,
            taskScripts: taskScripts,
            capabilities: capabilities
        )
        await server.start()
        let client = MCPClient(transport: clientTransport)
        if let elicitationHandler {
            await client.setElicitationHandler(elicitationHandler)
        }
        try await client.start()
        _ = try await client.listTools()
        return (client, server)
    }

    @Test func serverCapabilitiesParsedAtHandshake() async throws {
        let (client, server) = try await makeClientServer(tools: [])
        let caps = await client.serverCapabilities
        #expect(caps.supportsTaskAugmentedToolCalls)
        #expect(caps.supportsTaskCancel)
        #expect(caps.supportsTaskList)
        await client.shutdown()
        await server.shutdown()

        let (bareClient, bareServer) = try await makeClientServer(
            tools: [],
            capabilities: .object(["tools": .object([:])])
        )
        let bareCaps = await bareClient.serverCapabilities
        #expect(!bareCaps.supportsTaskAugmentedToolCalls)
        #expect(!bareCaps.supportsTaskCancel)
        #expect(!bareCaps.supportsTaskList)
        await bareClient.shutdown()
        await bareServer.shutdown()
    }

    @Test func listToolsParsesTaskSupport() async throws {
        let tools = [
            MCPTool(name: "a", description: "", inputSchema: .object([:]), taskSupport: .required),
            MCPTool(name: "b", description: "", inputSchema: .object([:]), taskSupport: .optional),
            MCPTool(name: "c", description: "", inputSchema: .object([:]), taskSupport: .forbidden),
        ]
        let (client, server) = try await makeClientServer(tools: tools)
        let listed = try await client.listTools()
        #expect(listed.map(\.taskSupport) == [.required, .optional, .forbidden])
        await client.shutdown()
        await server.shutdown()
    }

    @Test func requiredToolRunsAsTask() async throws {
        let collector = StatusCollector()
        let (client, server) = try await makeClientServer(
            tools: [researchTool()],
            taskScripts: ["research": [
                .working("Gathering sources..."),
                .working("Analyzing content..."),
                .completed("research report"),
            ]]
        )
        let result = try await client.callTool(
            name: "research",
            arguments: .object(["topic": .string("swift actors")]),
            onTaskStatus: { await collector.add($0) }
        )
        #expect(result.isError == false)
        #expect(result.content == [.text("research report")])

        let augmented = await server.sawTaskAugmentation["research"]
        #expect(augmented == true)
        let ttl = await server.lastRequestedTTL
        #expect(ttl == 1_200_000)
        // Regression guard: a tasks/result request carrying related-task
        // _meta is routed into the task's message queue by the reference TS
        // SDK and never answered — the request must stay meta-free.
        let meta = await server.lastResultRequestMeta
        #expect(meta == nil)

        let updates = await collector.updates
        #expect(updates.map(\.status) == [.working, .working, .completed])
        #expect(updates.map(\.statusMessage) == ["Gathering sources...", "Analyzing content...", nil])

        await client.shutdown()
        await server.shutdown()
    }

    @Test func duplicateStatusNotReemitted() async throws {
        let collector = StatusCollector()
        let (client, server) = try await makeClientServer(
            tools: [researchTool()],
            taskScripts: ["research": [
                .working("thinking"),
                .working("thinking"),
                .working("thinking"),
                .completed("done"),
            ]]
        )
        _ = try await client.callTool(
            name: "research",
            arguments: .object([:]),
            onTaskStatus: { await collector.add($0) }
        )
        let updates = await collector.updates
        #expect(updates.map(\.statusMessage) == ["thinking", nil])
        #expect(updates.map(\.status) == [.working, .completed])
        await client.shutdown()
        await server.shutdown()
    }

    @Test func plainToolNeverInvokesOnTaskStatus() async throws {
        let collector = StatusCollector()
        let (client, server) = try await makeClientServer(
            tools: [MCPTool(name: "echo", description: "", inputSchema: .object([:]))]
        )
        let result = try await client.callTool(
            name: "echo",
            arguments: .object(["msg": .string("hi")]),
            onTaskStatus: { await collector.add($0) }
        )
        #expect(result.content == [.text("echo: hi")])
        let updates = await collector.updates
        #expect(updates.isEmpty)
        let augmented = await server.sawTaskAugmentation["echo"]
        #expect(augmented == false)
        await client.shutdown()
        await server.shutdown()
    }

    @Test func optionalTaskSupportUsesTaskPath() async throws {
        // .optional tools take the task path when the server supports it —
        // they gain live progress + server-side cancellation for free.
        let (client, server) = try await makeClientServer(
            tools: [MCPTool(name: "echo", description: "", inputSchema: .object([:]), taskSupport: .optional)],
            taskScripts: ["echo": [.completed("echo: x")]]
        )
        let result = try await client.callTool(name: "echo", arguments: .object(["msg": .string("x")]))
        #expect(result.content == [.text("echo: x")])
        let augmented = await server.sawTaskAugmentation["echo"]
        #expect(augmented == true)
        await client.shutdown()
        await server.shutdown()
    }

    @Test func optionalTaskSupportFallsBackToPlainCallWithoutCapability() async throws {
        let (client, server) = try await makeClientServer(
            tools: [MCPTool(name: "echo", description: "", inputSchema: .object([:]), taskSupport: .optional)],
            capabilities: .object(["tools": .object([:])])
        )
        let result = try await client.callTool(name: "echo", arguments: .object(["msg": .string("x")]))
        #expect(result.content == [.text("echo: x")])
        let augmented = await server.sawTaskAugmentation["echo"]
        #expect(augmented == false)
        await client.shutdown()
        await server.shutdown()
    }

    @Test func noTasksCapabilityFallsBackToPlainCallAndSurfacesServerError() async throws {
        let (client, server) = try await makeClientServer(
            tools: [researchTool()],
            taskScripts: ["research": [.completed("unused")]],
            capabilities: .object(["tools": .object([:])])
        )
        do {
            _ = try await client.callTool(name: "research", arguments: .object([:]))
            Issue.record("expected throw")
        } catch let error as MCPClientError {
            guard case .rpcError(let code, let message) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(code == -32601)
            #expect(message.contains("requires task augmentation"))
            // The server's message must survive localizedDescription — this is
            // what the tool-runner catch-all renders.
            #expect(error.localizedDescription.contains("requires task augmentation"))
        }
        await client.shutdown()
        await server.shutdown()
    }

    @Test func failedTaskReturnsIsErrorResult() async throws {
        let (client, server) = try await makeClientServer(
            tools: [researchTool()],
            taskScripts: ["research": [
                .working(nil),
                .failed("API rate limit exceeded"),
            ]]
        )
        let result = try await client.callTool(name: "research", arguments: .object([:]))
        #expect(result.isError == true)
        #expect(result.content == [.text("API rate limit exceeded")])
        await client.shutdown()
        await server.shutdown()
    }

    @Test func taskExpirySurfacesServerMessage() async throws {
        let (client, server) = try await makeClientServer(
            tools: [researchTool()],
            taskScripts: ["research": [
                .working(nil),
                .expired,
            ]]
        )
        do {
            _ = try await client.callTool(name: "research", arguments: .object([:]))
            Issue.record("expected throw")
        } catch let MCPClientError.rpcError(code, message) {
            #expect(code == -32602)
            #expect(message.contains("expired"))
        }
        await client.shutdown()
        await server.shutdown()
    }

    @Test func cancellationMidPollSendsTasksCancel() async throws {
        let collector = StatusCollector()
        let (client, server) = try await makeClientServer(
            tools: [researchTool()],
            taskScripts: ["research": [.workingForever]]
        )
        let callTask = Task {
            try await client.callTool(
                name: "research",
                arguments: .object([:]),
                onTaskStatus: { await collector.add($0) }
            )
        }
        // Let the task get created and at least one poll happen.
        let sawUpdate = await eventually { await !collector.updates.isEmpty }
        #expect(sawUpdate)
        callTask.cancel()
        do {
            _ = try await callTask.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        let cancelled = await eventually { await server.cancelObserved }
        #expect(cancelled)
        await client.shutdown()
        await server.shutdown()
    }

    @Test func cancellationWithoutCancelCapabilitySkipsTasksCancel() async throws {
        let capabilities: JSONValue = .object([
            "tools": .object([:]),
            "tasks": .object([
                "requests": .object(["tools": .object(["call": .object([:])])]),
            ]),
        ])
        let (client, server) = try await makeClientServer(
            tools: [researchTool()],
            taskScripts: ["research": [.workingForever]],
            capabilities: capabilities
        )
        let callTask = Task {
            try await client.callTool(name: "research", arguments: .object([:]))
        }
        try await Task.sleep(for: .milliseconds(300))
        callTask.cancel()
        _ = try? await callTask.value
        // Grace period: a tasks/cancel would land within this window.
        try await Task.sleep(for: .milliseconds(300))
        let cancelled = await server.cancelObserved
        #expect(!cancelled)
        await client.shutdown()
        await server.shutdown()
    }

    @Test func inputRequiredElicitationAcceptFlow() async throws {
        let collector = StatusCollector()
        let elicitationSchema: JSONValue = .object([
            "message": .string("Which interpretation do you mean?"),
            "requestedSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "interpretation": .object([
                        "type": .string("string"),
                        "title": .string("Clarification"),
                        "oneOf": .array([
                            .object(["const": .string("technical"), "title": .string("Technical")]),
                            .object(["const": .string("historical"), "title": .string("Historical")]),
                        ]),
                    ]),
                ]),
                "required": .array([.string("interpretation")]),
            ]),
        ])
        let (client, server) = try await makeClientServer(
            tools: [researchTool()],
            taskScripts: ["research": [
                .working("Gathering sources..."),
                .inputRequired(elicitation: elicitationSchema),
                .working("Continuing..."),
                .completed("clarified report"),
            ]],
            elicitationHandler: { request in
                #expect(request.message == "Which interpretation do you mean?")
                #expect(request.relatedTaskId == "task-1")
                #expect(request.fields.count == 1)
                if let field = request.fields.first {
                    #expect(field.name == "interpretation")
                    #expect(field.isRequired)
                    if case .enumeration(let options, _) = field.kind {
                        #expect(options.map(\.value) == ["technical", "historical"])
                        #expect(options.map(\.title) == ["Technical", "Historical"])
                    } else {
                        Issue.record("expected enumeration kind, got \(field.kind)")
                    }
                }
                return .accept(.object(["interpretation": .string("technical")]))
            }
        )
        let result = try await client.callTool(
            name: "research",
            arguments: .object([:]),
            onTaskStatus: { await collector.add($0) }
        )
        #expect(result.content == [.text("clarified report")])

        let response = await server.lastElicitationResponse
        #expect(response?["action"]?.stringValue == "accept")
        #expect(response?["content"]?["interpretation"]?.stringValue == "technical")
        #expect(response?["_meta"]?["io.modelcontextprotocol/related-task"]?["taskId"]?.stringValue == "task-1")

        let updates = await collector.updates
        #expect(updates.map(\.status).contains(.inputRequired))

        await client.shutdown()
        await server.shutdown()
    }

    @Test func elicitationDeclineCompletesWithFallback() async throws {
        let elicitation: JSONValue = .object([
            "message": .string("Clarify?"),
            "requestedSchema": .object([
                "type": .string("object"),
                "properties": .object(["x": .object(["type": .string("string")])]),
            ]),
        ])
        let (client, server) = try await makeClientServer(
            tools: [researchTool()],
            taskScripts: ["research": [
                .working(nil),
                .inputRequired(elicitation: elicitation),
                .completed("fallback report"),
            ]],
            elicitationHandler: { _ in .decline }
        )
        let result = try await client.callTool(name: "research", arguments: .object([:]))
        #expect(result.content == [.text("fallback report")])
        let response = await server.lastElicitationResponse
        #expect(response?["action"]?.stringValue == "decline")
        #expect(response?["content"] == nil)
        await client.shutdown()
        await server.shutdown()
    }

    @Test func urlModeElicitationRejectedWithInvalidParams() async throws {
        let (client, server) = try await makeClientServer(
            tools: [],
            elicitationHandler: { _ in
                Issue.record("handler must not run for url mode")
                return .cancel
            }
        )
        let response = await server.sendServerRequest(method: "elicitation/create", params: .object([
            "mode": .string("url"),
            "message": .string("Open this"),
            "url": .string("https://example.com"),
            "elicitationId": .string("e-1"),
        ]))
        guard case .failure(let error) = response.result else {
            Issue.record("expected failure")
            return
        }
        #expect(error.code == -32602)
        await client.shutdown()
        await server.shutdown()
    }

    @Test func noHandlerMeansNoCapabilityAndMethodNotFound() async throws {
        let (client, server) = try await makeClientServer(tools: [])
        let initParams = await server.initializeParams
        #expect(initParams?["capabilities"]?["elicitation"] == nil)

        let response = await server.sendServerRequest(method: "elicitation/create", params: .object([
            "message": .string("anyone there?"),
            "requestedSchema": .object(["type": .string("object")]),
        ]))
        guard case .failure(let error) = response.result else {
            Issue.record("expected failure")
            return
        }
        #expect(error.code == -32601)
        await client.shutdown()
        await server.shutdown()
    }

    @Test func handlerPresenceDeclaresElicitationFormCapability() async throws {
        let (client, server) = try await makeClientServer(
            tools: [],
            elicitationHandler: { _ in .cancel }
        )
        let initParams = await server.initializeParams
        #expect(initParams?["capabilities"]?["elicitation"]?["form"] != nil)
        await client.shutdown()
        await server.shutdown()
    }

    @Test func unknownServerRequestGetsMethodNotFound() async throws {
        let (client, server) = try await makeClientServer(tools: [])
        let response = await server.sendServerRequest(
            method: "sampling/createMessage",
            params: .object([:])
        )
        guard case .failure(let error) = response.result else {
            Issue.record("expected failure")
            return
        }
        #expect(error.code == -32601)
        await client.shutdown()
        await server.shutdown()
    }

    @Test func plainCallIsCancellationResponsive() async throws {
        // Regression guard: a server that never answers must not hang the
        // caller past its cancellation (ToolRegistry relies on this for its
        // timeout to actually free the tool task).
        let (clientTransport, serverTransport) = await makeInMemoryTransportPair()
        // No server at all: frames go nowhere, so tools/call never resolves.
        _ = serverTransport
        let client = MCPClient(transport: clientTransport)
        let callTask = Task {
            try await client.callTool(name: "black-hole", arguments: .object([:]))
        }
        try await Task.sleep(for: .milliseconds(100))
        callTask.cancel()
        let outcome = await callTask.result
        guard case .failure(let error) = outcome else {
            Issue.record("expected failure")
            return
        }
        #expect(error is CancellationError)
        await client.shutdown()
    }
}
