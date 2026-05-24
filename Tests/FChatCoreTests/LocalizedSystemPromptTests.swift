import Testing
@testable import FChatCore

@Suite("LocalizedSystemPrompt")
struct LocalizedSystemPromptTests {
    @Test func englishContainsFChatAndDoesNotMentionSwedish() {
        let prompt = LocalizedSystemPrompt(language: .english).render()
        #expect(prompt.contains("F-Chat"))
        #expect(prompt.lowercased().contains("concise"))
        #expect(!prompt.contains("svenska"))
    }

    @Test func swedishAnchorPhrasePresent() {
        let prompt = LocalizedSystemPrompt(language: .swedish).render()
        #expect(prompt.contains("F-Chat"))
        #expect(prompt.contains("svenska"))
    }

    @Test func toolGuidanceTogglesSection() {
        let withTools = LocalizedSystemPrompt(language: .english, includeToolGuidance: true).render()
        let withoutTools = LocalizedSystemPrompt(language: .english, includeToolGuidance: false).render()
        #expect(withTools.contains("tools"))
        #expect(!withoutTools.contains("provided tools"))
    }

    @Test func ragGuidanceTogglesSection() {
        let withRAG = LocalizedSystemPrompt(language: .english, includeRAGGuidance: true).render()
        let withoutRAG = LocalizedSystemPrompt(language: .english, includeRAGGuidance: false).render()
        #expect(withRAG.contains("rag_search"))
        #expect(!withoutRAG.contains("rag_search"))
    }

    @Test func customSuffixAppended() {
        let prompt = LocalizedSystemPrompt(
            language: .english,
            customSuffix: "Always end answers with a haiku."
        ).render()
        #expect(prompt.hasSuffix("Always end answers with a haiku."))
    }

    @Test(arguments: PromptLanguage.allCases)
    func allLanguagesProduceNonEmptyOutputAcrossFlagMatrix(language: PromptLanguage) {
        for tools in [false, true] {
            for rag in [false, true] {
                let prompt = LocalizedSystemPrompt(
                    language: language,
                    includeToolGuidance: tools,
                    includeRAGGuidance: rag
                ).render()
                #expect(!prompt.isEmpty)
                #expect(prompt.count > 50)
            }
        }
    }
}
