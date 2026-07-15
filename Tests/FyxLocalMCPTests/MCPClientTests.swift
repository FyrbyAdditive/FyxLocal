// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalMCP

@Suite("MCPClient", .serialized)
struct MCPClientTests {
    @Test func initializeHandshakeAndListTools() async throws {
        let (clientTransport, serverTransport) = await makeInMemoryTransportPair()
        let server = MockMCPServer(transport: serverTransport, tools: [
            MCPTool(name: "echo", description: "echoes input", inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["msg": .object(["type": .string("string")])]),
                "required": .array([.string("msg")]),
            ]))
        ])
        await server.start()

        let client = MCPClient(transport: clientTransport, clientName: "test-client", clientVersion: "0.0.1", protocolVersion: "2025-11-25")
        try await client.start()

        let info = await client.serverInfo
        #expect(info?.name == "mock-server")
        #expect(info?.protocolVersion == "2025-11-25")

        let tools = try await client.listTools()
        #expect(tools.map(\.name) == ["echo"])
        #expect(tools.first?.description == "echoes input")

        let result = try await client.callTool(name: "echo", arguments: .object(["msg": .string("hello")]))
        #expect(result.isError == false)
        guard case .text(let echoed) = result.content.first else { Issue.record("expected text content"); return }
        #expect(echoed == "echo: hello")

        await client.shutdown()
        await server.shutdown()
    }

    @Test func toolCallErrorPropagates() async throws {
        let (ct, st) = await makeInMemoryTransportPair()
        let server = MockMCPServer(transport: st, tools: [])
        await server.start()
        let client = MCPClient(transport: ct)
        try await client.start()

        do {
            _ = try await client.callTool(name: "missing", arguments: .object([:]))
            Issue.record("expected throw")
        } catch let MCPClientError.rpcError(code, message) {
            #expect(code == -32601)
            #expect(message.contains("missing"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        await client.shutdown()
        await server.shutdown()
    }
}

@Suite("MCPClient pagination", .serialized)
struct MCPClientPaginationTests {
    private func tools(_ count: Int) -> [MCPTool] {
        (0..<count).map {
            MCPTool(name: String(format: "tool%03d", $0), description: "", inputSchema: .object([:]))
        }
    }

    @Test func multiPageToolListJoinsPagesInOrder() async throws {
        let (ct, st) = await makeInMemoryTransportPair()
        let server = MockMCPServer(transport: st, tools: tools(7), listPageSize: 3)
        await server.start()
        let client = MCPClient(transport: ct)
        try await client.start()

        let listed = try await client.listTools()
        #expect(listed.count == 7)
        #expect(listed.map(\.name) == (0..<7).map { String(format: "tool%03d", $0) })

        await client.shutdown()
        await server.shutdown()
    }

    @Test func circularCursorChainIsBounded() async throws {
        // A hostile server that always promises another page must not spin
        // the client forever — the page cap ends the loop.
        let (ct, st) = await makeInMemoryTransportPair()
        let server = MockMCPServer(transport: st, tools: tools(5), listPageSize: 5, cursorLoop: true)
        await server.start()
        let client = MCPClient(transport: ct)
        try await client.start()

        let listed = try await client.listTools()
        // 50-page cap × 5 tools/page = 250 items delivered, all duplicates of
        // the same 5 — what matters is that the call RETURNED.
        #expect(listed.count <= 250)

        await client.shutdown()
        await server.shutdown()
    }
}

// MockMCPServer lives in MockMCPServer.swift (extended with tasks +
// elicitation support for the 2025-11-25 spec tests).
