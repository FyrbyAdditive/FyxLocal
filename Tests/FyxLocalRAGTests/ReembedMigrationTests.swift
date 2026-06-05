// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FyxLocalCore
@testable import FyxLocalRAG

/// Thread-safe holder for the last (done,total) reported by the @Sendable
/// progress callback during re-embed.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _done = 0
    private var _total = 0
    func record(done: Int, total: Int) {
        lock.lock(); _done = done; _total = total; lock.unlock()
    }
    var done: Int { lock.lock(); defer { lock.unlock() }; return _done }
    var total: Int { lock.lock(); defer { lock.unlock() }; return _total }
}

@Suite("Re-embed migration (model swap)")
struct ReembedMigrationTests {

    /// Seed an in-memory collection embedded with an "old" model at `oldDim`.
    private func seed(dim: Int, model: String) async throws -> (CollectionStore, CollectionID) {
        let store = CollectionStore()
        let embedder = HashEmbedder(modelID: model, dim: dim)
        let c = try await store.createCollection(name: "notes", embedder: embedder, summary: nil, distance: .cosine)
        let body = """
        # Alpha
        The quick brown fox jumps over the lazy dog.

        # Beta
        Lorem ipsum dolor sit amet, consectetur adipiscing elit.
        """
        _ = try await store.ingest(data: Data(body.utf8), filename: "doc.md", collectionID: c.id)
        return (store, c.id)
    }

    @Test func detectsCollectionsNeedingReembedByDimAndModel() async throws {
        let (store, _) = try await seed(dim: 2560, model: "old-model")
        // Different model AND dim → stale.
        let stale = await store.collectionsNeedingReembed(currentModelID: "new-model", currentDim: 1024)
        #expect(stale.count == 1)
        // Same model + dim → nothing to do.
        let none = await store.collectionsNeedingReembed(currentModelID: "old-model", currentDim: 2560)
        #expect(none.isEmpty)
    }

    @Test func reembedRebuildsAtNewDimAndSearchWorks() async throws {
        let (store, cid) = try await seed(dim: 2560, model: "old-model")
        // Sanity: collection currently records the old dim.
        #expect(await store.collection(cid)?.dim == 2560)

        // Re-embed with a new 1024-dim model (from STORED chunk text — no re-ingest).
        let newEmbedder = HashEmbedder(modelID: "new-model", dim: 1024)
        let progress = ProgressBox()
        try await store.reembedCollection(cid, using: newEmbedder) { done, total in
            progress.record(done: done, total: total)
        }
        let lastDone = progress.done, lastTotal = progress.total

        // Metadata updated to the new model/dim.
        let updated = await store.collection(cid)
        #expect(updated?.dim == 1024)
        #expect(updated?.embeddingModel == "new-model")
        // Progress reported to completion.
        #expect(lastTotal > 0)
        #expect(lastDone == lastTotal)

        // Search now works at the new dim (would dimension-mismatch if the vec
        // store hadn't been rebuilt).
        let hits = try await store.search(query: "quick brown fox", in: cid, topK: 3)
        #expect(!hits.isEmpty)

        // Documents/chunks preserved — no re-import happened.
        let docs = await store.documents(in: cid)
        #expect(docs.count == 1)
        #expect(docs[0].filename == "doc.md")
    }

    @Test func reembedIsNoOpListWhenAlreadyCurrent() async throws {
        let (store, _) = try await seed(dim: 1024, model: "current")
        let stale = await store.collectionsNeedingReembed(currentModelID: "current", currentDim: 1024)
        #expect(stale.isEmpty)
    }
}
