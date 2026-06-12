// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI

enum DesignTokens {
    static let cornerRadius: CGFloat = 14
    static let smallRadius: CGFloat = 10
    static let composerCornerRadius: CGFloat = 18
    static let inlinePadding: CGFloat = 12
    static let panelPadding: CGFloat = 16
    static let composerMaxHeight: CGFloat = 220

    static let accent = Color.accentColor
    static let errorFill = Color.red.opacity(0.15)

    // MARK: - Neutrals (cool slate)

    /// The neutral the whole fill hierarchy hangs off. Slightly cool-cast
    /// slate instead of pure gray — same restraint, colder read.
    private static let slate = Color(red: 0.52, green: 0.58, blue: 0.68)

    /// Standard card/pill fill (was `gray.opacity(0.12)`).
    static let secondaryFill = slate.opacity(0.13)
    /// Quieter fill for inactive pills / code-block bodies (was gray 0.08).
    static let quietFill = slate.opacity(0.09)
    /// Slightly stronger fill for headers / hovered rows (was gray 0.10–0.15).
    static let strongFill = slate.opacity(0.18)

    // MARK: - Gradients

    /// The app's signature duotone — used on the send button and anywhere a
    /// single flat accent used to sit.
    static let accentGradient = LinearGradient(
        colors: [accent, Color.indigo],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// The assistant's sparkle mark.
    static let sparkleGradient = LinearGradient(
        colors: [Color.purple, Color.indigo, accent],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Compact role-badge gradients (tool/system rows keep badges; user and
    /// assistant messages are identified by layout instead).
    static func badgeGradient(_ base: Color) -> LinearGradient {
        LinearGradient(
            colors: [base.opacity(0.95), base.mixedWithIndigo],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - User bubble

    /// Fill for the user's right-aligned message bubble. Quiet accent wash —
    /// present in both modes without shouting.
    static let userBubbleFill = accent.opacity(0.14)
    static let userBubbleRadius: CGFloat = 16

    // MARK: - Sidebar

    /// Sidebar backgrounds, slightly deepened/cooled vs the old values.
    static let sidebarBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 18/255, green: 21/255, blue: 26/255, alpha: 1)
            : NSColor(srgbRed: 245/255, green: 247/255, blue: 249/255, alpha: 1)
    })
}

private extension Color {
    /// Blend toward indigo for duotone badge gradients without hand-picking
    /// a second colour per role.
    var mixedWithIndigo: Color {
        self.mix(with: .indigo, by: 0.45)
    }
}
