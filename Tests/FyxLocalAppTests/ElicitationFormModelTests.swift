// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FyxLocalMCP
@testable import FyxLocalApp

@Suite("ElicitationFormModel")
struct ElicitationFormModelTests {
    private func field(
        _ name: String,
        kind: MCPElicitationField.Kind,
        required: Bool = false,
        title: String? = nil
    ) -> MCPElicitationField {
        MCPElicitationField(name: name, title: title, description: nil, kind: kind, isRequired: required)
    }

    @Test func defaultsPrefill() {
        let form = ElicitationFormModel(fields: [
            field("name", kind: .string(minLength: nil, maxLength: nil, pattern: nil, format: nil, defaultValue: "tim")),
            field("age", kind: .number(isInteger: true, minimum: nil, maximum: nil, defaultValue: 42)),
            field("score", kind: .number(isInteger: false, minimum: nil, maximum: nil, defaultValue: 1.5)),
            field("on", kind: .boolean(defaultValue: true)),
            field("color", kind: .enumeration(options: [.init(value: "red"), .init(value: "blue")], defaultValue: "blue")),
            field("many", kind: .multiSelect(options: [.init(value: "a"), .init(value: "b")], defaultValue: ["b", "zzz"])),
        ])
        #expect(form.fields[0].text == "tim")
        #expect(form.fields[1].text == "42")
        #expect(form.fields[2].text == "1.5")
        #expect(form.fields[3].boolValue == true)
        #expect(form.fields[4].selection == "blue")
        // Unknown default values are dropped.
        #expect(form.fields[5].selections == ["b"])
    }

    @Test func requiredValidation() {
        var form = ElicitationFormModel(fields: [
            field("name", kind: .string(minLength: nil, maxLength: nil, pattern: nil, format: nil, defaultValue: nil), required: true),
            field("pick", kind: .enumeration(options: [.init(value: "x")], defaultValue: nil), required: true),
            field("multi", kind: .multiSelect(options: [.init(value: "x")], defaultValue: []), required: true),
        ])
        #expect(form.error(for: form.fields[0]) == .required)
        #expect(form.error(for: form.fields[1]) == .required)
        #expect(form.error(for: form.fields[2]) == .required)
        #expect(!form.isValid)
        form.fields[0].text = "hello"
        form.fields[1].selection = "x"
        form.fields[2].selections = ["x"]
        #expect(form.isValid)
    }

    @Test func optionalEmptyFieldsAreValidAndOmitted() {
        let form = ElicitationFormModel(fields: [
            field("note", kind: .string(minLength: nil, maxLength: nil, pattern: nil, format: nil, defaultValue: nil)),
            field("count", kind: .number(isInteger: true, minimum: nil, maximum: nil, defaultValue: nil)),
        ])
        #expect(form.isValid)
        #expect(form.contentJSON() == .object([:]))
    }

    @Test func emailValidation() {
        var form = ElicitationFormModel(fields: [
            field("mail", kind: .string(minLength: nil, maxLength: nil, pattern: nil, format: .email, defaultValue: nil), required: true),
        ])
        form.fields[0].text = "not-an-email"
        #expect(form.error(for: form.fields[0]) == .invalidEmail)
        form.fields[0].text = "a@b.co"
        #expect(form.error(for: form.fields[0]) == nil)
    }

    @Test func uriValidation() {
        var form = ElicitationFormModel(fields: [
            field("link", kind: .string(minLength: nil, maxLength: nil, pattern: nil, format: .uri, defaultValue: nil), required: true),
        ])
        form.fields[0].text = "no scheme"
        #expect(form.error(for: form.fields[0]) == .invalidURL)
        form.fields[0].text = "https://example.com/x"
        #expect(form.error(for: form.fields[0]) == nil)
    }

    @Test func dateValidation() {
        var form = ElicitationFormModel(fields: [
            field("day", kind: .string(minLength: nil, maxLength: nil, pattern: nil, format: .date, defaultValue: nil), required: true),
            field("when", kind: .string(minLength: nil, maxLength: nil, pattern: nil, format: .dateTime, defaultValue: nil), required: true),
        ])
        form.fields[0].text = "31/01/2026"
        #expect(form.error(for: form.fields[0]) == .invalidDate)
        form.fields[0].text = "2026-01-31"
        #expect(form.error(for: form.fields[0]) == nil)
        form.fields[1].text = "2026-01-31T12:00:00Z"
        #expect(form.error(for: form.fields[1]) == nil)
    }

    @Test func numberValidation() {
        var form = ElicitationFormModel(fields: [
            field("age", kind: .number(isInteger: true, minimum: 18, maximum: 120, defaultValue: nil), required: true),
        ])
        form.fields[0].text = "abc"
        #expect(form.error(for: form.fields[0]) == .notAWholeNumber)
        form.fields[0].text = "12.5"
        #expect(form.error(for: form.fields[0]) == .notAWholeNumber)
        form.fields[0].text = "12"
        #expect(form.error(for: form.fields[0]) == .outOfRange)
        form.fields[0].text = "200"
        #expect(form.error(for: form.fields[0]) == .outOfRange)
        form.fields[0].text = "30"
        #expect(form.error(for: form.fields[0]) == nil)
    }

    @Test func lengthValidation() {
        var form = ElicitationFormModel(fields: [
            field("code", kind: .string(minLength: 3, maxLength: 5, pattern: nil, format: nil, defaultValue: nil), required: true),
        ])
        form.fields[0].text = "ab"
        #expect(form.error(for: form.fields[0]) == .lengthOutOfBounds)
        form.fields[0].text = "abcdef"
        #expect(form.error(for: form.fields[0]) == .lengthOutOfBounds)
        form.fields[0].text = "abcd"
        #expect(form.error(for: form.fields[0]) == nil)
    }

    @Test func contentJSONTypes() {
        var form = ElicitationFormModel(fields: [
            field("name", kind: .string(minLength: nil, maxLength: nil, pattern: nil, format: nil, defaultValue: nil)),
            field("age", kind: .number(isInteger: true, minimum: nil, maximum: nil, defaultValue: nil)),
            field("score", kind: .number(isInteger: false, minimum: nil, maximum: nil, defaultValue: nil)),
            field("on", kind: .boolean(defaultValue: nil)),
            field("pick", kind: .enumeration(options: [.init(value: "x"), .init(value: "y")], defaultValue: nil)),
            field("multi", kind: .multiSelect(options: [.init(value: "a"), .init(value: "b"), .init(value: "c")], defaultValue: [])),
        ])
        form.fields[0].text = "  tim  "
        form.fields[1].text = "42"
        form.fields[2].text = "1.5"
        form.fields[3].boolValue = true
        form.fields[4].selection = "y"
        form.fields[5].selections = ["c", "a"]
        let content = form.contentJSON()
        #expect(content["name"] == .string("tim"))
        #expect(content["age"] == .int(42))
        #expect(content["score"] == .double(1.5))
        #expect(content["on"] == .bool(true))
        #expect(content["pick"] == .string("y"))
        // Multi-select preserves schema option order.
        #expect(content["multi"] == .array([.string("a"), .string("c")]))
    }
}
