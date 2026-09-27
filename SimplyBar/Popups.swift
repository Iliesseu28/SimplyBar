import AppKit
import SwiftUI

// MARK: - Building blocks

/// Frame shared by every popup: title with a settings button, content, Quit button.
struct PopupChrome<Content: View>: View {
    let module: Module
    let title: LocalizedStringKey
    let monitor: SystemMonitor
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: module.symbol).foregroundStyle(.secondary)
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    SettingsWindowController.shared.show(tab: .module(module))
                } label: {
                    Image(systemName: "gearshape.fill")
                }
                .buttonStyle(.borderless)
                .help(Text("Settings"))
            }
            Divider()
            content
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
                .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { monitor.popupOpened(module) }
        .onDisappear { monitor.popupClosed(module) }
    }
}

struct Headline: View {
    let title: LocalizedStringKey
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Text(value).foregroundStyle(color).monospacedDigit()
        }
        .font(.system(size: 13, weight: .medium))
    }
}

struct SectionTitle: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
    }
}

struct DetailRow<Trailing: View>: View {
    let title: LocalizedStringKey
    let value: String
    var dot: Color?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer()
            Text(value).monospacedDigit().textSelection(.enabled)
            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
            trailing
        }
        .font(.system(size: 12))
    }
}

extension DetailRow where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, _ value: String, dot: Color? = nil) {
        self.init(title: title, value: value, dot: dot) { EmptyView() }
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : "Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        }
        .controlSize(.small)
    }
}

private func gigabytesText(_ value: String) -> String { "\(value) \(String(localized: "GB"))" }

// MARK: - Popups

struct CPUPopup: View {
    let monitor: SystemMonitor

    var body: some View {
        PopupChrome(module: .cpu, title: "CPU Usage", monitor: monitor) {
            let cpu = monitor.cpu ?? CPUSample(user: 0, system: 0, idle: 1, perCore: [])
            Headline(title: "Total Usage:", value: Format.percent(cpu.total), color: Palette.load(cpu.total))
            TickBar(value: cpu.total)
            SectionTitle("Usage History:")
            HistoryChart(
                values: monitor.cpuHistory.values, capacity: SystemMonitor.historyLength,
                scale: ChartScale(values: monitor.cpuHistory.values, minimum: 0.1),
                barColor: { Palette.load($0) }, axisLabel: { Format.percent($0) }
            )
            .frame(height: 80)
            SectionTitle("Details:")
            VStack(spacing: 4) {
                DetailRow("User:", Format.percent(cpu.user))
                DetailRow("System:", Format.percent(cpu.system))
                DetailRow("Idle:", Format.percent(cpu.idle))
            }
            if !cpu.perCore.isEmpty {
                SectionTitle("Usage Per Core:")
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 6), count: min(8, cpu.perCore.count)), spacing: 6) {
                    ForEach(cpu.perCore.indices, id: \.self) { index in
                        CoreGauge(value: cpu.perCore[index])
                    }
                }
            }
        }
    }
}

struct MemoryPopup: View {
    let monitor: SystemMonitor

    var body: some View {
        PopupChrome(module: .memory, title: "RAM Usage", monitor: monitor) {
            if let memory = monitor.memory {
                Headline(title: "Pressure:", value: Format.percent(memory.pressure), color: Palette.load(memory.pressure))
                TickBar(value: memory.pressure)
                Headline(title: "Total Usage:", value: Format.percent(memory.usage, decimals: 1), color: Palette.load(memory.usage))
                TickBar(stacked: [
                    (memory.app / memory.total, Palette.app),
                    (memory.wired / memory.total, Palette.wired),
                    (memory.compressed / memory.total, Palette.compressed),
                ])
                SectionTitle("Details:")
                VStack(spacing: 4) {
                    DetailRow("Apps:", gigabytesText(Format.memoryGigabytes(memory.app)), dot: Palette.app)
                    DetailRow("Wired:", gigabytesText(Format.memoryGigabytes(memory.wired)), dot: Palette.wired)
                    DetailRow("Compressed:", gigabytesText(Format.memoryGigabytes(memory.compressed)), dot: Palette.compressed)
                    DetailRow("Free:", gigabytesText(Format.memoryGigabytes(memory.free)), dot: Palette.free)
                }
            } else {
                Text("Measuring…").foregroundStyle(.secondary)
            }
        }
    }
}

struct DiskPopup: View {
    let monitor: SystemMonitor

    var body: some View {
        PopupChrome(module: .disk, title: "SSD Usage", monitor: monitor) {
            if let disk = monitor.disk {
                let changes = monitor.diskChanges.values
                let scale = ChartScale(values: changes.map(abs), minimum: 0.1 * Format.decimalGigabyte)
                Headline(title: "Free:", value: gigabytesText(Format.diskGigabytes(disk.free)), color: Palette.load(disk.usage))
                TickBar(gradientValue: disk.usage)
                SectionTitle("Usage History:")
                MirrorChart(
                    up: changes.map { max(0, $0) }, down: changes.map { max(0, -$0) },
                    capacity: SystemMonitor.historyLength, upScale: scale, downScale: scale,
                    upColor: Palette.red, downColor: Palette.green,
                    axisLabel: { gigabytesText(Format.diskGigabytes($0)) }, downPrefix: "-"
                )
                .frame(height: 90)
                SectionTitle("Details:")
                VStack(spacing: 4) {
                    DetailRow("Total:", gigabytesText(Format.diskGigabytes(disk.total)))
                    DetailRow("Used:", gigabytesText(Format.diskGigabytes(disk.used)))
                    DetailRow("Free:", gigabytesText(Format.diskGigabytes(disk.free)))
                }
            } else {
                Text("Measuring…").foregroundStyle(.secondary)
            }
        }
    }
}

