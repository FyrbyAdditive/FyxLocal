// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalProviders
@testable import FyxLocalCore

@Suite("RequestPayloadBuilder")
struct RequestPayloadBuilderTests {
    let builder: RequestPayloadBuilder

    init() {
        // Use the heuristic tokenizer so tests are deterministic without
        // depending on the bundled BPE vocab files.
        builder = RequestPayloadBuilder(tokenizer: HeuristicTokenizer())
    }

    private func makeConversation(messages: [Message]) -> Conversation {
        Conversation(
            title: "test",
            settings: ChatSettings(model: "test", providerID: .init(rawValue: "test")),
            messages: messages
        )
    }

    @Test func assemblesUserAndAssistantTextOnly() {
        let convo = makeConversation(messages: [
            Message(role: .user, contentItems: [.text("hi")]),
            Message(role: .assistant, contentItems: [.text("hello")]),
        ])
        let items = builder.assemble(conversation: convo, draftUserText: "second")
        #expect(items.count == 3)
        guard case .message(let role, _) = items[0] else { Issue.record("bad first"); return }
        #expect(role == .user)
        guard case .message(let last, let content) = items.last,
              case .inputText(let text) = content.first
        else { Issue.record("bad last"); return }
        #expect(last == .user)
        #expect(text == "second")
    }

