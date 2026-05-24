import Testing
import Foundation
@testable import FChatProviders

@Suite("OpenAIResponsesProvider decoders")
struct ProviderDecodersTests {
    @Test func decodesModelList() throws {
        let json = #"""
        {"data":[
            {"id":"gpt-4o-mini","owned_by":"openai","context_window":128000,"max_output_tokens":16384},
            {"id":"llama-3-70b"}
        ]}
        """#
        let models = try OpenAIResponsesProvider.decodeModels(json.data(using: .utf8)!)
        #expect(models.count == 2)
        #expect(models[0].id == "gpt-4o-mini")
        #expect(models[0].contextWindow == 128000)
        #expect(models[1].id == "llama-3-70b")
        #expect(models[1].contextWindow == nil)
    }

    @Test func decodesEmbeddingsAndSortsByIndex() throws {
        let json = #"""
        {"data":[
            {"index":1,"embedding":[3.0,4.0]},
            {"index":0,"embedding":[1.0,2.0]}
        ]}
        """#
        let vectors = try OpenAIResponsesProvider.decodeEmbeddings(json.data(using: .utf8)!, expectedCount: 2)
        #expect(vectors == [[1.0, 2.0], [3.0, 4.0]])
    }

    @Test func embeddingsCountMismatchThrows() {
        let json = #"{"data":[{"index":0,"embedding":[1.0]}]}"#
        #expect(throws: ProviderError.malformedResponse("embeddings count mismatch: got 1 expected 3")) {
            _ = try OpenAIResponsesProvider.decodeEmbeddings(json.data(using: .utf8)!, expectedCount: 3)
        }
    }
}
