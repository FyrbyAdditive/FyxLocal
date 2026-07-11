// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// A parsed form-mode `elicitation/create` request from an MCP server.
/// `fields` is the pre-parsed convenience view of `requestedSchema` the UI
/// renders from; the raw schema is retained as a fallback/debugging aid.
public struct MCPElicitationRequest: Sendable, Hashable {
    public let message: String
    public let requestedSchema: JSONValue
    public let fields: [MCPElicitationField]
    /// From `_meta["io.modelcontextprotocol/related-task"].taskId` when the
    /// elicitation belongs to an in-flight task-augmented call.
    public let relatedTaskId: String?

    public init(message: String, requestedSchema: JSONValue, fields: [MCPElicitationField], relatedTaskId: String?) {
        self.message = message
        self.requestedSchema = requestedSchema
        self.fields = fields
        self.relatedTaskId = relatedTaskId
    }
}

/// One property of the restricted flat elicitation schema (MCP 2025-11-25:
/// string / number / integer / boolean / enum / multi-select enum only).
public struct MCPElicitationField: Sendable, Hashable {
    public struct EnumOption: Sendable, Hashable {
        public let value: String
        public let title: String?
        public init(value: String, title: String? = nil) {
            self.value = value
            self.title = title
        }
    }

    public enum StringFormat: String, Sendable, Hashable {
        case email
        case uri
        case date
        case dateTime = "date-time"
    }

    public enum Kind: Sendable, Hashable {
        case string(minLength: Int?, maxLength: Int?, pattern: String?, format: StringFormat?, defaultValue: String?)
        case number(isInteger: Bool, minimum: Double?, maximum: Double?, defaultValue: Double?)
        case boolean(defaultValue: Bool?)
        case enumeration(options: [EnumOption], defaultValue: String?)
        case multiSelect(options: [EnumOption], defaultValue: [String])
    }

    public let name: String
    public let title: String?
    public let description: String?
    public let kind: Kind
    public let isRequired: Bool

    public init(name: String, title: String?, description: String?, kind: Kind, isRequired: Bool) {
        self.name = name
        self.title = title
        self.description = description
        self.kind = kind
        self.isRequired = isRequired
    }
}

public enum MCPElicitationAction: String, Sendable, Hashable {
    case accept, decline, cancel
}

public struct MCPElicitationResult: Sendable, Hashable {
    public let action: MCPElicitationAction
    /// Flat object of submitted values; only serialized when `action == .accept`.
    public let content: JSONValue?

    public init(action: MCPElicitationAction, content: JSONValue? = nil) {
        self.action = action
        self.content = content
    }

    public static func accept(_ content: JSONValue) -> MCPElicitationResult {
        MCPElicitationResult(action: .accept, content: content)
    }
    public static let decline = MCPElicitationResult(action: .decline)
    public static let cancel = MCPElicitationResult(action: .cancel)
}

public typealias MCPElicitationHandler = @Sendable (MCPElicitationRequest) async -> MCPElicitationResult

/// Pure parser for `elicitation/create` params. The server is untrusted:
/// sizes are bounded and a property whose shape falls outside the restricted
/// subset degrades to an unconstrained string field (the form still renders)
/// rather than failing the whole request.
enum MCPElicitationParser {
    static let maxMessageLen = 8_192
    static let maxProperties = 64
    static let maxEnumOptions = 256
    static let maxTextLen = 1_024

    static func parse(params: JSONValue?) -> Result<MCPElicitationRequest, JSONRPCError> {
        guard let params, case .object = params else {
            return .failure(JSONRPCError(code: -32602, message: "elicitation/create params must be an object"))
        }
        guard let rawMessage = params["message"]?.stringValue, !rawMessage.isEmpty else {
            return .failure(JSONRPCError(code: -32602, message: "elicitation/create requires a 'message' string"))
        }
        let message = String(rawMessage.prefix(maxMessageLen))
        let schema = params["requestedSchema"] ?? .object([:])

        var fields: [MCPElicitationField] = []
        if let properties = schema["properties"]?.objectValue {
            let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            // Dictionary decoding loses the server's property order; sort by
            // key so the rendered form is at least deterministic.
            for name in properties.keys.sorted().prefix(maxProperties) {
                guard let property = properties[name] else { continue }
                fields.append(parseField(name: name, property: property, isRequired: required.contains(name)))
            }
        }

        let relatedTaskId = params["_meta"]?["io.modelcontextprotocol/related-task"]?["taskId"]?.stringValue

        return .success(MCPElicitationRequest(
            message: message,
            requestedSchema: schema,
            fields: fields,
            relatedTaskId: relatedTaskId
        ))
    }

