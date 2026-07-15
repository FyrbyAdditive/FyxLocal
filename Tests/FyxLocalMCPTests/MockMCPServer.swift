// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
@testable import FyxLocalMCP

/// Minimal in-process MCP server that knows just enough of the spec to drive
/// `MCPClient` end-to-end through the in-memory transport pair — including
/// the 2025-11-25 tasks extension and form-mode elicitation.
///
/// Task-capable tools are driven by a `TaskStep` script: the CreateTaskResult
/// reflects step 0, and each `tasks/get` advances one step (sticking at the
/// last). `tasks/result` blocks until the script reaches a terminal step,
/// sending `elicitation/create` when it encounters an `.inputRequired` step.
actor MockMCPServer {
    enum TaskStep: Sendable {
        case working(String?)
        /// Params for the elicitation/create request (mock adds related-task _meta).
        case inputRequired(elicitation: JSONValue)
        case completed(String)
        case failed(String)
        /// Never progresses; for cancellation tests.
        case workingForever
        /// tasks/get answers -32602, simulating server-side expiry.
        case expired
    }

    private struct TaskRecord {
        let toolName: String
        var steps: [TaskStep]
        var index: Int = 0
        var cancelled = false
        var elicitationSent = false

        var currentStep: TaskStep { steps[min(index, steps.count - 1)] }
        var isTerminal: Bool {
            if cancelled { return true }
            switch currentStep {
            case .completed, .failed, .expired: return true
            case .working, .workingForever, .inputRequired: return false
            }
        }
    }

    static let defaultCapabilities: JSONValue = .object([
        "tools": .object(["listChanged": .bool(false)]),
        "tasks": .object([
            "list": .object([:]),
            "cancel": .object([:]),
            "requests": .object(["tools": .object(["call": .object([:])])]),
        ]),
    ])

    private let transport: any MCPTransport
    private let tools: [MCPTool]
    private let capabilities: JSONValue
    private let taskScripts: [String: [TaskStep]]
    private let resources: [MCPResource]
    /// uri → raw `contents` array for resources/read.
    private let resourceContents: [String: JSONValue]
    private let prompts: [MCPPrompt]
    /// prompt name → raw prompts/get result object.
    private let promptResults: [String: JSONValue]
    /// When set, list methods emit pages of this size with `nextCursor`
    /// (cursor = stringified start index). When `cursorLoop` is true, every
    /// page reports a nextCursor pointing at itself — simulates a hostile
    /// server with a circular cursor chain.
    private let listPageSize: Int?
    private let cursorLoop: Bool
    private var task: Task<Void, Never>?

    private var taskRecords: [String: TaskRecord] = [:]
    private var nextTaskID = 0
    private var nextServerRequestID = 0
    private var pendingServerRequests: [JSONRPCID: CheckedContinuation<JSONRPCResponse, Never>] = [:]

    // Recorded for test assertions.
    private(set) var initializeParams: JSONValue?
    /// Whether the most recent tools/call for a given tool carried `task` augmentation.
    private(set) var sawTaskAugmentation: [String: Bool] = [:]
    /// Arguments of the most recent tools/call, as received on the wire.
    private(set) var lastToolCallArguments: JSONValue?
    private(set) var lastRequestedTTL: Int?
    private(set) var lastResultRequestMeta: JSONValue?
    private(set) var lastElicitationResponse: JSONValue?
    private(set) var cancelObserved = false
    private(set) var lastPromptArguments: JSONValue?

    init(
        transport: any MCPTransport,
        tools: [MCPTool],
        taskScripts: [String: [TaskStep]] = [:],
        capabilities: JSONValue = MockMCPServer.defaultCapabilities,
        listPageSize: Int? = nil,
        cursorLoop: Bool = false,
        resources: [MCPResource] = [],
        resourceContents: [String: JSONValue] = [:],
        prompts: [MCPPrompt] = [],
        promptResults: [String: JSONValue] = [:]
    ) {
        self.transport = transport
        self.tools = tools
        self.taskScripts = taskScripts
        self.capabilities = capabilities
        self.listPageSize = listPageSize
        self.cursorLoop = cursorLoop
        self.resources = resources
        self.resourceContents = resourceContents
        self.prompts = prompts
        self.promptResults = promptResults
    }

    func start() {
        task = Task { await self.run() }
    }

    func shutdown() async {
        task?.cancel()
        await transport.close()
    }

    /// Emits a tools list_changed notification to the client.
    func sendToolsListChanged() async {
        try? await transport.send(.notification(.init(method: "notifications/tools/list_changed")))
    }

    /// Sends a server→client request and awaits the client's response.
    /// Used directly by tests (unknown methods, standalone elicitation) and
    /// by the input_required flow.
    func sendServerRequest(method: String, params: JSONValue?) async -> JSONRPCResponse {
        nextServerRequestID += 1
        let id = JSONRPCID.string("srv-\(nextServerRequestID)")
        return await withCheckedContinuation { cont in
            pendingServerRequests[id] = cont
            Task { try? await transport.send(.request(.init(id: id, method: method, params: params))) }
        }
    }

    private func run() async {
        do {
            for try await frame in transport.incoming() {
                switch frame {
                case .request(let req):
                    // Handlers may block (tasks/result) or round-trip an
                    // elicitation — never stall the receive loop on them.
                    Task {
                        let response = await self.handle(req)
                        try? await self.transport.send(.response(response))
                    }
                case .response(let response):
                    if let cont = pendingServerRequests.removeValue(forKey: response.id) {
                        cont.resume(returning: response)
                    }
                case .notification:
                    break
                }
            }
        } catch {
            // transport closed; exit
        }
    }

    private func handle(_ req: JSONRPCRequest) async -> JSONRPCResponse {
        switch req.method {
        case "initialize":
            initializeParams = req.params
            let value: JSONValue = .object([
                "protocolVersion": .string("2025-11-25"),
                "capabilities": capabilities,
                "serverInfo": .object([
                    "name": .string("mock-server"),
                    "version": .string("1.0.0"),
                ]),
            ])
            return JSONRPCResponse(id: req.id, result: .success(value))

        case "tools/list":
            let entries: [JSONValue] = tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "inputSchema": tool.inputSchema,
                    "execution": .object(["taskSupport": .string(tool.taskSupport.rawValue)]),
                ])
            }
            return JSONRPCResponse(id: req.id, result: .success(
                paged(entries, key: "tools", cursor: req.params?["cursor"]?.stringValue)
            ))

        case "tools/call":
            return handleToolCall(req)

        case "resources/list":
            let entries: [JSONValue] = resources.map { resource in
                var object: [String: JSONValue] = [
                    "uri": .string(resource.uri),
                    "name": .string(resource.name),
                ]
                if let title = resource.title { object["title"] = .string(title) }
                if let description = resource.description { object["description"] = .string(description) }
                if let mimeType = resource.mimeType { object["mimeType"] = .string(mimeType) }
                if let size = resource.size { object["size"] = .int(size) }
                return .object(object)
            }
            return JSONRPCResponse(id: req.id, result: .success(
                paged(entries, key: "resources", cursor: req.params?["cursor"]?.stringValue)
            ))

        case "resources/read":
            guard let uri = req.params?["uri"]?.stringValue, let contents = resourceContents[uri] else {
                return JSONRPCResponse(id: req.id, result: .failure(.init(code: -32002, message: "Resource not found")))
            }
            return JSONRPCResponse(id: req.id, result: .success(.object(["contents": contents])))

        case "prompts/list":
            let entries: [JSONValue] = prompts.map { prompt in
                var object: [String: JSONValue] = ["name": .string(prompt.name)]
                if let title = prompt.title { object["title"] = .string(title) }
                if let description = prompt.description { object["description"] = .string(description) }
                if !prompt.arguments.isEmpty {
                    object["arguments"] = .array(prompt.arguments.map { argument in
                        var argObject: [String: JSONValue] = [
                            "name": .string(argument.name),
                            "required": .bool(argument.required),
                        ]
                        if let description = argument.description { argObject["description"] = .string(description) }
                        return .object(argObject)
                    })
                }
                return .object(object)
            }
            return JSONRPCResponse(id: req.id, result: .success(
                paged(entries, key: "prompts", cursor: req.params?["cursor"]?.stringValue)
            ))

        case "prompts/get":
            let name = req.params?["name"]?.stringValue ?? ""
            lastPromptArguments = req.params?["arguments"]
            guard let result = promptResults[name] else {
                return JSONRPCResponse(id: req.id, result: .failure(.init(code: -32602, message: "Unknown prompt: \(name)")))
            }
            return JSONRPCResponse(id: req.id, result: .success(result))

        case "tasks/get":
            return handleTasksGet(req)

        case "tasks/result":
            return await handleTasksResult(req)

        case "tasks/cancel":
            return handleTasksCancel(req)

        default:
            return JSONRPCResponse(id: req.id, result: .failure(.methodNotFound))
        }
    }

    // MARK: - tools/call

    private func handleToolCall(_ req: JSONRPCRequest) -> JSONRPCResponse {
        let name = req.params?["name"]?.stringValue ?? ""
        guard let tool = tools.first(where: { $0.name == name }) else {
            return JSONRPCResponse(id: req.id, result: .failure(.init(code: -32601, message: "tool missing: \(name)")))
        }
        let augmented = req.params?["task"] != nil
        sawTaskAugmentation[name] = augmented
        lastToolCallArguments = req.params?["arguments"]

        if augmented {
            lastRequestedTTL = req.params?["task"]?["ttl"]?.intValue
            guard let script = taskScripts[name], tool.taskSupport != .forbidden else {
                return JSONRPCResponse(id: req.id, result: .failure(.init(
                    code: -32601, message: "Tool \(name) does not support task augmentation"
                )))
            }
            nextTaskID += 1
            let taskId = "task-\(nextTaskID)"
            let record = TaskRecord(toolName: name, steps: script)
            taskRecords[taskId] = record
            return JSONRPCResponse(id: req.id, result: .success(.object([
                "task": taskJSON(taskId: taskId, record: record)
            ])))
        }

        if tool.taskSupport == .required {
            return JSONRPCResponse(id: req.id, result: .failure(.init(
                code: -32601,
                message: "Tool \(name) requires task augmentation (taskSupport: 'required')"
            )))
        }

        // Plain call: echo behaviour, as the original embedded mock did.
        let args = req.params?["arguments"] ?? .object([:])
        let echoed = args["msg"]?.stringValue ?? ""
        let value: JSONValue = .object([
            "content": .array([
                .object(["type": .string("text"), "text": .string("echo: \(echoed)")])
            ]),
            "isError": .bool(false),
        ])
        return JSONRPCResponse(id: req.id, result: .success(value))
    }

    // MARK: - tasks/*

    private func handleTasksGet(_ req: JSONRPCRequest) -> JSONRPCResponse {
        guard let taskId = req.params?["taskId"]?.stringValue, var record = taskRecords[taskId] else {
            return JSONRPCResponse(id: req.id, result: .failure(.init(code: -32602, message: "Task not found")))
        }
        if !record.cancelled, !record.isTerminal, record.index < record.steps.count - 1 {
            record.index += 1
            taskRecords[taskId] = record
        }
        if case .expired = record.currentStep {
            return JSONRPCResponse(id: req.id, result: .failure(.init(
                code: -32602, message: "Task not found or expired"
            )))
        }
        return JSONRPCResponse(id: req.id, result: .success(taskJSON(taskId: taskId, record: record)))
    }

    private func handleTasksResult(_ req: JSONRPCRequest) async -> JSONRPCResponse {
        guard let taskId = req.params?["taskId"]?.stringValue, taskRecords[taskId] != nil else {
            return JSONRPCResponse(id: req.id, result: .failure(.init(code: -32602, message: "Task not found")))
        }
        lastResultRequestMeta = req.params?["_meta"]

        // Block until terminal, driving the elicitation round-trip when the
        // script calls for input.
        while true {
            guard var record = taskRecords[taskId] else {
                return JSONRPCResponse(id: req.id, result: .failure(.init(code: -32602, message: "Task not found")))
            }
            if record.cancelled {
                return JSONRPCResponse(id: req.id, result: .failure(.init(code: -32800, message: "Task cancelled")))
            }
            switch record.currentStep {
            case .completed(let text):
                return JSONRPCResponse(id: req.id, result: .success(.object([
                    "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                    "isError": .bool(false),
                    "_meta": relatedTaskMeta(taskId),
                ])))
            case .failed(let text):
                return JSONRPCResponse(id: req.id, result: .success(.object([
                    "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                    "isError": .bool(true),
                    "_meta": relatedTaskMeta(taskId),
                ])))
            case .expired:
                return JSONRPCResponse(id: req.id, result: .failure(.init(
                    code: -32602, message: "Task not found or expired"
                )))
            case .inputRequired(let elicitation) where !record.elicitationSent:
                record.elicitationSent = true
                taskRecords[taskId] = record
                var params = elicitation.objectValue ?? [:]
                params["_meta"] = relatedTaskMeta(taskId)
                let response = await sendServerRequest(method: "elicitation/create", params: .object(params))
                if case .success(let value) = response.result {
                    lastElicitationResponse = value
                } else if case .failure(let e) = response.result {
                    lastElicitationResponse = .object([
                        "error": .object(["code": .int(e.code), "message": .string(e.message)])
                    ])
                }
                // Input received (or refused): move past the input step.
                if var advanced = taskRecords[taskId] {
                    advanced.index = min(advanced.index + 1, advanced.steps.count - 1)
                    taskRecords[taskId] = advanced
                }
            case .working:
                // A real server progresses its task in the background while
                // the requestor is blocked in tasks/result (the client does
                // not poll tasks/get during the blocking fetch). Self-advance
                // scripted .working steps so post-elicitation scripts reach
                // their terminal step.
                try? await Task.sleep(for: .milliseconds(5))
                if var advanced = taskRecords[taskId], !advanced.cancelled,
                   advanced.index < advanced.steps.count - 1 {
                    advanced.index += 1
                    taskRecords[taskId] = advanced
                }
            case .workingForever, .inputRequired:
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    private func handleTasksCancel(_ req: JSONRPCRequest) -> JSONRPCResponse {
        guard let taskId = req.params?["taskId"]?.stringValue, var record = taskRecords[taskId] else {
            return JSONRPCResponse(id: req.id, result: .failure(.init(code: -32602, message: "Task not found")))
        }
        guard !record.isTerminal else {
            return JSONRPCResponse(id: req.id, result: .failure(.init(
                code: -32602, message: "Cannot cancel task: already in terminal status"
            )))
        }
        record.cancelled = true
        taskRecords[taskId] = record
        cancelObserved = true
        return JSONRPCResponse(id: req.id, result: .success(taskJSON(taskId: taskId, record: record)))
    }

    // MARK: - Helpers

    private func taskJSON(taskId: String, record: TaskRecord) -> JSONValue {
        let status: String
        var statusMessage: String?
        if record.cancelled {
            status = "cancelled"
        } else {
            switch record.currentStep {
            case .working(let message):
                status = "working"
                statusMessage = message
            case .workingForever:
                status = "working"
            case .inputRequired:
                status = "input_required"
                statusMessage = "Waiting for input"
            case .completed:
                status = "completed"
            case .failed(let text):
                status = "failed"
                statusMessage = text
            case .expired:
                status = "working"
            }
        }
        var object: [String: JSONValue] = [
            "taskId": .string(taskId),
            "status": .string(status),
            "createdAt": .string("2026-01-01T00:00:00Z"),
            "lastUpdatedAt": .string("2026-01-01T00:00:00Z"),
            "ttl": .int(lastRequestedTTL ?? 60_000),
            "pollInterval": .int(10),
        ]
        if let statusMessage { object["statusMessage"] = .string(statusMessage) }
        return .object(object)
    }

    private func relatedTaskMeta(_ taskId: String) -> JSONValue {
        .object(["io.modelcontextprotocol/related-task": .object(["taskId": .string(taskId)])])
    }

    /// Slices `entries` per `listPageSize`; whole list in one page when unset.
    private func paged(_ entries: [JSONValue], key: String, cursor: String?) -> JSONValue {
        guard let pageSize = listPageSize else {
            return .object([key: .array(entries)])
        }
        let start = cursor.flatMap(Int.init) ?? 0
        if cursorLoop {
            // Same page forever, always promising more.
            let page = Array(entries.prefix(pageSize))
            return .object([key: .array(page), "nextCursor": .string(String(start))])
        }
        let end = min(start + pageSize, entries.count)
        let page = (start < end) ? Array(entries[start..<end]) : []
        var object: [String: JSONValue] = [key: .array(page)]
        if end < entries.count {
            object["nextCursor"] = .string(String(end))
        }
        return .object(object)
    }
}
