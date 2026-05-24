import Foundation
import FChatCore
import FChatProviders
import FChatWeb

public struct WebSearchTool: Tool {
    public let name = "web_search"
    public let provider: any WebSearchProvider
    public let defaultMaxResults: Int

    public init(provider: any WebSearchProvider, defaultMaxResults: Int = 5) {
        self.provider = provider
        self.defaultMaxResults = defaultMaxResults
    }

    public func definition(for language: PromptLanguage) -> ToolDefinition {
        let description: String
        switch language {
        case .english:
            description = "Search the public web for current information. Returns title/url/snippet for the top matches. Use when the answer may have changed since the model's training cutoff or when a citation is wanted."
        case .swedish:
            description = "Sök på det publika webben efter aktuell information. Returnerar titel/url/utdrag för de bästa träffarna. Använd när svaret kan ha ändrats sedan modellens träningsstopp eller när en källa önskas."
        }
        let schema = JSONSchema(raw: #"""
        {"type":"object","properties":{"query":{"type":"string","description":"Search query"},"max_results":{"type":"integer","minimum":1,"maximum":20,"default":5}},"required":["query"],"additionalProperties":false}
        """#)
        return ToolDefinition(name: name, description: description, parametersSchema: schema, strict: true)
    }

    public func invoke(arguments: String) async throws -> ToolOutput {
        struct Args: Decodable {
            let query: String
            let max_results: Int?
        }
        guard let data = arguments.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(Args.self, from: data) else {
            throw ToolInvocationError.badArguments(arguments)
        }
        let limit = max(1, min(parsed.max_results ?? defaultMaxResults, 20))
        let results = try await provider.search(query: parsed.query, maxResults: limit)
        let payload = WebSearchResultsPayload(query: parsed.query, results: results)
        let json = try JSONEncoder().encode(payload)
        let str = String(data: json, encoding: .utf8) ?? "{}"
        return ToolOutput(outputJSON: str, display: .markdown)
    }
}

private struct WebSearchResultsPayload: Encodable {
    let query: String
    let results: [WebSearchResult]
}
