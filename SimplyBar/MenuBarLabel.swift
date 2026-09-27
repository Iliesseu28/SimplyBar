import AppKit
import SwiftUI

/// What one menu bar item shows: optional icon, optional stacked letters, then bars or text.
struct StatusItemModel: Equatable {
    enum Content: Equatable {
        case bars([Double])
        case text(String, bold: Bool)
        case lines(String, String)
    }

    var symbol: String?
    var letters: String?
    var content: Content
    /// Drawn in red instead of the menu bar color (disk flash).
    var alert = false
}

/// Builds each module's menu bar model from the settings and the latest sample.
@MainActor
enum StatusItemModels {
    static func model(for module: Module, settings: AppSettings, monitor: SystemMonitor) -> StatusItemModel {
        switch module {
        case .cpu:
            let s = settings.cpu
            return StatusItemModel(symbol: s.showIcon ? module.symbol : nil, letters: s.showLabel ? module.shortLabel : nil,
                                   content: cpuContent(monitor.cpu, settings: s))
        case .memory:
            let s = settings.memory
            return StatusItemModel(symbol: s.showIcon ? module.symbol : nil, letters: s.showLabel ? module.shortLabel : nil,
                                   content: memoryContent(monitor.memory, settings: s))
        case .gpu:
            let s = settings.gpu
            let value = monitor.gpus.map(\.utilization).max() ?? 0
            let content: StatusItemModel.Content = s.style == .bar ? .bars([value]) : .text(Format.percent(value), bold: false)
            return StatusItemModel(symbol: s.showIcon ? module.symbol : nil, letters: s.showLabel ? module.shortLabel : nil,
                                   content: content)
        case .network:
            let s = settings.network
            return StatusItemModel(symbol: s.showIcon ? module.symbol : nil, letters: s.showLabel ? module.shortLabel : nil,
                                   content: networkContent(monitor.network, ip: monitor.localIP, settings: s))
        case .disk:
            let s = settings.disk
            return StatusItemModel(symbol: s.showIcon ? module.symbol : nil, letters: s.showLabel ? module.shortLabel : nil,
                                   content: diskContent(monitor.disk, settings: s), alert: monitor.diskFlashing)
        case .bluetooth:
            let s = settings.bluetooth
            let lowest = monitor.bluetoothDevices.compactMap(\.lowest).min()
            return StatusItemModel(symbol: s.showIcon ? module.symbol : nil, letters: s.showLabel ? module.shortLabel : nil,
                                   content: .text(lowest.map { "\($0)%" } ?? "-", bold: false))
        }
    }

    static func cpuContent(_ sample: CPUSample?, settings: CPUSettings) -> StatusItemModel.Content {
        // No measure yet (the first one needs two readings): no false 0 %.
        guard let cpu = sample else { return settings.style == .bar ? .bars([0]) : .text("-", bold: false) }
        let single: Double = switch settings.metric {
        case .total, .userSystem, .perCore: cpu.total
        case .system: cpu.system
        case .user: cpu.user
        case .idle: cpu.idle
        }
        guard settings.style == .bar else { return .text(Format.percent(single), bold: false) }
        switch settings.metric {
        case .userSystem: return .bars([cpu.user, cpu.system])
        case .perCore: return .bars(cpu.perCore.isEmpty ? [0] : cpu.perCore)
        default: return .bars([single])
        }
    }

    static func memoryContent(_ sample: MemorySample?, settings: MemorySettings) -> StatusItemModel.Content {
        guard let memory = sample else { return settings.style == .bar ? .bars([0]) : .text("-", bold: false) }
        let bytes: Double = switch settings.metric {
        case .total: memory.used
        case .app: memory.app
        case .wired: memory.wired
        case .compressed: memory.compressed
        case .pressure: memory.wired + memory.compressed
        }
        let fraction = settings.metric == .pressure ? memory.pressure : (memory.total > 0 ? bytes / memory.total : 0)
        switch settings.style {
        case .bar: return .bars([fraction])
        case .percent: return .text(Format.percent(fraction), bold: false)
        case .gigabytes:
            if settings.metric == .pressure { return .text(Format.percent(fraction), bold: false) }
            // With its unit, in the system language ("GB", "Go").
            return .text("\(Format.memoryGigabytes(bytes)) \(String(localized: "GB"))", bold: true)
        }
    }

