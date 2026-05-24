import SwiftUI
import FChatCore

struct TranscriptView: View {
    let messages: [Message]
    @State private var scrollPosition: ScrollPosition = .init(idType: MessageID.self)

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(messages) { message in
                    MessageView(message: message)
                        .id(message.id)
                        .padding(.horizontal, DesignTokens.panelPadding)
                }
                if messages.isEmpty {
                    EmptyChatView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                }
            }
            .padding(.vertical, DesignTokens.panelPadding)
        }
        .scrollPosition($scrollPosition, anchor: .bottom)
        .onChange(of: messages.last?.id) { _, newID in
            if let newID {
                scrollPosition.scrollTo(id: newID, anchor: .bottom)
            }
        }
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
            Text("Pick a model in the inspector, then type below.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius))
    }
}
