// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
@testable import FyxLocalApp

#if canImport(AppKit)
import AppKit

@Suite("Clipboard")
struct ClipboardTests {
    @Test func copyWritesStringToPasteboard() {
        let marker = "fyxlocal-copy-test-\(UUID().uuidString)"
        Clipboard.copy(marker)
        #expect(NSPasteboard.general.string(forType: .string) == marker)
    }
}
#endif
