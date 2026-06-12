// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import FyxLocalCore
#if canImport(AppKit)
import AppKit
import ImageIO
#endif

/// Per-message actions, threaded in as closures rather than a reference to the
/// view model. Keeping `MessageView` value-typed (no `@Bindable` VM) avoids
/// re-rendering every visible row when unrelated VM state changes — the
/// streaming hot path the file's comments call out. `nil` actions hide their
/// affordance (e.g. an export/preview transcript with no live VM behind it).
struct MessageActions {
    var copy: ((MessageID) -> Void)? = nil
    var edit: ((MessageID) -> Void)? = nil
    var regenerate: ((MessageID) -> Void)? = nil
    var delete: ((MessageID) -> Void)? = nil
    /// True while a reply is streaming — disables the mutating actions.
    var isStreaming: Bool = false
}

struct MessageView: View {
    let message: Message
    var contextTokens: Int? = nil
    var failureError: String? = nil
    var onRetry: (() -> Void)? = nil
    /// Id of the message currently being streamed into, if any. Used to drive
    /// live-thinking UI: the streaming row shows a "Thinking…" pill and its
    /// reasoning block auto-expands until the first text delta arrives.
    var streamingMessageID: MessageID? = nil
    /// Per-message action callbacks (copy/edit/regenerate/delete). Empty by
    /// default so non-interactive renders (exports, dropped-message previews)
    /// show no affordances.
    var actions: MessageActions = MessageActions()

    /// Whether the pointer is over this row — fades in the hover action bar.
    @State private var isHovering = false

    /// True while the model is mid-turn on *this* message and hasn't started
    /// emitting visible text yet. Drives the pill + reasoning-block expand.
    /// Computed once at the top of `body` (see the `let` there) and passed
    /// explicitly into the row sub-views — calling it on every render of
    /// every visible row was the post-thinking-commit hot path at 70k.
    /// Iterates `reversed()` because once text streaming starts, the text
    /// item is always at the tail of `contentItems` — O(1) common case.
    private func computeIsActivelyThinking() -> Bool {
        guard message.id == streamingMessageID else { return false }
        for item in message.contentItems.reversed() {
            if case .text(let s) = item, !s.isEmpty { return false }
        }
        return true
    }

