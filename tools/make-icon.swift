// Draws the SimplyBar app icon (our own pictograms, no SF Symbols) and writes the macOS AppIcon set.
// Usage: swift tools/make-icon.swift SimplyBar/Assets.xcassets/AppIcon.appiconset [preview-folder]
// With a preview folder, also writes icone-1024.png and icone-32.png there (docs/captures).
//
// Blue system gradient squircle on the macOS icon grid (824 px body in 1024), glass rim and top sheen,
// four white pictograms in a 2 x 2 grid: CPU chip, memory module, graphics card, network arrows.
// Every size is drawn from the vectors; 64 px and below use bolder, simpler pictograms.
import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
let output = URL(fileURLWithPath: arguments.first ?? ".", isDirectory: true)
let previews = arguments.count > 1 ? URL(fileURLWithPath: arguments[1], isDirectory: true) : nil
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
    )
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

/// Superellipse close to the macOS continuous-corner icon shape (same diagonal as a 185 px radius on 824 px).
func squircle(_ rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for index in 0..<steps {
        let angle = CGFloat(index) / CGFloat(steps) * 2 * .pi
        let cosine = cos(angle), sine = sin(angle)
        let point = CGPoint(
            x: rect.midX + rect.width / 2 * copysign(pow(abs(cosine), 2 / exponent), cosine),
            y: rect.midY + rect.height / 2 * copysign(pow(abs(sine), 2 / exponent), sine)
        )
        index == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: min(radius, rect.width / 2), cornerHeight: min(radius, rect.height / 2),
           transform: nil)
}

func centered(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
    CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
}

// MARK: - Pictograms, drawn in white around the origin in a 260 x 260 box. Holes use the even-odd rule.

/// Processor: a square package with pins on every side and the die cut out.
func chip(_ context: CGContext, small: Bool) {
    let body: CGFloat = small ? 176 : 168
    let pins = small ? 3 : 4
    let pinWidth: CGFloat = small ? 30 : 20
    let pinLength: CGFloat = small ? 36 : 40
    let package = CGMutablePath()
    package.addPath(rounded(centered(0, 0, body, body), small ? 30 : 26))
    let die: CGFloat = small ? 78 : 92
    package.addPath(rounded(centered(0, 0, die, die), small ? 12 : 14))
    if !small { package.addPath(rounded(centered(0, 0, die - 34, die - 34), 8)) }
    context.addPath(package)
    context.fillPath(using: .evenOdd)

    let span = body - (small ? 60 : 52)
    for index in 0..<pins {
        let offset = -span / 2 + span * CGFloat(index) / CGFloat(pins - 1)
        let reach = body / 2 + pinLength / 2 - 6
        for (x, y, horizontal) in [(offset, reach, false), (offset, -reach, false), (reach, offset, true), (-reach, offset, true)] {
            let rect = horizontal ? centered(x, y, pinLength, pinWidth) : centered(x, y, pinWidth, pinLength)
            context.addPath(rounded(rect, pinWidth * 0.4))
        }
    }
    context.fillPath()
}

/// Memory: a module with its chips, the contact fingers and the key notch.
func memory(_ context: CGContext, small: Bool) {
    let width: CGFloat = small ? 250 : 248
    let height: CGFloat = small ? 160 : 158
    let board = CGRect(x: -width / 2, y: -height / 2 + 6, width: width, height: height)
    let path = CGMutablePath()
    path.addPath(rounded(board, small ? 16 : 14))

    let chips = small ? 3 : 4
    let chipWidth: CGFloat = small ? 50 : 40
    let chipHeight: CGFloat = small ? 64 : 62
    let gap = (width - (small ? 44 : 40) - CGFloat(chips) * chipWidth) / CGFloat(chips - 1)
    for index in 0..<chips {
        let x = board.minX + (small ? 22 : 20) + CGFloat(index) * (chipWidth + gap)
        path.addPath(rounded(CGRect(x: x, y: board.maxY - 22 - chipHeight, width: chipWidth, height: chipHeight), 7))
    }
    if !small {
        // Contact fingers along the bottom edge.
        let fingers = 11
        let fingerSpan = width - 44
        for index in 0..<fingers {
            let x = board.minX + 22 + fingerSpan * CGFloat(index) / CGFloat(fingers - 1)
            path.addPath(rounded(centered(x, board.minY + 26, 9, 24), 4))
        }
    }
    context.addPath(path)
    context.fillPath(using: .evenOdd)

    // Key notch and side notches, punched through the board.
    context.setBlendMode(.clear)
    let notch: CGFloat = small ? 20 : 16
    context.addPath(rounded(centered(board.midX - width * 0.12, board.minY, notch, small ? 40 : 34), notch / 2))
    context.addEllipse(in: centered(board.minX, board.midY - 6, small ? 26 : 22, small ? 26 : 22))
    context.addEllipse(in: centered(board.maxX, board.midY - 6, small ? 26 : 22, small ? 26 : 22))
    context.fillPath()
    context.setBlendMode(.normal)
}

