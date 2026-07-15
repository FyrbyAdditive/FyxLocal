// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import Observation
import FyxLocalCore
import FyxLocalMCP
import FyxLocalTools

/// Owns the live `MCPClient` connections for every user-configured MCP
/// server, plus the `MCPToolAdapter` instances those clients spawned into
/// the shared `ToolRegistry`. Connection is lazy: nothing happens at app
/// launch; the first chat send triggers `ensureLoaded`, which walks the
/// enabled-server list in parallel and connects each.
///
/// Lifecycle responsibilities:
/// - `ensureLoaded(servers:)` — idempotent per session; called from
///   `ChatViewModel.send` before reading the tool registry's definitions.
/// - `connect(_:)` — used by Settings → MCP "Test connection / refresh
///   tools" buttons and by ensureLoaded.
/// - `disconnect(_:)` — clean shutdown + unregister tools. Called when a
///   server is toggled off or deleted from Settings.
/// - `reconnect(_:)` — convenience: disconnect followed by connect with
///   the new config. Used when the user edits a server in Settings.
@MainActor
@Observable
final class MCPRegistry {
    /// Per-server status, exposed for UI rendering. Observable so cards
    /// re-render automatically when `connect` flips state.
    enum Status: Equatable {
        case disconnected
        case connecting
        case ready(toolCount: Int)
        case failed(String)
    }

    private struct Entry {
        let client: MCPClient
        var adapterNames: [String]
        /// Consumes the client's notification stream (single-consumer — the
        /// registry owns it) to react to list_changed notifications.
        var listenerTask: Task<Void, Never>?
    }

    private enum RefreshKind: String { case tools, resources, prompts }

    private var entries: [MCPServerID: Entry] = [:]
    /// Debounce for burst list_changed notifications, keyed by server + kind.
    private var refreshDebounce: [String: Task<Void, Never>] = [:]
    private(set) var status: [MCPServerID: Status] = [:]
    /// Server-exposed resources/prompts, fetched at connect and refreshed on
    /// list_changed. Rendered by the Inspector's MCP section.
    private(set) var resources: [MCPServerID: [MCPResource]] = [:]
    private(set) var prompts: [MCPServerID: [MCPPrompt]] = [:]
    private let toolRegistry: ToolRegistry
    /// True after `ensureLoaded` has run once this session — subsequent
    /// calls return immediately so the chat send path stays O(1).
    private var loadedOnce: Bool = false
    /// OAuth coordinator for HTTP servers with `useOAuth = true`.
    /// Optional so test paths can construct a registry without one.
    let oauthCoordinator: OAuthCoordinator?

    /// Reads non-OAuth static auth tokens (bearer / basic) from the
    /// Keychain when building the Authorization header. Optional so test
    /// paths can omit it.
    private let secretStore: (any SecretStore)?

    /// Routes MCP form-mode elicitation requests to the UI. Optional so
    /// test paths can construct a registry without one (clients then don't
    /// declare the elicitation capability at all).
    private let elicitationCoordinator: MCPElicitationCoordinator?

    init(
        toolRegistry: ToolRegistry,
        oauthCoordinator: OAuthCoordinator? = nil,
        secretStore: (any SecretStore)? = nil,
        elicitationCoordinator: MCPElicitationCoordinator? = nil
    ) {
        self.toolRegistry = toolRegistry
        self.oauthCoordinator = oauthCoordinator
        self.secretStore = secretStore
        self.elicitationCoordinator = elicitationCoordinator
    }

    /// Mark a server's card as failed with a reason. Used by the
    /// AppEnvironment sign-in helper so an interactive-auth failure
    /// shows in the always-visible card header, not just the form's
    /// inline error line.
    func setFailedStatus(_ id: MCPServerID, reason: String) {
        status[id] = .failed(reason)
    }

