import SwiftUI

/// Colors of the gauges and charts.
nonisolated enum Palette {
    typealias RGB = (red: Double, green: Double, blue: Double)

    static let greenRGB: RGB = (0.30, 0.80, 0.36)
    static let yellowRGB: RGB = (0.98, 0.78, 0.12)
    static let orangeRGB: RGB = (1.00, 0.56, 0.12)
    static let redRGB: RGB = (0.95, 0.27, 0.25)

    static let green = color(greenRGB)
    static let yellow = color(yellowRGB)
    static let red = color(redRGB)
    static let orange = color(orangeRGB)
    static let blue = Color(red: 0.22, green: 0.52, blue: 1.0)
    static let track = Color.secondary.opacity(0.28)

    static let app = red
    static let wired = blue
    static let compressed = yellow
    static let free = Color.secondary.opacity(0.45)
    static let purgeable = Color.secondary.opacity(0.6)
    static let upload = blue
    static let download = red

    /// Load color: green when light, yellow from 50 %, orange from 75 %, red from 90 %, blended in between.
    static func loadRGB(_ fraction: Double) -> RGB {
        let value = Format.clamp(fraction)
        let stops: [(at: Double, rgb: RGB)] = [(0, greenRGB), (0.35, greenRGB), (0.55, yellowRGB), (0.75, orangeRGB), (0.9, redRGB), (1, redRGB)]
        for index in 1..<stops.count where value <= stops[index].at {
            let low = stops[index - 1], high = stops[index]
            let span = high.at - low.at
            let t = span > 0 ? (value - low.at) / span : 0
            return (
                low.rgb.red + (high.rgb.red - low.rgb.red) * t,
                low.rgb.green + (high.rgb.green - low.rgb.green) * t,
                low.rgb.blue + (high.rgb.blue - low.rgb.blue) * t
            )
        }
        return redRGB
    }

    static func load(_ fraction: Double) -> Color { color(loadRGB(fraction)) }

    /// Storage bar color by threshold: green under 70 % used, orange up to 90 %, red above.
    static func storage(_ usage: Double) -> Color {
        switch usage {
        case ..<0.7: green
        case ...0.9: orange
        default: red
        }
    }

    private static func color(_ rgb: RGB) -> Color { Color(red: rgb.red, green: rgb.green, blue: rgb.blue) }
}

/// Horizontal gauge made of thin vertical ticks, filled from the left.
struct TickBar: View {
    struct Segment {
        enum Coloring { case fixed(Color), byPosition }
        var fraction: Double
        var coloring: Coloring
    }

    var segments: [Segment]
    var height: CGFloat = 26
    var tickWidth: CGFloat = 2
    var spacing: CGFloat = 2

    /// One value colored by its own load.
    init(value: Double, height: CGFloat = 26) {
        segments = [Segment(fraction: value, coloring: .fixed(Palette.load(value)))]
        self.height = height
    }

    /// One value whose ticks go from green to red along the bar.
    init(gradientValue: Double, height: CGFloat = 26) {
        segments = [Segment(fraction: gradientValue, coloring: .byPosition)]
        self.height = height
    }

    /// Several stacked values, each with its color.
    init(stacked parts: [(Double, Color)], height: CGFloat = 26) {
        segments = parts.map { Segment(fraction: $0.0, coloring: .fixed($0.1)) }
        self.height = height
    }

    var body: some View {
        Canvas { context, size in
            let step = tickWidth + spacing
            let count = max(1, Int((size.width + spacing) / step))
            var colors: [Color] = []
            colors.reserveCapacity(count)
            for segment in segments {
                let ticks = Int((Format.clamp(segment.fraction) * Double(count)).rounded())
                for _ in 0..<ticks where colors.count < count {
                    switch segment.coloring {
                    case .fixed(let color): colors.append(color)
                    case .byPosition: colors.append(Palette.load(Double(colors.count + 1) / Double(count)))
                    }
                }
            }
            for index in 0..<count {
                let rect = CGRect(x: CGFloat(index) * step, y: 0, width: tickWidth, height: size.height)
                let color = index < colors.count ? colors[index] : Palette.track
                context.fill(Path(roundedRect: rect, cornerRadius: tickWidth / 2), with: .color(color))
            }
        }
        .padding(4)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.track, lineWidth: 1))
    }
}

/// Vertical bars of recent values, newest on the right, with a top and a half guide line labelled on the right.
struct HistoryChart: View {
    var values: [Double]
    var capacity: Int
    var scale: ChartScale
    var barColor: (Double) -> Color
    var axisLabel: (Double) -> String
    var labelWidth: CGFloat = 46

