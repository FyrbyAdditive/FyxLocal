// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalProviders

@Suite("ProviderError HTTP messages")
struct ProviderErrorTests {
    private func describe(_ code: Int, _ body: String) -> String {
        ProviderError.httpStatus(code, body: body).errorDescription ?? ""
    }

    @Test func anthropicErrorBodySurfacesCleanMessage() {
        // The exact 400 the deprecated-temperature case produces.
        let body = #"{"type":"error","error":{"type":"invalid_request_error","message":"`temperature` is deprecated for this model."},"request_id":"req_011Cbx"}"#
        let msg = describe(400, body)
        #expect(msg == "Request rejected (HTTP 400): `temperature` is deprecated for this model.")
        // No raw JSON leaks through.
        #expect(!msg.contains("request_id"))
        #expect(!msg.contains("invalid_request_error"))
    }

    @Test func openAIStyleErrorBodySurfacesMessage() {
        let body = #"{"error":{"message":"You exceeded your current quota.","type":"insufficient_quota","code":null}}"#
        #expect(describe(429, body) == "Request rejected (HTTP 429): You exceeded your current quota.")
    }

    @Test func plainMessageBodyHandled() {
        #expect(describe(400, #"{"message":"bad model"}"#) == "Request rejected (HTTP 400): bad model")
        #expect(describe(404, #"{"error":"not found"}"#) == "Request rejected (HTTP 404): not found")
    }

    @Test func nonJSONBodyFallsBackToExcerpt() {
        // A bare HTML/text 502 from a proxy isn't JSON — keep the old raw form.
        #expect(describe(502, "Bad Gateway") == "HTTP 502: Bad Gateway")
    }

    @Test func emptyBodyHandled() {
        #expect(describe(500, "") == "HTTP 500: <empty body>")
    }

    @Test func longNonJSONBodyTruncates() {
        let body = String(repeating: "x", count: 800)
        let msg = describe(500, body)
        #expect(msg.hasPrefix("HTTP 500: "))
        #expect(msg.hasSuffix("…"))
        #expect(msg.count < 700)
    }
}
