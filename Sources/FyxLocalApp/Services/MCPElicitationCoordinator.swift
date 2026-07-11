// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import Observation
import FyxLocalCore
import FyxLocalMCP

/// Owns the queue of pending MCP elicitation prompts and the one currently
/// on screen. `MCPRegistry` installs a per-client handler that funnels
/// `elicitation/create` requests here; `RootView` presents a sheet driven by
/// `current`. One prompt at a time, FIFO — a second server (or a second
/// request from the same server) waits until the first sheet resolves.
@MainActor
@Observable
final class MCPElicitationCoordinator {
    struct Prompt: Identifiable, Sendable {
        let id: UUID
        let serverID: MCPServerID
        let serverDisplayName: String
        let message: String
        let form: ElicitationFormModel
    }

    private struct Pending {
        let prompt: Prompt
        let continuation: CheckedContinuation<MCPElicitationResult, Never>
    }

    /// The prompt whose sheet is on screen (nil = no sheet).
    private(set) var current: Prompt?
    private var currentContinuation: CheckedContinuation<MCPElicitationResult, Never>?
    private var queue: [Pending] = []

    /// Entry point for MCPRegistry-installed handlers (hops to MainActor).
    /// Suspends until the user resolves the prompt — which may be minutes;
    /// the caller's tool-call timeout keeps ticking meanwhile.
    func elicit(
        serverID: MCPServerID,
        serverDisplayName: String,
        request: MCPElicitationRequest
    ) async -> MCPElicitationResult {
        let prompt = Prompt(
            id: UUID(),
            serverID: serverID,
            serverDisplayName: serverDisplayName,
            message: request.message,
            form: ElicitationFormModel(fields: request.fields)
        )
        return await withCheckedContinuation { continuation in
            queue.append(Pending(prompt: prompt, continuation: continuation))
            promoteIfIdle()
        }
    }

    /// Called by the sheet's buttons (and Esc/dismiss via RootView's binding).
    func resolveCurrent(with result: MCPElicitationResult) {
        guard let continuation = currentContinuation else { return }
        current = nil
        currentContinuation = nil
        continuation.resume(returning: result)
        promoteIfIdle()
    }

    /// Server teardown (toggle-off, delete, reconnect): resolve everything
    /// belonging to it with `.cancel`, dismissing the sheet if it was
    /// frontmost. Called before the client shuts down so the cancel
    /// response can still be delivered.
    func cancelAll(forServer id: MCPServerID) {
        let stranded = queue.filter { $0.prompt.serverID == id }
        queue.removeAll { $0.prompt.serverID == id }
        for pending in stranded {
            pending.continuation.resume(returning: .cancel)
        }
        if current?.serverID == id {
            resolveCurrent(with: .cancel)
        }
    }

    /// Teardown safety net (app shutdown paths).
    func cancelAll() {
        let stranded = queue
        queue.removeAll()
        for pending in stranded {
            pending.continuation.resume(returning: .cancel)
        }
        if current != nil {
            resolveCurrent(with: .cancel)
        }
    }

    private func promoteIfIdle() {
        guard current == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        current = next.prompt
        currentContinuation = next.continuation
    }
}