    var body: some View {
        Canvas { context, size in
            let plotWidth = max(1, size.width - labelWidth)
            drawGuide(context: &context, y: 0.5, width: plotWidth, label: axisLabel(scale.top), size: size)
            drawGuide(context: &context, y: size.height / 2, width: plotWidth, label: axisLabel(scale.half), size: size)

            let slot = plotWidth / CGFloat(max(capacity, 1))
            let barWidth = max(1, slot * 0.55)
            let recent = values.suffix(capacity)
            for (offset, value) in recent.enumerated() {
                let slotIndex = capacity - recent.count + offset
                let height = max(1.5, CGFloat(scale.fraction(of: value)) * size.height)
                let rect = CGRect(x: CGFloat(slotIndex) * slot + (slot - barWidth) / 2, y: size.height - height, width: barWidth, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(barColor(value)))
            }
        }
    }

    private func drawGuide(context: inout GraphicsContext, y: CGFloat, width: CGFloat, label: String, size: CGSize) {
        var line = Path()
        line.move(to: CGPoint(x: 0, y: y))
        line.addLine(to: CGPoint(x: width, y: y))
        context.stroke(line, with: .color(Palette.track), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
        context.draw(
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary),
            at: CGPoint(x: width + 6, y: max(6, y)),
            anchor: .leading
        )
    }
}

/// Two histories around a middle line: one grows up, the other grows down (network, disk changes).
struct MirrorChart: View {
    var up: [Double]
    var down: [Double]
    var capacity: Int
    var upScale: ChartScale
    var downScale: ChartScale
    var upColor: Color
    var downColor: Color
    var axisLabel: (Double) -> String
    /// Put before the labels of the lower half ("-" when the lower half means a decrease).
    var downPrefix = ""
    var labelWidth: CGFloat = 58

    var body: some View {
        Canvas { context, size in
            let plotWidth = max(1, size.width - labelWidth)
            let middle = size.height / 2
            let slot = plotWidth / CGFloat(max(capacity, 1))
            let barWidth = max(1, slot * 0.55)

            let guides: [(CGFloat, String)] = [
                (0.5, axisLabel(upScale.top)),
                (middle / 2, axisLabel(upScale.half)),
                (middle + middle / 2, downPrefix + axisLabel(downScale.half)),
                (size.height - 0.5, downPrefix + axisLabel(downScale.top)),
            ]
            for (y, label) in guides {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: plotWidth, y: y))
                context.stroke(line, with: .color(Palette.track), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                context.draw(Text(label).font(.system(size: 9)).foregroundStyle(.secondary),
                             at: CGPoint(x: plotWidth + 6, y: min(max(6, y), size.height - 6)), anchor: .leading)
            }

            draw(values: up, scale: upScale, color: upColor, upward: true, context: &context, middle: middle, slot: slot, barWidth: barWidth)
            draw(values: down, scale: downScale, color: downColor, upward: false, context: &context, middle: middle, slot: slot, barWidth: barWidth)

            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: middle))
            axis.addLine(to: CGPoint(x: plotWidth, y: middle))
            context.stroke(axis, with: .color(.secondary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [1.5, 1.5]))
        }
    }

    private func draw(values: [Double], scale: ChartScale, color: Color, upward: Bool,
                      context: inout GraphicsContext, middle: CGFloat, slot: CGFloat, barWidth: CGFloat) {
        let recent = values.suffix(capacity)
        for (offset, value) in recent.enumerated() {
            let slotIndex = capacity - recent.count + offset
            let length = CGFloat(scale.fraction(of: value)) * middle
            guard length >= 0.5 else { continue }
            let x = CGFloat(slotIndex) * slot + (slot - barWidth) / 2
            let rect = upward
                ? CGRect(x: x, y: middle - length, width: barWidth, height: length)
                : CGRect(x: x, y: middle, width: barWidth, height: length)
            context.fill(Path(rect), with: .color(color))
        }
    }
}

/// Small vertical gauge made of horizontal ticks, green at the bottom and red at the top (per-core usage).
struct CoreGauge: View {
    var value: Double
    var ticks = 14

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 1.5
            let tickHeight = max(1, (size.height - spacing * CGFloat(ticks - 1)) / CGFloat(ticks))
            let filled = Int((Format.clamp(value) * Double(ticks)).rounded(.up))
            for index in 0..<ticks {
                let y = size.height - CGFloat(index + 1) * tickHeight - CGFloat(index) * spacing
                let rect = CGRect(x: 0, y: y, width: size.width, height: tickHeight)
                let color = index < filled && value > 0.005 ? Palette.load(Double(index + 1) / Double(ticks)) : Palette.track
                context.fill(Path(roundedRect: rect, cornerRadius: 0.8), with: .color(color))
            }
        }
        .padding(4)
        .frame(width: 26, height: 50)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Palette.track, lineWidth: 1))
    }
}
