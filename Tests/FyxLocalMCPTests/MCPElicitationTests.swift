// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalMCP

@Suite("MCPElicitationParser")
struct MCPElicitationTests {
    private func parse(_ params: JSONValue?) -> MCPElicitationRequest? {
        if case .success(let request) = MCPElicitationParser.parse(params: params) {
            return request
        }
        return nil
    }

    private func schemaParams(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object([
            "message": .string("Please fill in"),
            "requestedSchema": .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
            ]),
        ])
    }

    @Test func missingMessageIsInvalidParams() {
        let result = MCPElicitationParser.parse(params: .object([
            "requestedSchema": .object(["type": .string("object")])
        ]))
        guard case .failure(let error) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(error.code == -32602)
    }

    @Test func nonObjectParamsIsInvalidParams() {
        guard case .failure(let error) = MCPElicitationParser.parse(params: .string("nope")) else {
            Issue.record("expected failure")
            return
        }
        #expect(error.code == -32602)
    }

    @Test func stringFieldWithConstraints() {
        let request = parse(schemaParams([
            "username": .object([
                "type": .string("string"),
                "title": .string("User name"),
                "description": .string("Your login"),
                "minLength": .int(3),
                "maxLength": .int(20),
                "pattern": .string("^[a-z]+$"),
                "format": .string("email"),
                "default": .string("me@example.com"),
            ]),
        ], required: ["username"]))
        guard let field = request?.fields.first else {
            Issue.record("expected a field")
            return
        }
        #expect(field.name == "username")
        #expect(field.title == "User name")
        #expect(field.description == "Your login")
        #expect(field.isRequired)
        guard case .string(let minLength, let maxLength, let pattern, let format, let defaultValue) = field.kind else {
            Issue.record("expected string kind")
            return
        }
        #expect(minLength == 3)
        #expect(maxLength == 20)
        #expect(pattern == "^[a-z]+$")
        #expect(format == .email)
        #expect(defaultValue == "me@example.com")
    }

    @Test func numberAndIntegerFields() {
        let request = parse(schemaParams([
            "age": .object([
                "type": .string("integer"),
                "minimum": .int(18),
                "maximum": .int(120),
                "default": .int(30),
            ]),
            "score": .object([
                "type": .string("number"),
                "minimum": .double(0.5),
            ]),
        ]))
        guard let fields = request?.fields, fields.count == 2 else {
            Issue.record("expected two fields")
            return
        }
        // Fields are sorted by name: age, score.
        guard case .number(let isInteger, let minimum, let maximum, let defaultValue) = fields[0].kind else {
            Issue.record("expected number kind")
            return
        }
        #expect(isInteger)
        #expect(minimum == 18)
        #expect(maximum == 120)
        #expect(defaultValue == 30)
        guard case .number(let isInteger2, let minimum2, _, _) = fields[1].kind else {
            Issue.record("expected number kind")
            return
        }
        #expect(!isInteger2)
        #expect(minimum2 == 0.5)
    }

    @Test func booleanFieldWithDefault() {
        let request = parse(schemaParams([
            "subscribe": .object(["type": .string("boolean"), "default": .bool(true)]),
        ]))
        guard case .boolean(let defaultValue) = request?.fields.first?.kind else {
            Issue.record("expected boolean kind")
            return
        }
        #expect(defaultValue == true)
    }

    @Test func plainEnumField() {
        let request = parse(schemaParams([
            "color": .object([
                "type": .string("string"),
                "enum": .array([.string("Red"), .string("Green")]),
                "default": .string("Red"),
            ]),
        ]))
        guard case .enumeration(let options, let defaultValue) = request?.fields.first?.kind else {
            Issue.record("expected enumeration kind")
            return
        }
        #expect(options.map(\.value) == ["Red", "Green"])
        #expect(options.map(\.title) == [nil, nil])
        #expect(defaultValue == "Red")
    }

    @Test func enumWithEnumNamesTitles() {
        let request = parse(schemaParams([
            "color": .object([
                "type": .string("string"),
                "enum": .array([.string("#F00"), .string("#0F0")]),
                "enumNames": .array([.string("Red"), .string("Green")]),
            ]),
        ]))
        guard case .enumeration(let options, _) = request?.fields.first?.kind else {
            Issue.record("expected enumeration kind")
            return
        }
        #expect(options.map(\.title) == ["Red", "Green"])
    }

    @Test func oneOfConstTitleEnum() {
        let request = parse(schemaParams([
            "choice": .object([
                "type": .string("string"),
                "oneOf": .array([
                    .object(["const": .string("a"), "title": .string("Option A")]),
                    .object(["const": .string("b"), "title": .string("Option B")]),
                ]),
            ]),
        ]))
        guard case .enumeration(let options, _) = request?.fields.first?.kind else {
            Issue.record("expected enumeration kind")
            return
        }
        #expect(options.map(\.value) == ["a", "b"])
        #expect(options.map(\.title) == ["Option A", "Option B"])
    }

    @Test func multiSelectViaItemsEnum() {
        let request = parse(schemaParams([
            "colors": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string"), "enum": .array([.string("Red"), .string("Blue")])]),
                "default": .array([.string("Red")]),
            ]),
        ]))
        guard case .multiSelect(let options, let defaults) = request?.fields.first?.kind else {
            Issue.record("expected multiSelect kind")
            return
        }
        #expect(options.map(\.value) == ["Red", "Blue"])
        #expect(defaults == ["Red"])
    }

    @Test func multiSelectViaItemsAnyOf() {
        let request = parse(schemaParams([
            "colors": .object([
                "type": .string("array"),
                "items": .object([
                    "anyOf": .array([
                        .object(["const": .string("#F00"), "title": .string("Red")]),
                        .object(["const": .string("#00F"), "title": .string("Blue")]),
                    ]),
                ]),
            ]),
        ]))
        guard case .multiSelect(let options, _) = request?.fields.first?.kind else {
            Issue.record("expected multiSelect kind")
            return
        }
        #expect(options.map(\.title) == ["Red", "Blue"])
    }

    @Test func unrecognizedShapeDegradesToString() {
        let request = parse(schemaParams([
            "weird": .object([
                "type": .string("object"),
                "properties": .object(["nested": .object(["type": .string("string")])]),
            ]),
        ]))
        guard case .string(let minLength, let maxLength, let pattern, let format, let defaultValue) = request?.fields.first?.kind else {
            Issue.record("expected degraded string kind")
            return
        }
        #expect(minLength == nil)
        #expect(maxLength == nil)
        #expect(pattern == nil)
        #expect(format == nil)
        #expect(defaultValue == nil)
    }

    @Test func propertyCountIsCapped() {
        var properties: [String: JSONValue] = [:]
        for i in 0..<100 {
            properties[String(format: "field%03d", i)] = .object(["type": .string("string")])
        }
        let request = parse(schemaParams(properties))
        #expect(request?.fields.count == MCPElicitationParser.maxProperties)
    }

    @Test func overlongTextsAreClipped() {
        let long = String(repeating: "x", count: 5_000)
        let request = parse(.object([
            "message": .string(String(repeating: "m", count: 10_000)),
            "requestedSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "f": .object(["type": .string("string"), "title": .string(long)]),
                ]),
            ]),
        ]))
        #expect(request?.message.count == MCPElicitationParser.maxMessageLen)
        #expect(request?.fields.first?.title?.count == MCPElicitationParser.maxTextLen)
    }

    @Test func missingSchemaYieldsZeroFields() {
        let request = parse(.object(["message": .string("hello")]))
        #expect(request != nil)
        #expect(request?.fields.isEmpty == true)
    }

    @Test func relatedTaskIdExtractedFromMeta() {
        let request = parse(.object([
            "message": .string("hi"),
            "requestedSchema": .object(["type": .string("object")]),
            "_meta": .object([
                "io.modelcontextprotocol/related-task": .object(["taskId": .string("task-9")]),
            ]),
        ]))
        #expect(request?.relatedTaskId == "task-9")
    }

    @Test func clientErrorDescriptions() {
        let cases: [(MCPClientError, String)] = [
            (.rpcError(code: -32601, message: "requires task augmentation"), "MCP error -32601: requires task augmentation"),
            (.taskDeadlineExceeded(taskId: "t-1"), "MCP task 't-1' did not complete before the client-side deadline"),
            (.transportClosed, "MCP transport closed"),
        ]
        for (error, expected) in cases {
            #expect(error.localizedDescription == expected)
        }
    }
}
