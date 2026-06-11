// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalCore

public protocol LLMProvider: Sendable {
    var id: ProviderID { get }
    func listModels() async throws -> [ModelInfo]
    func streamResponse(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error>
    func embed(_ texts: [String], model: String) async throws -> [[Float]]
}

public enum ProviderError: Error, Equatable, Sendable, LocalizedError {
    case missingAPIKey
    case httpStatus(Int, body: String)
    case malformedResponse(String)
    case streamTerminatedUnexpectedly
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Provider has no API key configured. Open Settings → Providers and save one to the Keychain."
        case .httpStatus(let code, let body):
            return Self.describeHTTPError(code: code, body: body)
        case .malformedResponse(let detail):
            return "Malformed response from server: \(detail)"
        case .streamTerminatedUnexpectedly:
            return "The streaming connection ended before the response completed."
        case .unsupported(let detail):
            return "Operation not supported by this provider: \(detail)"
        }
    }

    /// Turn an HTTP error body into a readable sentence. OpenAI- and
    /// Anthropic-style APIs both wrap errors as `{"error":{"message":…}}`, so
    /// we surface that message instead of dumping raw JSON into the chat (e.g.
    /// "`temperature` is deprecated for this model." rather than the full
    /// `{"type":"error","error":{…},"request_id":…}` blob). Falls back to a
    /// trimmed raw excerpt when the body isn't the expected shape.
    static func describeHTTPError(code: Int, body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = parsedErrorMessage(from: trimmed) {
            // A trailing period reads naturally after the prefix; avoid a double.
            return "Request rejected (HTTP \(code)): \(message)"
        }
        let excerpt = trimmed.count > 600 ? String(trimmed.prefix(600)) + "…" : trimmed
        return "HTTP \(code): \(excerpt.isEmpty ? "<empty body>" : excerpt)"
    }

    /// Extract `error.message` (string) from a JSON error body. Tolerates the
    /// message living at `error.message` (OpenAI / Anthropic) or a top-level
    /// `message`. Returns nil if the body isn't JSON or carries no message.
    static func parsedErrorMessage(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let error = root["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return message
        }
        // Some gateways return a plain `{"message": "..."}` or `{"error": "..."}`.
        if let message = root["message"] as? String, !message.isEmpty { return message }
        if let error = root["error"] as? String, !error.isEmpty { return error }
        return nil
    }
}
