// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Tiny wrapper over the system pasteboard. Lives here (not inline at the call
/// site) so the per-message "Copy" action stays testable and AppKit-free code
/// paths compile on non-AppKit targets.
enum Clipboard {
    /// Replace the general pasteboard's contents with `text` as plain string.
    static func copy(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
