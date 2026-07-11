// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalMCP

/// End-to-end verification against the real reference server
/// (`npx -y @modelcontextprotocol/server-everything`, stdio) — the exact
/// setup that produced the original "-32601 requires task augmentation"
/// failure. Needs node/npx and network for the first npx fetch, so it is
/// opt-in: FCHAT_MCP_E2E=1 swift test --filter MCPEverythingE2ETests
@Suite(
    "MCP everything-server E2E",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["FCHAT_MCP_E2E"] == "1")
)
struct MCPEverythingE2ETests {
    private actor StatusLog {
        private(set) var updates: [MCPTaskStatusUpdate] = []
        func add(_ update: MCPTaskStatusUpdate) { updates.append(update) }
    }

    private func startClient(
        elicitationHandler: MCPElicitationHandler? = nil
    ) async throws -> (MCPClient, StdioMCPTransport) {
        let transport = StdioMCPTransport(
            command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-everything"]
        )
        try await transport.start()
        let client = MCPClient(transport: transport)
        if let elicitationHandler {
            await client.setElicitationHandler(elicitationHandler)
        }
        try await client.start()
        return (client, transport)
    }

    @Test(.timeLimit(.minutes(2))) func simulateResearchQueryRunsAsTask() async throws {
        let (client, _) = try await startClient()
        defer { Task { await client.shutdown() } }

        let caps = await client.serverCapabilities
        #expect(caps.supportsTaskAugmentedToolCalls, "everything server should declare tasks.requests.tools.call")

        let tools = try await client.listTools()
        let research = tools.first { $0.name == "simulate-research-query" }
        #expect(research?.taskSupport == .required, "reference tool should declare taskSupport required")

        let log = StatusLog()
        let result = try await client.callTool(
            name: "simulate-research-query",
            arguments: .object(["topic": .string("the best model for DGX spark july 2026")]),
            onTaskStatus: { await log.add($0) }
        )
        #expect(result.isError == false)
        guard case .text(let text)? = result.content.first else {
            Issue.record("expected text content, got \(result.content)")
            return
        }
        #expect(!text.isEmpty)

        let updates = await log.updates
        #expect(updates.contains { $0.status == .working })
        #expect(updates.contains { $0.statusMessage?.contains("Gathering") == true })

        await client.shutdown()
    }

    @Test(.timeLimit(.minutes(2))) func ambiguousQueryElicitsAndAccepts() async throws {
        let picked = "technical"
        let (client, _) = try await startClient(elicitationHandler: { request in
            // The reference tool sends one enum field named "interpretation".
            guard let field = request.fields.first(where: { $0.name == "interpretation" }),
                  case .enumeration(let options, _) = field.kind,
                  let first = options.first else {
                return .decline
            }
            _ = first
            return .accept(.object(["interpretation": .string(picked)]))
        })
        defer { Task { await client.shutdown() } }
        _ = try await client.listTools()

        let log = StatusLog()
        let result = try await client.callTool(
            name: "simulate-research-query",
            arguments: .object([
                "topic": .string("swift actors"),
                "ambiguous": .bool(true),
            ]),
            onTaskStatus: { await log.add($0) }
        )
        #expect(result.isError == false)
        guard case .text(let text)? = result.content.first else {
            Issue.record("expected text content, got \(result.content)")
            return
        }
        // The report should reflect the clarified interpretation path (the
        // tool embeds the clarification in its output).
        #expect(!text.isEmpty)

        let updates = await log.updates
        #expect(updates.contains { $0.status == .inputRequired })

        await client.shutdown()
    }

    @Test(.timeLimit(.minutes(2))) func plainToolsStillWork() async throws {
        let (client, _) = try await startClient()
        defer { Task { await client.shutdown() } }
        _ = try await client.listTools()

        let result = try await client.callTool(
            name: "echo",
            arguments: .object(["message": .string("hello e2e")])
        )
        #expect(result.isError == false)
        guard case .text(let text)? = result.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(text.contains("hello e2e"))
        await client.shutdown()
    }
}
