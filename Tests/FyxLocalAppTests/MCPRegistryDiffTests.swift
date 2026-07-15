// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
@testable import FyxLocalApp

@Suite("MCPRegistry adapter diff")
struct MCPRegistryDiffTests {
    @Test func removedToolsAreStale() {
        let stale = MCPRegistry.staleAdapterNames(
            current: ["mcp__s__a", "mcp__s__b", "mcp__s__c"],
            updated: ["mcp__s__a", "mcp__s__c"]
        )
        #expect(stale == ["mcp__s__b"])
    }

    @Test func unchangedAndAddedToolsAreNotStale() {
        let stale = MCPRegistry.staleAdapterNames(
            current: ["mcp__s__a"],
            updated: ["mcp__s__a", "mcp__s__new"]
        )
        #expect(stale.isEmpty)
    }

    @Test func emptyUpdateRemovesEverything() {
        let stale = MCPRegistry.staleAdapterNames(
            current: ["mcp__s__a", "mcp__s__b"],
            updated: []
        )
        #expect(stale == ["mcp__s__a", "mcp__s__b"])
    }

    @Test func emptyCurrentYieldsNothing() {
        #expect(MCPRegistry.staleAdapterNames(current: [], updated: ["mcp__s__a"]).isEmpty)
    }
}
