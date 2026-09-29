import SwiftUI
import WidgetKit

struct BluetoothWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedStore.bluetoothWidgetKind, provider: PayloadProvider()) { entry in
            BluetoothWidgetView(payload: entry.payload).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Bluetooth")
        .description("Battery levels of your Bluetooth devices.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// The devices that report a battery level: three on the small size, six in two columns on the medium one.
struct BluetoothWidgetView: View {
    let payload: WidgetPayload?
    @Environment(\.widgetFamily) private var family

    private static let symbol = "dot.radiowaves.left.and.right"

    var body: some View {
        if let payload, let devices = payload.bluetooth {
            let withBattery = devices.filter { !$0.levels.isEmpty }
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(symbol: Self.symbol, title: "Bluetooth", date: payload.date)
                if withBattery.isEmpty {
                    Spacer(minLength: 0)
                    Text(devices.isEmpty ? "No Bluetooth device connected." : "No device reports its battery.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else if family == .systemSmall || withBattery.count <= 3 {
                    rows(Array(withBattery.prefix(3)))
                } else {
                    let shown = Array(withBattery.prefix(6))
                    HStack(alignment: .top, spacing: 14) {
                        rows(Array(shown.prefix(3)))
                        rows(Array(shown.dropFirst(3)))
                    }
                }
            }
        } else if payload != nil {
            // The app notices a new widget within 5 minutes, then reads the devices.
            NotRunningView(symbol: Self.symbol, title: "Bluetooth", message: "Appears within 5 minutes.")
        } else {
            NotRunningView(symbol: Self.symbol, title: "Bluetooth")
        }
    }

    private func rows(_ devices: [BluetoothDevice]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(devices) { BluetoothBatteryRow(device: $0) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Name and levels, then a bar of the lowest level, red at 20 % and under.
private struct BluetoothBatteryRow: View {
    let device: BluetoothDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: device.name).lineLimit(1)
                Spacer(minLength: 2)
                ForEach(device.levels, id: \.part) { level in
                    HStack(spacing: 2) {
                        switch level.part {
                        case .main: EmptyView()
                        case .left: Text("Left").foregroundStyle(.secondary)
                        case .right: Text("Right").foregroundStyle(.secondary)
                        case .caseBattery: Text("Case").foregroundStyle(.secondary)
                        }
                        Text(verbatim: "\(level.percent)%").fontWeight(.semibold).monospacedDigit()
                    }
                    .fixedSize()
                }
            }
            .font(.system(size: 11))
            if let lowest = device.lowest {
                BatteryBar(percent: lowest)
            }
        }
    }
}

private struct BatteryBar: View {
    let percent: Int

    var body: some View {
        GeometryReader { size in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule()
                    .fill(percent <= 20 ? Palette.red : Palette.green)
                    .frame(width: max(3, size.size.width * CGFloat(percent) / 100))
            }
        }
        .frame(height: 4)
    }
}
