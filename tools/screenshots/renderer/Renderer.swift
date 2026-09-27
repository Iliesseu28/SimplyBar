import AppKit
import SwiftUI
import WidgetKit

// Screenshot renderer. `tools/screenshots/make.sh` compiles it together with copies of the app and widget sources
// (never into the app itself) and runs it once per language with `-AppleLanguages` and `-AppleLocale`.
// It draws the real views (menu bar items, popups, widgets) with demo numbers into transparent PNGs; `compose.py`
// then lays them out on a desktop.
//
// Usage: Renderer <output folder> <demo names JSON> <scale> <ltr|rtl> [--video]
// With --video it draws the assets of the promo video instead (VideoAssets.swift).

/// Stands in for the one of `SimplyBarApp.swift`, which this build leaves out (it holds the app's `@main`).
@MainActor
enum AppServices {
    static let settings = AppSettings(defaults: RenderDefaults.suite)
    static let monitor = SystemMonitor(settings: settings)
}

/// Settings of the renderer live in their own domain, erased at start and at exit: the app's settings stay untouched.
enum RenderDefaults {
    static let name = "fr.simplibot.simplybar.screenshot-renderer"
    nonisolated(unsafe) static let suite: UserDefaults = {
        UserDefaults.standard.removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name) ?? .standard
    }()
}

@main
struct ScreenshotRenderer {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 5, let scale = Double(arguments[3]) else {
            fail("usage: Renderer <output folder> <demo names JSON> <scale> <ltr|rtl>")
        }
        let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
        if arguments.contains("--video") {
            // Launched by `open`, which leaves no terminal: messages go to a file of the output folder.
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let log = output.appendingPathComponent("render.log").path
            guard freopen(log, "w", stdout) != nil else { fail("cannot write \(log)") }
            setvbuf(stdout, nil, _IOLBF, 0)
            dup2(STDOUT_FILENO, STDERR_FILENO)
        }
        let rtl = arguments[4] == "rtl"
        let names: DemoNames
        do {
            names = try JSONDecoder().decode(DemoNames.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        } catch {
            fail("cannot read the demo names: \(error)")
        }

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .aqua)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let renderer = AssetRenderer(output: output, scale: scale, rtl: rtl, demo: DemoData(names: names))
        if arguments.contains("--video") {
            VideoAssetRenderer(renderer: renderer).renderAll(settingsOnly: arguments.contains("--settings-only"))
        } else {
            renderer.renderAll()
        }
        UserDefaults.standard.removePersistentDomain(forName: RenderDefaults.name)
        print("rendered \(renderer.count) images into \(output.path) (\(Bundle.main.preferredLocalizations.first ?? "?"))")
        exit(0)
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Renderer: \(message)\n".utf8))
        exit(1)
    }
}

@MainActor
final class AssetRenderer {
    let output: URL
    let scale: CGFloat
    let rtl: Bool
    let demo: DemoData
    private(set) var count = 0

    /// What the menu bar shows: every module, Bluetooth included (hidden by default in the app).
    private let settings = AppServices.settings

    init(output: URL, scale: CGFloat, rtl: Bool, demo: DemoData) {
        self.output = output
        self.scale = scale
        self.rtl = rtl
        self.demo = demo
    }

    func renderAll() {
        // Hidden modules are not sampled: only the popup being drawn reads this Mac, and the demo numbers win.
        for module in Module.allCases { settings.setShown(module, false) }

        // Menu bar items: drawn left to right as the app draws them, whatever the language.
        let labelMonitor = SystemMonitor(settings: settings)
        demo.apply(to: labelMonitor)
        for module in Module.allCases {
            let model = StatusItemModels.model(for: module, settings: settings, monitor: labelMonitor)
            save(StatusItemView(model: model), name: "menubar-\(module.rawValue)", mirrored: false)
        }
        save(SystemTray(date: DemoData.date), name: "menubar-system")

        // Popups, each with its own monitor so a sample taken when it appears cannot leak into another one.
        for module in Module.allCases {
            renderPopup(module)
        }

        renderWidgets()
    }

    /// Widgets, from the payload the app itself would write.
    func renderWidgets() {
        let labelMonitor = SystemMonitor(settings: settings)
        demo.apply(to: labelMonitor)
        let payload = demo.payload(from: labelMonitor)
        save(WidgetFrame(size: .small) { CPUWidgetView(payload: payload) }, name: "widget-cpu")
        save(WidgetFrame(size: .small) { MemoryWidgetView(payload: payload) }, name: "widget-memory")
        save(WidgetFrame(size: .small) { NetworkWidgetView(payload: payload) }, name: "widget-network")
        save(WidgetFrame(size: .small) { DiskWidgetView(payload: payload) }, name: "widget-disk")
        // The Storage widget picks its view from the widget family, which only WidgetKit can set: its three
        // sizes are drawn with the views it picks (small: the chosen disk; medium: 2 disks; large: 5, detailed).
        // The small one shows Photos, a short name in every language (a long one is cut next to the percentage).
        let chosen = StorageEntry(date: DemoData.date, payload: payload, diskID: "/Volumes/Photos")
        let all = StorageEntry(date: DemoData.date, payload: payload, diskID: nil)
        if let photos = chosen.volumes.first {
            save(WidgetFrame(size: .small) { SmallStorageView(volume: photos, date: DemoData.date) }, name: "widget-storage-small")
        }
        save(WidgetFrame(size: .medium) {
            StorageListView(volumes: Array(all.volumes.prefix(2)), date: DemoData.date, detailed: false)
        }, name: "widget-storage-medium")
        save(WidgetFrame(size: .large) {
            StorageListView(volumes: Array(all.volumes.prefix(5)), date: DemoData.date, detailed: true)
        }, name: "widget-storage-large")
    }

