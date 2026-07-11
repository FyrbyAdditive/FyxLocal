// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FyxLocalCore
import FyxLocalTools
@testable import FyxLocalMCP

@Suite("MCPToolAdapter")
struct MCPToolAdapterTests {
    @Test func namespacedNameAndDefinitionForward() async throws {
        let (ct, st) = await makeInMemoryTransportPair()
        let server = MockMCPServer(transport: st, tools: [
            MCPTool(name: "search", description: "search the docs", inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["q": .object(["type": .string("string")])]),
                "required": .array([.string("q")]),
            ]))
        ])
        await server.start()
        let client = MCPClient(transport: ct)
        try await client.start()

        let tools = try await client.listTools()
        let adapter = MCPToolAdapter(serverName: "docs", mcpTool: tools[0], client: client)
        #expect(adapter.name == "mcp__docs__search")
        let def = adapter.definition(for: .english)
        #expect(def.description == "search the docs")
        #expect(def.parametersSchema.raw.contains(#""type":"object""#))

        await client.shutdown()
        await server.shutdown()
    }

    @Test func invokeForwardsArgumentsAndDeliversText() async throws {
        let (ct, st) = await makeInMemoryTransportPair()
        let server = MockMCPServer(transport: st, tools: [
            MCPTool(name: "echo", description: "x", inputSchema: .object([:]))
        ])
        await server.start()
        let client = MCPClient(transport: ct)
        try await client.start()

        let tools = try await client.listTools()
        let adapter = MCPToolAdapter(serverName: "srv", mcpTool: tools[0], client: client)
        let output = try await adapter.invoke(arguments: #"{"msg":"world"}"#)
        #expect(output.isError == false)
        #expect(output.outputJSON.contains("echo: world"))

        await client.shutdown()
        await server.shutdown()
    }

    @Test func sloppyModelArgumentsAreCoercedToSchema() async throws {
        let (ct, st) = await makeInMemoryTransportPair()
        let server = MockMCPServer(transport: st, tools: [
            MCPTool(name: "echo", description: "", inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "msg": .object(["type": .string("string")]),
                    "loud": .object(["type": .string("boolean")]),
                ]),
            ]))
        ])
        await server.start()
        let client = MCPClient(transport: ct)
        try await client.start()

        let tools = try await client.listTools()
        let adapter = MCPToolAdapter(serverName: "srv", mcpTool: tools[0], client: client)
        // The model's sloppy JSON: number for a string field, 1 for a boolean.
        _ = try await adapter.invoke(arguments: #"{"msg":2026,"loud":1}"#)
        let received = await server.lastToolCallArguments
        #expect(received?["msg"] == .string("2026"))
        #expect(received?["loud"] == .bool(true))

        await client.shutdown()
        await server.shutdown()
    }

    @Test func preferredTimeoutOnlyForTaskRequiredTools() async throws {
        let (ct, st) = await makeInMemoryTransportPair()
        let server = MockMCPServer(transport: st, tools: [])
        await server.start()
        let client = MCPClient(transport: ct)
        try await client.start()

        func adapter(_ taskSupport: MCPTaskSupport) -> MCPToolAdapter {
            MCPToolAdapter(
                serverName: "srv",
                mcpTool: MCPTool(name: "t", description: "", inputSchema: .object([:]), taskSupport: taskSupport),
                client: client
            )
        }
        #expect(adapter(.required).preferredTimeout == .seconds(600))
        #expect(adapter(.optional).preferredTimeout == nil)
        #expect(adapter(.forbidden).preferredTimeout == nil)

        await client.shutdown()
        await server.shutdown()
    }

    @Test func taskStatusForwardsToProgressHandler() async throws {
        let (ct, st) = await makeInMemoryTransportPair()
        let server = MockMCPServer(
            transport: st,
            tools: [MCPTool(name: "research", description: "", inputSchema: .object([:]), taskSupport: .required)],
            taskScripts: ["research": [
                .working("Stage one"),
                .completed("done"),
            ]]
        )
        await server.start()
        let client = MCPClient(transport: ct)
        try await client.start()

        let tools = try await client.listTools()
        let adapter = MCPToolAdapter(serverName: "srv", mcpTool: tools[0], client: client)
        let box = AdapterProgressBox()
        let output = try await adapter.invoke(arguments: "{}", onProgress: { box.append($0) })
        #expect(output.isError == false)
        #expect(output.outputJSON.contains("done"))
        // Terminal statuses are filtered; only the working stage surfaces.
        #expect(box.snapshot() == ["Stage one"])

        await client.shutdown()
        await server.shutdown()
    }
}

/// Progress callbacks are synchronous and may arrive off-actor.
private final class AdapterProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String?] = []
    func append(_ message: String?) {
        lock.lock()
        defer { lock.unlock() }
        items.append(message)
    }
    func snapshot() -> [String?] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
