import Foundation
import FChatCore
import FChatProviders

public protocol RAGRetriever: Sendable {
    func search(query: String, collectionID: CollectionID, topK: Int) async throws -> [RAGSearchHit]
    func collection(named name: String) async throws -> CollectionID?
}

public struct RAGSearchHit: Sendable, Hashable, Codable {
    public var chunkID: ChunkID
    public var documentName: String
    public var page: Int?
    public var section: String?
    public var text: String
    public var score: Double

    public init(chunkID: ChunkID, documentName: String, page: Int?, section: String?, text: String, score: Double) {
        self.chunkID = chunkID
        self.documentName = documentName
        self.page = page
        self.section = section
        self.text = text
        self.score = score
    }
}

public struct RAGSearchTool: Tool {
    public let name = "rag_search"
    public let retriever: any RAGRetriever
    public let defaultTopK: Int

    public init(retriever: any RAGRetriever, defaultTopK: Int = 6) {
        self.retriever = retriever
        self.defaultTopK = defaultTopK
    }

    public func definition(for language: PromptLanguage) -> ToolDefinition {
        let description: String
        switch language {
        case .english:
            description = "Search the user's attached document collections for passages relevant to a query. Returns chunks with document name, page/section, and a relevance score. Use whenever the answer might be in the user's own corpus."
        case .swedish:
            description = "Sök i användarens bifogade dokumentsamlingar efter avsnitt relevanta för en fråga. Returnerar utdrag med dokumentnamn, sida/avsnitt och en relevanspoäng. Använd när svaret kan finnas i användarens eget material."
        }
        let schema = JSONSchema(raw: #"""
        {"type":"object","properties":{"query":{"type":"string"},"collection":{"type":"string","description":"Collection name"},"top_k":{"type":"integer","minimum":1,"maximum":20,"default":6}},"required":["query","collection"],"additionalProperties":false}
        """#)
        return ToolDefinition(name: name, description: description, parametersSchema: schema, strict: true)
    }

    public func invoke(arguments: String) async throws -> ToolOutput {
        struct Args: Decodable {
            let query: String
            let collection: String
            let top_k: Int?
        }
        guard let data = arguments.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(Args.self, from: data) else {
            throw ToolInvocationError.badArguments(arguments)
        }
        guard let id = try await retriever.collection(named: parsed.collection) else {
            let body = #"{"error":"unknown collection '\#(parsed.collection)'"}"#
            return ToolOutput(outputJSON: body, isError: true)
        }
        let topK = max(1, min(parsed.top_k ?? defaultTopK, 20))
        let hits = try await retriever.search(query: parsed.query, collectionID: id, topK: topK)
        let payload = RAGSearchPayload(query: parsed.query, collection: parsed.collection, hits: hits)
        let json = try JSONEncoder().encode(payload)
        return ToolOutput(outputJSON: String(data: json, encoding: .utf8) ?? "{}", display: .markdown)
    }
}

private struct RAGSearchPayload: Encodable {
    let query: String
    let collection: String
    let hits: [RAGSearchHit]
}
