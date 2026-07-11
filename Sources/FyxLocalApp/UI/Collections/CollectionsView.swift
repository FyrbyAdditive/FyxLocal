// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import UniformTypeIdentifiers
import FyxLocalCore
import FyxLocalRAG

/// 3-pane collections manager: list of collections (left), documents in the
/// selected collection (middle), chunks for the selected document (right).
struct CollectionsView: View {
    @Bindable var environment: AppEnvironment

    @State private var collections: [RAGCollection] = []
    @State private var selectedCollectionID: CollectionID?
    @State private var documents: [RAGDocument] = []
    @State private var selectedDocumentID: DocumentID?
    @State private var chunks: [RAGChunk] = []
    @State private var showNewSheet = false
    @State private var pendingCollectionDelete: CollectionID?
    @State private var pendingDocumentDelete: DocumentID?
    @State private var refreshTrigger = 0
    /// Id of the collection being renamed in place, or nil. When non-nil
    /// the matching row swaps Text for a focused TextField.
    @State private var renamingCollectionID: CollectionID?
    @State private var collectionRenameDraft: String = ""
    @FocusState private var collectionRenameFocus: CollectionID?
    /// Coalesces documents-pane reloads during a bulk import: at most one
    /// reload per second while files complete, plus one final authoritative
    /// reload when the queue goes idle for the selected collection.
    @State private var documentsReloadTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            collectionsList
                .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)
            Divider()
            documentsPane
                .frame(minWidth: 340, idealWidth: 420)
            Divider()
            chunksPane
                .frame(maxWidth: .infinity)
        }
        .navigationTitle("Collections")
        .task { await refresh() }
        .onChange(of: refreshTrigger) { _, _ in Task { await refresh() } }
        .sheet(isPresented: $showNewSheet) {
            NewCollectionSheet(environment: environment, isPresented: $showNewSheet, onCreated: {
                refreshTrigger += 1
            })
        }
        .confirmationDialog(
            "Delete this collection?",
            isPresented: Binding(
                get: { pendingCollectionDelete != nil },
                set: { if !$0 { pendingCollectionDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingCollectionDelete {
                    Task {
                        try? await environment.collectionStore.deleteCollection(id)
                        // Drop any leftover ingest queue rows so they don't
                        // appear under whatever collection the user opens next.
                        environment.ingestQueue?.removeAll(forCollection: id)
                        if selectedCollectionID == id { selectedCollectionID = nil }
                        refreshTrigger += 1
                    }
                }
                pendingCollectionDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingCollectionDelete = nil }
        } message: {
            Text("All documents and embeddings in this collection will be removed permanently.")
        }
        .confirmationDialog(
            "Delete this document?",
            isPresented: Binding(
                get: { pendingDocumentDelete != nil },
                set: { if !$0 { pendingDocumentDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingDocumentDelete {
                    Task {
                        try? await environment.collectionStore.deleteDocument(id)
                        if selectedDocumentID == id { selectedDocumentID = nil }
                        refreshTrigger += 1
                    }
                }
                pendingDocumentDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDocumentDelete = nil }
        }
    }

    // MARK: - Left pane: collections list

    @ViewBuilder
    private var collectionsList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedCollectionID) {
                Section {
                    if collections.isEmpty {
                        Text("No collections yet")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else {
                        ForEach(collections) { collection in
                            VStack(alignment: .leading, spacing: 2) {
                                if renamingCollectionID == collection.id {
                                    TextField("Collection name", text: $collectionRenameDraft)
                                        .textFieldStyle(.plain)
                                        .font(.body)
                                        .focused($collectionRenameFocus, equals: collection.id)
                                        .onSubmit { commitCollectionRename() }
                                        .onExitCommand { cancelCollectionRename() }
                                        .onChange(of: collectionRenameFocus) { _, newFocus in
                                            if newFocus != collection.id && renamingCollectionID == collection.id {
                                                commitCollectionRename()
                                            }
                                        }
                                } else {
                                    Text(collection.name)
                                        .font(.body)
                                }
                            }
                            .tag(collection.id)
                            .contextMenu {
                                Button {
                                    beginCollectionRename(collection)
                                } label: {
                                    Label("Rename\u{2026}", systemImage: "pencil")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    pendingCollectionDelete = collection.id
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("Collections")
                }
            }
            Divider()
            HStack {
                Spacer()
                Button {
                    showNewSheet = true
                } label: {
                    Label("New collection", systemImage: "plus")
                }
            }
            .padding(8)
        }
        .onChange(of: selectedCollectionID) { _, _ in
            selectedDocumentID = nil
            Task { await loadDocuments() }
        }
        // Reload the documents pane as ingests complete for the current
        // collection — the queue updates reactively but `documents` is local
        // @State that needs a fresh fetch from the store. Throttled: a bulk
        // import of hundreds of files would otherwise re-fetch every row
        // once per completed file (O(n²) decodes + a List re-diff each).
        .onChange(of: succeededIngestCount) { _, _ in
            scheduleThrottledDocumentsReload()
        }
        .onChange(of: selectedCollectionIngestActive) { _, active in
            guard !active else { return }
            // Queue went idle (finished or cancelled) for this collection —
            // drop any pending throttle tick and do one authoritative reload
            // so the list is never left stale.
            documentsReloadTask?.cancel()
            documentsReloadTask = nil
            Task { await loadDocuments() }
        }
    }

    /// Live count of succeeded ingest entries for the selected collection.
    /// Drives a (throttled) documents-pane refresh whenever it ticks up.
    private var succeededIngestCount: Int {
        guard let collectionID = selectedCollectionID,
              let queue = environment.ingestQueue else { return 0 }
        return queue.entries.reduce(0) { acc, entry in
            (entry.collectionID == collectionID && entry.status == .succeeded) ? acc + 1 : acc
        }
    }

    /// True while the selected collection has pending/running ingest work.
    /// Per-collection rather than the queue-global `isProcessing` so the
    /// idle transition also fires after a per-collection Cancel.
    private var selectedCollectionIngestActive: Bool {
        guard let collectionID = selectedCollectionID,
              let queue = environment.ingestQueue else { return false }
        return queue.entries.contains {
            $0.collectionID == collectionID && ($0.status == .pending || $0.status == .running)
        }
    }

    /// Leading-edge throttle: if no tick is in flight, schedule a reload one
    /// second out; ticks arriving meanwhile (including during a slow
    /// `loadDocuments()`) are swallowed. Anything missed is covered by the
    /// final reload on the idle transition above.
    private func scheduleThrottledDocumentsReload() {
        guard documentsReloadTask == nil else { return }
        documentsReloadTask = Task {
            defer { documentsReloadTask = nil }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await loadDocuments()
        }
    }

    // MARK: - Middle pane: documents

    @ViewBuilder
    private var documentsPane: some View {
        if let collectionID = selectedCollectionID,
           let collection = collections.first(where: { $0.id == collectionID }) {
            VStack(spacing: 0) {
                IngestDropTarget(
                    collectionID: collectionID,
                    environment: environment,
                    refreshTrigger: $refreshTrigger
                )
                .padding()
                IngestProgressView(environment: environment, collectionID: collectionID)
                Divider()
                if documents.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("No documents in \(collection.name)")
                            .foregroundStyle(.secondary)
                        Text("Drop files above, or use the file picker.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selectedDocumentID) {
                        ForEach(documents) { doc in
                            DocumentRow(document: doc, isSelected: selectedDocumentID == doc.id)
                                .tag(doc.id)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        pendingDocumentDelete = doc.id
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
            .onChange(of: selectedDocumentID) { _, _ in Task { await loadChunks() } }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Select or create a collection")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Right pane: chunks for selected document

    @ViewBuilder
    private var chunksPane: some View {
        if let docID = selectedDocumentID,
           let doc = documents.first(where: { $0.id == docID }) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(doc.filename).font(.headline)
                    Text("\(doc.kind.rawValue) · \(doc.byteSize.formatted(.byteCount(style: .binary))) · \(chunks.count) chunks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                Divider()
                if chunks.isEmpty {
                    Text("No chunks for this document")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(chunks) { chunk in
                                ChunkPreview(chunk: chunk)
                            }
                        }
                        .padding()
                    }
                }
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "doc.plaintext")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Select a document")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Data loading

    private func refresh() async {
        let store = environment.collectionStore
        let all = await store.listCollections()
        await MainActor.run { collections = all }
        await loadDocuments()
        await loadChunks()
    }

    private func loadDocuments() async {
        guard let cid = selectedCollectionID else {
            await MainActor.run { documents = [] }
            return
        }
        let docs = await environment.collectionStore.documents(in: cid)
        await MainActor.run { documents = docs }
    }

    private func loadChunks() async {
        guard let did = selectedDocumentID else {
            await MainActor.run { chunks = [] }
            return
        }
        let cs = await environment.collectionStore.chunks(of: did)
        await MainActor.run { chunks = cs }
    }

    // MARK: - Rename

    private func beginCollectionRename(_ collection: RAGCollection) {
        collectionRenameDraft = collection.name
        renamingCollectionID = collection.id
        // Defer focus until the TextField is mounted on the next runloop.
        Task { @MainActor in
            collectionRenameFocus = collection.id
        }
    }

    private func commitCollectionRename() {
        guard let id = renamingCollectionID else { return }
        let trimmed = collectionRenameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = collections.first(where: { $0.id == id })?.name ?? ""
        renamingCollectionID = nil
        collectionRenameDraft = ""
        guard !trimmed.isEmpty, trimmed != original else { return }
        Task {
            do {
                try await environment.collectionStore.renameCollection(id, to: trimmed)
                refreshTrigger += 1
            } catch {
                FileHandle.standardError.write(Data("[FyxLocal] rename collection failed: \(error)\n".utf8))
            }
        }
    }

    private func cancelCollectionRename() {
        renamingCollectionID = nil
        collectionRenameDraft = ""
    }
}

// MARK: - Document row

private struct DocumentRow: View {
    let document: RAGDocument
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.filename)
                    .lineLimit(1)
                Text("\(document.kind.rawValue) · \(document.byteSize.formatted(.byteCount(style: .binary)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var icon: String {
        switch document.kind {
        case .pdf: return "doc.richtext"
        case .markdown: return "doc.text"
        case .docx: return "doc"
        case .pptx: return "rectangle.on.rectangle"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .text: return "doc.plaintext"
        case .html: return "globe"
        case .jupyter: return "book.closed"
        case .rtf: return "doc.text"
        }
    }
}

// MARK: - Chunk preview

private struct ChunkPreview: View {
    let chunk: RAGChunk

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("#\(chunk.ordinal)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let page = chunk.meta.page {
                    Text("p.\(page)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let section = chunk.meta.section, !section.isEmpty {
                    Text("· \(section)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            Text(chunk.text)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(8)
        }
        .padding(10)
        .background(DesignTokens.secondaryFill, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
    }
}

// MARK: - Ingest drop target

private struct IngestDropTarget: View {
    let collectionID: CollectionID
    @Bindable var environment: AppEnvironment
    @Binding var refreshTrigger: Int

    @State private var isTargeted: Bool = false
    @State private var showFilePicker: Bool = false
    @State private var lastSkipMessage: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("Drop files or folders here")
                .font(.callout.bold())
            Text("PDF, .md, .txt, source code. Folders are walked recursively; hidden files and unsupported types are skipped.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Choose files or folder…") { showFilePicker = true }
                .controlSize(.small)
            if let skipped = lastSkipMessage {
                Text(skipped)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadius)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.gray.opacity(0.4))
        )
        .background(
            isTargeted ? Color.accentColor.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius)
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handle(providers: providers)
            return true
        }
        // Allow both individual files and whole folders in one picker.
        // `.item` covers any file leaf; `.folder` makes folders selectable
        // as a leaf (Open button enabled) rather than just navigable into.
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item, .folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                enqueueExpanded(urls)
            }
        }
    }

    private func handle(providers: [NSItemProvider]) {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await loadFileURL(from: provider) {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            enqueueExpanded(urls)
        }
    }

    /// Walk any folders in `urls`, filter by supported extensions, and
    /// enqueue. Surfaces a small "skipped N" status so the user knows
    /// when a recursive drop excluded a bunch of non-ingestable files.
    @MainActor
    private func enqueueExpanded(_ urls: [URL]) {
        let queue = ingestQueue()
        let expander = IngestFolderExpander(supportedExtensions: queue.supportedExtensions)
        let result = expander.expand(urls)
        if !result.urls.isEmpty {
            queue.enqueue(urls: result.urls, into: collectionID)
            refreshTrigger += 1
        }
        lastSkipMessage = skipSummary(result: result)
    }

    private func skipSummary(result: IngestFolderExpander.Result) -> String? {
        var parts: [String] = []
        if !result.urls.isEmpty {
            parts.append("queued \(result.urls.count)")
        }
        let totalSkipped = result.skippedHidden + result.skippedUnknownType + result.skippedTooBig
        if totalSkipped > 0 {
            var detail: [String] = []
            if result.skippedUnknownType > 0 { detail.append("\(result.skippedUnknownType) unsupported") }
            if result.skippedTooBig > 0 { detail.append("\(result.skippedTooBig) too large") }
            if result.skippedHidden > 0 { detail.append("\(result.skippedHidden) hidden") }
            parts.append("skipped \(totalSkipped) (\(detail.joined(separator: ", ")))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    private func ingestQueue() -> IngestQueue {
        if let existing = environment.ingestQueue { return existing }
        let q = IngestQueue(store: environment.collectionStore, ingestor: environment.ingestor)
        environment.ingestQueue = q
        return q
    }
}

// MARK: - Ingest progress

private struct IngestProgressView: View {
    @Bindable var environment: AppEnvironment
    let collectionID: CollectionID
    /// Failure rows whose full error message is expanded. Ids, not indices —
    /// the failures list shifts as later files fail or entries are cleared.
    @State private var expandedFailureIDs: Set<UUID> = []

    var body: some View {
        // Only summarise entries for the currently-selected collection. A
        // single shared IngestQueue serves all collections so progress
        // survives pane switches, but the per-collection view should never
        // leak entries from a different (or deleted) collection.
        //
        // Compact by design: a bulk drop can queue hundreds of files, and a
        // per-file row list has no bounded height — it buries the document
        // List and pushes its own buttons off-screen (issue #3). One summary
        // row + a capped failures list keeps the worst case ~170 pt tall no
        // matter how many files are queued.
        let summary = IngestSummary(
            entries: environment.ingestQueue?.entries ?? [],
            collectionID: collectionID
        )
        if !summary.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if summary.isActive {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            ProgressView(value: Double(summary.done), total: Double(summary.total))
                                .controlSize(.small)
                            HStack(spacing: 6) {
                                Text("Ingesting \(min(summary.done + 1, summary.total)) of \(summary.total)")
                                    .font(.caption)
                                    .monospacedDigit()
                                if let name = summary.currentFilename {
                                    Text(name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                        Button("Cancel", role: .destructive) {
                            environment.ingestQueue?.cancel(collectionID: collectionID)
                        }
                        .controlSize(.small)
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: summary.failed > 0
                            ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(summary.failed > 0 ? .yellow : .green)
                        finishedText(summary)
                            .font(.caption)
                        Spacer()
                        Button("Clear done") {
                            environment.ingestQueue?.clearCompleted(collectionID: collectionID)
                        }
                        .controlSize(.small)
                    }
                }
                if !summary.failures.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(summary.failures) { entry in
                                failureRow(entry)
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    /// One failure row: filename plus its error, one line when collapsed;
    /// click toggles the full (possibly multi-line) message. The list stays
    /// inside the capped ScrollView either way, so expanding can't push the
    /// pane's contents off-screen.
    @ViewBuilder
    private func failureRow(_ entry: IngestQueue.Entry) -> some View {
        let isExpanded = expandedFailureIDs.contains(entry.id)
        let message: String? = {
            if case .failed(let msg) = entry.status { return msg }
            return nil
        }()
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(entry.filename)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if !isExpanded, let message {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            if isExpanded, let message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isExpanded {
                expandedFailureIDs.remove(entry.id)
            } else {
                expandedFailureIDs.insert(entry.id)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isExpanded ? Text("Collapse error details") : Text("Expand error details"))
    }

    /// "300 imported, 2 failed, 5 cancelled" — zero-count parts omitted.
    private func finishedText(_ summary: IngestSummary) -> Text {
        var parts: [Text] = []
        if summary.succeeded > 0 { parts.append(Text("\(summary.succeeded) imported")) }
        if summary.failed > 0 { parts.append(Text("\(summary.failed) failed")) }
        if summary.cancelled > 0 { parts.append(Text("\(summary.cancelled) cancelled")) }
        guard var result = parts.first else { return Text("Import complete") }
        for part in parts.dropFirst() { result = Text("\(result), \(part)") }
        return result
    }
}

// MARK: - New collection sheet

private struct NewCollectionSheet: View {
    @Bindable var environment: AppEnvironment
    @Binding var isPresented: Bool
    var onCreated: () -> Void
    @State private var name: String = "New collection"
    @State private var error: String?
    @State private var isWorking: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New collection").font(.title3.bold())
            Text("Documents are embedded on-device. No network access required.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .disabled(isWorking)
            if isWorking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading model\u{2026}")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button("Create") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        error = "Name is required."
                        return
                    }
                    isWorking = true
                    error = nil
                    Task {
                        do {
                            let container = try await MLXEmbedderLoader.shared.shared()
                            let embedder = MLXQwen3Embedder(container: container)
                            _ = try await environment.collectionStore.createCollection(
                                name: trimmed,
                                embedder: embedder,
                                summary: nil,
                                distance: .cosine
                            )
                            isWorking = false
                            isPresented = false
                            onCreated()
                        } catch {
                            isWorking = false
                            self.error = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
