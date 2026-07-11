// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FyxLocalCore
@testable import FyxLocalApp

/// Unit tests for `IngestSummary`, the pure roll-up the compact ingest
/// progress UI renders from (issue #3: hundreds of per-file rows used to
/// blow the documents pane off-screen). The struct is file-scope and
/// side-effect free precisely so this logic is testable without SwiftUI
/// or a live queue.
@MainActor
@Suite("Ingest summary counting")
struct IngestSummaryTests {

    private let cidA = CollectionID()
    private let cidB = CollectionID()

    private func entry(
        _ name: String,
        _ status: IngestQueue.Entry.Status,
        in cid: CollectionID
    ) -> IngestQueue.Entry {
        IngestQueue.Entry(
            id: UUID(),
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            filename: name,
            collectionID: cid,
            status: status
        )
    }

    @Test func countsMixedStatuses() {
        let summary = IngestSummary(entries: [
            entry("a.md", .succeeded, in: cidA),
            entry("b.md", .succeeded, in: cidA),
            entry("c.md", .failed("boom"), in: cidA),
            entry("d.md", .cancelled, in: cidA),
            entry("e.md", .running, in: cidA),
            entry("f.md", .pending, in: cidA),
        ], collectionID: cidA)
        #expect(summary.total == 6)
        #expect(summary.succeeded == 2)
        #expect(summary.failed == 1)
        #expect(summary.cancelled == 1)
        #expect(summary.remaining == 2)
        #expect(summary.done == 4)
        #expect(summary.isActive)
        #expect(!summary.isEmpty)
    }

    @Test func filtersOtherCollections() {
        let summary = IngestSummary(entries: [
            entry("mine.md", .succeeded, in: cidA),
            entry("theirs1.md", .running, in: cidB),
            entry("theirs2.md", .failed("x"), in: cidB),
        ], collectionID: cidA)
        #expect(summary.total == 1)
        #expect(summary.succeeded == 1)
        #expect(summary.failed == 0)
        #expect(summary.failures.isEmpty)
        #expect(!summary.isActive)
    }

    @Test func currentFilenamePrefersRunningOverPending() {
        let summary = IngestSummary(entries: [
            entry("queued.md", .pending, in: cidA),
            entry("active.md", .running, in: cidA),
        ], collectionID: cidA)
        #expect(summary.currentFilename == "active.md")
    }

    @Test func currentFilenameFallsBackToFirstPendingBetweenFiles() {
        // Between files (worker just finished one, hasn't marked the next
        // running yet) there is no running entry — show the next up.
        let summary = IngestSummary(entries: [
            entry("done.md", .succeeded, in: cidA),
            entry("next.md", .pending, in: cidA),
            entry("later.md", .pending, in: cidA),
        ], collectionID: cidA)
        #expect(summary.currentFilename == "next.md")
    }

    @Test func failuresExcludeCancelledAndPreserveQueueOrder() {
        let summary = IngestSummary(entries: [
            entry("bad1.md", .failed("parse"), in: cidA),
            entry("stopped.md", .cancelled, in: cidA),
            entry("bad2.md", .failed("embed"), in: cidA),
        ], collectionID: cidA)
        #expect(summary.failures.map(\.filename) == ["bad1.md", "bad2.md"])
        #expect(summary.failed == 2)
        #expect(summary.cancelled == 1)
    }

    @Test func doneNeverExceedsTotalWhenMoreFilesDroppedMidRun() {
        var entries = [
            entry("a.md", .succeeded, in: cidA),
            entry("b.md", .running, in: cidA),
        ]
        // User drops three more while the worker is mid-file; both counts
        // come from the same snapshot, so the invariant holds.
        entries.append(entry("c.md", .pending, in: cidA))
        entries.append(entry("d.md", .pending, in: cidA))
        entries.append(entry("e.md", .pending, in: cidA))
        let summary = IngestSummary(entries: entries, collectionID: cidA)
        #expect(summary.done <= summary.total)
        #expect(summary.done == 1)
        #expect(summary.total == 5)
        #expect(summary.isActive)
    }

    @Test func emptyAndIdleStates() {
        let empty = IngestSummary(entries: [], collectionID: cidA)
        #expect(empty.isEmpty)
        #expect(!empty.isActive)
        #expect(empty.currentFilename == nil)

        let idle = IngestSummary(entries: [
            entry("a.md", .succeeded, in: cidA),
            entry("b.md", .cancelled, in: cidA),
        ], collectionID: cidA)
        #expect(!idle.isEmpty)
        #expect(!idle.isActive)
        #expect(idle.done == 2)
        #expect(idle.currentFilename == nil)
    }
}
