// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalApp

@Suite("SourceFileLink")
struct SourceFileLinkTests {
    @Test func existingFileIsOpenable() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sfl-\(UUID().uuidString).txt")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        guard case .openable(let opened) = SourceFileLink.availability(url.path) else {
            Issue.record("expected .openable")
            return
        }
        #expect(opened.path == url.path)
    }

    @Test func deletedPathIsMissing() {
        let gone = NSTemporaryDirectory() + "/definitely-gone-\(UUID().uuidString).txt"
        #expect(SourceFileLink.availability(gone) == .missing)
    }

    @Test func nilAndEmptyAreNone() {
        #expect(SourceFileLink.availability(nil) == .none)
        #expect(SourceFileLink.availability("") == .none)
    }

    @Test func payloadDecodesToolOutputShape() throws {
        let json = #"""
        {"query":"llamas","collection":"notes","hits":[
            {"chunkID":"11111111-2222-3333-4444-555555555555","documentName":"a.md","page":2,"section":"Intro","text":"llama facts","score":0.91,"sourcePath":"/tmp/a.md"},
            {"chunkID":"11111111-2222-3333-4444-666666666666","documentName":"b.md","text":"alpaca facts","score":0.5}
        ]}
        """#
        let view = RAGSearchResultView(json: json)
        let payload = try #require(view?.payload)
        #expect(payload.hits.count == 2)
        #expect(payload.hits[0].sourcePath == "/tmp/a.md")
        #expect(payload.hits[0].page == 2)
        #expect(payload.hits[1].sourcePath == nil)
    }

    @Test func malformedPayloadYieldsNilView() {
        #expect(RAGSearchResultView(json: #"{"error":"boom"}"#) == nil)
        #expect(RAGSearchResultView(json: "not json") == nil)
    }
}
