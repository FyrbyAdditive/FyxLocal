import SwiftUI
import FChatCore

struct SidebarView: View {
    @Bindable var environment: AppEnvironment

    var body: some View {
        List(selection: $environment.sidebarSelection) {
            Section {
                ForEach(environment.conversations) { conversation in
                    NavigationLink(value: SidebarSelection.conversation(conversation.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conversation.title)
                                .lineLimit(1)
                                .font(.body)
                            Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Conversations")
            }

            Section {
                NavigationLink(value: SidebarSelection.collections) {
                    Label("Collections", systemImage: "books.vertical")
                }
                NavigationLink(value: SidebarSelection.settings) {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .navigationTitle("F-Chat")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    environment.newConversation(title: "New chat")
                } label: {
                    Label("New chat", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
        }
    }
}
