// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FyxLocalCore
import FyxLocalMCP
@testable import FyxLocalApp

@MainActor
@Suite("MCPElicitationCoordinator")
struct MCPElicitationCoordinatorTests {
    private func request(_ message: String) -> MCPElicitationRequest {
        MCPElicitationRequest(
            message: message,
            requestedSchema: .object([:]),
            fields: [],
            relatedTaskId: nil
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func elicitPromotesToCurrentAndResolveReturns() async {
        let coordinator = MCPElicitationCoordinator()
        let serverID = MCPServerID(rawValue: UUID().uuidString)
        let task = Task {
            await coordinator.elicit(serverID: serverID, serverDisplayName: "Everything", request: request("q1"))
        }
        await waitUntil { coordinator.current != nil }
        #expect(coordinator.current?.message == "q1")
        #expect(coordinator.current?.serverDisplayName == "Everything")

        coordinator.resolveCurrent(with: .accept(.object(["a": .bool(true)])))
        let result = await task.value
        #expect(result.action == .accept)
        #expect(result.content?["a"] == .bool(true))
        #expect(coordinator.current == nil)
    }

    @Test func concurrentElicitationsSerializeFIFO() async {
        let coordinator = MCPElicitationCoordinator()
        let serverID = MCPServerID(rawValue: UUID().uuidString)
        let first = Task {
            await coordinator.elicit(serverID: serverID, serverDisplayName: "S", request: request("first"))
        }
        await waitUntil { coordinator.current != nil }
        let second = Task {
            await coordinator.elicit(serverID: serverID, serverDisplayName: "S", request: request("second"))
        }
        // Give the second a chance to enqueue; it must not displace the first.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(coordinator.current?.message == "first")

        coordinator.resolveCurrent(with: .decline)
        let firstResult = await first.value
        #expect(firstResult.action == .decline)

        await waitUntil { coordinator.current?.message == "second" }
        #expect(coordinator.current?.message == "second")
        coordinator.resolveCurrent(with: .cancel)
        let secondResult = await second.value
        #expect(secondResult.action == .cancel)
    }

    @Test func cancelAllForServerResolvesOnlyThatServer() async {
        let coordinator = MCPElicitationCoordinator()
        let serverA = MCPServerID(rawValue: "server-a")
        let serverB = MCPServerID(rawValue: "server-b")
        let fromA = Task {
            await coordinator.elicit(serverID: serverA, serverDisplayName: "A", request: request("from A"))
        }
        await waitUntil { coordinator.current != nil }
        let fromB = Task {
            await coordinator.elicit(serverID: serverB, serverDisplayName: "B", request: request("from B"))
        }
        try? await Task.sleep(for: .milliseconds(50))

        coordinator.cancelAll(forServer: serverA)
        let resultA = await fromA.value
        #expect(resultA.action == .cancel)

        // B's prompt is promoted, not cancelled.
        await waitUntil { coordinator.current?.message == "from B" }
        #expect(coordinator.current?.message == "from B")
        coordinator.resolveCurrent(with: .decline)
        let resultB = await fromB.value
        #expect(resultB.action == .decline)
    }

    @Test func cancelAllResolvesEverything() async {
        let coordinator = MCPElicitationCoordinator()
        let serverID = MCPServerID(rawValue: "s")
        let first = Task {
            await coordinator.elicit(serverID: serverID, serverDisplayName: "S", request: request("1"))
        }
        await waitUntil { coordinator.current != nil }
        let second = Task {
            await coordinator.elicit(serverID: serverID, serverDisplayName: "S", request: request("2"))
        }
        try? await Task.sleep(for: .milliseconds(50))

        coordinator.cancelAll()
        let r1 = await first.value
        let r2 = await second.value
        #expect(r1.action == .cancel)
        #expect(r2.action == .cancel)
        #expect(coordinator.current == nil)
    }
}
