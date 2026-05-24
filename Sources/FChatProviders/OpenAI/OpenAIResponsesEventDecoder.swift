import Foundation
import FChatCore

/// Decodes raw SSE events from the OpenAI Responses API into `StreamEvent`.
/// Tolerant of unknown event types (they are dropped silently).
public struct OpenAIResponsesEventDecoder {
    public init() {}

    public func decode(_ sse: SSEEvent) throws -> StreamEvent? {
        let typeName = sse.event ?? extractType(from: sse.data) ?? ""
        guard let data = sse.data.data(using: .utf8) else { return nil }

        switch typeName {
        case "response.created":
            let payload = try JSONDecoder().decode(ResponseCreatedPayload.self, from: data)
            return .responseStarted(id: payload.response.id)

        case "response.output_text.delta":
            let payload = try JSONDecoder().decode(OutputTextDeltaPayload.self, from: data)
            return .textDelta(itemID: payload.item_id, delta: payload.delta)

        case "response.output_text.done":
            let payload = try JSONDecoder().decode(OutputTextDonePayload.self, from: data)
            return .textCompleted(itemID: payload.item_id, fullText: payload.text)

        case "response.reasoning_summary_text.delta",
             "response.reasoning_summary.delta":
            let payload = try JSONDecoder().decode(ReasoningSummaryDeltaPayload.self, from: data)
            return .reasoningSummaryDelta(itemID: payload.item_id, delta: payload.delta)

        case "response.reasoning.encrypted_content":
            let payload = try JSONDecoder().decode(ReasoningEncryptedPayload.self, from: data)
            return .reasoningEncryptedContent(itemID: payload.item_id, encrypted: payload.encrypted_content)

        case "response.output_item.added":
            let payload = try JSONDecoder().decode(OutputItemAddedPayload.self, from: data)
            if payload.item.type == "function_call",
               let name = payload.item.name,
               let callID = payload.item.call_id {
                return .toolCallStarted(itemID: payload.item.id ?? UUID().uuidString, callID: callID, name: name)
            }
            return nil

        case "response.function_call_arguments.delta":
            let payload = try JSONDecoder().decode(FunctionCallArgsDeltaPayload.self, from: data)
            return .toolCallArgumentsDelta(itemID: payload.item_id, callID: payload.call_id ?? payload.item_id, delta: payload.delta)

        case "response.function_call_arguments.done":
            let payload = try JSONDecoder().decode(FunctionCallArgsDonePayload.self, from: data)
            return .toolCallCompleted(
                itemID: payload.item_id,
                callID: payload.call_id ?? payload.item_id,
                name: payload.name ?? "",
                arguments: payload.arguments
            )

        case "response.completed":
            let payload = try JSONDecoder().decode(ResponseCompletedPayload.self, from: data)
            return .usage(payload.response.usage?.toUsageInfo() ?? UsageInfo(inputTokens: 0, outputTokens: 0))

        case "response.failed", "response.error":
            let payload = try JSONDecoder().decode(ResponseErrorPayload.self, from: data)
            return .responseError(message: payload.error.message, code: payload.error.code)

        default:
            return nil
        }
    }

    /// Some servers omit the SSE `event:` field and only emit `data: { "type": "..." }`.
    /// We pre-peek the type when that happens.
    private func extractType(from json: String) -> String? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(TypeOnly.self, from: data))?.type
    }

    private struct TypeOnly: Decodable { let type: String? }

    // MARK: - Payloads

    private struct ResponseCreatedPayload: Decodable {
        struct R: Decodable { let id: String }
        let response: R
    }

    private struct OutputTextDeltaPayload: Decodable {
        let item_id: String
        let delta: String
    }

    private struct OutputTextDonePayload: Decodable {
        let item_id: String
        let text: String
    }

    private struct ReasoningSummaryDeltaPayload: Decodable {
        let item_id: String
        let delta: String
    }

    private struct ReasoningEncryptedPayload: Decodable {
        let item_id: String
        let encrypted_content: String
    }

    private struct OutputItemAddedPayload: Decodable {
        struct Item: Decodable {
            let id: String?
            let type: String
            let name: String?
            let call_id: String?
        }
        let item: Item
    }

    private struct FunctionCallArgsDeltaPayload: Decodable {
        let item_id: String
        let call_id: String?
        let delta: String
    }

    private struct FunctionCallArgsDonePayload: Decodable {
        let item_id: String
        let call_id: String?
        let name: String?
        let arguments: String
    }

    private struct ResponseCompletedPayload: Decodable {
        struct R: Decodable {
            struct U: Decodable {
                let input_tokens: Int?
                let output_tokens: Int?
                let reasoning_tokens: Int?
                let input_tokens_details: Details?
                struct Details: Decodable { let cached_tokens: Int? }

                func toUsageInfo() -> UsageInfo {
                    UsageInfo(
                        inputTokens: input_tokens ?? 0,
                        outputTokens: output_tokens ?? 0,
                        reasoningTokens: reasoning_tokens,
                        cachedInputTokens: input_tokens_details?.cached_tokens
                    )
                }
            }
            let usage: U?
        }
        let response: R
    }

    private struct ResponseErrorPayload: Decodable {
        struct E: Decodable {
            let message: String
            let code: String?
        }
        let error: E
    }
}
