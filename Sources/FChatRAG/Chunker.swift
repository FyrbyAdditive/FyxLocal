import Foundation
import FChatCore

public struct Chunker: Sendable {
    public var targetSize: Int
    public var overlap: Int
    public var separators: [String]

    public init(
        targetSize: Int = 1000,
        overlap: Int = 150,
        separators: [String] = ["\n\n", "\n", ". ", " ", ""]
    ) {
        precondition(targetSize > 0, "chunk size must be positive")
        precondition(overlap >= 0 && overlap < targetSize, "overlap must be in [0, targetSize)")
        precondition(!separators.isEmpty, "must provide at least one separator")
        self.targetSize = targetSize
        self.overlap = overlap
        self.separators = separators
    }

    public func chunk(_ text: String) -> [String] {
        var pieces: [String] = []
        splitRecursive(text, separators: separators, into: &pieces)
        return mergePieces(pieces)
    }

    private func splitRecursive(_ text: String, separators: [String], into output: inout [String]) {
        if text.isEmpty { return }
        if text.count <= targetSize {
            output.append(text)
            return
        }
        guard let separator = separators.first else {
            output.append(text)
            return
        }
        let remainder = Array(separators.dropFirst())
        if separator.isEmpty {
            // Hard character split fallback.
            var index = text.startIndex
            while index < text.endIndex {
                let end = text.index(index, offsetBy: targetSize, limitedBy: text.endIndex) ?? text.endIndex
                output.append(String(text[index..<end]))
                index = end
            }
            return
        }
        let components = text.components(separatedBy: separator)
        for (i, part) in components.enumerated() {
            let glued = i == components.count - 1 ? part : part + separator
            if glued.count <= targetSize {
                output.append(glued)
            } else {
                splitRecursive(glued, separators: remainder, into: &output)
            }
        }
    }

    private func mergePieces(_ pieces: [String]) -> [String] {
        var merged: [String] = []
        var current = ""
        for piece in pieces {
            if current.isEmpty {
                current = piece
                continue
            }
            if current.count + piece.count <= targetSize {
                current += piece
            } else {
                merged.append(current)
                if overlap > 0 && current.count > overlap {
                    let start = current.index(current.endIndex, offsetBy: -overlap)
                    let tail = String(current[start...])
                    current = tail + piece
                } else {
                    current = piece
                }
            }
        }
        if !current.isEmpty { merged.append(current) }
        return merged
    }
}
