import AppKit
import SwiftUI

// Assets of the promo video (tools/promo-video), drawn by the same renderer as the screenshots:
//   zsh tools/screenshots/make.sh --video <output folder>
// It writes, at `scale` pixels per point, on transparent backgrounds:
//   menubar-<module>-<state>.png   the menu bar items of the video, one image per update
//   popup-<module>-<state>.png     their popups, histories moving one sample per update
//   menubar-system.png, widget-*.png  as for the screenshots
//   settings-<module>-<off|on>.png the real settings window, shown in front (see SettingsCapture)
//   video-assets.json              sizes in points
// Every number is demo data: a deterministic series, the same on every run.

/// The modules the video turns on, in the order the cursor switches them on.
let videoModules: [Module] = [.cpu, .memory, .network, .disk]

/// Numbers of the video, one state per update: each state moves every history one sample forward.
@MainActor
struct VideoSeries {
    static let states = 40
    static let history = SystemMonitor.historyLength
    private static let length = history + states

    let base: DemoData
    private let cpuTotal: [Double]
    private let download: [Double]
    private let upload: [Double]
    private let diskChanges: [Double]
    private let memoryApp: [Double]
    private let memoryCompressed: [Double]

    init(base: DemoData) {
        self.base = base
        let n = Self.length
        let noise1 = DemoData.noise(count: n, seed: 21)
        let noise2 = DemoData.noise(count: n, seed: 23)
        let noise3 = DemoData.noise(count: n, seed: 29)
        let noise4 = DemoData.noise(count: n, seed: 31)
        cpuTotal = (0..<n).map { index in
            let wave = 0.22 + 0.07 * sin(Double(index) / 4)
            let burst = index >= 58 && index <= 70 ? 0.34 * sin(Double(index - 57) / 14 * .pi) : 0
            return min(0.92, max(0.06, wave + burst + 0.12 * noise1[index]))
        }
        download = (0..<n).map { index in
            let active = 9_000_000 + 12_000_000 * (0.5 + 0.5 * sin(Double(index) / 5))
            return max(150_000, active * (0.55 + 0.9 * noise2[index] * noise2[index]))
        }
        upload = (0..<n).map { index in
            600_000 + 900_000 * noise3[index] + (index % 9 == 0 ? 700_000 : 0)
        }
        diskChanges = (0..<n).map { index in
            switch index {
            case 12: 1_700_000_000
            case 27: -880_000_000
            case 61: 1_150_000_000
            default: (noise4[index] - 0.35) * 150_000_000
            }
        }
        memoryApp = (0..<n).map { index in (5.0 + 0.35 * sin(Double(index) / 6) + 0.15 * noise1[(index * 7) % n]) * DemoData.gib }
        memoryCompressed = (0..<n).map { index in (3.9 + 0.2 * sin(Double(index) / 9)) * DemoData.gib }
    }

    /// The 50 values shown at `state`, oldest first; the last one is the current reading.
    private func window(_ series: [Double], _ state: Int) -> [Double] {
        Array(series[(state + 1)...(state + Self.history)])
    }

    func apply(state: Int, to monitor: SystemMonitor) {
        base.apply(to: monitor)
        let now = state + Self.history
        let total = cpuTotal[now]
        let user = total * 0.66
        let system = total - user
        let spread = [1.9, 1.6, 1.3, 1.05, 0.75, 0.55, 0.4, 0.3]
        let noise = DemoData.noise(count: 8, seed: UInt64(100 + state))
        let perCore = spread.indices.map { min(0.98, max(0.02, total * spread[$0] * (0.8 + 0.4 * noise[$0]))) }
        monitor.cpu = CPUSample(user: user, system: system, idle: 1 - total, perCore: perCore)
        monitor.cpuHistory = History(capacity: Self.history, values: window(cpuTotal, state))

        monitor.memory = MemorySample(total: 16 * DemoData.gib, app: memoryApp[now], wired: 3.2 * DemoData.gib,
                                      compressed: memoryCompressed[now])

        monitor.network = NetworkSample(upload: upload[now], download: download[now])
        monitor.uploadHistory = History(capacity: Self.history, values: window(upload, state))
        monitor.downloadHistory = History(capacity: Self.history, values: window(download, state))

        // Used space follows the changes: what was written since the first state is no longer free.
        let written = diskChanges[Self.history...now].reduce(0, +)
        monitor.disk = DiskSample(name: "", total: base.disk.total, free: base.disk.free - written)
        monitor.diskChanges = History(capacity: Self.history, values: window(diskChanges, state))
    }

    /// True while no reading of this Mac replaced the numbers of `state` (a popup samples when it appears).
    func isShown(state: Int, by monitor: SystemMonitor) -> Bool {
        let expected = SystemMonitor(settings: AppServices.settings)
        apply(state: state, to: expected)
        return monitor.cpu == expected.cpu && monitor.memory == expected.memory && monitor.network == expected.network
            && monitor.disk == expected.disk && monitor.cpuHistory.values == expected.cpuHistory.values
            && monitor.downloadHistory.values == expected.downloadHistory.values && monitor.localIP == expected.localIP
    }
}

@MainActor
final class VideoAssetRenderer {
    let renderer: AssetRenderer
    let series: VideoSeries
    private var sizes: [String: [String: Double]] = [:]
    private let settings = AppServices.settings

    init(renderer: AssetRenderer) {
        self.renderer = renderer
        series = VideoSeries(base: renderer.demo)
    }

