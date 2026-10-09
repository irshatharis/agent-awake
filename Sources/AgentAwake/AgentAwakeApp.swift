import SwiftUI
import AppKit
import Darwin

@main struct AgentAwakeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AwakeModel.shared
    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(systemName: model.symbol)
                .accessibilityLabel("Agent Awake: \(model.title)")
        }
        .menuBarExtraStyle(.window)
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        umask(0o077)
        NSApp.setActivationPolicy(.accessory)
        if !UserDefaults.standard.bool(forKey: "hasOpenedSetup") || CommandLine.arguments.contains("--settings") {
            UserDefaults.standard.set(true, forKey: "hasOpenedSetup")
            AwakeModel.shared.showSettings()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AwakeModel.shared.showSettings()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
