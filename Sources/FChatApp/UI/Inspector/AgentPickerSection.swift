import SwiftUI
import FChatCore

struct AgentPickerSection: View {
    @Bindable var viewModel: ChatViewModel
    @Bindable var environment: AppEnvironment

    var body: some View {
        Section("Agent") {
            Picker("Agent", selection: Binding(
                get: {
                    // nil → fall back to global default → fall back to Default agent.
                    viewModel.conversation.settings.agentID
                        ?? environment.defaultAgentForNewChats
                        ?? .defaultAgent
                },
                set: { newID in
                    viewModel.conversation.settings.agentID = newID
                }
            )) {
                ForEach(environment.agents) { agent in
                    Text(agent.name).tag(agent.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            // Tiny preview of the currently-selected agent's prompt.
            let resolved = environment.resolveAgent(for: viewModel.conversation)
            if let preview = resolved.basePrompt, !preview.isEmpty {
                Text(preview)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Uses F-Chat's built-in preamble.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("Set the default for new chats in Settings → Agents.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
