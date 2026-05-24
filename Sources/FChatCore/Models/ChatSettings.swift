import Foundation

public struct ChatSettings: Codable, Sendable, Hashable {
    public var model: String
    public var providerID: ProviderID
    public var systemPrompt: String?
    public var temperature: Double?
    public var topP: Double?
    public var maxOutputTokens: Int?
    public var reasoningEffort: ReasoningEffort?
    public var parallelToolCalls: Bool
    public var maxToolIterations: Int
    public var enabledBuiltInTools: Set<String>
    public var enabledMCPServers: Set<MCPServerID>
    public var attachedCollections: Set<CollectionID>
    public var enabledServerTools: Set<ServerSideTool>
    public var responseStorageMode: ResponseStorageMode

    public init(
        model: String,
        providerID: ProviderID,
        systemPrompt: String? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxOutputTokens: Int? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        parallelToolCalls: Bool = true,
        maxToolIterations: Int = 8,
        enabledBuiltInTools: Set<String> = [],
        enabledMCPServers: Set<MCPServerID> = [],
        attachedCollections: Set<CollectionID> = [],
        enabledServerTools: Set<ServerSideTool> = [],
        responseStorageMode: ResponseStorageMode = .serverStored
    ) {
        self.model = model
        self.providerID = providerID
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.maxOutputTokens = maxOutputTokens
        self.reasoningEffort = reasoningEffort
        self.parallelToolCalls = parallelToolCalls
        self.maxToolIterations = maxToolIterations
        self.enabledBuiltInTools = enabledBuiltInTools
        self.enabledMCPServers = enabledMCPServers
        self.attachedCollections = attachedCollections
        self.enabledServerTools = enabledServerTools
        self.responseStorageMode = responseStorageMode
    }
}

public enum ReasoningEffort: String, Codable, Sendable, CaseIterable {
    case minimal, low, medium, high
}

public enum ServerSideTool: String, Codable, Sendable, CaseIterable {
    case webSearch = "web_search"
    case fileSearch = "file_search"
    case codeInterpreter = "code_interpreter"
    case imageGeneration = "image_generation"
}

public enum ResponseStorageMode: String, Codable, Sendable {
    case serverStored
    case stateless
    case statelessEncryptedReasoning
}
