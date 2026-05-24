import Foundation
import SwiftUI
import FChatCore
import FChatProviders
import FChatTools
import FChatWeb
import FChatRAG
import FChatMCP

/// Owns the long-lived services the UI binds against. A single instance is
/// created at app start and injected into the environment.
@MainActor
@Observable
final class AppEnvironment {
    let secretStore: any SecretStore
    let toolRegistry: ToolRegistry
    let collectionStore: CollectionStore
    let ingestor: FileIngestor
    let pageExtractor: any PageExtractor
    let searchProvider: any WebSearchProvider
    var providerRecords: [ProviderRecord]
    var conversations: [Conversation]
    var selectedConversationID: ConversationID?
    var promptLanguage: PromptLanguage
    var sidebarSelection: SidebarSelection?

    /// Cached `/models` results per provider, keyed by ProviderID.
    var detectedModels: [ProviderID: [ModelInfo]] = [:]
    var providerStatus: [ProviderID: ProviderConnectionStatus] = [:]

    init() {
        self.secretStore = KeychainStore()
        self.toolRegistry = ToolRegistry()
        self.collectionStore = CollectionStore()
        self.ingestor = FileIngestor()
        self.pageExtractor = WebKitPageExtractor()
        self.searchProvider = DuckDuckGoProvider()
        self.providerRecords = AppEnvironment.defaultProviders()
        self.conversations = []
        self.promptLanguage = PromptLanguage.resolve()
        self.sidebarSelection = nil
    }

    func currentProvider() -> ProviderRecord? {
        providerRecords.first
    }

    func provider(_ id: ProviderID) -> ProviderRecord? {
        providerRecords.first(where: { $0.id == id })
    }

    func makeRuntimeProvider(for record: ProviderRecord) -> any LLMProvider {
        OpenAIResponsesProvider(
            id: record.id,
            baseURL: record.baseURL,
            session: .shared,
            secretStore: secretStore
        )
    }

    func refreshModels(for record: ProviderRecord) async {
        providerStatus[record.id] = .checking
        let runtime = makeRuntimeProvider(for: record)
        do {
            let models = try await runtime.listModels()
            let sorted = models.sorted { $0.id < $1.id }
            detectedModels[record.id] = sorted
            providerStatus[record.id] = .ok(modelCount: sorted.count, checkedAt: .now)
            // Backfill any conversations bound to this provider that have a model id
            // the server doesn't actually expose — common immediately after launch when
            // newConversation runs before detection completes.
            backfillConversationModels(providerID: record.id, detected: sorted)
        } catch {
            detectedModels[record.id] = []
            providerStatus[record.id] = .failed(message: error.localizedDescription, checkedAt: .now)
        }
    }

    private func backfillConversationModels(providerID: ProviderID, detected: [ModelInfo]) {
        guard let first = detected.first else { return }
        let validIDs = Set(detected.map(\.id))
        for index in conversations.indices where conversations[index].settings.providerID == providerID {
            let current = conversations[index].settings.model
            if current.isEmpty || !validIDs.contains(current) {
                conversations[index].settings.model = first.id
            }
        }
    }

    func updateProvider(_ updated: ProviderRecord) {
        if let i = providerRecords.firstIndex(where: { $0.id == updated.id }) {
            providerRecords[i] = updated
        }
    }

    func addProvider(displayName: String, baseURL: URL) -> ProviderRecord {
        let id = ProviderID(rawValue: slug(from: displayName.isEmpty ? baseURL.host ?? "provider" : displayName))
        let record = ProviderRecord(id: id, displayName: displayName.isEmpty ? id.rawValue : displayName, baseURL: baseURL)
        providerRecords.append(record)
        return record
    }

    func removeProvider(_ id: ProviderID) {
        providerRecords.removeAll { $0.id == id }
        detectedModels[id] = nil
        providerStatus[id] = nil
    }

    func registerBuiltInTools() async {
        let webSearch = WebSearchTool(provider: searchProvider)
        let webFetch = WebFetchTool(extractor: pageExtractor)
        let rag = RAGSearchTool(retriever: CollectionStoreRetriever(store: collectionStore))
        await toolRegistry.register(webSearch)
        await toolRegistry.register(webFetch)
        await toolRegistry.register(rag)
    }

    static func defaultProviders() -> [ProviderRecord] {
        [
            ProviderRecord(
                id: ProviderID(rawValue: "fyrby-magi"),
                displayName: "Fyrby Magi (dev)",
                baseURL: URL(string: "https://magi.fyrby.internal:8000/v1")!,
                defaultModel: nil
            )
        ]
    }

    func newConversation(title: String) {
        guard let provider = currentProvider() else { return }
        let model = provider.defaultModel
            ?? detectedModels[provider.id]?.first?.id
            ?? ""
        let settings = ChatSettings(
            model: model,
            providerID: provider.id,
            enabledBuiltInTools: ["web_search", "web_fetch", "rag_search"]
        )
        let conversation = Conversation(title: title, settings: settings)
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
        sidebarSelection = .conversation(conversation.id)
        // Kick off model detection so the chat can be used immediately.
        if detectedModels[provider.id] == nil {
            Task { await refreshModels(for: provider) }
        }
    }

    func conversation(_ id: ConversationID) -> Conversation? {
        conversations.first(where: { $0.id == id })
    }

    func update(_ conversation: Conversation) {
        if let i = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[i] = conversation
        }
    }

    private func slug(from text: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let lower = text.lowercased()
        var out = ""
        var lastDash = false
        for ch in lower {
            if allowed.contains(ch) {
                out.append(ch)
                lastDash = (ch == "-")
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "provider-\(UUID().uuidString.prefix(6))" : trimmed
    }
}

enum ProviderConnectionStatus: Sendable {
    case unknown
    case checking
    case ok(modelCount: Int, checkedAt: Date)
    case failed(message: String, checkedAt: Date)
}

enum SidebarSelection: Hashable {
    case conversation(ConversationID)
    case settings
    case collections
}
