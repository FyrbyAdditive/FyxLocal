// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalMCP

@Suite("MCP resources & prompts", .serialized)
struct MCPResourcesPromptsTests {
    private func makeClientServer(
        resources: [MCPResource] = [],
        resourceContents: [String: JSONValue] = [:],
        prompts: [MCPPrompt] = [],
        promptResults: [String: JSONValue] = [:],
        capabilities: JSONValue? = nil,
        listPageSize: Int? = nil
    ) async throws -> (MCPClient, MockMCPServer) {
        let (clientTransport, serverTransport) = await makeInMemoryTransportPair()
        let caps = capabilities ?? .object([
            "tools": .object([:]),
            "resources": .object(["listChanged": .bool(true)]),
            "prompts": .object(["listChanged": .bool(true)]),
        ])
        let server = MockMCPServer(
            transport: serverTransport,
            tools: [],
            capabilities: caps,
            listPageSize: listPageSize,
            resources: resources,
            resourceContents: resourceContents,
            prompts: prompts,
            promptResults: promptResults
        )
        await server.start()
        let client = MCPClient(transport: clientTransport)
        try await client.start()
        return (client, server)
    }

    @Test func capabilitiesParseResourcesAndPrompts() async throws {
        let (client, server) = try await makeClientServer()
        let caps = await client.serverCapabilities
        #expect(caps.supportsResources)
        #expect(caps.resourcesListChanged)
        #expect(caps.supportsPrompts)
        #expect(caps.promptsListChanged)
        await client.shutdown()
        await server.shutdown()

        let (bare, bareServer) = try await makeClientServer(capabilities: .object(["tools": .object([:])]))
        let bareCaps = await bare.serverCapabilities
        #expect(!bareCaps.supportsResources)
        #expect(!bareCaps.supportsPrompts)
        await bare.shutdown()
        await bareServer.shutdown()
    }

    @Test func listResourcesDecodesFieldsAndPaginates() async throws {
        let resources = (0..<5).map {
            MCPResource(
                uri: "file:///doc\($0).txt",
                name: "doc\($0)",
                title: "Document \($0)",
                description: "test resource",
                mimeType: "text/plain",
                size: 100 + $0
            )
        }
        let (client, server) = try await makeClientServer(resources: resources, listPageSize: 2)
        let listed = try await client.listResources()
        #expect(listed.count == 5)
        #expect(listed[0].uri == "file:///doc0.txt")
        #expect(listed[0].title == "Document 0")
        #expect(listed[0].mimeType == "text/plain")
        #expect(listed[4].size == 104)
        await client.shutdown()
        await server.shutdown()
    }

    @Test func readResourceDecodesTextAndBlob() async throws {
        let contents: JSONValue = .array([
            .object(["uri": .string("res://a"), "mimeType": .string("text/plain"), "text": .string("hello")]),
            .object(["uri": .string("res://b"), "mimeType": .string("image/png"), "blob": .string("QUJD")]),
        ])
        let (client, server) = try await makeClientServer(resourceContents: ["res://a": contents])
        let read = try await client.readResource(uri: "res://a")
        #expect(read.count == 2)
        guard case .text(let uri, let mime, let text) = read[0] else {
            Issue.record("expected text contents")
            return
        }
        #expect(uri == "res://a")
        #expect(mime == "text/plain")
        #expect(text == "hello")
        guard case .blob(_, let blobMime, let base64) = read[1] else {
            Issue.record("expected blob contents")
            return
        }
        #expect(blobMime == "image/png")
        #expect(base64 == "QUJD")
        await client.shutdown()
        await server.shutdown()
    }

    @Test func oversizedResourceThrowsResourceTooLarge() async throws {
        let huge = String(repeating: "x", count: 4_000_001)
        let contents: JSONValue = .array([
            .object(["uri": .string("res://big"), "text": .string(huge)]),
        ])
        let (client, server) = try await makeClientServer(resourceContents: ["res://big": contents])
        do {
            _ = try await client.readResource(uri: "res://big")
            Issue.record("expected throw")
        } catch let MCPClientError.resourceTooLarge(uri) {
            #expect(uri == "res://big")
        }
        await client.shutdown()
        await server.shutdown()
    }

    @Test func missingResourceSurfacesServerError() async throws {
        let (client, server) = try await makeClientServer()
        do {
            _ = try await client.readResource(uri: "res://nope")
            Issue.record("expected throw")
        } catch let MCPClientError.rpcError(code, _) {
            #expect(code == -32002)
        }
        await client.shutdown()
        await server.shutdown()
    }

    @Test func listPromptsDecodesArguments() async throws {
        let prompts = [
            MCPPrompt(
                name: "summarize",
                title: "Summarize",
                description: "Summarize a document",
                arguments: [
                    MCPPromptArgument(name: "style", description: "tone to use", required: true),
                    MCPPromptArgument(name: "length", required: false),
                ]
            ),
            MCPPrompt(name: "plain"),
        ]
        let (client, server) = try await makeClientServer(prompts: prompts)
        let listed = try await client.listPrompts()
        #expect(listed.count == 2)
        #expect(listed[0].name == "summarize")
        #expect(listed[0].arguments.map(\.name) == ["style", "length"])
        #expect(listed[0].arguments.map(\.required) == [true, false])
        #expect(listed[1].arguments.isEmpty)
        await client.shutdown()
        await server.shutdown()
    }

    @Test func getPromptSendsArgumentsAndDecodesMessages() async throws {
        let result: JSONValue = .object([
            "description": .string("A summary prompt"),
            "messages": .array([
                .object([
                    "role": .string("user"),
                    "content": .object(["type": .string("text"), "text": .string("Summarize crisply.")]),
                ]),
                .object([
                    "role": .string("user"),
                    "content": .object([
                        "type": .string("resource"),
                        "resource": .object(["uri": .string("res://ctx"), "text": .string("context body")]),
                    ]),
                ]),
            ]),
        ])
        let (client, server) = try await makeClientServer(promptResults: ["summarize": result])
        let prompt = try await client.getPrompt(name: "summarize", arguments: ["style": "crisp"])
        #expect(prompt.description == "A summary prompt")
        #expect(prompt.messages.count == 2)
        guard case .text(let text) = prompt.messages[0].content else {
            Issue.record("expected text content")
            return
        }
        #expect(text == "Summarize crisply.")
        guard case .resource(let uri, let resourceText) = prompt.messages[1].content else {
            Issue.record("expected resource content")
            return
        }
        #expect(uri == "res://ctx")
        #expect(resourceText == "context body")

        let sent = await server.lastPromptArguments
        #expect(sent?["style"]?.stringValue == "crisp")

        await client.shutdown()
        await server.shutdown()
    }

    @Test func unknownPromptSurfacesServerError() async throws {
        let (client, server) = try await makeClientServer()
        do {
            _ = try await client.getPrompt(name: "missing", arguments: [:])
            Issue.record("expected throw")
        } catch let MCPClientError.rpcError(code, message) {
            #expect(code == -32602)
            #expect(message.contains("missing"))
        }
        await client.shutdown()
        await server.shutdown()
    }
}
