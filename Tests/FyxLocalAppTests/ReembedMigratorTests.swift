// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FyxLocalCore
import FyxLocalRAG
@testable import FyxLocalApp

@MainActor
@Suite("ReembedMigrator coordinator")
struct ReembedMigratorTests {
    private func seededStore(model: String, dim: Int) async throws -> CollectionStore {
        let store = CollectionStore()
        let embedder = HashEmbedder(modelID: model, dim: dim)
        let c = try await store.createCollection(name: "notes", embedder: embedder, summary: nil, distance: .cosine)
        _ = try await store.ingest(data: Data("alpha beta gamma delta".utf8), filename: "x.txt", collectionID: c.id)
        return store
    }

    @Test func needsMigrationThenRunsToFinished() async throws {
        let store = try await seededStore(model: "old-model", dim: 2560)
        let migrator = ReembedMigrator(
            store: store,
            currentModelID: "new-model",
            currentDim: 1024,
            makeEmbedder: { HashEmbedder(modelID: "new-model", dim: 1024) }
        )
        #expect(await migrator.needsMigration())
        await migrator.run()
        #expect(migrator.phase == .finished)
        #expect(migrator.fractionComplete == 1)
        // After migration, nothing remains stale.
        #expect(!(await migrator.needsMigration()))
    }

    @Test func noMigrationWhenAlreadyCurrent() async throws {
        let store = try await seededStore(model: "new-model", dim: 1024)
        let migrator = ReembedMigrator(
            store: store,
            currentModelID: "new-model",
            currentDim: 1024,
            makeEmbedder: { HashEmbedder(modelID: "new-model", dim: 1024) }
        )
        #expect(!(await migrator.needsMigration()))
    }
}
