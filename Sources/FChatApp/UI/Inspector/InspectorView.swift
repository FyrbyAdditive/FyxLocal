import SwiftUI
import FChatCore

struct InspectorView: View {
    @Bindable var viewModel: ChatViewModel
    @Bindable var environment: AppEnvironment

    var body: some View {
        Form {
            Section("Active provider") {
                if let record = environment.currentProvider() {
                    LabeledContent("Provider") {
                        Text(record.displayName).foregroundStyle(.secondary)
                    }
                    LabeledContent("Model") {
                        Text(record.defaultModel ?? "—").foregroundStyle(.secondary)
                    }
                    samplingSummary(for: record)
                    Text("Configure provider, model, and sampling in Settings → Providers.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No provider configured. Open Settings → Providers.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Conversation") {
                LabeledContent("Created") {
                    Text(viewModel.conversation.createdAt, format: .dateTime)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Messages") {
                    Text("\(viewModel.conversation.messages.count)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func samplingSummary(for record: ProviderRecord) -> some View {
        let s = record.sampling
        LabeledContent("Temperature") {
            Text(s.temperature.map { String(format: "%.2f", $0) } ?? "default")
                .foregroundStyle(.secondary)
        }
        LabeledContent("top_p") {
            Text(s.topP.map { String(format: "%.2f", $0) } ?? "default")
                .foregroundStyle(.secondary)
        }
        LabeledContent("Max output tokens") {
            Text(s.maxOutputTokens.map(String.init) ?? "default")
                .foregroundStyle(.secondary)
        }
        LabeledContent("Reasoning") {
            Text(s.reasoningEffort?.rawValue.capitalized ?? "default")
                .foregroundStyle(.secondary)
        }
        LabeledContent("Max tool iterations") {
            Text("\(s.maxToolIterations)")
                .foregroundStyle(.secondary)
        }
    }
}
