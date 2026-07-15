// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// A server-exposed resource from `resources/list`. Subscriptions and
/// resource templates are deliberately out of scope for now — listing and
/// one-shot reads cover the attach-to-chat use case.
public struct MCPResource: Sendable, Hashable, Identifiable {
    public var uri: String
    public var name: String
    public var title: String?
    public var description: String?
    public var mimeType: String?
    public var size: Int?

    public var id: String { uri }

    public init(uri: String, name: String, title: String? = nil, description: String? = nil, mimeType: String? = nil, size: Int? = nil) {
        self.uri = uri
        self.name = name
        self.title = title
        self.description = description
        self.mimeType = mimeType
        self.size = size
    }
}

/// One entry of a `resources/read` result's `contents` array.
public enum MCPResourceContents: Sendable, Hashable {
    case text(uri: String, mimeType: String?, text: String)
    case blob(uri: String, mimeType: String?, base64: String)
}

public struct MCPPromptArgument: Sendable, Hashable {
    public var name: String
    public var title: String?
    public var description: String?
    public var required: Bool

    public init(name: String, title: String? = nil, description: String? = nil, required: Bool = false) {
        self.name = name
        self.title = title
        self.description = description
        self.required = required
    }
}

/// A server-exposed prompt template from `prompts/list`.
public struct MCPPrompt: Sendable, Hashable, Identifiable {
    public var name: String
    public var title: String?
    public var description: String?
    public var arguments: [MCPPromptArgument]

    public var id: String { name }

    public init(name: String, title: String? = nil, description: String? = nil, arguments: [MCPPromptArgument] = []) {
        self.name = name
        self.title = title
        self.description = description
        self.arguments = arguments
    }
}

public struct MCPPromptMessage: Sendable, Hashable {
    public var role: String
    public var content: MCPContent

    public init(role: String, content: MCPContent) {
        self.role = role
        self.content = content
    }
}

/// The materialized result of `prompts/get`.
public struct MCPPromptResult: Sendable, Hashable {
    public var description: String?
    public var messages: [MCPPromptMessage]

    public init(description: String? = nil, messages: [MCPPromptMessage]) {
        self.description = description
        self.messages = messages
    }
}
