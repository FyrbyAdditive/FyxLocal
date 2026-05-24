import SwiftUI

struct ComposerView: View {
    @Bindable var viewModel: ChatViewModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            if let error = viewModel.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignTokens.errorFill, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: $viewModel.draftText)
                    .focused($focused)
                    .frame(minHeight: 40, maxHeight: DesignTokens.composerMaxHeight)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.composerCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.composerCornerRadius)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )

                Button {
                    if viewModel.isStreaming {
                        viewModel.cancel()
                    } else {
                        viewModel.send()
                    }
                } label: {
                    Image(systemName: viewModel.isStreaming ? "stop.fill" : "arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(DesignTokens.accent.gradient, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!viewModel.isStreaming && viewModel.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DesignTokens.panelPadding)
        .onAppear { focused = true }
    }
}
