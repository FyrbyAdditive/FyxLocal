// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import Observation
import FyxLocalCore
import FyxLocalRAG

/// Background queue that ingests dropped files into a collection one at a
/// time, reporting per-file status. UI binds against `entries` for the
/// progress list and `isProcessing` to know whether the spinner is up.
@MainActor
@Observable
final class IngestQueue {
    struct Entry: Identifiable, Hashable {
        let id: UUID
        let url: URL
        let filename: String
        let collectionID: CollectionID
        var status: Status
        enum Status: Hashable {
            case pending
            case running
            /// Newly added.
            case succeeded
            /// Replaced an older version of the same source.
            case updated
            /// Unchanged content — dedup skipped it entirely.
            case skipped
            case failed(String)
            case cancelled
        }
    }

    var entries: [Entry] = []
    var isProcessing: Bool = false

    private let store: any CollectionStoreProtocol
    private let ingestor: FileIngestor
    private var workTask: Task<Void, Never>?

    /// File extensions the ingestor knows how to parse. Used by the UI's
    /// folder-walk to pre-filter recursively-collected files.
    var supportedExtensions: Set<String> { ingestor.supportedExtensions }

    init(store: any CollectionStoreProtocol, ingestor: FileIngestor = FileIngestor()) {
        self.store = store
        self.ingestor = ingestor
    }

    /// Add files to the queue and kick the worker if it isn't already running.
    /// Reentrant — new entries appended while the worker is mid-loop are
    /// picked up automatically.
    func enqueue(urls: [URL], into collectionID: CollectionID) {
        for url in urls {
            entries.append(Entry(
                id: UUID(),
                url: url,
                filename: url.lastPathComponent,
                collectionID: collectionID,
                status: .pending
            ))
        }
        startWorkerIfNeeded()
    }

    func cancelAll() {
        workTask?.cancel()
        workTask = nil
        isProcessing = false
        for i in entries.indices where entries[i].status == .running || entries[i].status == .pending {
            entries[i].status = .cancelled
        }
    }

    /// Mark every pending/running entry for this collection as cancelled.
    /// Other collections' entries keep running.
    func cancel(collectionID: CollectionID) {
        for i in entries.indices where entries[i].collectionID == collectionID
            && (entries[i].status == .pending || entries[i].status == .running) {
            entries[i].status = .cancelled
        }
        // If there's no work left at all anywhere, also kill the worker
        // so its loop exits and `isProcessing` flips off.
        if !entries.contains(where: { $0.status == .pending }) {
            workTask?.cancel()
            workTask = nil
            isProcessing = false
        }
    }

    func clearCompleted() {
        entries.removeAll { entry in
            switch entry.status {
            case .succeeded, .updated, .skipped, .failed, .cancelled: return true
            default: return false
            }
        }
    }

    /// Drop completed/failed/cancelled entries for one collection only.
    func clearCompleted(collectionID: CollectionID) {
        entries.removeAll { entry in
            guard entry.collectionID == collectionID else { return false }
            switch entry.status {
            case .succeeded, .updated, .skipped, .failed, .cancelled: return true
            default: return false
            }
        }
    }

    /// Drop every entry — running, pending, or done — for a collection.
    /// Called when the collection itself is deleted so the progress view
    /// doesn't leak stale rows into the next collection the user opens.
    func removeAll(forCollection collectionID: CollectionID) {
        entries.removeAll { $0.collectionID == collectionID }
        if !entries.contains(where: { $0.status == .pending || $0.status == .running }) {
            workTask?.cancel()
            workTask = nil
            isProcessing = false
        }
    }

    private func startWorkerIfNeeded() {
        guard workTask == nil else { return }
        isProcessing = true
        workTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while let nextIndex = self.entries.firstIndex(where: { $0.status == .pending }) {
                if Task.isCancelled { break }
                self.entries[nextIndex].status = .running
                let entry = self.entries[nextIndex]
                let outcome: Entry.Status
                do {
                    let data = try await Self.readData(at: entry.url)
                    let result = try await self.store.ingest(
                        data: data,
                        filename: entry.filename,
                        sourcePath: entry.url.standardizedFileURL.path,
                        collectionID: entry.collectionID,
                        ingestor: self.ingestor,
                        chunker: Chunker()
                    )
                    switch result.outcome {
                    case .added: outcome = .succeeded
                    case .updated: outcome = .updated
                    case .skippedUnchanged: outcome = .skipped
                    }
                } catch {
                    outcome = .failed(Self.describe(error))
                }
                // `entries` may have been mutated during the awaits (clear,
                // cancel, collection delete), so `nextIndex` can be stale —
                // re-find by id, and don't overwrite a status someone else
                // set (e.g. cancelled mid-flight).
                if let idx = self.entries.firstIndex(where: { $0.id == entry.id }),
                   self.entries[idx].status == .running {
                    self.entries[idx].status = outcome
                }
            }
            self.workTask = nil
            self.isProcessing = false
        }
    }

    /// Reads file bytes off the main actor so the worker loop never stalls
    /// UI frames on disk I/O (each file can be up to 16 MB).
    private static func readData(at url: URL) async throws -> Data {
        try await Task.detached { try Data(contentsOf: url) }.value
    }

    static func describe(_ error: Error) -> String {
        if let p = error as? PersistentIngestError {
            switch p {
            case .parseFailure(_, let message): return message
            }
        }
        return error.localizedDescription
    }
}

