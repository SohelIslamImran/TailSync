import AppKit
import SwiftUI

@main
struct TailSyncMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var store = MacSyncStore()

    var body: some Scene {
        MenuBarExtra {
            MacMenuBarView(store: store) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        } label: {
            Label("TailSync", systemImage: store.isRunning ? "arrow.triangle.2.circlepath" : "paperplane")
        }
        .menuBarExtraStyle(.menu)

        WindowGroup("TailSync", id: "main") {
            MacContentView(store: store)
                .frame(minWidth: 940, minHeight: 620)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Sync Now") {
                    Task { await store.syncNow() }
                }
                .keyboardShortcut("s", modifiers: [.command])

                Button(store.isPaused ? "Resume Sync" : "Pause Sync") {
                    store.togglePaused()
                }
                .keyboardShortcut("p", modifiers: [.command])
            }
        }

        Settings {
            MacSettingsView(store: store)
                .frame(width: 460)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