    var body: some View {
        let isActivelyThinking = computeIsActivelyThinking()
        // Pre-pair tool results with the call they belong to, so a
        // `.toolCall` row renders both halves in one combined box and the
        // matching `.toolResult` row is skipped during iteration.
        // RequestPayloadBuilder still lowers them as separate input items
        // when re-sending history — this pairing is purely visual.
        let resultsByCallID: [String: ToolResultRecord] = Dictionary(
            message.contentItems.compactMap { item -> (String, ToolResultRecord)? in
                if case .toolResult(let r) = item { return (r.callID, r) }
                return nil
            },
            uniquingKeysWith: { first, _ in first }
        )
        // Set of call ids that DO have a preceding `.toolCall` item — those
        // results are folded into the combined box; the rest fall through
        // to the defensive standalone render.
        let pairedCallIDs: Set<String> = Set(
            message.contentItems.compactMap { item -> String? in
                if case .toolCall(let r) = item { return r.id }
                return nil
            }
        )
        Group {
            if message.role == .user {
                userRow(resultsByCallID: resultsByCallID, pairedCallIDs: pairedCallIDs)
            } else {
                standardRow(
                    isActivelyThinking: isActivelyThinking,
                    resultsByCallID: resultsByCallID,
                    pairedCallIDs: pairedCallIDs
                )
            }
        }
        .padding(.vertical, 6)
        // Hover action bar. Fades + drifts in on hover; the same actions are
        // also on the right-click context menu (trackpad-friendly). For user
        // rows the bubble hugs the trailing edge, so the bar sits leading —
        // opposite the content instead of on top of it.
        .overlay(alignment: message.role == .user ? .topLeading : .topTrailing) {
            if hasAnyAction {
                MessageActionsBar(message: message, actions: actions)
                    .padding(message.role == .user ? .leading : .trailing, 4)
                    .opacity(isHovering ? 1 : 0)
                    .offset(y: isHovering ? 0 : 4)
                    .animation(Motion.quick, value: isHovering)
                    // Don't steal hover/clicks when hidden.
                    .allowsHitTesting(isHovering)
            }
        }
        // Make the WHOLE row rect a hover target — not just the (possibly
        // short, single-line) text. Without this, .onHover only fires over
        // opaque content, so a one-word message left the area under the
        // top-trailing action bar non-hoverable and the icons unreachable.
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            if hasAnyAction {
                MessageActionsMenu(message: message, actions: actions)
            }
        }
    }

    /// User messages: a right-aligned soft bubble. The alignment IS the role
    /// marker — no badge, which keeps the transcript quieter than before.
    @ViewBuilder
    private func userRow(
        resultsByCallID: [String: ToolResultRecord],
        pairedCallIDs: Set<String>
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 56)
            VStack(alignment: .trailing, spacing: 6) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(message.contentItems.enumerated()), id: \.offset) { _, item in
                        contentView(
                            for: item,
                            isActivelyThinking: false,
                            resultsByCallID: resultsByCallID,
                            pairedCallIDs: pairedCallIDs
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    DesignTokens.userBubbleFill,
                    in: RoundedRectangle(cornerRadius: DesignTokens.userBubbleRadius)
                )
                if let failureError, let onRetry {
                    FailureRetryBanner(message: failureError, onRetry: onRetry)
                }
                if !metricsLine.isEmpty {
                    Text(metricsLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Assistant / system / tool rows: full-width content with a slim leading
    /// marker — the assistant's is just a gradient sparkle, no box.
    @ViewBuilder
    private func standardRow(
        isActivelyThinking: Bool,
        resultsByCallID: [String: ToolResultRecord],
        pairedCallIDs: Set<String>
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            roleMarker
                .frame(width: 24, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                if isActivelyThinking {
                    ThinkingPill()
                }
                ForEach(Array(message.contentItems.enumerated()), id: \.offset) { _, item in
                    contentView(
                        for: item,
                        isActivelyThinking: isActivelyThinking,
                        resultsByCallID: resultsByCallID,
                        pairedCallIDs: pairedCallIDs
                    )
                }
                if let failureError, let onRetry {
                    FailureRetryBanner(message: failureError, onRetry: onRetry)
                }
                if !metricsLine.isEmpty {
                    Text(metricsLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Which mutating actions apply to this row (copy is always available when
    /// wired; edit only to user rows, regenerate only to assistant rows).
    private var hasAnyAction: Bool {
        actions.copy != nil || actions.delete != nil
            || (message.role == .user && actions.edit != nil)
            || (message.role == .assistant && actions.regenerate != nil)
    }

    private var metricsLine: String {
        var parts: [String] = []
        if let usage = message.usage {
            parts.append("\(usage.inputTokens) → \(usage.outputTokens) tokens")
            if let cached = usage.cachedInputTokens, cached > 0 {
                parts.append("\(cached) cached")
            }
            if let reasoning = usage.reasoningTokens, reasoning > 0 {
                parts.append("\(reasoning) reasoning")
            }
        }
        if let duration = message.generationDuration, duration > 0 {
            parts.append(String(format: "%.1fs", duration))
            if let tps = message.tokensPerSecond, tps.isFinite {
                let format = tps >= 100 ? "%.0f tok/s" : "%.1f tok/s"
                parts.append(String(format: format, tps))
            }
        }
        if let ctx = contextTokens, ctx > 0 {
            parts.append("context \(ctx.tokenCountLabel)")
        }
        return parts.joined(separator: " · ")
    }

    /// Leading marker for non-user rows. The assistant gets a bare gradient
    /// sparkle (no box — the lightest possible mark); system/tool keep a
    /// compact duotone badge since they're rare and benefit from the label.
    @ViewBuilder
    private var roleMarker: some View {
        switch message.role {
        case .assistant:
            Image(systemName: "sparkle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignTokens.sparkleGradient)
        case .system:
            compactBadge(symbol: "gearshape.fill", base: .gray)
        case .tool:
            compactBadge(symbol: "wrench.and.screwdriver.fill", base: .green)
        case .user:
            EmptyView() // user rows use the bubble layout, no marker
        }
    }

    private func compactBadge(symbol: String, base: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(6)
            .background(DesignTokens.badgeGradient(base), in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private func contentView(
        for item: MessageContent,
        isActivelyThinking: Bool,
        resultsByCallID: [String: ToolResultRecord],
        pairedCallIDs: Set<String>
    ) -> some View {
        switch item {
        case .text(let text):
            if message.role == .user {
                Text(text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                MarkdownView(source: text)
            }
        case .reasoningSummary(let text):
            ReasoningBlock(text: text, isActive: isActivelyThinking)
        case .thinking(let text, _):
            // Signed Anthropic thinking renders exactly like a summary; the
            // signature is replay plumbing, not display.
            ReasoningBlock(text: text, isActive: isActivelyThinking)
        case .redactedThinking:
            // Opaque safety-encrypted block — kept for replay, nothing to show.
            EmptyView()
        case .toolCall(let rec):
            ToolCallResultBlock(call: rec, result: resultsByCallID[rec.id])
        case .toolResult(let result):
            // Already folded into the matching call's combined box above.
            // Defensive fallback: if no call ever appeared for this result
            // (data corruption / out-of-order arrival), render it standalone
            // so the user still sees the data.
            if pairedCallIDs.contains(result.callID) {
                EmptyView()
            } else {
                ToolCallResultBlock(call: nil, result: result)
            }
        case .image(let ref):
#if canImport(AppKit)
            MessageImageView(ref: ref)
#endif
        case .attachment(let ref):
            Label(ref.filename ?? "attachment", systemImage: "paperclip")
                .padding(8)
                .background(DesignTokens.secondaryFill, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
        }
    }
}

#if canImport(AppKit)
/// Renders a message image from the BlobStore without blocking scrolling.
///
/// The old path read the blob and built an `NSImage` synchronously inside
/// `body` — on the main thread, on every body evaluation — and LazyVStack
/// tears rows down offscreen, so every scroll pass over an image re-read and
/// re-decoded it mid-gesture. That was a visible hitch ("scroll gets stuck at
/// the bottom of the image").
///
/// Now: the first appearance reads + downsamples off the main thread (ImageIO
/// thumbnail at ≤1024px — the view renders at ≤480pt, decoding a multi-MP
/// photo at full size was pure waste) behind a fixed-size placeholder, and the
/// result lands in a process-wide cache keyed by content hash. Every later
/// materialization — including all scroll-back passes — renders synchronously
/// from cache with stable layout.
private struct MessageImageView: View {
    let ref: BlobRef
    @State private var image: NSImage?
    @State private var failed = false

    init(ref: BlobRef) {
        self.ref = ref
        // Re-materialized rows render instantly: seed from cache so there's
        // no placeholder flash (and no layout jump) on scroll-back.
        _image = State(initialValue: MessageImageCache.image(for: ref))
    }

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 480)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
        } else if failed {
            // Missing/undecodable blob — match the old behaviour (render
            // nothing) rather than spin forever.
            EmptyView()
        } else {
            RoundedRectangle(cornerRadius: DesignTokens.smallRadius)
                .fill(DesignTokens.secondaryFill)
                .frame(maxWidth: 480)
                .frame(height: 220)
                .overlay(ProgressView().controlSize(.small))
                .task(id: ref.sha256) {
                    if let loaded = await MessageImageCache.load(ref) {
                        image = loaded
                    } else {
                        failed = true
                    }
                }
        }
    }
}

/// Process-wide decoded-image cache, keyed by blob content hash. Cost-bounded
/// so a long transcript of screenshots can't pin unbounded memory; NSCache
/// evicts under pressure.
private enum MessageImageCache {
    /// One transfer of an immutable, freshly-created NSImage out of the decode
    /// task. NSImage isn't Sendable, but nothing mutates it after creation.
    private struct Box: @unchecked Sendable { let image: NSImage }

    // NSCache is documented thread-safe ("you can add, remove, and query
    // items in the cache from different threads") but predates Sendable.
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 128 * 1024 * 1024
        return c
    }()

    static func image(for ref: BlobRef) -> NSImage? {
        cache.object(forKey: ref.sha256 as NSString)
    }

    /// Read + downsample off the main thread, then cache. Returns nil when the
    /// blob is missing/undecodable (the row simply shows nothing, as before).
    static func load(_ ref: BlobRef) async -> NSImage? {
        if let hit = image(for: ref) { return hit }
        let box: Box? = await Task.detached(priority: .userInitiated) {
            guard let data = try? BlobStore.shared.data(for: ref),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,   // honour EXIF rotation
                      kCGImageSourceThumbnailMaxPixelSize: 1024,          // 480pt view @2x
                  ] as CFDictionary)
            else { return nil }
            return Box(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
        }.value
        guard let box else { return nil }
        // Cost ≈ decoded bitmap bytes (RGBA), not the on-disk size.
        cache.setObject(box.image, forKey: ref.sha256 as NSString, cost: Int(box.image.size.width * box.image.size.height * 4))
        return box.image
    }
}
#endif

struct ReasoningBlock: View {
    let text: String
    var isActive: Bool = false
    /// `nil` means "follow the live-thinking state" (expanded while active,
    /// collapsed when not). The first explicit user toggle records a `Bool`
    /// here and from then on the user's choice wins for the life of this
    /// view. New messages get a fresh @State so auto behaviour returns.
    @State private var userOverride: Bool? = nil

    private var effectiveExpanded: Bool {
        userOverride ?? isActive
    }

    var body: some View {
        let binding = Binding<Bool>(
            get: { effectiveExpanded },
            set: { userOverride = $0 }
        )
        DisclosureGroup(isExpanded: binding) {
            Text(text)
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                // Pin to the leading edge + full width. Without this the Text
                // sizes to its content and centres in the box, so streaming
                // reasoning starts mid-box and visibly shifts left as it fills.
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label("Thinking", systemImage: "brain")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(DesignTokens.quietFill, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
        .hairline(in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
        .animation(Motion.spring, value: effectiveExpanded)
    }
}

/// Small pulsing pill shown at the top of the streaming-message body while
/// the model is producing reasoning content or pre-first-text. Disappears
/// the instant the first text delta arrives.
struct ThinkingPill: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignTokens.sparkleGradient)
                .symbolEffect(.variableColor.iterative, options: .repeating)
            // Reuses the existing "Thinking" key. Xcode normalises trailing
            // punctuation when generating string-catalog symbols, so we
            // can't carry both "Thinking" and "Thinking…" — append the
            // ellipsis with a separate Text fragment.
            (Text("Thinking") + Text("\u{2026}"))
                .font(.caption)
                .italic()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(DesignTokens.quietFill, in: Capsule())
        .shimmer(active: true)          // pill only exists while reasoning
        .clipShape(Capsule())
        .hairline(in: Capsule())
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

/// One collapsible box per tool invocation, holding both the call (args)
/// and the matching result (output) if it has arrived. Replaces what used
/// to be two stacked boxes per tool turn. The data model still stores
/// `.toolCall` and `.toolResult` as separate `MessageContent` items so
/// `RequestPayloadBuilder.messageItems(for:)` can lower them into the
/// distinct OpenAI Responses input items the wire requires — pairing is
/// purely visual, handled by `MessageView`.
struct ToolCallResultBlock: View {
    /// Optional so a stranded `.toolResult` with no matching `.toolCall`
    /// still renders defensively as a result-only box.
    let call: ToolCallRecord?
    let result: ToolResultRecord?
    @State private var expanded: Bool

    init(call: ToolCallRecord?, result: ToolResultRecord?) {
        self.call = call
        self.result = result
        // Chart and map results render the visual as their primary affordance —
        // start expanded so the user sees it immediately. Other tool
        // results default to collapsed to keep the transcript scan-able.
        _expanded = State(initialValue: result?.display == .chart || result?.display == .map)
    }

    /// If the result reports an error, treat the whole invocation as failed
    /// even when the call's own status field still says `.succeeded`. This
    /// keeps the visual feedback consistent regardless of which side the
    /// failure originated from.
    private var effectiveStatus: ToolStatus {
        if let result, result.isError { return .failed }
        return call?.status ?? .succeeded
    }

    private var displayName: String {
        call?.name ?? "Tool result"
    }

    /// One-line summary for the collapsed label, derived from known
    /// tool-arg shapes so common tools show the URL / query instead of raw
    /// JSON. Unknown tools fall back to a truncated args preview.
    private var collapsedSummary: String {
        guard let call,
              let data = call.argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }
        switch call.name {
        case "web_search", "rag_search":
            return (obj["query"] as? String) ?? ""
        case "web_fetch":
            return (obj["url"] as? String) ?? ""
        case "make_chart":
            // Just the chart type — using the user-supplied title here
            // duplicates what's already rendered inside the chart itself.
            // "make_chart  bar" / "line" / "pie" is enough context for
            // the collapsed row.
            return (obj["type"] as? String) ?? ""
        default:
            let trimmed = call.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "{}" || trimmed.isEmpty { return "" }
            return String(trimmed.prefix(80))
        }
    }

    /// True when the result is a chart. Charts are their own visualisation
    /// of the underlying data, so we suppress the raw-JSON arguments
    /// section, the "Result" label, and the divider — just the chart, in
    /// the same collapsible box, with no JSON noise.
    private var isChart: Bool {
        result?.display == .chart && !(result?.isError ?? false)
    }
    private var isMap: Bool {
        result?.display == .map && !(result?.isError ?? false)
    }
    /// A self-contained visual widget (chart/map) renders without the
    /// arguments/Result-label/divider chrome — just the widget.
    private var isWidget: Bool { isChart || isMap }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if !isWidget, let call {
                    argumentsSection(call)
                }
                if let result {
                    if !isWidget, call != nil { Divider() }
                    resultSection(result)
                } else if call?.status == .running {
                    Label("Awaiting result\u{2026}", systemImage: "ellipsis")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.caption)
                Text(displayName)
                    .font(.callout.bold())
                let summary = collapsedSummary
                if !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                statusBadge(for: effectiveStatus)
            }
        }
        .padding(10)
        .background(
            (effectiveStatus == .failed ? DesignTokens.errorFill : DesignTokens.quietFill),
            in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius)
        )
        .hairline(in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
        .animation(Motion.spring, value: expanded)
    }

    @ViewBuilder
    private func argumentsSection(_ call: ToolCallRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Arguments")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(call.argumentsJSON.isEmpty ? "{}" : call.argumentsJSON)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func resultSection(_ result: ToolResultRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Charts are their own affordance — no "Result" label above
            // the chart. Errors and other tool results still get one so
            // the user has visual context for the payload below.
            if !isWidget {
                Text(result.isError ? "Result (error)" : "Result")
                    .font(.caption2)
                    .foregroundStyle(result.isError ? .red : .secondary)
            }
            // Dispatch on the display hint so non-JSON-shaped results can
            // render as their own widgets. .chart → ToolChartView (Swift
            // Charts bar/line/pie); .map → ToolMapView (MapKit). Default
            // falls back to pretty-printed JSON — same as original behaviour.
            switch result.display {
            case .chart:
                ToolChartView(json: result.outputJSON)
            case .map:
                ToolMapView(json: result.outputJSON)
            default:
                Text(Self.prettyJSON(for: result.outputJSON))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func statusBadge(for status: ToolStatus) -> some View {
        switch status {
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "stop.circle.fill").foregroundStyle(.orange)
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        }
    }

    private static func prettyJSON(for raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8) else {
            return raw
        }
        return str
    }
}

struct FailureRetryBanner: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer()
            Button("Retry", action: onRetry)
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(.red)
        }
        .padding(8)
        .background(DesignTokens.errorFill, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Per-message action affordances

/// One per-message action: a system-image, a localized title, an enabled flag,
/// and the closure to run. Shared by the hover bar (icon buttons) and the
/// context menu (labeled rows) so the two stay in lockstep.
private struct MessageActionItem: Identifiable {
    let id: String           // stable key for ForEach (the symbol name)
    let systemImage: String
    let title: LocalizedStringKey
    let isEnabled: Bool
    let isDestructive: Bool
    let run: () -> Void
}

/// Build the ordered list of actions that apply to `message`. Copy is always
/// available (read-only, even mid-stream); edit only on user rows; regenerate
/// only on assistant rows; delete on any row. Mutating actions are disabled
/// while a reply is streaming.
private func messageActionItems(for message: Message, _ actions: MessageActions) -> [MessageActionItem] {
    var items: [MessageActionItem] = []
    if let copy = actions.copy {
        items.append(MessageActionItem(
            id: "copy", systemImage: "doc.on.doc", title: "Copy",
            isEnabled: true, isDestructive: false, run: { copy(message.id) }
        ))
    }
    if message.role == .user, let edit = actions.edit {
        items.append(MessageActionItem(
            id: "edit", systemImage: "pencil", title: "Edit",
            isEnabled: !actions.isStreaming, isDestructive: false, run: { edit(message.id) }
        ))
    }
    if message.role == .assistant, let regenerate = actions.regenerate {
        items.append(MessageActionItem(
            id: "regen", systemImage: "arrow.clockwise", title: "Regenerate",
            isEnabled: !actions.isStreaming, isDestructive: false, run: { regenerate(message.id) }
        ))
    }
    if let delete = actions.delete {
        items.append(MessageActionItem(
            id: "delete", systemImage: "trash", title: "Delete",
            isEnabled: !actions.isStreaming, isDestructive: true, run: { delete(message.id) }
        ))
    }
    return items
}

/// Compact row of icon buttons shown on hover at the top-trailing of a message.
private struct MessageActionsBar: View {
    let message: Message
    let actions: MessageActions

    var body: some View {
        HStack(spacing: 2) {
            ForEach(messageActionItems(for: message, actions)) { item in
                Button(action: item.run) {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(PressableButtonStyle())
                .foregroundStyle(item.isDestructive ? Color.red : Color.secondary)
                .disabled(!item.isEnabled)
                .help(item.title)
            }
        }
        .padding(2)
        .glassChrome(in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
    }
}

/// The same actions as labeled rows for the right-click context menu.
private struct MessageActionsMenu: View {
    let message: Message
    let actions: MessageActions

    var body: some View {
        ForEach(messageActionItems(for: message, actions)) { item in
            Button(role: item.isDestructive ? .destructive : nil, action: item.run) {
                Label(item.title, systemImage: item.systemImage)
            }
            .disabled(!item.isEnabled)
        }
    }
}
