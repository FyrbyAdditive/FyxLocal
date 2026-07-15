// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalProviders
@testable import FyxLocalCore

@Suite("Anthropic prompt caching")
struct AnthropicPromptCachingTests {
    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// All (message, block) positions carrying a cache_control marker.
    private func markerPositions(_ json: [String: Any]) -> [[Int]] {
        guard let messages = json["messages"] as? [[String: Any]] else { return [] }
        var positions: [[Int]] = []
        for (m, message) in messages.enumerated() {
            for (b, block) in ((message["content"] as? [[String: Any]]) ?? []).enumerated() {
                if block["cache_control"] != nil { positions.append([m, b]) }
            }
        }
        return positions
    }

    private func request(tools: Bool = true, extraHistory: [InputItem] = []) -> ChatRequest {
        var input: [InputItem] = [
            .message(role: .user, content: [.inputText("first question")]),
            .message(role: .assistant, content: [.outputText("first answer")]),
        ]
        input.append(contentsOf: extraHistory)
        input.append(.message(role: .user, content: [.inputText("Today is Tuesday.\n\nlatest question")]))
        return ChatRequest(
            model: "claude-opus-4-8",
            input: input,
            instructions: "You are helpful.",
            tools: tools ? [ToolDefinition(name: "get_time", description: "now", parametersSchema: .emptyObject)] : []
        )
    }

    @Test func disabledEmitsNoMarkersAndStringSystem() throws {
        let json = try object(try AnthropicMessagesRequestEncoder().encode(request(), stream: true))
        #expect(markerPositions(json).isEmpty)
        #expect(json["system"] as? String == "You are helpful.")
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.allSatisfy { $0["cache_control"] == nil })
    }

    @Test func enabledMarksToolsSystemAndHistory() throws {
        let encoder = AnthropicMessagesRequestEncoder(promptCaching: true)
        let json = try object(try encoder.encode(request(), stream: true))

        // Tools: marker on the last tool only.
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.last?["cache_control"] != nil)

        // System: array-of-blocks form with a marker.
        let system = try #require(json["system"] as? [[String: Any]])
        #expect(system.first?["cache_control"] != nil)
        #expect(system.first?["text"] as? String == "You are helpful.")

        // History: marker before the final user message + marker at the end.
        // Input encodes to: [user first] [assistant answer] [user latest].
        // Last eligible before final text user = assistant answer (msg 1);
        // last eligible overall = final user text (msg 2).
        let positions = markerPositions(json)
        #expect(positions.count == 2)
        #expect(positions.contains([1, 0]))
        #expect(positions.contains([2, 0]))
    }

    @Test func totalMarkersNeverExceedFour() throws {
        let encoder = AnthropicMessagesRequestEncoder(promptCaching: true)
        let json = try object(try encoder.encode(request(), stream: true))
        let historyMarkers = markerPositions(json).count
        let toolMarkers = ((json["tools"] as? [[String: Any]]) ?? []).filter { $0["cache_control"] != nil }.count
        let systemMarkers = ((json["system"] as? [[String: Any]]) ?? []).filter { $0["cache_control"] != nil }.count
        #expect(historyMarkers + toolMarkers + systemMarkers <= 4)
    }

    @Test func shortHistoryDedupesToSingleMarker() throws {
        // Only one user message: "before final user" finds nothing; the
        // overall-last marker is the only history marker.
        let encoder = AnthropicMessagesRequestEncoder(promptCaching: true)
        let request = ChatRequest(
            model: "m",
            input: [.message(role: .user, content: [.inputText("hi")])],
            instructions: "sys"
        )
        let json = try object(try encoder.encode(request, stream: true))
        #expect(markerPositions(json).count == 1)
    }

    @Test func thinkingBlocksAreNeverMarked() throws {
        // History tail: signed thinking + tool_use (assistant), tool_result
        // (user). The final-overall marker must land on the tool_result and
        // the before-final-user marker must skip the thinking block.
        let encoder = AnthropicMessagesRequestEncoder(promptCaching: true)
        let history: [InputItem] = [
            .message(role: .assistant, content: [.thinking(text: "pondering", signature: "sig")]),
            .functionCall(callID: "c1", name: "get_time", argumentsJSON: "{}"),
            .functionCallOutput(callID: "c1", outputJSON: #"{"time":"now"}"#),
        ]
        let json = try object(try encoder.encode(request(extraHistory: history), stream: true))
        let messages = try #require(json["messages"] as? [[String: Any]])
        for position in markerPositions(json) {
            let block = (messages[position[0]]["content"] as? [[String: Any]])?[position[1]]
            let type = block?["type"] as? String
            #expect(type != "thinking" && type != "redacted_thinking")
        }
    }

    @Test func noToolsEmitsNoToolMarker() throws {
        let encoder = AnthropicMessagesRequestEncoder(promptCaching: true)
        let json = try object(try encoder.encode(request(tools: false), stream: true))
        #expect(json["tools"] == nil)
        #expect((json["system"] as? [[String: Any]]) != nil)
    }
}

