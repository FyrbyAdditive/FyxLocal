import Foundation

public struct WebSearchResult: Sendable, Hashable, Codable {
    public var title: String
    public var url: URL
    public var snippet: String

    public init(title: String, url: URL, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

public protocol WebSearchProvider: Sendable {
    var displayName: String { get }
    func search(query: String, maxResults: Int) async throws -> [WebSearchResult]
}

public enum WebSearchError: Error, Equatable, Sendable {
    case rateLimited
    case httpStatus(Int)
    case parseFailure(String)
    case emptyQuery
}