/// Graphics card: the board with two fans, its bracket on the left and the slot connector below.
func graphicsCard(_ context: CGContext, small: Bool) {
    let board = CGRect(x: -100, y: -62, width: 226, height: small ? 142 : 136)
    let path = CGMutablePath()
    path.addPath(rounded(board, small ? 20 : 18))
    let fanRadius: CGFloat = small ? 44 : 43
    let fans = [CGPoint(x: board.minX + 60, y: board.midY), CGPoint(x: board.maxX - 60, y: board.midY)]
    for fan in fans {
        path.addEllipse(in: centered(fan.x, fan.y, fanRadius * 2, fanRadius * 2))
    }
    context.addPath(path)
    context.fillPath(using: .evenOdd)

    // Fan hubs, and curved blades in the large sizes.
    for fan in fans {
        context.addEllipse(in: centered(fan.x, fan.y, small ? 30 : 24, small ? 30 : 24))
    }
    context.fillPath()
    if !small {
        context.setStrokeColor(.white)
        context.setLineWidth(9)
        context.setLineCap(.round)
        for fan in fans {
            for blade in 0..<5 {
                let angle = CGFloat(blade) / 5 * 2 * .pi
                context.move(to: CGPoint(x: fan.x + cos(angle) * 10, y: fan.y + sin(angle) * 10))
                context.addQuadCurve(
                    to: CGPoint(x: fan.x + cos(angle + 0.9) * 33, y: fan.y + sin(angle + 0.9) * 33),
                    control: CGPoint(x: fan.x + cos(angle + 0.15) * 30, y: fan.y + sin(angle + 0.15) * 30)
                )
            }
        }
        context.strokePath()
    }

    // Bracket on the left, taller than the board.
    context.addPath(rounded(CGRect(x: board.minX - (small ? 30 : 26), y: board.minY - 34, width: small ? 22 : 18,
                                   height: board.height + 58), 7))
    // Slot connector under the board.
    let connector = CGRect(x: board.minX + 34, y: board.minY - (small ? 30 : 28), width: 150, height: small ? 34 : 32)
    if small {
        context.addPath(rounded(connector, 8))
    } else {
        for index in 0..<9 {
            context.addPath(rounded(CGRect(x: connector.minX + CGFloat(index) * 17, y: connector.minY,
                                           width: 11, height: connector.height), 4))
        }
    }
    context.fillPath()
}

/// Network: an upload arrow and a download arrow, side by side.
func arrows(_ context: CGContext, small: Bool) {
    let shaft: CGFloat = small ? 30 : 24
    let head: CGFloat = small ? 66 : 62
    let headHeight: CGFloat = small ? 78 : 76
    let length: CGFloat = 212
    context.setLineJoin(.round)
    context.setLineWidth(small ? 18 : 14)
    context.setStrokeColor(.white)
    for (x, up) in [(CGFloat(-58), true), (CGFloat(58), false)] {
        let direction: CGFloat = up ? 1 : -1
        let center = CGPoint(x: x, y: direction * 14)
        let tip = center.y + direction * length / 2
        let base = tip - direction * headHeight
        let tail = center.y - direction * length / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: tip))
        path.addLine(to: CGPoint(x: x + head, y: base))
        path.addLine(to: CGPoint(x: x + shaft, y: base))
        path.addLine(to: CGPoint(x: x + shaft, y: tail))
        path.addLine(to: CGPoint(x: x - shaft, y: tail))
        path.addLine(to: CGPoint(x: x - shaft, y: base))
        path.addLine(to: CGPoint(x: x - head, y: base))
        path.closeSubpath()
        context.addPath(path)
        context.drawPath(using: .fillStroke)
    }
}

