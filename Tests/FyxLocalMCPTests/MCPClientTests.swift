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

// MockMCPServer lives in MockMCPServer.swift (extended with tasks +
// elicitation support for the 2025-11-25 spec tests).
