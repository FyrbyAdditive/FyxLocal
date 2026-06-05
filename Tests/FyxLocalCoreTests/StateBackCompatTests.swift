// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalCore

/// Guards the `state.json` back-compat contract: a file written by an OLDER app
/// version must still decode on the current `PersistedAppState`.
///
/// `PersistedAppState` uses *synthesized* Codable — a future NON-optional field
/// would make every old state.json throw on decode, and `AppStateStore.load()`
/// then backs the file up and starts empty (looks like total data loss). These
/// tests pin authentic old-shape JSON (no `ragRerankEnabled` key, the field
/// added since v0.5.2) so any such regression turns red instead of shipping.
///
/// JSON is inlined (not a bundled fixture) so the test is self-contained and
/// FyxLocalCoreTests needs no resources declaration. ID encoding mirrors the
/// models: String-rawValue ids (ProviderID) are bare strings; UUID-rawValue ids
/// (ConversationID/AgentID/MessageID) are `{"rawValue":"<uuid>"}`; dates are
/// ISO8601 (AppStateStore decodes with `.iso8601`).
@Suite("state.json back-compat")
struct StateBackCompatTests {

    private func loadFromJSON(_ json: String, file: StaticString = #filePath) throws -> (state: PersistedAppState, notices: [MigrationNotice]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backcompat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("state.json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: dir) }
        let loaded = AppStateStore(fileURL: url).load()
        return try #require(loaded, "old-shape state.json must decode, not return nil")
    }

    /// A realistic v0.5.2 state.json: version 6, one provider, one conversation
    /// with a user+assistant message, enabled tools, an agent — and crucially
    /// NO `ragRerankEnabled` key (added after 0.5.2). Must load with data intact.
    @Test func decodesRealisticV052State() throws {
        let json = """
        {
          "version": 6,
          "promptLanguage": "en",
          "activeProviderID": "openai",
          "selectedConversationID": { "rawValue": "11111111-1111-1111-1111-111111111111" },
          "enabledTools": ["web_search", "web_fetch"],
          "providers": [
            {
              "id": "openai",
              "displayName": "OpenAI",
              "baseURL": "https://api.openai.com/v1",
              "defaultModel": "gpt-4o",
              "apiKind": "openai-responses"
            }
          ],
          "agents": [
            {
              "id": { "rawValue": "22222222-2222-2222-2222-222222222222" },
              "name": "Default",
              "createdAt": "2026-01-01T00:00:00Z",
              "updatedAt": "2026-01-01T00:00:00Z"
            }
          ],
          "conversations": [
            {
              "id": { "rawValue": "11111111-1111-1111-1111-111111111111" },
              "title": "Old chat",
              "createdAt": "2026-01-02T03:04:05Z",
              "updatedAt": "2026-01-02T03:04:05Z",
              "settings": {
                "model": "gpt-4o",
                "providerID": "openai",
                "parallelToolCalls": true,
                "maxToolIterations": 8,
                "enabledBuiltInTools": ["web_search"],
                "enabledMCPServers": [],
                "attachedCollections": [],
                "enabledServerTools": [],
                "responseStorageMode": "stateless"
              },
              "messages": [
                {
                  "id": { "rawValue": "33333333-3333-3333-3333-333333333333" },
                  "role": "user",
                  "createdAt": "2026-01-02T03:04:05Z",
                  "contentItems": [ { "type": "text", "text": "hello from 0.5.2" } ]
                },
                {
                  "id": { "rawValue": "44444444-4444-4444-4444-444444444444" },
                  "role": "assistant",
                  "createdAt": "2026-01-02T03:04:06Z",
                  "contentItems": [ { "type": "text", "text": "hi back" } ]
                }
              ]
            }
          ]
        }
        """
        let (state, _) = try loadFromJSON(json)

        // Top-level data survived.
        #expect(state.version == 6)
        #expect(state.promptLanguage == .english)
        #expect(state.providers.count == 1)
        #expect(state.providers.first?.id.rawValue == "openai")
        #expect(state.providers.first?.defaultModel == "gpt-4o")
        #expect(state.enabledTools == ["web_search", "web_fetch"])
        #expect(state.agents?.count == 1)

        // Conversation + messages survived.
        #expect(state.conversations.count == 1)
        let convo = try #require(state.conversations.first)
        #expect(convo.title == "Old chat")
        #expect(convo.messages.count == 2)
        #expect(convo.messages.first?.plainText == "hello from 0.5.2")
        #expect(convo.settings.model == "gpt-4o")

        // THE GUARD: the field added since 0.5.2 was absent from the file and
        // decoded to nil (not a throw). A future non-optional field here breaks this.
        #expect(state.ragRerankEnabled == nil)
    }

    /// The smallest legal old file — only the non-optional fields, every
    /// Optional/array field absent. Catches a future non-optional addition the
    /// instant it lands (this minimal file would stop decoding).
    @Test func minimalOldStateDecodes() throws {
        let json = """
        {
          "version": 6,
          "promptLanguage": "en",
          "providers": [],
          "conversations": []
        }
        """
        let (state, _) = try loadFromJSON(json)
        #expect(state.providers.isEmpty)
        #expect(state.conversations.isEmpty)
        #expect(state.enabledTools == nil)
        #expect(state.agents == nil)
        #expect(state.mcpServers == nil)
        #expect(state.skills == nil)
        #expect(state.ragRerankEnabled == nil)
    }
}
