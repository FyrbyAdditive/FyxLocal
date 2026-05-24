import Testing
@testable import FChatWeb

@Suite("Web smoke")
struct WebSmokeTests {
    @Test func errorTypes() {
        #expect(WebSearchError.rateLimited == .rateLimited)
        #expect(WebSearchError.httpStatus(429) != .rateLimited)
    }
}