    func renderAll(settingsOnly: Bool) {
        for module in Module.allCases { settings.setShown(module, false) }
        if !settingsOnly {
            renderMenuBar()
            for module in videoModules { renderPopups(module) }
            renderer.renderWidgets()
        }
        SettingsCapture(renderer: renderer, settings: settings, recordSize: { name, size in
            self.sizes[name] = ["w": size.width, "h": size.height]
        }).captureAll()
        writeManifest()
    }

    private func renderMenuBar() {
        for state in 0..<VideoSeries.states {
            let monitor = SystemMonitor(settings: settings)
            series.apply(state: state, to: monitor)
            for module in videoModules {
                let model = StatusItemModels.model(for: module, settings: settings, monitor: monitor)
                note(renderer.save(StatusItemView(model: model), name: "menubar-\(module.rawValue)-\(state)", mirrored: false))
            }
        }
        note(renderer.save(SystemTray(date: DemoData.date), name: "menubar-system"))
    }

    private func renderPopups(_ module: Module) {
        for state in 0..<VideoSeries.states {
            var done = false
            for _ in 1...4 where !done {
                let monitor = SystemMonitor(settings: settings)
                series.apply(state: state, to: monitor)
                let view: AnyView = switch module {
                case .cpu: AnyView(CPUPopup(monitor: monitor))
                case .memory: AnyView(MemoryPopup(monitor: monitor))
                case .network: AnyView(NetworkPopup(monitor: monitor))
                case .disk: AnyView(DiskPopup(monitor: monitor))
                default: ScreenshotRenderer.fail("no popup for \(module.rawValue) in the video")
                }
                let image = renderer.capture(view) { series.apply(state: state, to: monitor) }
                if series.isShown(state: state, by: monitor), let image {
                    note(renderer.write(image, name: "popup-\(module.rawValue)-\(state)"))
                    done = true
                }
            }
            if !done { ScreenshotRenderer.fail("popup \(module.rawValue) state \(state) kept showing measured numbers") }
        }
    }

    private func note(_ written: (name: String, size: CGSize)) {
        sizes[written.name] = ["w": written.size.width, "h": written.size.height]
    }

    /// Sizes of this run, added to those of an earlier one (a --settings-only run redraws the settings alone).
    private func writeManifest() {
        let url = renderer.output.appendingPathComponent("video-assets.json")
        if let data = try? Data(contentsOf: url),
           let earlier = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let earlierSizes = earlier["sizes"] as? [String: [String: Double]] {
            sizes.merge(earlierSizes) { current, _ in current }
        }
        for name in ["widget-cpu", "widget-memory", "widget-network", "widget-disk", "widget-storage-large",
                     "widget-storage-medium", "widget-storage-small"] {
            if let image = NSImage(contentsOf: renderer.output.appendingPathComponent("\(name).png")),
               let rep = image.representations.first {
                sizes[name] = ["w": Double(rep.pixelsWide) / renderer.scale, "h": Double(rep.pixelsHigh) / renderer.scale]
            }
        }
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let rgb = [accent.redComponent, accent.greenComponent, accent.blueComponent].map { Int(($0 * 255).rounded()) }
        if rgb != [0, 122, 255] {
            // The switches and the selected row take this Mac's accent colour: blue is the one of a new Mac.
            print("Renderer: warning, accent colour \(rgb) is not the default blue")
        }
        let manifest: [String: Any] = [
            "scale": renderer.scale, "states": VideoSeries.states, "sizes": sizes, "accent": rgb,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
        } catch {
            ScreenshotRenderer.fail("cannot write video-assets.json: \(error)")
        }
    }
}

/// The real settings window, on screen and in front as the app shows it: the switches, the selected row and the
/// window buttons take their colours only in the active window (an offscreen drawing leaves them grey). make.sh
/// launches the renderer with `open` for this, since macOS brings to the front an app LaunchServices launched, not
/// one started from a shell. The window is then drawn at the renderer's scale, title bar included.
@MainActor
struct SettingsCapture {
    let renderer: AssetRenderer
    let settings: AppSettings
    let recordSize: (String, CGSize) -> Void

    func captureAll() {
        let selection = SettingsSelection()
        let hosting = NSHostingController(rootView: SettingsView(settings: settings, selection: selection)
            .environment(\.colorScheme, .light))
        let window = RenderWindow(contentViewController: hosting)
        window.forcedScale = renderer.scale
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = String(localized: "SimplyBar Settings")
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 700, height: 440))
        window.center()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        let limit = Date().addingTimeInterval(10)
        while !NSApp.isActive && Date() < limit { spin(0.2) }
        if !NSApp.isActive {
            ScreenshotRenderer.fail("the settings window is not in front: its switches would be grey (run make.sh --video)")
        }

        for module in videoModules {
            for shown in [false, true] {
                settings.setShown(module, shown)
                selection.tab = .module(module)
                spin(0.5)
                // A click or a notification may have taken the focus since: never write grey switches.
                guard NSApp.isActive else { ScreenshotRenderer.fail("the settings window lost the focus") }
                capture(window, name: "settings-\(module.rawValue)-\(shown ? "on" : "off")")
            }
        }
        window.orderOut(nil)
    }

    private func capture(_ window: NSWindow, name: String) {
        // The frame view holds the title bar and the content.
        guard let frameView = window.contentView?.superview else { ScreenshotRenderer.fail("no frame view") }
        let size = frameView.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * renderer.scale),
                                         pixelsHigh: Int(size.height * renderer.scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { ScreenshotRenderer.fail("no bitmap for \(name)") }
        rep.size = size
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        guard let image = rep.cgImage else { ScreenshotRenderer.fail("nothing drawn for \(name)") }
        renderer.write(image, name: name)
        recordSize(name, size)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
