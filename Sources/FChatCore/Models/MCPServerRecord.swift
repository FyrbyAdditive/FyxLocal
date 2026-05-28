import Foundation

public struct MCPServerRecord: Identifiable, Sendable, Hashable, Codable {
    public let id: MCPServerID
    public var displayName: String
    public var transport: MCPTransportConfig
    public var enabled: Bool

    public init(
        id: MCPServerID,
        displayName: String,
        transport: MCPTransportConfig,
        enabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.transport = transport
        self.enabled = enabled
    }
}

public enum MCPTransportConfig: Sendable, Hashable, Codable {
    case stdio(StdioConfig)
    case http(HTTPConfig)

    public struct StdioConfig: Sendable, Hashable, Codable {
        public var command: String
        public var arguments: [String]
        public var environment: [String: String]
        public var workingDirectory: String?

        public init(
            command: String,
            arguments: [String] = [],
            environment: [String: String] = [:],
            workingDirectory: String? = nil
        ) {
            self.command = command
            self.arguments = arguments
            self.environment = environment
            self.workingDirectory = workingDirectory
        }
    }

    public struct HTTPConfig: Sendable, Hashable, Codable {
        public var url: URL
        public var headers: [String: String]
        public var useOAuth: Bool
        /// Pre-registered OAuth client_id. Leave nil and the coordinator
        /// will perform RFC 7591 dynamic client registration on first
        /// sign-in (assuming the authorization server supports it).
        public var oauthClientID: String?
        /// Override the OAuth authorization server URL. Defaults to whatever
        /// the MCP server advertises via RFC 9728 protected-resource-metadata.
        public var oauthAuthorizationServerURL: URL?
        /// Space-separated scope list to request. nil → the auth server's
        /// default scope set.
        public var oauthScopes: String?
        /// RFC 8707 resource indicator value. nil → defaults to `url`
        /// (the MCP server endpoint), which is the right answer in
        /// almost every case.
        public var oauthResourceIndicator: URL?

        public init(
            url: URL,
            headers: [String: String] = [:],
            useOAuth: Bool = false,
            oauthClientID: String? = nil,
            oauthAuthorizationServerURL: URL? = nil,
            oauthScopes: String? = nil,
            oauthResourceIndicator: URL? = nil
        ) {
            self.url = url
            self.headers = headers
            self.useOAuth = useOAuth
            self.oauthClientID = oauthClientID
            self.oauthAuthorizationServerURL = oauthAuthorizationServerURL
            self.oauthScopes = oauthScopes
            self.oauthResourceIndicator = oauthResourceIndicator
        }
    }
}
