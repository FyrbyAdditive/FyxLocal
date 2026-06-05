// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import Observation
import FyxLocalCore
import FyxLocalRAG

/// Drives the one-time re-embed migration after the bundled embedder model is
/// swapped (Qwen3-4B 2560-dim → 0.6B 1024-dim). Existing collections store
/// vectors in the old dimension; they must be re-embedded from their stored
/// chunk text (no re-import) before search works again.
///
/// `@Observable` so a blocking SwiftUI sheet can show live per-collection
/// progress. The whole run is gated by `needsMigration` (computed against the
/// current bundled model), so a normal launch with up-to-date collections is a
/// single cheap check and the sheet never appears.
@MainActor
@Observable
final class ReembedMigrator {
    /// Phase of the migration, drives the UI.
    enum Phase: Equatable {
        case idle
        case running
        case finished
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// 1-based index of the collection currently being processed.
    private(set) var currentCollectionIndex = 0
    private(set) var totalCollections = 0
    /// Name of the collection currently being re-embedded.
    private(set) var currentCollectionName = ""
    /// Chunks embedded / total for the current collection.
    private(set) var embeddedChunks = 0
    private(set) var totalChunks = 0

    private let store: any CollectionStoreProtocol
    /// Builds the current (new) embedder. Injected so this is testable with a
    /// stub and so the app supplies the real MLX-backed embedder.
    private let makeEmbedder: @Sendable () async throws -> any Embedder
    private let currentModelID: String
    private let currentDim: Int

    init(
        store: any CollectionStoreProtocol,
        currentModelID: String,
        currentDim: Int,
        makeEmbedder: @escaping @Sendable () async throws -> any Embedder
    ) {
        self.store = store
        self.currentModelID = currentModelID
        self.currentDim = currentDim
        self.makeEmbedder = makeEmbedder
    }

    /// Fractional progress across the whole migration (0…1), weighting each
    /// collection equally then blending in the current collection's chunk
    /// progress. Drives the progress bar.
    var fractionComplete: Double {
        guard totalCollections > 0 else { return 0 }
        let perCollection = 1.0 / Double(totalCollections)
        let completed = Double(max(0, currentCollectionIndex - 1)) * perCollection
        let withinCurrent = totalChunks > 0
            ? (Double(embeddedChunks) / Double(totalChunks)) * perCollection
            : 0
        return min(1, completed + withinCurrent)
    }

    /// True if any collection was embedded with a different model/dim and so
    /// needs re-embedding. Cheap — a metadata-only DB read.
    func needsMigration() async -> Bool {
        !(await store.collectionsNeedingReembed(currentModelID: currentModelID, currentDim: currentDim)).isEmpty
    }

    /// Run the migration. Re-embeds each stale collection in turn, publishing
    /// progress. Marks `.finished` on success or `.failed` with a message.
    /// Safe to call only when `needsMigration()` is true (the caller gates it).
    func run() async {
        phase = .running
        let stale = await store.collectionsNeedingReembed(currentModelID: currentModelID, currentDim: currentDim)
        totalCollections = stale.count
        do {
            let embedder = try await makeEmbedder()
            for (i, collection) in stale.enumerated() {
                currentCollectionIndex = i + 1
                currentCollectionName = collection.name
                embeddedChunks = 0
                totalChunks = 0
                try await store.reembedCollection(collection.id, using: embedder) { [weak self] done, total in
                    Task { @MainActor in
                        guard let self else { return }
                        self.embeddedChunks = done
                        self.totalChunks = total
                    }
                }
            }
            phase = .finished
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
