import Testing
@testable import FChatRAG

@Suite("RAG smoke")
struct RAGSmokeTests {
    @Test func enumPlaceholder() {
        #expect(EmbedderError.emptyInput == .emptyInput)
    }
}
