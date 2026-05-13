import SwiftUI
import AppKit
import FanFiCore

@main
struct FanFiAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var monitor = StatusMonitor()
    @State private var presets = PresetController()
    @State private var installer = HelperInstaller()

    init() {
        AppDelegate.sharedPresets = nil  // will be wired after init in delegate
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(monitor: monitor, presets: presets, installer: installer)
                .onAppear { AppDelegate.sharedPresets = presets }
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set from SwiftUI; read from `applicationWillTerminate` (which can't
    /// inject SwiftUI state).
    @MainActor static var sharedPresets: PresetController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Tell the helper to release manual control before we exit. Sync
        // wait (DispatchSemaphore inside) — gives the XPC call ~2 s to reach
        // the helper. The helper itself stays alive as a LaunchDaemon and
        // will handle the restoreAuto on its own thread.
        let presets = MainActor.assumeIsolated { AppDelegate.sharedPresets }
        presets?.restoreOnQuitSync()
    }
}
