import Foundation
import FChatCore

#if canImport(NaturalLanguage)
import NaturalLanguage

/// Wraps `NLContextualEmbedding` initialisation with model-availability
/// awareness. Apple's on-device embedding model is downloaded lazily by
/// the OS; the first call may block until the asset is fetched.
///
/// Returns a typed result so callers (UI, ingest queue) can show progress
/// or a meaningful "still downloading…" status instead of just crashing
/// when the model isn't available yet.
public enum AppleEmbedderLoader {
    public enum LoadResult: Sendable {
        case ready(any Embedder)
        case unavailable(reason: String)
    }

    /// Try to load the Latin-script Apple contextual embedding model
    /// (covers English + Swedish + most western European scripts).
    /// Returns immediately; the actual asset download (if needed) happens
    /// inside `NLContextualEmbedding.load()` synchronously.
    public static func loadLatin() -> LoadResult {
        do {
            let embedder = try AppleEmbedder(script: .latin)
            return .ready(embedder)
        } catch let err as EmbedderError {
            switch err {
            case .unavailable(let detail):
                return .unavailable(reason: detail)
            case .emptyInput, .dimensionMismatch:
                return .unavailable(reason: String(describing: err))
            }
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }
}
#endif