    static func networkContent(_ sample: NetworkSample?, ip: String?, settings: NetworkSettings) -> StatusItemModel.Content {
        let up = sample.map { Format.speedText($0.upload) } ?? "-"
        let down = sample.map { Format.speedText($0.download) } ?? "-"
        switch settings.metric {
        case .both: return .lines("↑\(up)", "↓\(down)")
        case .upload: return .text("↑\(up)", bold: false)
        case .download: return .text("↓\(down)", bold: false)
        case .ipAddress: return .text(ip ?? "-", bold: false)
        }
    }

    static func diskContent(_ sample: DiskSample?, settings: DiskSettings) -> StatusItemModel.Content {
        guard let disk = sample else { return settings.style == .bar ? .bars([0]) : .text("-", bold: false) }
        let bytes: Double = switch settings.metric {
        case .total: disk.total
        case .free: disk.free
        case .used: disk.used
        }
        let fraction = disk.total > 0 ? bytes / disk.total : 0
        switch settings.style {
        case .bar: return .bars([fraction])
        case .percent: return .text(Format.percent(fraction), bold: false)
        case .gigabytes: return .text(Format.diskGigabytes(bytes, decimals: 1), bold: true)
        }
    }
}

/// SwiftUI drawing of a menu bar item, rendered to an image (a menu bar label only shows images and text).
struct StatusItemView: View {
    let model: StatusItemModel

    var body: some View {
        HStack(spacing: 3) {
            if let symbol = model.symbol {
                Image(systemName: symbol).font(.system(size: 12.5, weight: .regular))
            }
            if let letters = model.letters {
                VStack(spacing: -2) {
                    ForEach(Array(letters.enumerated()), id: \.offset) { item in
                        Text(String(item.element)).font(.system(size: 6.5, weight: .bold))
                    }
                }
            }
            content
        }
        .foregroundStyle(model.alert ? Color.red : Color.black)
        .frame(height: 22)
        .fixedSize()
    }

    @ViewBuilder private var content: some View {
        switch model.content {
        case .bars(let values):
            let thin = values.count > 2
            HStack(spacing: thin ? 1 : 2) {
                ForEach(values.indices, id: \.self) { index in
                    VerticalBar(value: values[index], width: thin ? 3 : 6)
                }
            }
        case .text(let text, let bold):
            Text(text).font(.system(size: 12.5, weight: bold ? .bold : .medium)).monospacedDigit()
        case .lines(let first, let second):
            VStack(alignment: .leading, spacing: -1.5) {
                Text(first)
                Text(second)
            }
            .font(.system(size: 9, weight: .medium))
            .monospacedDigit()
        }
    }
}

/// Vertical gauge of the menu bar: faint track, solid fill from the bottom.
struct VerticalBar: View {
    var value: Double
    var width: CGFloat
    var height: CGFloat = 17

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 1.5).opacity(0.3)
            RoundedRectangle(cornerRadius: 1.5).frame(height: max(1, height * Format.clamp(value)))
        }
        .frame(width: width, height: height)
    }
}

/// Renders menu bar images, re-using the previous image while the model has not changed.
@MainActor
final class StatusItemRenderer {
    static let shared = StatusItemRenderer()

    private var cache: [Module: (model: StatusItemModel, image: NSImage)] = [:]

    func image(for module: Module, model: StatusItemModel) -> NSImage {
        if let cached = cache[module], cached.model == model { return cached.image }
        let renderer = ImageRenderer(content: StatusItemView(model: model))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 16, height: 22))
        image.isTemplate = !model.alert
        cache[module] = (model, image)
        return image
    }
}

/// The label of a `MenuBarExtra`: re-evaluated when the module's sample or settings change.
struct MenuBarLabel: View {
    let module: Module
    let settings: AppSettings
    let monitor: SystemMonitor

    var body: some View {
        let model = StatusItemModels.model(for: module, settings: settings, monitor: monitor)
        Image(nsImage: StatusItemRenderer.shared.image(for: module, model: model))
            .renderingMode(model.alert ? .original : .template)
    }
}
