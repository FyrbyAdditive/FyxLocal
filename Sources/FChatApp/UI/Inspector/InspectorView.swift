import SwiftUI
import FChatCore

struct InspectorView: View {
    @Bindable var viewModel: ChatViewModel
    @Bindable var environment: AppEnvironment

    var body: some View {
        Form {
            Section("Model") {
                providerPicker
                modelPicker
                HStack {
                    Button {
                        if let record = environment.provider(viewModel.conversation.settings.providerID) {
                            Task { await environment.refreshModels(for: record) }
                        }
                    } label: {
                        Label("Refresh models", systemImage: "arrow.clockwise")
                    }
                    Spacer()
                }
            }

            Section("Built-in tools") {
                Toggle("Web search", isOn: binding(for: "web_search"))
                Toggle("Web fetch", isOn: binding(for: "web_fetch"))
                Toggle("RAG search", isOn: binding(for: "rag_search"))
            }

            Section("Sampling") {
                LabeledContent("Max output tokens") {
                    Text(viewModel.conversation.settings.maxOutputTokens.map(String.init) ?? "—")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Temperature") {
                    Text(viewModel.conversation.settings.temperature.map { String(format: "%.2f", $0) } ?? "—")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Reasoning") {
                    Text(viewModel.conversation.settings.reasoningEffort?.rawValue ?? "—")
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
        .task(id: viewModel.conversation.settings.providerID) {
            // Auto-fetch on first open if we haven't yet.
            let pid = viewModel.conversation.settings.providerID
            if environment.detectedModels[pid] == nil, let record = environment.provider(pid) {
                await environment.refreshModels(for: record)
            }
        }
    }

    @ViewBuilder
    private var providerPicker: some View {
        Picker("Provider", selection: providerBinding) {
            ForEach(environment.providerRecords) { record in
                Text(record.displayName).tag(record.id)
            }
        }
    }

    @ViewBuilder
    private var modelPicker: some View {
        let pid = viewModel.conversation.settings.providerID
        let detected = environment.detectedModels[pid] ?? []
        let currentModel = viewModel.conversation.settings.model
        if detected.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text("Model")
                Spacer()
                TextField("model-id", text: modelTextBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
            Text("No models detected yet. Click Refresh, or set the API key and base URL in Settings.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Picker("Model", selection: modelBinding(detected: detected)) {
                if currentModel.isEmpty || !detected.contains(where: { $0.id == currentModel }) {
                    Text(currentModel.isEmpty ? "— pick a model —" : "\(currentModel) (not on server)")
                        .tag(currentModel)
                }
                ForEach(detected) { info in
                    Text(info.displayName).tag(info.id)
                }
            }
            if !currentModel.isEmpty && !detected.contains(where: { $0.id == currentModel }) {
                Text("Selected model isn't on the server. Pick one of \(detected.count) detected.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var providerBinding: Binding<ProviderID> {
        Binding(
            get: { viewModel.conversation.settings.providerID },
            set: { newID in
                var s = viewModel.conversation.settings
                s.providerID = newID
                if let pick = environment.detectedModels[newID]?.first?.id ?? environment.provider(newID)?.defaultModel {
                    s.model = pick
                }
                viewModel.conversation.settings = s
            }
        )
    }

    private func modelBinding(detected: [ModelInfo]) -> Binding<String> {
        Binding(
            get: { viewModel.conversation.settings.model },
            set: { newValue in
                var s = viewModel.conversation.settings
                s.model = newValue
                viewModel.conversation.settings = s
            }
        )
    }

    private var modelTextBinding: Binding<String> {
        Binding(
            get: { viewModel.conversation.settings.model },
            set: { newValue in
                var s = viewModel.conversation.settings
                s.model = newValue
                viewModel.conversation.settings = s
            }
        )
    }

    private func binding(for tool: String) -> Binding<Bool> {
        Binding(
            get: { viewModel.conversation.settings.enabledBuiltInTools.contains(tool) },
            set: { isOn in
                var s = viewModel.conversation.settings
                if isOn { s.enabledBuiltInTools.insert(tool) }
                else { s.enabledBuiltInTools.remove(tool) }
                viewModel.conversation.settings = s
            }
        )
    }
}
