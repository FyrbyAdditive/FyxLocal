// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalMCP

/// Pure form-state model for an MCP form-mode elicitation. Built from the
/// pre-parsed `MCPElicitationField`s the protocol layer extracted from the
/// restricted schema subset; deliberately SwiftUI-free so validation and
/// content serialization are headless-testable.
struct ElicitationFormModel: Sendable, Hashable {
    struct Field: Identifiable, Sendable, Hashable {
        let spec: MCPElicitationField
        /// Text entry for string and number kinds (defaults pre-filled).
        var text: String = ""
        var boolValue: Bool = false
        /// Selected value for `.enumeration`.
        var selection: String?
        /// Selected values for `.multiSelect`.
        var selections: Set<String> = []

        var id: String { spec.name }
        var displayTitle: String { spec.title ?? spec.name }
    }

    enum FieldError: Hashable, Sendable {
        case required
        case invalidEmail
        case invalidURL
        case invalidDate
        case notANumber
        case notAWholeNumber
        case outOfRange
        case lengthOutOfBounds
    }

    var fields: [Field]

    init(fields specs: [MCPElicitationField]) {
        self.fields = specs.map { spec in
            var field = Field(spec: spec)
            switch spec.kind {
            case .string(_, _, _, _, let defaultValue):
                field.text = defaultValue ?? ""
            case .number(let isInteger, _, _, let defaultValue):
                if let defaultValue {
                    field.text = isInteger
                        ? String(Int(defaultValue))
                        : String(defaultValue)
                }
            case .boolean(let defaultValue):
                field.boolValue = defaultValue ?? false
            case .enumeration(let options, let defaultValue):
                if let defaultValue, options.contains(where: { $0.value == defaultValue }) {
                    field.selection = defaultValue
                }
            case .multiSelect(let options, let defaultValues):
                let valid = Set(options.map(\.value))
                field.selections = Set(defaultValues).intersection(valid)
            }
            return field
        }
    }

    // MARK: - Validation

    func error(for field: Field) -> FieldError? {
        let trimmed = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field.spec.kind {
        case .string(let minLength, let maxLength, _, let format, _):
            if trimmed.isEmpty {
                return field.spec.isRequired ? .required : nil
            }
            if let minLength, trimmed.count < minLength { return .lengthOutOfBounds }
            if let maxLength, trimmed.count > maxLength { return .lengthOutOfBounds }
            switch format {
            case .email:
                if !Self.looksLikeEmail(trimmed) { return .invalidEmail }
            case .uri:
                guard let url = URL(string: trimmed), url.scheme != nil else { return .invalidURL }
            case .date:
                if Self.parseDate(trimmed) == nil { return .invalidDate }
            case .dateTime:
                if Self.parseDateTime(trimmed) == nil { return .invalidDate }
            case nil:
                break
            }
            return nil
        case .number(let isInteger, let minimum, let maximum, _):
            if trimmed.isEmpty {
                return field.spec.isRequired ? .required : nil
            }
            guard let value = Double(trimmed) else {
                return isInteger ? .notAWholeNumber : .notANumber
            }
            if isInteger, value != value.rounded() || Int(exactly: value.rounded()) == nil {
                return .notAWholeNumber
            }
            if let minimum, value < minimum { return .outOfRange }
            if let maximum, value > maximum { return .outOfRange }
            return nil
        case .boolean:
            // A toggle always carries a value.
            return nil
        case .enumeration:
            if field.selection == nil, field.spec.isRequired { return .required }
            return nil
        case .multiSelect:
            if field.selections.isEmpty, field.spec.isRequired { return .required }
            return nil
        }
    }

    var isValid: Bool {
        fields.allSatisfy { error(for: $0) == nil }
    }

    // MARK: - Serialization

    /// Flat content object for the accept response. Required fields are
    /// always present (validation guarantees a value); optional fields with
    /// no entry are omitted.
    func contentJSON() -> JSONValue {
        var object: [String: JSONValue] = [:]
        for field in fields {
            let trimmed = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch field.spec.kind {
            case .string:
                if !trimmed.isEmpty { object[field.spec.name] = .string(trimmed) }
            case .number(let isInteger, _, _, _):
                guard let value = Double(trimmed) else { break }
                object[field.spec.name] = isInteger ? .int(Int(value.rounded())) : .double(value)
            case .boolean:
                object[field.spec.name] = .bool(field.boolValue)
            case .enumeration:
                if let selection = field.selection { object[field.spec.name] = .string(selection) }
            case .multiSelect(let options, _):
                guard !field.selections.isEmpty else { break }
                // Preserve the option order from the schema.
                let ordered = options.map(\.value).filter { field.selections.contains($0) }
                object[field.spec.name] = .array(ordered.map { .string($0) })
            }
        }
        return .object(object)
    }

    // MARK: - Format helpers

    private static func looksLikeEmail(_ value: String) -> Bool {
        // Light structural check (x@y.z) — the server revalidates anyway.
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private static func parseDateTime(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: value)
    }
}
