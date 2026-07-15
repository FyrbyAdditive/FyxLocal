// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import AppKit

/// Compact hit-list rendering for `rag_search` tool results, replacing the
/// pretty-printed JSON blob. Document names become buttons that open the
/// original file when its ingest-time source path still exists on disk.
/// Falls back to nil (→ caller renders raw JSON) for old payload shapes or
/// error bodies.
struct RAGSearchResultView: View {
    /// App-local mirror of the tool's payload — the tool's own struct is
    /// private to FyxLocalTools, and a mirror keeps the layering clean.
    struct Payload: Decodable {
        struct Hit: Decodable {
            var documentName: String
            var page: Int?
            var section: String?
            var text: String
            var score: Double
            var sourcePath: String?
        }
        var query: String
        var collection: String
        var hits: [Hit]
    }

    let payload: Payload

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        self.payload = decoded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if payload.hits.isEmpty {
                Text("No matches", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(payload.hits.enumerated()), id: \.offset) { _, hit in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        sourceLabel(hit)
                        if let page = hit.page {
                            Text(verbatim: "p.\(page)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let section = hit.section, !section.isEmpty {
                            Text(verbatim: section)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 0)
                        Text(verbatim: String(format: "%.2f", hit.score))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Text(verbatim: hit.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func sourceLabel(_ hit: Payload.Hit) -> some View {
        switch SourceFileLink.availability(hit.sourcePath) {
        case .openable(let url):
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Text(verbatim: hit.documentName)
                    .font(.caption.weight(.medium))
                    .underline()
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Text("Reveal in Finder", bundle: .module)
                }
            }
            .help(Text("Open source file", bundle: .module))
        case .missing:
            Text(verbatim: hit.documentName)
                .font(.caption.weight(.medium))
                .help(Text("Original file not found", bundle: .module))
        case .none:
            Text(verbatim: hit.documentName)
                .font(.caption.weight(.medium))
        }
    }
}

/// Pure, testable classification of a hit's source path.
enum SourceFileLink {
    enum Availability: Equatable {
        /// The original file still exists — offer to open it.
        case openable(URL)
        /// A path was recorded but nothing is there any more.
        case missing
        /// No path was ever recorded (pre-feature ingests, bare-data ingests).
        case none
    }

    static func availability(_ path: String?, fileManager: FileManager = .default) -> Availability {
        guard let path, !path.isEmpty else { return .none }
        guard fileManager.fileExists(atPath: path) else { return .missing }
        return .openable(URL(fileURLWithPath: path))
    }
}
