import Testing
@testable import FChatProviders

@Suite("Providers smoke")
struct ProvidersSmokeTests {
    @Test func errorEquatable() {
        #expect(ProviderError.missingAPIKey == .missingAPIKey)
        #expect(ProviderError.httpStatus(500, body: "x") != .missingAPIKey)
    }
}