    @Test func includesToolCallsAndResultsInHistory() {
        // The bug fix: tool calls + results MUST appear in re-sent history
        // so the model can reference its own prior tool output.
        let convo = makeConversation(messages: [
            Message(role: .user, contentItems: [.text("search swift news")]),
            Message(role: .assistant, contentItems: [
                .toolCall(ToolCallRecord(id: "call_1", name: "web_search", argumentsJSON: #"{"q":"swift"}"#, status: .succeeded)),
                .toolResult(ToolResultRecord(callID: "call_1", outputJSON: "[results]")),
                .text("Here you go"),
            ]),
        ])
        let items = builder.assemble(conversation: convo, draftUserText: "")
        let kinds = items.map { item -> String in
            switch item {
            case .message: return "message"
            case .functionCall: return "functionCall"
            case .functionCallOutput: return "functionCallOutput"
            case .reasoning: return "reasoning"
            }
        }
        #expect(kinds.contains("functionCall"))
        #expect(kinds.contains("functionCallOutput"))
    }

    @Test func interleavedTextDoesNotSplitToolCallFromResult() {
        // Real-world shape (MiniMax/Claude): the assistant emits commentary
        // text BETWEEN a tool call and its result within one turn. The lowered
        // items must keep the call immediately followed by its result — no
        // message item between them — or OpenAI Chat Completions 400s with
        // "Message has tool role, but there was no previous assistant message
        // with a tool call".
        let convo = makeConversation(messages: [
            Message(role: .user, contentItems: [.text("q")]),
            Message(role: .assistant, contentItems: [
                .text("Let me search."),
                .toolCall(ToolCallRecord(id: "call_1", name: "web_search", argumentsJSON: "{}", status: .succeeded)),
                .text("Searching now…"),                                    // interleaved!
                .toolResult(ToolResultRecord(callID: "call_1", outputJSON: "[results]")),
                .text("Here is the answer."),
            ]),
        ])
        let items = builder.assemble(conversation: convo, draftUserText: "")
        // Find the functionCall and its functionCallOutput; assert nothing
        // sits between them.
        guard let callIdx = items.firstIndex(where: { if case .functionCall = $0 { return true }; return false }),
              let outIdx = items.firstIndex(where: { if case .functionCallOutput = $0 { return true }; return false }) else {
            Issue.record("missing call/output"); return
        }
        #expect(outIdx == callIdx + 1)  // result immediately follows the call
    }

    @Test func parallelCallsThenResultsStayGrouped() {
        // Two calls, then two results in one turn (Anthropic parallel tools).
        // All calls precede all results, contiguously.
        let convo = makeConversation(messages: [
            Message(role: .assistant, contentItems: [
                .text("Looking these up."),
                .toolCall(ToolCallRecord(id: "a", name: "web_search", argumentsJSON: "{}")),
                .toolCall(ToolCallRecord(id: "b", name: "web_search", argumentsJSON: "{}")),
                .toolResult(ToolResultRecord(callID: "a", outputJSON: "[a]")),
                .toolResult(ToolResultRecord(callID: "b", outputJSON: "[b]")),
                .text("Done."),
            ]),
        ])
        let items = builder.assemble(conversation: convo, draftUserText: "")
        let kinds = items.map { item -> String in
            switch item {
            case .message: return "msg"
            case .functionCall: return "call"
            case .functionCallOutput: return "out"
            case .reasoning: return "reasoning"
            }
        }
        // Expect: msg(leading text), call, call, out, out, msg(trailing text).
        #expect(kinds == ["msg", "call", "call", "out", "out", "msg"])
    }

    @Test func multipleToolRoundsInOneMessageCollapseToOneValidGroup() {
        // A single assistant message can hold TWO tool rounds (call/result,
        // text, call/result — real shape from a multi-step web-search turn).
        // They deliberately collapse into one contiguous group — all calls,
        // then all results, interleaved text merged after — which is wire-
        // valid on every provider (one tool_calls assistant + N tool messages)
        // at the cost of mild ordering distortion. Pinned here so the
        // trade-off stays deliberate.
        let convo = makeConversation(messages: [
            Message(role: .assistant, contentItems: [
                .text("Round one."),
                .toolCall(ToolCallRecord(id: "a", name: "web_search", argumentsJSON: "{}")),
                .toolResult(ToolResultRecord(callID: "a", outputJSON: "[a]")),
                .text("Round two."),
                .toolCall(ToolCallRecord(id: "b", name: "web_fetch", argumentsJSON: "{}")),
                .toolResult(ToolResultRecord(callID: "b", outputJSON: "[b]")),
                .text("Answer."),
            ]),
        ])
        let items = builder.assemble(conversation: convo, draftUserText: "")
        let kinds = items.map { item -> String in
            switch item {
            case .message: return "msg"
            case .functionCall: return "call"
            case .functionCallOutput: return "out"
            case .reasoning: return "reasoning"
            }
        }
        #expect(kinds == ["msg", "call", "call", "out", "out", "msg"])
        // Call/result pairing survives the regrouping.
        guard case .functionCall("a", _, _) = items[1],
              case .functionCall("b", _, _) = items[2],
              case .functionCallOutput("a", _) = items[3],
              case .functionCallOutput("b", _) = items[4] else {
            Issue.record("unexpected ordering: \(items)"); return
        }
    }

    @Test func reasoningSummariesAreStrippedFromPayload() {
        let convo = makeConversation(messages: [
            Message(role: .assistant, contentItems: [
                .reasoningSummary("I think therefore I am"),
                .text("Answer is 42"),
            ]),
        ])
        let items = builder.assemble(conversation: convo, draftUserText: "")
        // Only one message item containing the text, no reasoning leaked.
        #expect(items.count == 1)
        guard case .message(_, let content) = items[0],
              case .inputText(let text) = content.first
        else { Issue.record("bad"); return }
        #expect(text == "Answer is 42")
    }

    @Test func imagesLowerToPlaceholderForNonVisionModels() {
        // Switching a chat with image history to a text-only model must not
        // send image parts (hard 400: "is not a multi-modal model").
        let convo = makeConversation(messages: [
            Message(role: .user, contentItems: [
                .text("what is in this picture?"),
                .image(data: Data([0xFF, 0xD8, 0xFF]), mimeType: "image/jpeg"),
            ]),
            Message(role: .assistant, contentItems: [.text("A cat.")]),
        ])
        let items = builder.assemble(conversation: convo, draftUserText: "", includeImages: false)

        var sawImagePart = false
        var sawPlaceholder = false
        for item in items {
            guard case .message(_, let content) = item else { continue }
            for part in content {
                if case .inputImageData = part { sawImagePart = true }
                if case .inputImage = part { sawImagePart = true }
                if case .inputText(let t) = part, t.contains("does not accept image input") { sawPlaceholder = true }
            }
        }
        #expect(!sawImagePart)
        #expect(sawPlaceholder)
    }

    @Test func imagesPassThroughForVisionModels() {
        let convo = makeConversation(messages: [
            Message(role: .user, contentItems: [
                .image(data: Data([0xFF, 0xD8, 0xFF]), mimeType: "image/jpeg"),
            ]),
        ])
        // Default (includeImages: true) keeps the image part.
        let items = builder.assemble(conversation: convo, draftUserText: "")
        var sawImagePart = false
        for item in items {
            guard case .message(_, let content) = item else { continue }
            for part in content {
                if case .inputImageData = part { sawImagePart = true }
            }
        }
        #expect(sawImagePart)
    }

    @Test func imageOnlyMessageStillAppearsAsPlaceholder() {
        // An image-only user message must not vanish from history when the
        // target model is text-only — the turn structure stays intact.
        let convo = makeConversation(messages: [
            Message(role: .user, contentItems: [
                .image(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png"),
            ]),
            Message(role: .assistant, contentItems: [.text("Nice image.")]),
        ])
        let items = builder.assemble(conversation: convo, draftUserText: "", includeImages: false)
        guard case .message(let role, let content) = items.first,
              case .inputText(let t) = content.first else {
            Issue.record("expected placeholder user message, got \(items)"); return
        }
        #expect(role == .user)
        #expect(t.contains("image"))
        #expect(items.count == 2)
    }

    @Test func summaryPrefacesKeptHistory() {
        let convo = makeConversation(messages: [
            Message(role: .user, contentItems: [.text("old 1")]),
            Message(role: .user, contentItems: [.text("old 2")]),
            Message(role: .user, contentItems: [.text("recent 1")]),
            Message(role: .user, contentItems: [.text("recent 2")]),
        ])
        let items = builder.assemble(
            conversation: convo,
            draftUserText: "new draft",
            summary: "Earlier: user said hi twice",
            keepRange: 2..<4
        )
        // First item should be the summary system message.
        guard case .message(let firstRole, let firstContent) = items[0],
              case .inputText(let firstText) = firstContent.first
        else { Issue.record("expected system summary first"); return }
        #expect(firstRole == .system)
        #expect(firstText.contains("Summary of earlier conversation"))
        #expect(firstText.contains("Earlier: user said hi twice"))
        // Old 1 / Old 2 should NOT appear; recent 1, recent 2, draft should.
        let bodies = items.compactMap { item -> String? in
            if case .message(_, let content) = item,
               case .inputText(let t) = content.first { return t }
            return nil
        }
        #expect(bodies.contains(where: { $0 == "recent 1" }))
        #expect(bodies.contains(where: { $0 == "recent 2" }))
        #expect(bodies.contains(where: { $0 == "new draft" }))
        #expect(!bodies.contains(where: { $0 == "old 1" }))
    }

    @Test func projectionMatchesHeuristicCounts() {
        let convo = makeConversation(messages: [
            Message(role: .user, contentItems: [.text(String(repeating: "x", count: 80))]),
        ])
        let projection = builder.project(
            conversation: convo,
            draftUserText: String(repeating: "y", count: 40),
            instructions: String(repeating: "z", count: 20),
            toolDefinitions: []
        )
        // HeuristicTokenizer = max(1, chars/4); plus per-message envelope of 3.
        #expect(projection.draftTokens == 10)
        #expect(projection.systemTokens == 5)
        #expect(projection.historyTokens >= 20)
        #expect(projection.totalTokens > projection.draftTokens)
    }

    // MARK: - ClearOptions / threshold clearing

    /// Build a conversation with N (call, result) pairs each having a sizeable
    /// outputJSON. Used to drive the threshold-clear logic.
    private func conversationWithToolPairs(_ n: Int, resultBodySize: Int = 4000) -> Conversation {
        var messages: [Message] = []
        for i in 0..<n {
            let callID = "call_\(i)"
            messages.append(Message(role: .user, contentItems: [.text("ask \(i)")]))
            let bigResult = String(repeating: "x", count: resultBodySize)
            messages.append(Message(role: .assistant, contentItems: [
                .toolCall(ToolCallRecord(id: callID, name: "web_fetch", argumentsJSON: #"{"url":"https://e/\#(i)"}"#, status: .succeeded)),
                .toolResult(ToolResultRecord(callID: callID, outputJSON: bigResult, isError: false)),
                .text("done \(i)"),
            ]))
        }
        return makeConversation(messages: messages)
    }

    @Test func assembleWithoutClearOptionsIsUnchanged() {
        let convo = conversationWithToolPairs(3)
        let plain = builder.assemble(conversation: convo, draftUserText: "")
        let opted = builder.assemble(conversation: convo, draftUserText: "", clearOptions: nil)
        #expect(plain == opted)
    }

    @Test func assembleClearsOldestResultsAboveTrigger() {
        // 5 tool result pairs of 4000 chars each → at HeuristicTokenizer
        // 1 token/4 chars, ~1000 tokens per result, ~5000 history total.
        // Trigger at 3000 with keep=2 should clear the oldest 3.
        let convo = conversationWithToolPairs(5)
        let options = ClearOptions(triggerTokens: 3_000, keepRecentResults: 2, tokenizer: HeuristicTokenizer())
        let items = builder.assemble(
            conversation: convo,
            draftUserText: "",
            clearOptions: options
        )

        // Extract every functionCallOutput in order.
        let outputs: [(String, String)] = items.compactMap { item in
            if case .functionCallOutput(let id, let json) = item { return (id, json) }
            return nil
        }
        #expect(outputs.count == 5, "all 5 outputs are still present, just some cleared")

        // First three are placeholders, last two are verbatim.
        for (i, (callID, json)) in outputs.enumerated() {
            if i < 3 {
                #expect(json.contains("\"_fchat_cleared\":true"), "result \(i) should be cleared placeholder; got: \(json.prefix(200))")
                #expect(json.contains("\"call_id\":\"\(callID)\""), "placeholder should embed the call id")
                #expect(json.contains("\"original_tokens\""), "placeholder should embed original token count")
                #expect(json.contains("\"hint\""), "placeholder should embed re-call hint")
            } else {
                #expect(!json.contains("\"_fchat_cleared\""), "result \(i) should be verbatim")
                #expect(json.count > 100, "verbatim result should still be its original size")
            }
        }
    }

    @Test func assembleLeavesToolCallsUntouched() {
        // The matching `function_call` must always pass through. Only the
        // `function_call_output` is ever cleared.
        let convo = conversationWithToolPairs(4)
        let options = ClearOptions(triggerTokens: 100, keepRecentResults: 1, tokenizer: HeuristicTokenizer())
        let items = builder.assemble(conversation: convo, draftUserText: "", clearOptions: options)
        let calls: [String] = items.compactMap { item in
            if case .functionCall(let id, _, _) = item { return id }
            return nil
        }
        #expect(calls == ["call_0", "call_1", "call_2", "call_3"])
    }

    @Test func assembleClearingBelowTriggerDoesNothing() {
        let convo = conversationWithToolPairs(2, resultBodySize: 100)
        let options = ClearOptions(triggerTokens: 100_000, keepRecentResults: 2, tokenizer: HeuristicTokenizer())
        let items = builder.assemble(conversation: convo, draftUserText: "", clearOptions: options)
        for item in items {
            if case .functionCallOutput(_, let json) = item {
                #expect(!json.contains("\"_fchat_cleared\""))
            }
        }
    }

    @Test func assembleClearingIsIdempotent() {
        // Running the clearing pass twice over the same conversation shape
        // should not double-clear (placeholders already-cleared are detected
        // and skipped). This guards against accidental token inflation when
        // a turn re-assembles after a partial mutation.
        let convo = conversationWithToolPairs(4)
        let options = ClearOptions(triggerTokens: 500, keepRecentResults: 2, tokenizer: HeuristicTokenizer())
        let first = builder.assemble(conversation: convo, draftUserText: "", clearOptions: options)
        let second = builder.assemble(conversation: convo, draftUserText: "", clearOptions: options)
        // Counts of each kind should match exactly.
        let firstClearedCount = first.filter { item in
            if case .functionCallOutput(_, let json) = item { return json.contains("\"_fchat_cleared\"") }
            return false
        }.count
        let secondClearedCount = second.filter { item in
            if case .functionCallOutput(_, let json) = item { return json.contains("\"_fchat_cleared\"") }
            return false
        }.count
        #expect(firstClearedCount == secondClearedCount)
    }

    // MARK: - todayHeader

    @Test func assembleWithoutTodayHeaderIsUnchanged() {
        let convo = makeConversation(messages: [
            Message(role: .user, contentItems: [.text("hi")]),
        ])
        let plain = builder.assemble(conversation: convo, draftUserText: "")
        let opted = builder.assemble(conversation: convo, draftUserText: "", todayHeader: nil)
        #expect(plain == opted)
    }

    @Test func assemblePrependsTodayHeaderToLatestUserMessage() {
        let convo = makeConversation(messages: [
            Message(role: .user, contentItems: [.text("first")]),
            Message(role: .assistant, contentItems: [.text("reply")]),
            Message(role: .user, contentItems: [.text("second")]),
        ])
        let items = builder.assemble(
            conversation: convo,
            draftUserText: "",
            todayHeader: "[Today is Tue 2026-05-26]"
        )
        // Three message items total. Walk through to confirm the LAST user
        // message got the prefix and the FIRST user message did not.
        var userTexts: [String] = []
        for item in items {
            if case .message(let role, let content) = item, role == .user,
               case .inputText(let s) = content.first {
                userTexts.append(s)
            }
        }
        #expect(userTexts.count == 2)
        #expect(userTexts[0] == "first")
        #expect(userTexts[1] == "[Today is Tue 2026-05-26]\nsecond")
    }

    @Test func assembleTodayHeaderNoOpWhenNoUserMessage() {
        // No user message in history → header is silently ignored.
        let convo = makeConversation(messages: [
            Message(role: .assistant, contentItems: [.text("just a note")]),
        ])
        let items = builder.assemble(
            conversation: convo,
            draftUserText: "",
            todayHeader: "[Today is Tue 2026-05-26]"
        )
        // No item should contain the header anywhere.
        for item in items {
            if case .message(_, let content) = item {
                for part in content {
                    if case .inputText(let s) = part {
                        #expect(!s.contains("Today is"))
                    }
                }
            }
        }
    }

    @Test func assembleTodayHeaderEmptyStringIsTreatedAsNoop() {
        let convo = makeConversation(messages: [
            Message(role: .user, contentItems: [.text("hi")]),
        ])
        let plain = builder.assemble(conversation: convo, draftUserText: "")
        let empty = builder.assemble(conversation: convo, draftUserText: "", todayHeader: "")
        #expect(plain == empty)
    }

    @Test func assembleKeepRangeRespectsClearing() {
        // If keepRange already drops older history, the clearer sees fewer
        // items and only clears within the kept window.
        let convo = conversationWithToolPairs(5)
        let options = ClearOptions(triggerTokens: 200, keepRecentResults: 1, tokenizer: HeuristicTokenizer())
        // Skip the first 4 messages (2 pairs of user+assistant rows).
        let items = builder.assemble(
            conversation: convo,
            draftUserText: "",
            keepRange: 4..<convo.messages.count,
            clearOptions: options
        )
        let outputs = items.compactMap { item -> String? in
            if case .functionCallOutput(_, let json) = item { return json }
            return nil
        }
        // 3 results remain in the kept window; keep last 1 verbatim, clear 2.
        #expect(outputs.count == 3)
        #expect(outputs[0].contains("\"_fchat_cleared\""))
        #expect(outputs[1].contains("\"_fchat_cleared\""))
        #expect(!outputs[2].contains("\"_fchat_cleared\""))
    }
}
