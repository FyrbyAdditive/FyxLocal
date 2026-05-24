import Foundation
import FChatCore

#if canImport(NaturalLanguage)
import NaturalLanguage

/// Wraps `NLContextualEmbedding` (BERT-style sentence embeddings, ~512 dims,
/// 256-token max). The embedding model is downloaded on first use; if the
/// model isn't available we throw `EmbedderError.unavailable`.
///
/// Swedish coverage rides on the Latin-script model; verify quality with a
/// Swedish eval set during integration testing.
public final class AppleEmbedder: Embedder, @unchecked Sendable {
    public let kind: EmbedderKind = .appleNLContextual
    public let modelID: String
    public let dim: Int
    public let script: NLScript

    private let embedding: NLContextualEmbedding

    public init(script: NLScript = .latin) throws {
        guard let embedding = NLContextualEmbedding(script: script) else {
            throw EmbedderError.unavailable("NLContextualEmbedding(script: \(script.rawValue)) not available")
        }
        if !embedding.hasAvailableAssets {
            try embedding.load()
        }
        self.embedding = embedding
        self.dim = embedding.dimension
        self.modelID = "apple-nl-contextual:\(script.rawValue):\(embedding.revision)"
        self.script = script
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { throw EmbedderError.emptyInput }
        return try texts.map { text in
            let result = try embedding.embeddingResult(for: text, language: nil)
            var vector = [Float](repeating: 0, count: dim)
            var count: Int = 0
            result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { tokenVector, _ in
                for (i, v) in tokenVector.enumerated() where i < self.dim {
                    vector[i] += Float(v)
                }
                count += 1
                return true
            }
            if count > 0 {
                for i in 0..<vector.count { vector[i] /= Float(count) }
            }
            return vector
        }
    }
}
#endif
