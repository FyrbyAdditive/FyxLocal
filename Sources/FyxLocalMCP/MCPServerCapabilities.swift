// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// Server capabilities captured from the `initialize` response. The raw
/// JSON is retained for debugging/forward-compat; the booleans the client
/// actually branches on are parsed once here so the tool-call hot path
/// never re-walks the JSON.
public struct MCPServerCapabilities: Sendable, Hashable {
    public let raw: JSONValue
    /// `capabilities.tasks.requests.tools.call` declared — the server accepts
    /// task-augmented `tools/call` requests (MCP 2025-11-25 tasks, experimental).
    public let supportsTaskAugmentedToolCalls: Bool
    /// `capabilities.tasks.cancel` declared.
    public let supportsTaskCancel: Bool
    /// `capabilities.tasks.list` declared.
    public let supportsTaskList: Bool
    /// `capabilities.resources` declared. (`resources.subscribe` is
    /// deliberately not parsed — subscriptions are out of scope.)
    public let supportsResources: Bool
    /// `capabilities.resources.listChanged == true`.
    public let resourcesListChanged: Bool
    /// `capabilities.prompts` declared.
    public let supportsPrompts: Bool
    /// `capabilities.prompts.listChanged == true`.
    public let promptsListChanged: Bool

    public init(raw: JSONValue) {
        self.raw = raw
        let tasks = raw["tasks"]
        // Presence of the key (any object value) is the declaration; the
        // spec uses empty objects as markers.
        self.supportsTaskAugmentedToolCalls = tasks?["requests"]?["tools"]?["call"] != nil
        self.supportsTaskCancel = tasks?["cancel"] != nil
        self.supportsTaskList = tasks?["list"] != nil
        self.supportsResources = raw["resources"] != nil
        self.resourcesListChanged = raw["resources"]?["listChanged"]?.boolValue == true
        self.supportsPrompts = raw["prompts"] != nil
        self.promptsListChanged = raw["prompts"]?["listChanged"]?.boolValue == true
    }

    public static let none = MCPServerCapabilities(raw: .object([:]))
}