    /// Idempotent: walks the enabled-server list once per session and
    /// connects each (sequentially, so we don't spawn N subprocesses
    /// before the first chat turn even begins). Subsequent calls are
    /// no-ops. Tools land in the shared `toolRegistry` via
    /// `MCPToolAdapter` so the existing chat-turn machinery picks them
    /// up without further plumbing.
    ///
    /// Sequential rather than parallel because (a) most users will have
    /// at most a handful of servers, (b) failures don't block each
    /// other — we surface per-server status into the UI — and (c)
    /// keeping it ordered makes the first-load latency predictable.
    func ensureLoaded(servers: [MCPServerRecord]) async {
        guard !loadedOnce else { return }
        loadedOnce = true
        for record in servers where record.enabled {
            await connect(record)
        }
    }

    /// Connect (or reconnect) to a single server. Spawns the appropriate
    /// transport, runs the MCP `initialize` handshake, fetches the tool
    /// list, and registers an `MCPToolAdapter` per tool. Re-entrant: if
    /// already connected we shut down the previous client first.
    func connect(_ record: MCPServerRecord) async {
        await disconnect(record.id)
        status[record.id] = .connecting

        let transport: any MCPTransport
        switch record.transport {
        case .stdio(let config):
            let stdio = StdioMCPTransport(
                command: config.command,
                arguments: config.arguments,
                environment: config.environment,
                workingDirectory: config.workingDirectory
            )
            do {
                try await stdio.start()
            } catch {
                status[record.id] = .failed(Self.describe(error))
                return
            }
            transport = stdio
        case .http(let config):
            var headers = config.headers
            if config.useOAuth {
                guard let coordinator = oauthCoordinator else {
                    status[record.id] = .failed("OAuth requested but no coordinator configured")
                    return
                }
                do {
                    let token = try await coordinator.accessToken(
                        for: record.id,
                        resource: config.url,
                        httpConfig: config
                    )
                    headers["Authorization"] = "Bearer \(token)"
                } catch {
                    status[record.id] = .failed(Self.describe(error))
                    return
                }
            } else if let authHeader = await staticAuthorizationHeader(for: record.id, config: config) {
                // Non-OAuth bearer / basic auth — token from Keychain.
                headers["Authorization"] = authHeader
            }
            let http = HTTPMCPTransport(
                url: config.url,
                extraHeaders: headers
            )
            if config.useOAuth, let coordinator = oauthCoordinator {
                let serverID = record.id
                let resource = config.url
                let httpConfig = config
                await http.setAuthorizationRefresher {
                    let fresh = try await coordinator.accessToken(
                        for: serverID,
                        resource: resource,
                        httpConfig: httpConfig
                    )
                    return "Bearer \(fresh)"
                }
            }
            transport = http
        }

        let client = MCPClient(transport: transport)
        // Install before start(): the elicitation capability is only
        // declared in the initialize handshake when a handler is present.
        // The display name is captured at connect time; Settings edits go
        // through reconnect(_:), which reinstalls with the new name.
        if let coordinator = elicitationCoordinator {
            let serverID = record.id
            let displayName = record.displayName
            await client.setElicitationHandler { request in
                await coordinator.elicit(
                    serverID: serverID,
                    serverDisplayName: displayName,
                    request: request
                )
            }
        }
        do {
            try await client.start()
            let slug = serverSlug(record.displayName)
            let tools = try await client.listTools()
            var registeredNames: [String] = []
            for tool in tools {
                let adapter = MCPToolAdapter(
                    serverName: slug,
                    mcpTool: tool,
                    client: client
                )
                await toolRegistry.register(adapter)
                registeredNames.append(adapter.name)
            }
            entries[record.id] = Entry(client: client, adapterNames: registeredNames)
            status[record.id] = .ready(toolCount: tools.count)
            startNotificationListener(id: record.id, client: client, slug: slug)
            // Resources/prompts are additive surfaces — a failure here must
            // not fail the connection, so errors degrade to empty lists.
            let caps = await client.serverCapabilities
            if caps.supportsResources {
                resources[record.id] = (try? await client.listResources()) ?? []
            }
            if caps.supportsPrompts {
                prompts[record.id] = (try? await client.listPrompts()) ?? []
            }
        } catch {
            await client.shutdown()
            // For stdio servers, the child often writes the real reason to
            // stderr (e.g. "env: node: No such file or directory") before
            // dying; surface it alongside the transport error.
            var message = Self.describe(error)
            if let stdio = transport as? StdioMCPTransport, let err = await stdio.drainStderr() {
                message += " — \(err)"
            }
            status[record.id] = .failed(message)
        }
    }

