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
        public var oauthClientID: String?

        public init(
            url: URL,
            headers: [String: String] = [:],
            useOAuth: Bool = false,
            oauthClientID: String? = nil
        ) {
            self.url = url
            self.headers = headers
            self.useOAuth = useOAuth
            self.oauthClientID = oauthClientID
        }
    }
}
