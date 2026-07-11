// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// Lenient decoding of a model's tool-call argument JSON.
///
/// Some models stringify scalar values — e.g. Nemotron emits
/// `{"max_results":"5"}` instead of `{"max_results":5}`. Swift's `JSONDecoder`
/// is strict and rejects that, so a perfectly reasonable tool call fails with
/// a parse error the user can't act on (and can't reliably prompt away).
///
/// `ToolArguments.decode` decodes strictly first, and only when that fails for
/// a *type mismatch* does it coerce the exact offending field (string→number/
/// bool) and retry. Coercion is therefore **type-directed by the decoder
/// itself**, not a blind tree rewrite — so a genuine string that merely looks
/// numeric (e.g. `query:"2026"`) is never mangled, because strict decoding of
/// a `String` field accepts it and never complains. Every existing
/// `struct Args: Decodable` keeps working unchanged — only the call site swaps
/// from `JSONDecoder().decode(...)` to `ToolArguments.decode(...)`.
public enum ToolArguments {
    /// Decode `json` into `T`, tolerating stringified scalars. Returns nil on
    /// malformed JSON or a shape that still can't satisfy `T` (callers fall
    /// back to their existing "could not parse" error).
    public static func decode<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalised = trimmed.isEmpty ? "{}" : trimmed
        guard let data = normalised.data(using: .utf8) else { return nil }
        guard var current = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }

        // Up to a bounded number of repair passes: decode; if it fails on a
        // type mismatch at a known key path, coerce the scalar at exactly that
        // path and retry. The bound is the field count ceiling — each pass
        // fixes one field, and it can't loop because a coerced field that
        // decodes is never revisited.
        for _ in 0..<32 {
            guard let attemptData = try? JSONSerialization.data(withJSONObject: current, options: [.fragmentsAllowed])
            else { return nil }
            do {
                return try JSONDecoder().decode(T.self, from: attemptData)
            } catch let DecodingError.typeMismatch(_, ctx) {
                // Coerce the scalar at the offending key path, if we can.
                guard let repaired = coerceAtPath(current, path: ctx.codingPath) else { return nil }
                current = repaired
            } catch {
                return nil
            }
        }
        return nil
    }

    /// Walk `codingPath` into the JSON tree and coerce the scalar found there
    /// (string→int/double/bool). Returns the mutated tree, or nil if the path
    /// doesn't resolve to a coercible scalar (so the caller stops trying).
    private static func coerceAtPath(_ root: Any, path: [CodingKey]) -> Any? {
        guard !path.isEmpty else { return nil }
        return mutate(root, path: path[...])
    }

    private static func mutate(_ node: Any, path: ArraySlice<CodingKey>) -> Any? {
        guard let key = path.first else {
            // Leaf: coerce the scalar; nil if it isn't a coercible string.
            if let s = node as? String, let c = coerceScalar(s) { return c }
            return nil
        }
        let rest = path.dropFirst()
        if let idx = key.intValue, var arr = node as? [Any] {
            guard idx >= 0, idx < arr.count, let child = mutate(arr[idx], path: rest) else { return nil }
            arr[idx] = child
            return arr
        }
        if var dict = node as? [String: Any] {
            guard let v = dict[key.stringValue], let child = mutate(v, path: rest) else { return nil }
            dict[key.stringValue] = child
            return dict
        }
        return nil
    }

    /// A string that is *exactly* an integer, decimal, or bool → that typed
    /// scalar; nil otherwise. Whole-string match only ("5"→5, but "5 cats",
    /// "5px", "" → nil). Numbers kept as `NSNumber` so they re-serialize
    /// unquoted.
    static func coerceScalar(_ s: String) -> Any? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        switch t.lowercased() {
        case "true": return true
        case "false": return false
        default: break
        }
        if let i = Int(t) { return NSNumber(value: i) }
        if let d = Double(t), d.isFinite, t.contains(where: \.isNumber) { return NSNumber(value: d) }
        return nil
    }

    /// Recursively coerce every coercible string scalar in a tree. Used by
    /// make_chart, whose strict validator (ChartSpec) isn't a plain Decodable
    /// and doesn't surface a per-field coding path, so it gets the whole-tree
    /// pass instead. Safe there because ChartSpec's string fields (names,
    /// labels) tolerate the change or are validated separately.
    static func coerce(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.mapValues(coerce)
        case let arr as [Any]:
            return arr.map(coerce)
        case let str as String:
            return coerceScalar(str) ?? str
        default:
            return value
        }
    }
}