    /// Build the static (non-OAuth) Authorization header value for an
    /// HTTP server from its auth mode + the Keychain-stored token.
    /// Returns nil when the mode is `.none`, the token is missing, or
    /// no secret store is configured. For `.basic`, base64-encodes
    /// `email:token` (e.g. Atlassian personal API tokens).
    private func staticAuthorizationHeader(
        for id: MCPServerID,
        config: MCPTransportConfig.HTTPConfig
    ) async -> String? {
        guard config.authMode != .none, let secretStore else { return nil }
        let token = (try? await secretStore.secret(for: KeychainAccount.mcpStaticAuthToken(id))) ?? nil
        guard let token, !token.isEmpty else { return nil }
        switch config.authMode {
        case .none:
            return nil
        case .bearer:
            return "Bearer \(token)"
        case .basic:
            let email = config.basicAuthEmail ?? ""
            let pair = "\(email):\(token)"
            let encoded = Data(pair.utf8).base64EncodedString()
            return "Basic \(encoded)"
        }
    }

    /// Clean shutdown: stop the client, unregister its tools from the
    /// shared registry, flip status to `.disconnected`. Safe to call
    /// even if the server was never connected.
    func disconnect(_ id: MCPServerID) async {
        for kind in [RefreshKind.tools, .resources, .prompts] {
            refreshDebounce.removeValue(forKey: debounceKey(id, kind))?.cancel()
        }
        resources[id] = nil
        prompts[id] = nil
        guard let entry = entries.removeValue(forKey: id) else {
            status[id] = .disconnected
            return
        }
        entry.listenerTask?.cancel()
        // Resolve any pending elicitation sheet for this server with
        // .cancel BEFORE shutting the client down, so the cancel response
        // can still be delivered over the transport.
        elicitationCoordinator?.cancelAll(forServer: id)
        for name in entry.adapterNames {
            await toolRegistry.unregister(name: name)
        }
        await entry.client.shutdown()
        status[id] = .disconnected
    }

    // MARK: - list_changed auto-refresh

    /// Consumes the client's notification stream (single-consumer; the
    /// registry is its sole owner) and reacts to list_changed notifications
    /// with a debounced re-list. Without this, a server that adds or removes
    /// tools after connect silently serves a stale tool set until reconnect.
    private func startNotificationListener(id: MCPServerID, client: MCPClient, slug: String) {
        let listener = Task { [weak self] in
            let stream = await client.notifications()
            for await note in stream {
                guard let self else { return }
                switch note.method {
                case "notifications/tools/list_changed":
                    self.scheduleRefresh(.tools, id: id, client: client, slug: slug)
                case "notifications/resources/list_changed":
                    self.scheduleRefresh(.resources, id: id, client: client, slug: slug)
                case "notifications/prompts/list_changed":
                    self.scheduleRefresh(.prompts, id: id, client: client, slug: slug)
                default:
                    break
                }
            }
        }
        entries[id]?.listenerTask = listener
    }

    private func debounceKey(_ id: MCPServerID, _ kind: RefreshKind) -> String {
        "\(id.rawValue)/\(kind.rawValue)"
    }