struct NetworkPopup: View {
    let monitor: SystemMonitor

    var body: some View {
        PopupChrome(module: .network, title: "Network Usage", monitor: monitor) {
            let up = monitor.uploadHistory.values
            let down = monitor.downloadHistory.values
            SectionTitle("Usage History:")
            MirrorChart(
                up: up, down: down, capacity: SystemMonitor.historyLength,
                upScale: ChartScale(values: up, minimum: 10_000), downScale: ChartScale(values: down, minimum: 10_000),
                upColor: Palette.upload, downColor: Palette.download,
                axisLabel: { Format.speedText($0, decimals: 2) }
            )
            .frame(height: 90)
            SectionTitle("Details:")
            VStack(spacing: 4) {
                DetailRow("Upload:", Format.speedText(monitor.network?.upload ?? 0, decimals: 2), dot: Palette.upload)
                DetailRow("Download:", Format.speedText(monitor.network?.download ?? 0, decimals: 2), dot: Palette.download)
                DetailRow(title: "IP Address:", value: monitor.localIP ?? "-") {
                    if let ip = monitor.localIP { CopyButton(text: ip) }
                }
            }
        }
    }
}

struct GPUPopup: View {
    let monitor: SystemMonitor

    var body: some View {
        PopupChrome(module: .gpu, title: "GPU Usage", monitor: monitor) {
            if monitor.gpus.isEmpty {
                Text("Unavailable").foregroundStyle(.secondary)
            }
            ForEach(Array(monitor.gpus.enumerated()), id: \.offset) { item in
                let gpu = item.element
                HStack(spacing: 4) {
                    Text("\(gpu.model):", comment: "GPU model name, such as Apple M4, followed by a colon before its usage.")
                    Text(Format.percent(gpu.utilization)).foregroundStyle(Palette.load(gpu.utilization)).monospacedDigit()
                }
                .font(.system(size: 13, weight: .medium))
                TickBar(value: gpu.utilization)
            }
            Group {
                if let model = monitor.gpus.first?.model {
                    Text("\(model) Usage History", comment: "Title of the GPU history chart; the argument is the GPU model, such as Apple M4.")
                } else {
                    Text("Usage History")
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            HistoryChart(
                values: monitor.gpuHistory.values, capacity: SystemMonitor.historyLength,
                scale: ChartScale(values: monitor.gpuHistory.values, minimum: 0.1),
                barColor: { _ in Palette.green }, axisLabel: { Format.percent($0) }
            )
            .frame(height: 80)
        }
    }
}

struct BluetoothPopup: View {
    let monitor: SystemMonitor

    var body: some View {
        PopupChrome(module: .bluetooth, title: "Bluetooth Devices", monitor: monitor) {
            SectionTitle("Bluetooth Devices Battery:")
            if !monitor.bluetoothLoaded {
                ProgressView().controlSize(.small)
            } else if monitor.bluetoothDevices.isEmpty {
                Text("No Bluetooth device connected.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(monitor.bluetoothDevices) { device in
                        BluetoothDeviceRow(device: device)
                    }
                }
            }
            Text("If a device is missing, disconnect it and connect it again while the list refreshes.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A device and its battery levels. The levels never shrink: they sit beside the whole name when they fit, else
/// under it, else one per line, so no label is cut or wrapped in any language.
private struct BluetoothDeviceRow: View {
    let device: BluetoothDevice

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                name
                Spacer(minLength: 0)
                HStack(spacing: 8) { levels }.fixedSize()
            }
            VStack(alignment: .trailing, spacing: 2) {
                nameLine
                HStack(spacing: 8) { levels }.fixedSize()
            }
            VStack(alignment: .trailing, spacing: 2) {
                nameLine
                VStack(alignment: .trailing, spacing: 2) { levels }.fixedSize()
            }
        }
        .font(.system(size: 12))
    }

    private var name: some View {
        Text(verbatim: device.name).lineLimit(1)
    }

    /// The name on a line of its own may be cut: only the levels decide which layout fits.
    private var nameLine: some View {
        name.frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var levels: some View {
        if device.levels.isEmpty {
            Text("Battery not reported").foregroundStyle(.secondary)
        }
        ForEach(device.levels, id: \.part) { level in
            BatteryLevelView(level: level)
        }
    }
}

private struct BatteryLevelView: View {
    let level: BluetoothDevice.Level

    var body: some View {
        HStack(spacing: 2) {
            switch level.part {
            case .main: EmptyView()
            case .left: Text("Left").foregroundStyle(.secondary)
            case .right: Text("Right").foregroundStyle(.secondary)
            case .caseBattery: Text("Case").foregroundStyle(.secondary)
            }
            Text(verbatim: "\(level.percent)%")
                .monospacedDigit()
                .foregroundStyle(level.percent <= 20 ? Palette.red : Color.primary)
        }
    }
}
