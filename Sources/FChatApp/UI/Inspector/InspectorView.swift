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
                temperatureRow
                topPRow
                maxTokensRow
                reasoningRow
                toolIterationRow
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

    // MARK: Sampling rows

    @ViewBuilder
    private var temperatureRow: some View {
        OptionalNumericRow(
            label: "Temperature",
            placeholder: "default",
            value: bindingFor(\.temperature, default: 0.7),
            range: 0.0...2.0,
            step: 0.05,
            format: "%.2f"
        )
    }

    @ViewBuilder
    private var topPRow: some View {
        OptionalNumericRow(
            label: "top_p",
            placeholder: "default",
            value: bindingFor(\.topP, default: 1.0),
            range: 0.0...1.0,
            step: 0.01,
            format: "%.2f"
        )
    }

    @ViewBuilder
    private var maxTokensRow: some View {
        OptionalIntRow(
            label: "Max output tokens",
            placeholder: "server default",
            value: Binding(
                get: { viewModel.conversation.settings.maxOutputTokens },
                set: {
                    var s = viewModel.conversation.settings
                    s.maxOutputTokens = $0
                    viewModel.conversation.settings = s
                }
            ),
            defaultValue: 2048
        )
    }

    @ViewBuilder
    private var reasoningRow: some View {
        Picker("Reasoning effort", selection: Binding(
            get: { ReasoningEffortChoice(viewModel.conversation.settings.reasoningEffort) },
            set: { newValue in
                var s = viewModel.conversation.settings
                s.reasoningEffort = newValue.effort
                viewModel.conversation.settings = s
            }
        )) {
            ForEach(ReasoningEffortChoice.allCases) { choice in
                Text(choice.displayName).tag(choice)
            }
        }
    }

    @ViewBuilder
    private var toolIterationRow: some View {
        Stepper(value: Binding(
            get: { viewModel.conversation.settings.maxToolIterations },
            set: {
                var s = viewModel.conversation.settings
                s.maxToolIterations = max(1, min($0, 32))
                viewModel.conversation.settings = s
            }
        ), in: 1...32) {
            HStack {
                Text("Max tool iterations")
                Spacer()
                Text("\(viewModel.conversation.settings.maxToolIterations)").foregroundStyle(.secondary)
            }
        }
    }

    private func bindingFor(
        _ keyPath: WritableKeyPath<ChatSettings, Double?>,
        default fallback: Double
    ) -> Binding<Double?> {
        Binding(
            get: { viewModel.conversation.settings[keyPath: keyPath] },
            set: { newValue in
                var s = viewModel.conversation.settings
                s[keyPath: keyPath] = newValue
                viewModel.conversation.settings = s
            }
        )
    }
}

private enum ReasoningEffortChoice: Hashable, CaseIterable, Identifiable {
    case `default`, minimal, low, medium, high

    init(_ effort: ReasoningEffort?) {
        switch effort {
        case .none: self = .default
        case .minimal: self = .minimal
        case .low: self = .low
        case .medium: self = .medium
        case .high: self = .high
        }
    }

    var effort: ReasoningEffort? {
        switch self {
        case .default: return nil
        case .minimal: return .minimal
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        }
    }

    var displayName: String {
        switch self {
        case .default: return "Default"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var id: String { displayName }
}

private struct OptionalNumericRow: View {
    let label: String
    let placeholder: String
    @Binding var value: Double?
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Toggle("Override", isOn: Binding(
                    get: { value != nil },
                    set: { isOn in
                        if isOn {
                            if value == nil { value = (range.lowerBound + range.upperBound) / 2 }
                        } else {
                            value = nil
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
            if let current = value {
                HStack {
                    Slider(value: Binding(
                        get: { current },
                        set: { value = $0 }
                    ), in: range, step: step)
                    Text(String(format: format, current))
                        .font(.callout.monospaced())
                        .frame(minWidth: 50, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(placeholder)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct OptionalIntRow: View {
    let label: String
    let placeholder: String
    @Binding var value: Int?
    let defaultValue: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Toggle("Override", isOn: Binding(
                    get: { value != nil },
                    set: { isOn in
                        value = isOn ? (value ?? defaultValue) : nil
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
            if let current = value {
                Stepper(value: Binding(
                    get: { current },
                    set: { value = $0 }
                ), in: 1...1_000_000, step: 256) {
                    HStack {
                        Text("\(current)")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            } else {
                Text(placeholder)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
