import SwiftUI
import FChatCore

/// Chat transcript with sticky-bottom semantics implemented via inverted scroll.
///
/// The whole `ScrollView` is rotated 180°, and each row is rotated back. In the
/// flipped coordinate space the visual bottom (latest message) maps to scroll
/// offset 0 — so "stay pinned to the bottom" is just "stay at offset 0", which
/// SwiftUI's `ScrollView` does for free when content grows. No `scrollTo`
/// gymnastics, no user-vs-programmatic scroll detection, no race against
/// streaming deltas.
///
/// This is the same architecture used by iMessage, ChatGPT.app, and
/// `vellum-ai/vellum-assistant` (MIT, the pattern that inspired this port).
struct TranscriptView: View {
    let conversation: Conversation
    var failureForMessageID: MessageID? = nil
    var failureMessage: String? = nil
    var onRetry: (() -> Void)? = nil
    /// Indices of compaction record ids whose dropped originals are currently
    /// expanded by the user. Empty by default — originals are collapsed.
    @State private var expandedCompactions: Set<UUID> = []
    /// Viewport height, captured from the ScrollView geometry. Used to give
    /// the content a `minHeight` so an under-full transcript pins to the
    /// visual top (= the flipped layout's bottom) instead of free-floating.
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        // Render rows newest-first; the .flipped() below visually re-reverses
        // so the user sees them oldest-first with newest at the visual bottom.
        let rows = buildRows()

        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(rows) { row in
                    rowView(for: row)
                        .flipped()
                }
                if conversation.messages.isEmpty {
                    EmptyChatView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                        .flipped()
                }
            }
            .padding(.vertical, DesignTokens.panelPadding)
            // Pin under-full content to the visual top (= post-flip `.bottom`)
            // so a fresh chat with one short message anchors cleanly to the
            // top of the empty area instead of floating in the middle.
            .frame(minHeight: viewportHeight, alignment: .bottom)
        }
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.containerSize.height }) { _, h in
            viewportHeight = h
        }
        .flipped()
    }

    // MARK: - Row model

    /// Flat list of rows in *newest-first* order (so the ScrollView, once
    /// flipped, presents them oldest-first with newest at the visual bottom).
    private enum Row: Identifiable {
        case message(Message, contextTokens: Int?, failure: String?, retry: (() -> Void)?)
        case droppedMessage(Message)
        case compactionMarker(CompactionRecord, isExpanded: Bool)

        var id: AnyHashable {
            switch self {
            case .message(let m, _, _, _):      return AnyHashable(m.id)
            case .droppedMessage(let m):        return AnyHashable("dropped-\(m.id.rawValue)")
            case .compactionMarker(let r, _):   return AnyHashable("marker-\(r.id)")
            }
        }
    }

    private func buildRows() -> [Row] {
        let recordsByEnd: [Int: [CompactionRecord]] = Dictionary(
            grouping: conversation.compactions, by: \.toIndex
        )

        var rows: [Row] = []
        rows.reserveCapacity(conversation.messages.count + conversation.compactions.count)

        for (index, message) in conversation.messages.enumerated() {
            // A marker sits *before* the first kept message after a dropped block.
            if let records = recordsByEnd[index] {
                for record in records {
                    rows.append(.compactionMarker(record, isExpanded: expandedCompactions.contains(record.id)))
                }
            }

            let recordContainingThis = conversation.compactions.first { record in
                index >= record.fromIndex && index < record.toIndex
            }
            if let record = recordContainingThis {
                if expandedCompactions.contains(record.id) {
                    rows.append(.droppedMessage(message))
                }
                // Collapsed: skip the message; only the marker is visible.
            } else {
                rows.append(.message(
                    message,
                    contextTokens: conversation.contextTokensByMessage[message.id],
                    failure: failureForMessageID == message.id ? failureMessage : nil,
                    retry: failureForMessageID == message.id ? onRetry : nil
                ))
            }
        }

        // Reverse so the LazyVStack renders newest first; .flipped() then puts
        // them at the visual bottom in the original chronological order.
        return rows.reversed()
    }

    @ViewBuilder
    private func rowView(for row: Row) -> some View {
        switch row {
        case .message(let message, let contextTokens, let failure, let retry):
            MessageView(
                message: message,
                contextTokens: contextTokens,
                failureError: failure,
                onRetry: retry
            )
            .padding(.horizontal, DesignTokens.panelPadding)
            .id(message.id)

        case .droppedMessage(let message):
            MessageView(message: message)
                .opacity(0.55)
                .padding(.horizontal, DesignTokens.panelPadding)
                .id(message.id)

        case .compactionMarker(let record, let isExpanded):
            CompactionMarker(
                record: record,
                isExpanded: isExpanded,
                onToggle: {
                    if expandedCompactions.contains(record.id) {
                        expandedCompactions.remove(record.id)
                    } else {
                        expandedCompactions.insert(record.id)
                    }
                }
            )
            .padding(.horizontal, DesignTokens.panelPadding)
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Flipped modifier

/// Rotates a view 180° and mirrors it horizontally so that text reads correctly
/// after a parent flip. Apply once to the ScrollView, once to each row, and the
/// rotations cancel for content while inverting the scroll axis.
extension View {
    fileprivate func flipped() -> some View {
        rotationEffect(.degrees(180))
            .scaleEffect(x: -1, y: 1, anchor: .center)
    }
}

private struct EmptyChatView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Start a conversation")
                .font(.title3.weight(.semibold))
            Text("Type below to begin.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius))
    }
}