/// Pure roll-up of one collection's queue entries, recomputed from a single
/// snapshot of `entries` on each render. The single-snapshot rule is what
/// guarantees `done <= total` even while the user drops more files mid-run —
/// never keep separately-incremented counters in view state. Lives at file
/// scope (not nested in the queue) so the counting logic is unit-testable
/// without SwiftUI.
@MainActor
struct IngestSummary {
    var total = 0
    var succeeded = 0
    var updated = 0
    var skipped = 0
    var failed = 0
    var cancelled = 0
    /// Pending + running.
    var remaining = 0
    /// The running entry's filename, else the first pending one.
    var currentFilename: String?
    /// `.failed` entries only (cancellations aren't failures), queue order.
    var failures: [IngestQueue.Entry] = []

    var done: Int { total - remaining }
    var isActive: Bool { remaining > 0 }
    var isEmpty: Bool { total == 0 }

    init(entries: [IngestQueue.Entry], collectionID: CollectionID) {
        for entry in entries where entry.collectionID == collectionID {
            total += 1
            switch entry.status {
            case .pending:
                remaining += 1
                if currentFilename == nil { currentFilename = entry.filename }
            case .running:
                remaining += 1
                currentFilename = entry.filename
            case .succeeded:
                succeeded += 1
            case .updated:
                updated += 1
            case .skipped:
                skipped += 1
            case .failed:
                failed += 1
                failures.append(entry)
            case .cancelled:
                cancelled += 1
            }
        }
    }
}

/// Expand a list of URLs that may include folders into a flat list of
/// file URLs ready to enqueue. Folders are walked recursively; hidden
/// files (`.git`, `.DS_Store`, dotfiles) are skipped; files whose
/// extension isn't recognised by `supportedExtensions` are skipped; files
/// larger than `maxBytes` are skipped (default 16 MB — a single ingest of
/// a 100 MB binary would otherwise stall the queue and blow embedding
/// budgets).
///
/// Returns the expanded URL list plus a count of files that were skipped
/// (so the caller can surface "imported 42 of 187 files" without losing
/// the user's trust).
public struct IngestFolderExpander {
    public var supportedExtensions: Set<String>
    public var maxBytes: Int
    public var skipHidden: Bool

    public init(
        supportedExtensions: Set<String>,
        maxBytes: Int = 16 * 1024 * 1024,
        skipHidden: Bool = true
    ) {
        self.supportedExtensions = supportedExtensions
        self.maxBytes = maxBytes
        self.skipHidden = skipHidden
    }

    public struct Result {
        public var urls: [URL]
        public var skippedHidden: Int
        public var skippedUnknownType: Int
        public var skippedTooBig: Int
    }

    public func expand(_ urls: [URL]) -> Result {
        var collected: [URL] = []
        var skippedHidden = 0
        var skippedUnknown = 0
        var skippedTooBig = 0
        let fm = FileManager.default

        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let walker = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: skipHidden ? [.skipsHiddenFiles] : []
                ) else { continue }
                for case let fileURL as URL in walker {
                    let (kept, reason) = consider(fileURL, fm: fm)
                    if kept {
                        collected.append(fileURL)
                    } else {
                        switch reason {
                        case .hidden: skippedHidden += 1
                        case .unknownType: skippedUnknown += 1
                        case .tooBig: skippedTooBig += 1
                        case .notRegularFile: break
                        }
                    }
                }
            } else {
                let (kept, reason) = consider(url, fm: fm)
                if kept {
                    collected.append(url)
                } else {
                    switch reason {
                    case .hidden: skippedHidden += 1
                    case .unknownType: skippedUnknown += 1
                    case .tooBig: skippedTooBig += 1
                    case .notRegularFile: break
                    }
                }
            }
        }
        return Result(
            urls: collected,
            skippedHidden: skippedHidden,
            skippedUnknownType: skippedUnknown,
            skippedTooBig: skippedTooBig
        )
    }

    private enum SkipReason { case hidden, unknownType, tooBig, notRegularFile }

    private func consider(_ url: URL, fm: FileManager) -> (kept: Bool, reason: SkipReason) {
        if skipHidden && url.lastPathComponent.hasPrefix(".") {
            return (false, .hidden)
        }
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            return (false, .unknownType)
        }
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) {
            if values.isRegularFile != true { return (false, .notRegularFile) }
            if let size = values.fileSize, size > maxBytes { return (false, .tooBig) }
        }
        return (true, .hidden) // reason unused on the success branch
    }
}
