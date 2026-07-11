// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalCore

/// `progressMessage` is transient UI state: it must never appear in encoded
/// JSON (state.json shape is frozen), and pre-existing four-key records must
/// keep decoding.
@Suite("ToolCallRecord coding")
struct ToolCallRecordCodingTests {
    @Test func decodesLegacyFourKeyShape() throws {
        let json = #"{"id":"call_1","name":"web_search","argumentsJSON":"{}","status":"succeeded"}"#
        let record = try JSONDecoder().decode(ToolCallRecord.self, from: Data(json.utf8))
        #expect(record.id == "call_1")
        #expect(record.status == .succeeded)
        #expect(record.progressMessage == nil)
    }

    @Test func progressMessageIsNeverEncoded() throws {
        let record = ToolCallRecord(
            id: "call_2",
            name: "mcp__everything__simulate-research-query",
            argumentsJSON: "{}",
            status: .running,
            progressMessage: "Analyzing content..."
        )
        let data = try JSONEncoder().encode(record)
        let raw = String(decoding: data, as: UTF8.self)
        #expect(!raw.contains("progressMessage"))
        #expect(!raw.contains("Analyzing"))

        // Round trip: the transient field rehydrates as nil.
        let decoded = try JSONDecoder().decode(ToolCallRecord.self, from: data)
        #expect(decoded.progressMessage == nil)
        #expect(decoded.status == .running)
    }
}
