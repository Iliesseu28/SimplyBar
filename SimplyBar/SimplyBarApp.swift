import AppKit
import SwiftUI

/// The shared settings and monitor, created once for the whole app.
@MainActor
enum AppServices {
    static let settings = AppSettings()
    static let monitor = SystemMonitor(settings: settings)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppServices.monitor.start()
        if AppServices.settings.openSettingsAtLaunch {
            SettingsWindowController.shared.show()
        }
    }

    /// Opening the app again while it runs (Finder, Spotlight, Launchpad) shows the settings, the only way back
    /// when every menu bar item is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }
}

@main
struct SimplyBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Bindable private var settings = AppServices.settings
    private let monitor = AppServices.monitor

    var body: some Scene {
        // Declaration order sets the initial order: the first item ends up rightmost.
        MenuBarExtra(isInserted: $settings.cpu.shown) {
            CPUPopup(monitor: monitor)
        } label: {
            MenuBarLabel(module: .cpu, settings: settings, monitor: monitor)
        }
        .menuBarExtraStyle(.window)

        MenuBarExtra(isInserted: $settings.memory.shown) {
            MemoryPopup(monitor: monitor)
        } label: {
            MenuBarLabel(module: .memory, settings: settings, monitor: monitor)
        }
        .menuBarExtraStyle(.window)

        MenuBarExtra(isInserted: $settings.network.shown) {
            NetworkPopup(monitor: monitor)
        } label: {
            MenuBarLabel(module: .network, settings: settings, monitor: monitor)
        }
        .menuBarExtraStyle(.window)

        MenuBarExtra(isInserted: $settings.disk.shown) {
            DiskPopup(monitor: monitor)
        } label: {
            MenuBarLabel(module: .disk, settings: settings, monitor: monitor)
        }
        .menuBarExtraStyle(.window)

        MenuBarExtra(isInserted: $settings.gpu.shown) {
            GPUPopup(monitor: monitor)
        } label: {
            MenuBarLabel(module: .gpu, settings: settings, monitor: monitor)
        }
        .menuBarExtraStyle(.window)

        MenuBarExtra(isInserted: $settings.bluetooth.shown) {
            BluetoothPopup(monitor: monitor)
        } label: {
            MenuBarLabel(module: .bluetooth, settings: settings, monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}
