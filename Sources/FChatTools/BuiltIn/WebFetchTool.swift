import Foundation
import FChatCore
import FChatProviders
import FChatWeb

public struct WebFetchTool: Tool {
    public let name = "web_fetch"
    public let extractor: any PageExtractor
    public let defaultTimeout: TimeInterval

    public init(extractor: any PageExtractor, defaultTimeout: TimeInterval = 12.0) {
        self.extractor = extractor
        self.defaultTimeout = defaultTimeout
    }

    public func definition(for language: PromptLanguage) -> ToolDefinition {
        let description: String
        switch language {
        case .english:
            description = "Fetch a web page by URL and return its main readable text, title, byline, and excerpt. Use after web_search when you need the page contents, not just the search snippet."
        case .swedish:
            description = "Hämta en webbsida på en URL och returnera sidans läsbara huvudtext, titel, författare och utdrag. Använd efter web_search när du behöver sidans innehåll, inte bara sökutdraget."
        }
        let schema = JSONSchema(raw: #"""
        {"type":"object","properties":{"url":{"type":"string","format":"uri"}},"required":["url"],"additionalProperties":false}
        """#)
        return ToolDefinition(name: name, description: description, parametersSchema: schema, strict: true)
    }

    public func invoke(arguments: String) async throws -> ToolOutput {
        struct Args: Decodable { let url: String }
        guard let data = arguments.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(Args.self, from: data),
              let url = URL(string: parsed.url) else {
            throw ToolInvocationError.badArguments(arguments)
        }
        let extracted = try await extractor.extract(url: url, timeout: defaultTimeout)
        let json = try JSONEncoder().encode(extracted)
        return ToolOutput(outputJSON: String(data: json, encoding: .utf8) ?? "{}", display: .markdown)
    }
}
