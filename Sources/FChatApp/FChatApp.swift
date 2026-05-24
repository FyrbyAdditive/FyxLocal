import SwiftUI
import FChatCore
#if canImport(AppKit)
import AppKit
#endif

@main
struct FChatApp: App {
    @State private var environment = AppEnvironment()
    #if canImport(AppKit)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    environment.newConversation(title: "New chat")
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
        }

        Settings {
            SettingsView(environment: environment)
        }
    }
}

#if canImport(AppKit)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When the binary is launched outside a proper .app bundle (e.g. via
        // `swift run` or `.build/debug/FChat`), macOS leaves the process in
        // a background activation policy. Force it to `.regular` so the
        // window gets a Dock icon, key-window status, and keyboard focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
#endif
