import SwiftUI
import WidgetKit

struct HealthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedStore.healthWidgetKind, provider: PayloadProvider()) { entry in
            HealthWidgetView(payload: entry.payload).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Mac Health")
        .description("Heat level of this Mac, and its battery on a laptop.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// The heat level and, on a Mac with a battery, its charge and health. The medium size adds what to do when the Mac is
/// hot. A Mac without a battery shows the heat level alone, never an empty battery.
struct HealthWidgetView: View {
    let payload: WidgetPayload?
    @Environment(\.widgetFamily) private var family

    private static let symbol = "thermometer.medium"

    var body: some View {
        if let payload, let health = payload.health {
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(symbol: Self.symbol, title: "Mac Health", date: payload.date)
                if family == .systemSmall {
                    heat(health.thermal, advice: false)
                    if let battery = health.battery {
                        Spacer(minLength: 0)
                        HealthBatteryRows(battery: battery, showsCondition: false)
                    } else {
                        Spacer(minLength: 0)
                    }
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        heat(health.thermal, advice: true)
                        if let battery = health.battery {
                            HealthBatteryRows(battery: battery, showsCondition: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        } else if payload != nil {
            // The app notices a new widget within 5 minutes, then measures.
            NotRunningView(symbol: Self.symbol, title: "Mac Health", message: "Appears within 5 minutes.")
        } else {
            NotRunningView(symbol: Self.symbol, title: "Mac Health")
        }
    }

    private func heat(_ level: ThermalLevel, advice: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(level.title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Palette.heat(level))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HeatGauge(level: level)
            if advice, let text = level.advice {
                Text(text)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Charge with its bar, then maximum capacity and cycle count when macOS gives them.
private struct HealthBatteryRows: View {
    let battery: MacBattery
    let showsCondition: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Battery").foregroundStyle(.secondary)
                Spacer(minLength: 2)
                if battery.isCharging {
                    Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(Palette.green)
                }
                Text(verbatim: Format.percent(Double(battery.charge) / 100)).fontWeight(.semibold).monospacedDigit()
            }
            BatteryBar(percent: battery.charge)
            if let capacity = battery.maximumCapacity {
                row("Capacity", Format.percent(Double(capacity) / 100))
            }
            if let cycles = battery.cycleCount {
                row("Cycles", Format.number(Double(cycles), decimals: 0))
            }
            if showsCondition, battery.condition == .serviceRecommended {
                Text("Service recommended").foregroundStyle(Palette.orange).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 2)
            Text(verbatim: value).monospacedDigit()
        }
    }
}
