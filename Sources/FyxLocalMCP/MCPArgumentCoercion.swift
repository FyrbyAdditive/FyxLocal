// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// Schema-directed repair of sloppy tool-call arguments before they go to an
/// MCP server. Local models emit near-miss scalars — `{"ambiguous": 1}` where
/// the tool's inputSchema says boolean, `{"count": "5"}` where it says
/// integer — and MCP servers validate strictly (the everything server
/// rejects `ambiguous: 1` with a -32602). Built-in tools get the equivalent
/// tolerance from `ToolArguments.decode`; MCP tools can do better because the
/// server ships its schema in `tools/list`.
///
/// Philosophy matches `ToolArguments.coerceScalar`: coerce only exact
/// whole-value matches toward the schema-declared type, and never touch a
/// value the schema already accepts or whose intent is ambiguous.
enum MCPArgumentCoercion {
    /// Returns `arguments` with every property that has a schema-declared
    /// primitive type nudged to that type where safely possible. Values
    /// already of the right type, unknown properties, and anything not
    /// safely coercible pass through untouched.
    static func normalize(_ arguments: JSONValue, schema: JSONValue) -> JSONValue {
        normalizeValue(arguments, schema: schema)
    }

    private static func normalizeValue(_ value: JSONValue, schema: JSONValue) -> JSONValue {
        switch schema["type"]?.stringValue {
        case "boolean":
            return coerceBool(value) ?? value
        case "integer":
            return coerceInt(value) ?? value
        case "number":
            return coerceNumber(value) ?? value
        case "string":
            return coerceString(value) ?? value
        case "object":
            guard case .object(let object) = value,
                  let properties = schema["properties"]?.objectValue else { return value }
            var normalized = object
            for (key, propertySchema) in properties {
                if let present = object[key] {
                    normalized[key] = normalizeValue(present, schema: propertySchema)
                }
            }
            return .object(normalized)
        case "array":
            guard case .array(let items) = value, let itemSchema = schema["items"] else { return value }
            return .array(items.map { normalizeValue($0, schema: itemSchema) })
        default:
            return value
        }
    }

    /// bool stays; 0/1 (int) and "true"/"false"/"0"/"1" (string) coerce.
    private static func coerceBool(_ value: JSONValue) -> JSONValue? {
        switch value {
        case .bool:
            return value
        case .int(0):
            return .bool(false)
        case .int(1):
            return .bool(true)
        case .string(let s):
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "1": return .bool(true)
            case "false", "0": return .bool(false)
            default: return nil
            }
        default:
            return nil
        }
    }

    /// int stays; integral double and whole-integer string coerce.
    private static func coerceInt(_ value: JSONValue) -> JSONValue? {
        switch value {
        case .int:
            return value
        case .double(let d) where d == d.rounded() && Int(exactly: d.rounded()) != nil:
            return .int(Int(d.rounded()))
        case .string(let s):
            if let i = Int(s.trimmingCharacters(in: .whitespaces)) { return .int(i) }
            return nil
        default:
            return nil
        }
    }

    /// int/double stay; numeric string coerces.
    private static func coerceNumber(_ value: JSONValue) -> JSONValue? {
        switch value {
        case .int, .double:
            return value
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if let i = Int(trimmed) { return .int(i) }
            if let d = Double(trimmed), d.isFinite { return .double(d) }
            return nil
        default:
            return nil
        }
    }

    /// string stays; bare scalars stringify ({"q": 2026} where schema says
    /// string). Objects/arrays/null never stringify.
    private static func coerceString(_ value: JSONValue) -> JSONValue? {
        switch value {
        case .string:
            return value
        case .int(let i):
            return .string(String(i))
        case .double(let d):
            return .string(String(d))
        case .bool(let b):
            return .string(b ? "true" : "false")
        default:
            return nil
        }
    }
}