    private func renderPopup(_ module: Module) {
        for attempt in 1...3 {
            let monitor = SystemMonitor(settings: settings)
            demo.apply(to: monitor)
            if module == .bluetooth { monitor.bluetoothLoaded = false }
            let view: AnyView = switch module {
            case .cpu: AnyView(CPUPopup(monitor: monitor))
            case .memory: AnyView(MemoryPopup(monitor: monitor))
            case .gpu: AnyView(GPUPopup(monitor: monitor))
            case .network: AnyView(NetworkPopup(monitor: monitor))
            case .disk: AnyView(DiskPopup(monitor: monitor))
            case .bluetooth: AnyView(BluetoothPopup(monitor: monitor))
            }
            let image = capture(view) {
                // The popup sampled this Mac when it appeared (Bluetooth asynchronously): wait for that reading,
                // then put the demo numbers back before drawing.
                if module == .bluetooth { spin(until: { monitor.bluetoothLoaded }, timeout: 5) }
                demo.apply(to: monitor)
            }
            if demo.isShown(by: monitor), let image {
                write(image, name: "popup-\(module.rawValue)")
                return
            }
            FileHandle.standardError.write(Data("Renderer: popup \(module.rawValue) changed while drawing, attempt \(attempt)\n".utf8))
        }
        ScreenshotRenderer.fail("popup \(module.rawValue) kept showing measured numbers")
    }

    // MARK: - Drawing

    /// Writes `name`.png and returns its size in points.
    @discardableResult
    func save<V: View>(_ view: V, name: String, mirrored: Bool = true) -> (name: String, size: CGSize) {
        guard let image = capture(AnyView(view), mirrored: mirrored, prepare: {}) else {
            ScreenshotRenderer.fail("nothing drawn for \(name)")
        }
        return write(image, name: name)
    }

    /// Draws a view the way a window shows it (buttons included, which `ImageRenderer` leaves out) at `scale`
    /// pixels per point, on a transparent background.
    func capture(_ view: AnyView, mirrored: Bool = true, prepare: () -> Void) -> CGImage? {
        let direction: LayoutDirection = rtl && mirrored ? .rightToLeft : .leftToRight
        let host = NSHostingView(rootView: view
            .environment(\.colorScheme, .light)
            .environment(\.layoutDirection, direction)
            .environment(\.timeZone, .current))
        host.appearance = NSAppearance(named: .aqua)
        host.userInterfaceLayoutDirection = direction == .rightToLeft ? .rightToLeft : .leftToRight
        var size = host.fittingSize
        let window = RenderWindow(contentRect: CGRect(x: -8000, y: -8000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        window.forcedScale = scale
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.contentView = host
        window.orderFront(nil)
        spin(for: 0.15)
        prepare()
        spin(for: 0.1)
        size = host.fittingSize
        window.setContentSize(size)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        host.display()
        defer { window.orderOut(nil) }
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()),
                                         pixelsHigh: Int((size.height * scale).rounded()), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.cgImage
    }

    @discardableResult
    func write(_ image: CGImage, name: String) -> (name: String, size: CGSize) {
        let url = output.appendingPathComponent("\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            ScreenshotRenderer.fail("cannot write \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { ScreenshotRenderer.fail("cannot write \(url.path)") }
        count += 1
        return (name, CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    }

    private func spin(for seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func spin(until done: () -> Bool, timeout: TimeInterval) {
        let limit = Date().addingTimeInterval(timeout)
        while !done() && Date() < limit { spin(for: 0.05) }
    }
}

/// An offscreen window whose backing scale is chosen: views are drawn sharp at 3 or 4 pixels per point, not
/// scaled up from the screen's 2.
final class RenderWindow: NSWindow {
    var forcedScale: CGFloat = 2
    override var backingScaleFactor: CGFloat { forcedScale }
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
}

/// A desktop widget's size and content margins on macOS; the card itself is drawn by `compose.py`.
struct WidgetFrame<Content: View>: View {
    enum Size {
        case small, medium, large
        var points: CGSize {
            switch self {
            case .small: CGSize(width: 170, height: 170)
            case .medium: CGSize(width: 364, height: 170)
            case .large: CGSize(width: 364, height: 382)
            }
        }
    }

    let size: Size
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(width: size.points.width, height: size.points.height, alignment: .topLeading)
    }
}

/// The system side of the menu bar next to the app's items: generic symbols and the clock, no brand.
struct SystemTray: View {
    let date: Date

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "battery.75percent")
            Image(systemName: "wifi")
            Image(systemName: "magnifyingglass")
            Image(systemName: "switch.2")
            Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                .monospacedDigit()
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Color.black)
        .frame(height: 22)
        .fixedSize()
    }
}
