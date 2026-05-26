import Foundation
import FChatCore
@preconcurrency import MLX
@preconcurrency import MLXEmbedders

/// On-device embedder backed by Qwen3-Embedding-4B running on MLX
/// (Apple Silicon GPU/ANE). Vectors are 2560-dim, L2-normalised.
///
/// We wrap the underlying `EmbedderModelContainer` (which already
/// serialises GPU access internally) in our own `Embedder` adapter so
/// the rest of FChatRAG can stay protocol-typed.
///
/// Note on pooling: the MLX-converted Qwen3-Embedding DWQ checkpoint
/// ships without a `1_Pooling/config.json` in some snapshots, in which
/// case the upstream factory falls back to first-token pooling — wrong
/// for a causal-LM-based embedder. We override the pooling strategy
/// to `.last` explicitly here, mirroring Qwen3 docs. Tracked upstream
/// at https://github.com/ml-explore/mlx-swift-lm/issues/36.
public struct MLXQwen3Embedder: Embedder {
    public static let modelID = "mlx-community/Qwen3-Embedding-4B-4bit-DWQ"
    public static let embeddingDim = 2560
    public static let queryInstruction =
        "Instruct: Given a query, retrieve relevant passages that answer the query\nQuery: "

    public let kind: EmbedderKind = .mlxQwen3Embedding4B
    public let modelID: String = MLXQwen3Embedder.modelID
    public let dim: Int = MLXQwen3Embedder.embeddingDim

    private let container: EmbedderModelContainer
    private let pooling: Pooling

    public init(container: EmbedderModelContainer) {
        self.container = container
        // Force last-token pooling regardless of what (if anything) the
        // model directory's pooling config says. Qwen3-Embedding is a
        // causal-LM-based encoder; the embedding lives at the final
        // non-pad token of the prompt, not the first.
        self.pooling = Pooling(strategy: .last)
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { throw EmbedderError.emptyInput }
        let pooling = self.pooling
        return try await container.perform { ctx in
            return try embedBatch(texts, in: ctx, pooling: pooling)
        }
    }

    /// Apply the Qwen3-recommended retrieval instruction prefix on the
    /// query side only. Chunks (ingest) get no prefix.
    public func embedQuery(_ query: String) async throws -> [Float] {
        let prefixed = Self.queryInstruction + query
        let vectors = try await embed([prefixed])
        return vectors[0]
    }
}

// MARK: - Batch helper (runs inside container.perform)

@Sendable
private func embedBatch(
    _ texts: [String],
    in ctx: EmbedderModelContext,
    pooling: Pooling
) throws -> [[Float]] {
    let tokenizer = ctx.tokenizer
    let model = ctx.model

    // Tokenise each input with special tokens (EOS marker is crucial for
    // last-token pooling).
    let encoded = texts.map { tokenizer.encode(text: $0, addSpecialTokens: true) }
    let maxLen = encoded.map(\.count).max() ?? 0
    guard maxLen > 0 else { throw EmbedderError.emptyInput }
    let padID = (tokenizer.eosTokenId ?? 0)

    // Build [batch, maxLen] padded input + attention mask.
    var flatInput = [Int32]()
    var flatMask = [Int32]()
    flatInput.reserveCapacity(texts.count * maxLen)
    flatMask.reserveCapacity(texts.count * maxLen)
    for tokens in encoded {
        for t in tokens {
            flatInput.append(Int32(t))
            flatMask.append(1)
        }
        for _ in tokens.count ..< maxLen {
            flatInput.append(Int32(padID))
            flatMask.append(0)
        }
    }
    let inputIds = MLXArray(flatInput, [texts.count, maxLen])
    let attentionMask = MLXArray(flatMask, [texts.count, maxLen])

    let output = model(inputIds, positionIds: nil, tokenTypeIds: nil, attentionMask: attentionMask)
    // Pooling with our forced `.last` strategy + L2 normalise.
    let pooled = pooling(output, mask: attentionMask, normalize: true)
    eval(pooled)
    return pooled.map { row in
        row.asArray(Float.self)
    }
}
