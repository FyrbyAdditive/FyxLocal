import Foundation

/// Streamable HTTP MCP transport (MCP 2025-11-25 spec).
///
/// **Not yet implemented.** Pulled out as a stub so the type exists in the
/// public surface and call sites can be set up. Implementing this properly
/// requires:
///
/// - HTTP POST request/response framing
/// - SSE channel for server→client streaming
/// - OAuth 2.1 flow (RFC 9728 protected-resource metadata discovery,
///   PKCE, optional dynamic client registration RFC 7591, RFC 8707
///   `resource` parameter on auth + token requests)
/// - Token storage in Keychain + refresh-on-401
///
/// Tracked as a follow-up to v1; stdio MCP servers cover the dominant
/// use case for the initial release.
public actor HTTPMCPTransport: MCPTransport {
    public let url: URL
    public let extraHeaders: [String: String]

    public init(url: URL, extraHeaders: [String: String] = [:]) {
        self.url = url
        self.extraHeaders = extraHeaders
    }

    public func send(_ frame: JSONRPCFrame) async throws {
        throw MCPTransportError.protocolError("HTTPMCPTransport not yet implemented")
    }

    nonisolated public func incoming() -> AsyncThrowingStream<JSONRPCFrame, Error> {
        AsyncThrowingStream(JSONRPCFrame.self) { continuation in
            continuation.finish(throwing: MCPTransportError.protocolError("HTTPMCPTransport not yet implemented"))
        }
    }

    public func close() async {}
}
