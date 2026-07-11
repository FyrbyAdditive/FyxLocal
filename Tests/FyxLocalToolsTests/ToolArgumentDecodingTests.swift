// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalTools

@Suite("ToolArguments lenient decode")
struct ToolArgumentDecodingTests {
    private struct Sample: Decodable, Equatable {
        var query: String
        var max_results: Int?
        var ratio: Double?
        var enabled: Bool?
    }

    @Test func stringifiedIntCoercesToInt() {
        // The exact Nemotron shape.
        let s = ToolArguments.decode(Sample.self, from: #"{"query":"x","max_results":"5"}"#)
        #expect(s == Sample(query: "x", max_results: 5, ratio: nil, enabled: nil))
    }

    @Test func realIntStillWorks() {
        let s = ToolArguments.decode(Sample.self, from: #"{"query":"x","max_results":5}"#)
        #expect(s?.max_results == 5)
    }

    @Test func stringifiedDoubleAndBool() {
        let s = ToolArguments.decode(Sample.self, from: #"{"query":"x","ratio":"1.5","enabled":"true"}"#)
        #expect(s?.ratio == 1.5)
        #expect(s?.enabled == true)
    }

    @Test func negativeAndZero() {
        let s = ToolArguments.decode(Sample.self, from: #"{"query":"x","max_results":"-3"}"#)
        #expect(s?.max_results == -3)
        let z = ToolArguments.decode(Sample.self, from: #"{"query":"x","max_results":"0"}"#)
        #expect(z?.max_results == 0)
    }

    @Test func realStringNotMangled() {
        // A query that looks numeric must stay a string (its field is String).
        let s = ToolArguments.decode(Sample.self, from: #"{"query":"2026","max_results":"5"}"#)
        #expect(s?.query == "2026")
        #expect(s?.max_results == 5)
    }

    @Test func nonNumericStringsLeftAlone() {
        // "5 cats" / "5px" / "" must not become numbers (would corrupt data).
        struct Q: Decodable { let query: String }
        #expect(ToolArguments.decode(Q.self, from: #"{"query":"5 cats"}"#)?.query == "5 cats")
        #expect(ToolArguments.decode(Q.self, from: #"{"query":"5px"}"#)?.query == "5px")
    }

    @Test func nestedObjectsAndArraysCoerced() {
        struct Point: Decodable, Equatable { let y: Double }
        struct Series: Decodable, Equatable { let points: [Point] }
        let s = ToolArguments.decode(Series.self, from: #"{"points":[{"y":"42"},{"y":"3.14"}]}"#)
        #expect(s == Series(points: [Point(y: 42), Point(y: 3.14)]))
    }

    @Test func malformedReturnsNil() {
        #expect(ToolArguments.decode(Sample.self, from: "not json") == nil)
        // Missing required field → still nil (caller shows its parse error).
        #expect(ToolArguments.decode(Sample.self, from: #"{"max_results":5}"#) == nil)
    }

    @Test func emptyAndWhitespaceDecodeAsEmptyObject() {
        struct Opt: Decodable, Equatable { let limit: Int? }
        #expect(ToolArguments.decode(Opt.self, from: "") == Opt(limit: nil))
        #expect(ToolArguments.decode(Opt.self, from: "   ") == Opt(limit: nil))
    }
}
