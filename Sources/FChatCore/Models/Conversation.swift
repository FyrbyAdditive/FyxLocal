import Foundation

public struct Conversation: Identifiable, Sendable, Hashable {
    public let id: ConversationID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var settings: ChatSettings
    public var messages: [Message]
    public var previousResponseID: String?

    public init(
        id: ConversationID = .init(),
        title: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        settings: ChatSettings,
        messages: [Message] = [],
        previousResponseID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.settings = settings
        self.messages = messages
        self.previousResponseID = previousResponseID
    }
}

public struct Message: Identifiable, Sendable, Hashable {
    public let id: MessageID
    public var role: MessageRole
    public var contentItems: [MessageContent]
    public var usage: UsageInfo?
    public var createdAt: Date
    public var responseID: String?

    public init(
        id: MessageID = .init(),
        role: MessageRole,
        contentItems: [MessageContent],
        usage: UsageInfo? = nil,
        createdAt: Date = .now,
        responseID: String? = nil
    ) {
        self.id = id
        self.role = role
        self.contentItems = contentItems
        self.usage = usage
        self.createdAt = createdAt
        self.responseID = responseID
    }

    public var plainText: String {
        contentItems.compactMap { item -> String? in
            if case .text(let s) = item { return s }
            return nil
        }.joined(separator: "\n")
    }
}
