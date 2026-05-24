import Foundation

public struct ProviderRecord: Identifiable, Sendable, Hashable, Codable {
    public let id: ProviderID
    public var displayName: String
    public var baseURL: URL
    public var defaultModel: String?
    public var capability: ProviderCapability
    public var modelOverrides: [ModelOverride]

    public init(
        id: ProviderID,
        displayName: String,
        baseURL: URL,
        defaultModel: String? = nil,
        capability: ProviderCapability = .init(),
        modelOverrides: [ModelOverride] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.capability = capability
        self.modelOverrides = modelOverrides
    }
}

public struct ProviderCapability: Sendable, Hashable, Codable {
    public var supportsResponses: Bool
    public var supportsEmbeddings: Bool
    public var supportsModelListing: Bool

    public init(
        supportsResponses: Bool = true,
        supportsEmbeddings: Bool = true,
        supportsModelListing: Bool = true
    ) {
        self.supportsResponses = supportsResponses
        self.supportsEmbeddings = supportsEmbeddings
        self.supportsModelListing = supportsModelListing
    }
}

public struct ModelOverride: Sendable, Hashable, Codable {
    public var modelID: String
    public var displayName: String?
    public var contextWindow: Int?
    public var maxOutputTokens: Int?
    public var supportsTools: Bool
    public var supportsVision: Bool
    public var supportsReasoning: Bool

    public init(
        modelID: String,
        displayName: String? = nil,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        supportsTools: Bool = true,
        supportsVision: Bool = false,
        supportsReasoning: Bool = false
    ) {
        self.modelID = modelID
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportsTools = supportsTools
        self.supportsVision = supportsVision
        self.supportsReasoning = supportsReasoning
    }
}

public struct ModelInfo: Identifiable, Sendable, Hashable, Codable {
    public var id: String
    public var displayName: String
    public var contextWindow: Int?
    public var maxOutputTokens: Int?
    public var supportsTools: Bool
    public var supportsVision: Bool
    public var supportsReasoning: Bool

    public init(
        id: String,
        displayName: String? = nil,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        supportsTools: Bool = true,
        supportsVision: Bool = false,
        supportsReasoning: Bool = false
    ) {
        self.id = id
        self.displayName = displayName ?? id
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportsTools = supportsTools
        self.supportsVision = supportsVision
        self.supportsReasoning = supportsReasoning
    }
}