@Suite("Anthropic cache usage decoding")
struct AnthropicCacheUsageDecodingTests {
    @Test func cacheFieldsFlowIntoUsage() throws {
        let d = AnthropicMessagesEventDecoder()
        _ = try d.decode(SSEEvent(
            event: "message_start",
            data: #"{"type":"message_start","message":{"id":"m","usage":{"input_tokens":100,"cache_read_input_tokens":80,"cache_creation_input_tokens":15}}}"#
        ))
        let event = try d.decode(SSEEvent(
            event: "message_delta",
            data: #"{"type":"message_delta","usage":{"output_tokens":7}}"#
        ))
        guard case .usage(let usage) = event else { Issue.record("expected .usage"); return }
        #expect(usage.inputTokens == 100)
        #expect(usage.outputTokens == 7)
        #expect(usage.cachedInputTokens == 80)
        #expect(usage.cacheCreationInputTokens == 15)
    }

    @Test func deltaUsageOverridesMessageStart() throws {
        let d = AnthropicMessagesEventDecoder()
        _ = try d.decode(SSEEvent(
            event: "message_start",
            data: #"{"type":"message_start","message":{"id":"m","usage":{"input_tokens":1}}}"#
        ))
        let event = try d.decode(SSEEvent(
            event: "message_delta",
            data: #"{"type":"message_delta","usage":{"output_tokens":3,"input_tokens":42,"cache_read_input_tokens":40}}"#
        ))
        guard case .usage(let usage) = event else { Issue.record("expected .usage"); return }
        #expect(usage.inputTokens == 42)
        #expect(usage.cachedInputTokens == 40)
        #expect(usage.cacheCreationInputTokens == nil)
    }

    @Test func absentCacheFieldsDecodeToNil() throws {
        let d = AnthropicMessagesEventDecoder()
        _ = try d.decode(SSEEvent(
            event: "message_start",
            data: #"{"type":"message_start","message":{"id":"m","usage":{"input_tokens":9}}}"#
        ))
        let event = try d.decode(SSEEvent(
            event: "message_delta",
            data: #"{"type":"message_delta","usage":{"output_tokens":2}}"#
        ))
        guard case .usage(let usage) = event else { Issue.record("expected .usage"); return }
        #expect(usage.cachedInputTokens == nil)
        #expect(usage.cacheCreationInputTokens == nil)
    }
}

@Suite("Prompt caching model back-compat")
struct PromptCachingBackCompatTests {
    @Test func legacyProviderRecordDecodesWithNilPromptCaching() throws {
        let legacy = #"{"id":"p1","displayName":"Test","baseURL":"https://api.anthropic.com/v1","apiKind":"anthropic-messages"}"#
        let record = try JSONDecoder().decode(ProviderRecord.self, from: Data(legacy.utf8))
        #expect(record.promptCaching == nil)
        #expect(record.promptCachingResolved)
    }

    @Test func promptCachingResolvedDefaultsByKind() {
        var record = ProviderRecord(
            id: ProviderID(rawValue: "p"),
            displayName: "x",
            baseURL: URL(string: "https://example.com")!,
            apiKind: .anthropicMessages
        )
        #expect(record.promptCachingResolved)
        record.promptCaching = false
        #expect(!record.promptCachingResolved)
        record.apiKind = .openAIResponses
        record.promptCaching = nil
        #expect(!record.promptCachingResolved)
    }

    @Test func legacyUsageInfoDecodesWithoutCacheCreation() throws {
        let legacy = #"{"inputTokens":10,"outputTokens":5}"#
        let usage = try JSONDecoder().decode(UsageInfo.self, from: Data(legacy.utf8))
        #expect(usage.cacheCreationInputTokens == nil)
        #expect(usage.inputTokens == 10)
    }
}
