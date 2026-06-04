// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalCore

/// Core-level coverage for the data semantics the per-message actions
/// (copy / edit / regenerate / delete) depend on. The action methods live on
/// the app-layer `ChatViewModel`, which can't be instantiated without a full
/// `AppEnvironment` (real RAG DB + EventKit providers); these tests pin the
/// underlying, env-free logic those methods rely on.
@Suite("Per-message action support")
struct MessageActionsSupportTests {

    private func tempStore() -> BlobStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("msgact-\(UUID().uuidString)", isDirectory: true)
        return BlobStore(root: dir)
    }

    // MARK: copy / edit text extraction

    @Test func plainTextSkipsReasoningAndKeepsText() {
        // Copy + edit both use Message.plainText: only the readable text parts,
        // joined by newlines, skipping reasoning / tool calls / images.
        let msg = Message(role: .assistant, contentItems: [
            .reasoningSummary("thinking out loud"),
            .text("Hello"),
            .toolCall(ToolCallRecord(id: "c1", name: "web_search", argumentsJSON: "{}")),
            .text("world"),
        ])
        #expect(msg.plainText == "Hello\nworld")
    }

    // MARK: messagesAfter / truncation index math

    /// Mirrors `ChatViewModel.messagesAfter`: count of messages sitting after
    /// the one with `id`. Drives the discard-warning threshold.
    private func messagesAfter(_ id: MessageID, in messages: [Message]) -> Int {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return 0 }
        return messages.count - 1 - index
    }

    @Test func messagesAfterCountsTrailingMessages() {
        let m0 = Message(role: .user, contentItems: [.text("a")])
        let m1 = Message(role: .assistant, contentItems: [.text("b")])
        let m2 = Message(role: .user, contentItems: [.text("c")])
        let m3 = Message(role: .assistant, contentItems: [.text("d")])
        let msgs = [m0, m1, m2, m3]
        #expect(messagesAfter(m0.id, in: msgs) == 3)
        #expect(messagesAfter(m2.id, in: msgs) == 1)
        #expect(messagesAfter(m3.id, in: msgs) == 0)        // last → no warning
        #expect(messagesAfter(MessageID(), in: msgs) == 0)  // unknown id
    }

    @Test func editTruncatesFromTargetOnward() {
        // Editing a user message removes it and everything after (linear
        // truncate + resend). `removeSubrange(index...)` is the operation.
        let m0 = Message(role: .user, contentItems: [.text("first")])
        let m1 = Message(role: .assistant, contentItems: [.text("reply")])
        let m2 = Message(role: .user, contentItems: [.text("second")])
        var msgs = [m0, m1, m2]
        let index = msgs.firstIndex(where: { $0.id == m1.id })!   // edit can also target an assistant index in regen
        msgs.removeSubrange(index...)
        #expect(msgs.map(\.id) == [m0.id])
    }

    // MARK: blob GC roots (the real delete-safety risk)

    @Test func gcKeepsBlobSharedByAnotherMessageAfterDelete() throws {
        // Two messages reference the SAME image bytes (content-addressed → one
        // blob). Deleting one message must NOT free a blob the other still
        // uses. This is the correctness crux of delete + gcBlobs.
        let store = tempStore()
        let bytes = Data("shared-image".utf8)
        let ref = try store.put(bytes, mimeType: "image/png")

        let kept = Message(role: .user, contentItems: [.image(ref), .text("keep me")])
        let deletedOnly = Message(role: .assistant, contentItems: [.image(ref)])
        // Survivors after deleting `deletedOnly`: just `kept`.
        let survivors = [kept]
        let liveHashes = Set(survivors.flatMap { $0.contentItems }.flatMap { $0.blobHashes })

        store.garbageCollect(keeping: liveHashes)
        #expect(store.contains(ref))   // still referenced by `kept` → survives
        _ = deletedOnly
    }

    @Test func gcFreesOrphanedBlobAfterDelete() throws {
        // A blob referenced by ONLY the deleted message becomes orphaned and
        // must be freed by the post-delete sweep.
        let store = tempStore()
        let orphanRef = try store.put(Data("orphan".utf8), mimeType: "image/png")
        let keepRef = try store.put(Data("survivor".utf8), mimeType: "image/png")

        let deleted = Message(role: .user, contentItems: [.image(orphanRef)])
        let survivor = Message(role: .user, contentItems: [.image(keepRef)])
        let liveHashes = Set([survivor].flatMap { $0.contentItems }.flatMap { $0.blobHashes })

        store.garbageCollect(keeping: liveHashes)
        #expect(!store.contains(orphanRef))   // orphaned → freed
        #expect(store.contains(keepRef))       // still referenced → kept
        _ = deleted
    }
}
