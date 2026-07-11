// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// A tool's declared task-execution mode from `tools/list`
/// (`execution.taskSupport`, MCP 2025-11-25). Absent or unrecognised
/// values map to `.forbidden` — i.e. today's plain-call behaviour.
public enum MCPTaskSupport: String, Sendable, Hashable {
    case required
    case optional
    case forbidden
}

/// Task lifecycle status. Unknown strings from the (experimental) spec are
/// treated as `.working` by the snapshot parser so a newer server doesn't
/// hard-fail us; the client-side deadline still bounds the call.
public enum MCPTaskState: String, Sendable, Hashable {
    case working
    case inputRequired = "input_required"
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .working, .inputRequired: return false
        }
    }
}

/// One observed change of a task's status/statusMessage, delivered to the
/// `onTaskStatus` handler of a task-augmented `callTool`. Consecutive
/// duplicates are suppressed by the client.
public struct MCPTaskStatusUpdate: Sendable, Hashable {
    public let taskId: String
    public let status: MCPTaskState
    public let statusMessage: String?

    public init(taskId: String, status: MCPTaskState, statusMessage: String? = nil) {
        self.taskId = taskId
        self.status = status
        self.statusMessage = statusMessage
    }
}

public typealias MCPTaskStatusHandler = @Sendable (MCPTaskStatusUpdate) async -> Void

/// Parsed Task object from a `CreateTaskResult`, `tasks/get` response, or
/// `notifications/tasks/status` payload. The server is untrusted: bound the
/// taskId and statusMessage sizes.
struct MCPTaskSnapshot: Sendable, Hashable {
    var taskId: String
    var status: MCPTaskState
    var statusMessage: String?
    var pollIntervalMS: Int?

    static let maxTaskIdLen = 512
    static let maxStatusMessageLen = 4_096

    static func parse(_ value: JSONValue) throws -> MCPTaskSnapshot {
        guard let taskId = value["taskId"]?.stringValue,
              !taskId.isEmpty, taskId.count <= maxTaskIdLen else {
            throw MCPClientError.unexpectedResult
        }
        let statusRaw = value["status"]?.stringValue ?? ""
        let status = MCPTaskState(rawValue: statusRaw) ?? .working
        let message = value["statusMessage"]?.stringValue.map { String($0.prefix(maxStatusMessageLen)) }
        return MCPTaskSnapshot(
            taskId: taskId,
            status: status,
            statusMessage: message,
            pollIntervalMS: value["pollInterval"]?.intValue
        )
    }
}