    private static func parseField(name: String, property: JSONValue, isRequired: Bool) -> MCPElicitationField {
        let title = clipped(property["title"]?.stringValue)
        let description = clipped(property["description"]?.stringValue)
        return MCPElicitationField(
            name: String(name.prefix(maxTextLen)),
            title: title,
            description: description,
            kind: parseKind(property),
            isRequired: isRequired
        )
    }

    private static func parseKind(_ property: JSONValue) -> MCPElicitationField.Kind {
        let type = property["type"]?.stringValue

        // Single-select enum: `enum: [...]` (optionally parallel `enumNames`)
        // or `oneOf: [{const, title}]`.
        if let options = enumOptions(from: property) {
            return .enumeration(options: options, defaultValue: property["default"]?.stringValue)
        }

        switch type {
        case "string":
            return .string(
                minLength: property["minLength"]?.intValue,
                maxLength: property["maxLength"]?.intValue,
                pattern: clipped(property["pattern"]?.stringValue),
                format: property["format"]?.stringValue.flatMap { MCPElicitationField.StringFormat(rawValue: $0) },
                defaultValue: clipped(property["default"]?.stringValue)
            )
        case "number", "integer":
            return .number(
                isInteger: type == "integer",
                minimum: property["minimum"]?.doubleValue,
                maximum: property["maximum"]?.doubleValue,
                defaultValue: property["default"]?.doubleValue
            )
        case "boolean":
            return .boolean(defaultValue: property["default"]?.boolValue)
        case "array":
            if let items = property["items"], let options = enumOptions(from: items) {
                let defaults = property["default"]?.arrayValue?.compactMap(\.stringValue) ?? []
                return .multiSelect(options: options, defaultValue: defaults)
            }
            // Arrays other than multi-select enums are outside the restricted
            // subset — degrade to an unconstrained string field.
            return .string(minLength: nil, maxLength: nil, pattern: nil, format: nil, defaultValue: nil)
        default:
            // Unknown/absent type: degrade to an unconstrained string field.
            return .string(minLength: nil, maxLength: nil, pattern: nil, format: nil, defaultValue: nil)
        }
    }

    /// Extracts enum options from a schema node: `enum`/`enumNames` arrays or
    /// `oneOf`/`anyOf` arrays of `{const, title}` objects. Returns nil when
    /// the node is not an enum shape.
    private static func enumOptions(from node: JSONValue) -> [MCPElicitationField.EnumOption]? {
        if let values = node["enum"]?.arrayValue {
            let names = node["enumNames"]?.arrayValue
            let options = values.prefix(maxEnumOptions).enumerated().compactMap { index, value -> MCPElicitationField.EnumOption? in
                guard let raw = value.stringValue else { return nil }
                let title = names.flatMap { index < $0.count ? clipped($0[index].stringValue) : nil }
                return MCPElicitationField.EnumOption(value: String(raw.prefix(maxTextLen)), title: title)
            }
            return options.isEmpty ? nil : options
        }
        for key in ["oneOf", "anyOf"] {
            if let variants = node[key]?.arrayValue {
                let options = variants.prefix(maxEnumOptions).compactMap { variant -> MCPElicitationField.EnumOption? in
                    guard let value = variant["const"]?.stringValue else { return nil }
                    return MCPElicitationField.EnumOption(
                        value: String(value.prefix(maxTextLen)),
                        title: clipped(variant["title"]?.stringValue)
                    )
                }
                if !options.isEmpty { return options }
            }
        }
        return nil
    }

    private static func clipped(_ value: String?) -> String? {
        value.map { String($0.prefix(maxTextLen)) }
    }
}
