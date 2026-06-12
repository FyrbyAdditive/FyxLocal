// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI

// MARK: - Motion

/// Shared animation curves so every micro-interaction moves the same way.
/// Sparing by design: nothing here loops while idle.
enum Motion {
    /// Default spring for expand/collapse and layout settles.
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.82)
    /// Snappier spring for hover/press feedback.
    static let quick = Animation.spring(response: 0.22, dampingFraction: 0.86)
}

// MARK: - Hairline stroke ("top-lit edge")

/// The 1px gradient edge used on all floating chrome. Brighter at the top,
/// fading down — reads as light catching the edge of glass, and is most of
/// what makes a surface look premium instead of flat.
struct Hairline {
    static func gradient(_ scheme: ColorScheme, emphasized: Bool = false) -> LinearGradient {
        let top: Color
        let bottom: Color
        if scheme == .dark {
            top = .white.opacity(emphasized ? 0.45 : 0.22)
            bottom = .white.opacity(emphasized ? 0.18 : 0.06)
        } else {
            top = .black.opacity(emphasized ? 0.22 : 0.10)
            bottom = .black.opacity(emphasized ? 0.10 : 0.04)
        }
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }
}

extension View {
    /// Overlay a hairline gradient edge on `shape`.
    func hairline<S: InsettableShape>(in shape: S, emphasized: Bool = false) -> some View {
        modifier(HairlineModifier(shape: shape, emphasized: emphasized))
    }

    /// Floating-chrome treatment: glass material + hairline edge + soft lift
    /// shadow. Used for the composer field, hover action bars, chips and
    /// banners — surfaces that sit *above* the content plane. Flat cards
    /// (reasoning/tool/code blocks) deliberately do NOT use this.
    func glassChrome<S: InsettableShape>(in shape: S, emphasized: Bool = false) -> some View {
        modifier(GlassChromeModifier(shape: shape, emphasized: emphasized))
    }
}

private struct HairlineModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let emphasized: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.overlay(
            shape.strokeBorder(Hairline.gradient(scheme, emphasized: emphasized), lineWidth: 1)
        )
    }
}

private struct GlassChromeModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let emphasized: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: shape)
            .overlay(
                shape.strokeBorder(Hairline.gradient(scheme, emphasized: emphasized), lineWidth: 1)
            )
            .shadow(
                color: .black.opacity(scheme == .dark ? 0.28 : 0.10),
                radius: 10, x: 0, y: 3
            )
    }
}

// MARK: - Pressable button style

/// Hover + press feedback for icon buttons: slight grow on hover, slight
/// shrink on press. Quick spring; no opacity games.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Pressable(configuration: configuration)
    }

    private struct Pressable: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.92 : (hovering ? 1.06 : 1.0))
                .animation(Motion.quick, value: configuration.isPressed)
                .animation(Motion.quick, value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Shimmer sweep

extension View {
    /// A soft highlight that sweeps across the view while `active` — used on
    /// the Thinking pill so live reasoning visibly *breathes*. The overlay is
    /// only mounted while active, so nothing animates at idle. Callers clip
    /// (e.g. `.clipShape(Capsule())`) to keep the sweep inside their shape.
    func shimmer(active: Bool) -> some View {
        overlay {
            if active {
                ShimmerSweep().allowsHitTesting(false)
            }
        }
    }
}

private struct ShimmerSweep: View {
    @State private var phase: CGFloat = -0.6
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LinearGradient(
            colors: [
                .clear,
                (scheme == .dark ? Color.white : Color.white).opacity(scheme == .dark ? 0.22 : 0.55),
                .clear,
            ],
            startPoint: UnitPoint(x: phase - 0.4, y: 0.4),
            endPoint: UnitPoint(x: phase + 0.4, y: 0.6)
        )
        .onAppear {
            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                phase = 1.6
            }
        }
    }
}
