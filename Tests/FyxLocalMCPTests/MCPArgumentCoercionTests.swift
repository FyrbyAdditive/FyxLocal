// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalMCP

@Suite("MCPArgumentCoercion")
struct MCPArgumentCoercionTests {
    private func schema(_ properties: [String: JSONValue]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
        ])
    }

    @Test func numericBooleanCoerces() {
        // The exact real-world failure: Qwen emitted {"ambiguous": 1} and the
        // everything server rejected the call with -32602.
        let s = schema([
            "topic": .object(["type": .string("string")]),
            "ambiguous": .object(["type": .string("boolean")]),
        ])
        let out = MCPArgumentCoercion.normalize(
            .object(["topic": .string("spark"), "ambiguous": .int(1)]),
            schema: s
        )
        #expect(out["ambiguous"] == .bool(true))
        #expect(out["topic"] == .string("spark"))

        let out0 = MCPArgumentCoercion.normalize(.object(["ambiguous": .int(0)]), schema: s)
        #expect(out0["ambiguous"] == .bool(false))
    }

    @Test func stringScalarsCoerceTowardSchema() {
        let s = schema([
            "flag": .object(["type": .string("boolean")]),
            "count": .object(["type": .string("integer")]),
            "ratio": .object(["type": .string("number")]),
        ])
        let out = MCPArgumentCoercion.normalize(
            .object([
                "flag": .string("true"),
                "count": .string("5"),
                "ratio": .string("2.5"),
            ]),
            schema: s
        )
        #expect(out["flag"] == .bool(true))
        #expect(out["count"] == .int(5))
        #expect(out["ratio"] == .double(2.5))
    }

    @Test func bareScalarStringifiesForStringFields() {
        let s = schema(["query": .object(["type": .string("string")])])
        let out = MCPArgumentCoercion.normalize(.object(["query": .int(2026)]), schema: s)
        #expect(out["query"] == .string("2026"))
    }

    @Test func nonCoercibleAndCorrectValuesPassThrough() {
        let s = schema([
            "flag": .object(["type": .string("boolean")]),
            "count": .object(["type": .string("integer")]),
            "query": .object(["type": .string("string")]),
        ])
        let input: JSONValue = .object([
            "flag": .bool(true),          // already right
            "count": .string("5 cats"),   // not a whole number — untouched
            "query": .string("2026"),     // string field keeps its string
            "extra": .int(7),             // not in schema — untouched
        ])
        let out = MCPArgumentCoercion.normalize(input, schema: s)
        #expect(out == input)
    }

    @Test func integralDoubleBecomesInt() {
        let s = schema(["count": .object(["type": .string("integer")])])
        let out = MCPArgumentCoercion.normalize(.object(["count": .double(5.0)]), schema: s)
        #expect(out["count"] == .int(5))
        // Non-integral double stays as-is (server's problem to report).
        let bad = MCPArgumentCoercion.normalize(.object(["count": .double(5.5)]), schema: s)
        #expect(bad["count"] == .double(5.5))
    }

    @Test func nestedObjectsAndArraysRecurse() {
        let s = schema([
            "options": .object([
                "type": .string("object"),
                "properties": .object([
                    "deep": .object(["type": .string("boolean")]),
                ]),
            ]),
            "tags": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
            ]),
        ])
        let out = MCPArgumentCoercion.normalize(
            .object([
                "options": .object(["deep": .int(1)]),
                "tags": .array([.int(1), .string("two")]),
            ]),
            schema: s
        )
        #expect(out["options"]?["deep"] == .bool(true))
        #expect(out["tags"] == .array([.string("1"), .string("two")]))
    }

    @Test func schemalessArgumentsUntouched() {
        let input: JSONValue = .object(["anything": .int(1)])
        #expect(MCPArgumentCoercion.normalize(input, schema: .object([:])) == input)
    }
}
