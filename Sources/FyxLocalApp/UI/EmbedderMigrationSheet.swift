// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI

/// Blocking, non-dismissable sheet shown once after the embedding model is
/// upgraded, while existing document collections are re-embedded from their
/// stored text. There is no close button — RAG search would dimension-mismatch
/// mid-migration, so the user waits (it's fast on the 0.6B model). The sheet
/// auto-dismisses via its binding when the migrator finishes.
struct EmbedderMigrationSheet: View {
    @Bindable var migrator: ReembedMigrator
    /// Called when the user acknowledges a finished/failed run.
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 28))
                    .foregroundStyle(DesignTokens.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Upgrading document search", bundle: .module)
                        .font(.title2.bold())
                    Text("FyxLocal switched to a smaller, faster on-device model. Your collections are being re-indexed — your documents are untouched.", bundle: .module)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            switch migrator.phase {
            case .idle, .running:
                progressBody
            case .finished:
                doneBody(success: true)
            case .failed(let message):
                doneBody(success: false, message: message)
            }
        }
        .padding(28)
        .frame(width: 460)
        .interactiveDismissDisabled(true)
    }

    @ViewBuilder
    private var progressBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: migrator.fractionComplete)
                .progressViewStyle(.linear)
            HStack {
                if migrator.totalCollections > 1 {
                    Text("Collection \(migrator.currentCollectionIndex) of \(migrator.totalCollections)", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(migrator.fractionComplete * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !migrator.currentCollectionName.isEmpty {
                Text(migrator.currentCollectionName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private func doneBody(success: Bool, message: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if success {
                Label("Done — your document search is ready.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Re-indexing didn't finish", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    if let message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Spacer()
                Button {
                    onDone()
                } label: {
                    Text("Continue", bundle: .module)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
