import Testing
@testable import FChatMCP

@Suite("MCP smoke")
struct MCPSmokeTests {
    @Test func errorEnumEquatable() {
        #expect(MCPClientError.notInitialized == .notInitialized)
        #expect(MCPClientError.unexpectedResult != .notInitialized)
    }
}
