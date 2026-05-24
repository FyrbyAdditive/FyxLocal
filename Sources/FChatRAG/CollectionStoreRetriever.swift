import Foundation
import FChatCore
import FChatTools

/// Adapts `CollectionStore` to the Tools-layer `RAGRetriever` protocol so the
/// built-in `rag_search` tool can drive a real collection store.
public struct CollectionStoreRetriever: RAGRetriever {
    public let store: CollectionStore

    public init(store: CollectionStore) {
        self.store = store
    }

    public func search(query: String, collectionID: CollectionID, topK: Int) async throws -> [RAGSearchHit] {
        let hits = try await store.search(query: query, in: collectionID, topK: topK)
        var output: [RAGSearchHit] = []
        for hit in hits {
            guard let chunk = await store.chunk(hit.chunkID) else { continue }
            let document = await store.document(chunk.documentID)
            output.append(RAGSearchHit(
                chunkID: hit.chunkID,
                documentName: document?.filename ?? "unknown",
                page: chunk.meta.page,
                section: chunk.meta.section,
                text: chunk.text,
                score: Double(hit.score)
            ))
        }
        return output
    }

    public func collection(named name: String) async throws -> CollectionID? {
        await store.collection(named: name)?.id
    }
}
