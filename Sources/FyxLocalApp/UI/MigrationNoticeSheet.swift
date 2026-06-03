// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import FyxLocalCore

/// Shown once on launch when one or more state migrations produced a user
/// notice (e.g. the Apple tools being disabled after the FyxLocal rebrand). All
/// pending notices are listed together so a combined multi-version upgrade reads
/// as a single update summary. Inform-only: one Dismiss button.
struct MigrationNoticeSheet: View {
    let notices: [MigrationNotice]
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("FyxLocal was updated", bundle: .module)
                .font(.title2.bold())

            Text("Some changes were made during this update:", bundle: .module)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(notices, id: \.titleKey) { notice in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(LocalizedStringKey(notice.titleKey), bundle: .module)
                            .font(.headline)
                        Text(LocalizedStringKey(notice.bodyKey), bundle: .module)
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Text("Dismiss", bundle: .module)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