    /// Coalesces notification bursts: each new notification restarts a short
    /// window; the refresh runs once the burst goes quiet.
    private func scheduleRefresh(_ kind: RefreshKind, id: MCPServerID, client: MCPClient, slug: String) {
        let key = debounceKey(id, kind)
        refreshDebounce[key]?.cancel()
        refreshDebounce[key] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            switch kind {
            case .tools:
                await self?.refreshTools(id: id, client: client, slug: slug)
            case .resources:
                await self?.refreshResources(id: id, client: client)
            case .prompts:
                await self?.refreshPrompts(id: id, client: client)
            }
        }
    }

    private func refreshResources(id: MCPServerID, client: MCPClient) async {
        guard entries[id]?.client === client else { return }
        guard let updated = try? await client.listResources() else { return }
        guard entries[id]?.client === client else { return }
        resources[id] = updated
    }

    private func refreshPrompts(id: MCPServerID, client: MCPClient) async {
        guard entries[id]?.client === client else { return }
        guard let updated = try? await client.listPrompts() else { return }
        guard entries[id]?.client === client else { return }
        prompts[id] = updated
    }

    // MARK: - Resource/prompt pass-throughs for the Inspector UI

    func readResource(serverID: MCPServerID, uri: String) async throws -> [MCPResourceContents] {
        guard let client = entries[serverID]?.client else { throw MCPClientError.notInitialized }
        return try await client.readResource(uri: uri)
    }

    func getPrompt(serverID: MCPServerID, name: String, arguments: [String: String]) async throws -> MCPPromptResult {
        guard let client = entries[serverID]?.client else { throw MCPClientError.notInitialized }
        return try await client.getPrompt(name: name, arguments: arguments)
    }

    private func refreshTools(id: MCPServerID, client: MCPClient, slug: String) async {
        // The client identity guards against a disconnect/reconnect racing
        // this refresh — a stale client must not touch the new entry.
        guard entries[id]?.client === client else { return }
        guard let tools = try? await client.listTools() else {
            // Transient failure: keep serving the old tool set rather than
            // flipping the server card to failed.
            return
        }
        guard entries[id]?.client === client else { return }
        var registeredNames: [String] = []
        for tool in tools {
            let adapter = MCPToolAdapter(serverName: slug, mcpTool: tool, client: client)
            await toolRegistry.register(adapter)
            registeredNames.append(adapter.name)
        }
        guard var entry = entries[id], entry.client === client else { return }
        for name in Self.staleAdapterNames(current: entry.adapterNames, updated: registeredNames) {
            await toolRegistry.unregister(name: name)
        }
        entry.adapterNames = registeredNames
        entries[id] = entry
        status[id] = .ready(toolCount: tools.count)
    }

    /// Adapter names registered before that no longer exist in the updated
    /// list. (Updated tools are re-registered wholesale — register-by-name
    /// overwrites replace changed schemas in place.)
    nonisolated static func staleAdapterNames(current: [String], updated: [String]) -> [String] {
        let updatedSet = Set(updated)
        return current.filter { !updatedSet.contains($0) }
    }

    /// Disconnect + reconnect in sequence. Used when the user edits the
    /// transport config of a connected server in Settings.
    func reconnect(_ record: MCPServerRecord) async {
        await disconnect(record.id)
        if record.enabled {
            await connect(record)
        }
    }

    /// MCPToolAdapter namespaces tool names as `mcp__<slug>__<tool>`. We
    /// derive the slug from the user's display name so users see something
    /// recognisable in tool-call rows ("mcp__filesystem__read_file"
    /// rather than a UUID). Lowercase, alphanumerics + underscore only.
    private func serverSlug(_ displayName: String) -> String {
        let lowered = displayName.lowercased()
        let stripped = lowered.unicodeScalars.map { scalar -> Character in
            if (scalar.value >= 0x30 && scalar.value <= 0x39) // 0-9
                || (scalar.value >= 0x61 && scalar.value <= 0x7A) // a-z
                || scalar.value == 0x5F { // _
                return Character(scalar)
            }
            return "_"
        }
        let collapsed = String(stripped).split(separator: "_", omittingEmptySubsequences: true).joined(separator: "_")
        return collapsed.isEmpty ? "server" : collapsed
    }

    private static func describe(_ error: Error) -> String {
        if let mcp = error as? MCPClientError {
            // MCPClientError is LocalizedError; its descriptions carry the
            // server's message verbatim for rpcError.
            return mcp.localizedDescription
        }
        return "\(error)"
    }
}
