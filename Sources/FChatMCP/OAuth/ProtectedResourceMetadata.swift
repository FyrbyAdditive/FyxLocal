import Foundation

/// RFC 9728 protected-resource-metadata document. The MCP server tells
/// us which OAuth authorization server(s) issue tokens for it.
public struct ProtectedResourceMetadata: Sendable, Equatable {
    /// Identifier of the protected resource.
    public let resource: String?
    /// URLs of authorization servers that issue tokens for this
    /// resource. We pick the first one that responds to the
    /// `oauth-authorization-server` discovery call.
    public let authorizationServers: [URL]

    /// Fetches `<resource>/.well-known/oauth-protected-resource` and
    /// parses it. Throws on transport errors, non-2xx HTTP responses,
    /// or missing required fields.
    public static func fetch(
        resource: URL,
        session: URLSession
    ) async throws -> ProtectedResourceMetadata {
        let url = wellKnownURL(for: resource)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.discoveryFailed(reason: "non-HTTP response from \(url)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AuthError.discoveryFailed(reason: "HTTP \(http.statusCode) from \(url)")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AuthError.discoveryFailed(reason: "non-JSON body from \(url)")
        }
        let resourceID = json["resource"] as? String
        let servers = (json["authorization_servers"] as? [String]) ?? []
        let parsed = servers.compactMap { URL(string: $0) }
        guard !parsed.isEmpty else {
            throw AuthError.missingMetadata(field: "authorization_servers")
        }
        return ProtectedResourceMetadata(
            resource: resourceID,
            authorizationServers: parsed
        )
    }

    /// Resolves `<resource-root>/.well-known/oauth-protected-resource`
    /// preserving any path the user typed at the MCP server URL — we
    /// rebase to the host root because `.well-known` paths are
    /// host-scoped per the RFC.
    static func wellKnownURL(for resource: URL) -> URL {
        var components = URLComponents()
        components.scheme = resource.scheme
        components.host = resource.host
        components.port = resource.port
        components.path = "/.well-known/oauth-protected-resource"
        return components.url ?? resource
    }
}