// MARK: - Icon

func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let scale = size / 1024
    context.scaleBy(x: scale, y: scale)
    context.interpolationQuality = .high
    let small = pixels <= 64

    // macOS icon grid: 824 x 824 body centred in 1024, soft shadow below.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(body)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 22 * scale, color: rgb(0x000000, 0.32))
    context.addPath(shape)
    context.setFillColor(rgb(0x0040DD))
    context.fillPath()
    context.restoreGState()

    // Blue system gradient, lighter at the top.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.drawLinearGradient(
        gradient([rgb(0x3FA0FF), rgb(0x0A84FF), rgb(0x0055E8), rgb(0x0040DD)], [0, 0.28, 0.72, 1]),
        start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: []
    )
    // Top sheen, like the glass of the macOS 26 icons.
    context.drawRadialGradient(
        gradient([rgb(0xFFFFFF, 0.24), rgb(0xFFFFFF, 0)], [0, 1]),
        startCenter: CGPoint(x: 512, y: body.maxY + 40), startRadius: 0,
        endCenter: CGPoint(x: 512, y: body.maxY + 40), endRadius: 560, options: []
    )
    // Deeper blue in the bottom corners for relief.
    context.drawRadialGradient(
        gradient([rgb(0x00206E, 0), rgb(0x00206E, 0.28)], [0, 1]),
        startCenter: CGPoint(x: 512, y: 560), startRadius: 360,
        endCenter: CGPoint(x: 512, y: 560), endRadius: 700, options: []
    )
    context.restoreGState()

    // Glass rim: bright along the top edge, fading towards the bottom.
    context.saveGState()
    let rim = CGMutablePath()
    rim.addPath(shape)
    let inset = small ? 22.0 : 7.0
    rim.addPath(squircle(body.insetBy(dx: inset, dy: inset)))
    context.addPath(rim)
    context.clip(using: .evenOdd)
    context.drawLinearGradient(
        gradient([rgb(0xFFFFFF, 0.75), rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0.06), rgb(0xFFFFFF, 0.30)], [0, 0.35, 0.8, 1]),
        start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: []
    )
    context.restoreGState()

    // Pictograms: white with a faint cool tint at the bottom and a soft shadow for depth.
    let spread: CGFloat = small ? 196 : 180
    let glyphScale: CGFloat = small ? 1.22 : 1
    let cells: [(CGPoint, (CGContext, Bool) -> Void)] = [
        (CGPoint(x: 512 - spread, y: 512 + spread), chip),
        (CGPoint(x: 512 + spread, y: 512 + spread), memory),
        (CGPoint(x: 512 - spread, y: 512 - spread), graphicsCard),
        (CGPoint(x: 512 + spread, y: 512 - spread), arrows),
    ]
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 14 * scale, color: rgb(0x001A5C, 0.35))
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.setFillColor(.white)
    for (center, draw) in cells {
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: glyphScale, y: glyphScale)
        draw(context, small)
        context.restoreGState()
    }
    context.setBlendMode(.sourceAtop)
    context.drawLinearGradient(
        gradient([rgb(0xFFFFFF), rgb(0xE4EEFF)], [0, 1]),
        start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: []
    )
    context.endTransparencyLayer()
    context.restoreGState()

    let image = context.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: points * scale).write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appendingPathComponent("Contents.json"))
print("wrote \(images.count) images to \(output.path)")

if let previews {
    try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
    try render(pixels: 1024).write(to: previews.appendingPathComponent("icone-1024.png"))
    try render(pixels: 32).write(to: previews.appendingPathComponent("icone-32.png"))
    print("wrote previews to \(previews.path)")
}
