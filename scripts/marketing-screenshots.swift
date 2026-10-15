#!/usr/bin/env swift
// Captioned App Store screenshots: each screenshot from scripts/app-store-screenshots.sh on the
// own.audio background (the website's waves), with a headline and a line under it from
// AppStore/<language>/captions.json, at the store's exact sizes.
//
// Usage: swift scripts/marketing-screenshots.swift
//        → AppStore/marketing/<language>/<device>/<name>.png
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let shots = root.appendingPathComponent("AppStore/screenshots")
let output = root.appendingPathComponent("AppStore/marketing")

/// Store sizes, in pixels: the 6.9" iPhone and the 13" iPad.
let sizes: [String: CGSize] = [
    "iPhone 17 Pro Max": CGSize(width: 1320, height: 2868),
    "iPad Pro 13-inch (M5)": CGSize(width: 2064, height: 2752),
]
/// Screenshot folders by language, and where each language's captions are.
let languages = ["en": "en-US", "cs": "cs"]

func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Deterministic, so a picture is the same every time it is made.
struct Random {
    var state: UInt32
    mutating func next() -> CGFloat {
        state = state &* 1_664_525 &+ 1_013_904_223
        return CGFloat(state) / CGFloat(UInt32.max)
    }
}

/// The website's hero: sine waves, purple strong and gold and teal fine, with scattered dots in
/// the family's colours, on near-black.
func drawBackground(_ size: CGSize, seed: UInt32) {
    let gradient = NSGradient(colors: [colour(0x0B0B10), colour(0x17112B)])!
    gradient.draw(in: NSRect(origin: .zero, size: size), angle: -90)
    var random = Random(state: seed)
    let scale = size.width / 1200
    func wave(amplitude: CGFloat, length: CGFloat, phase: CGFloat, y: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        var x: CGFloat = -20
        path.move(to: NSPoint(x: x, y: y + amplitude * sin(phase)))
        while x <= size.width + 20 {
            x += 10
            path.line(to: NSPoint(x: x, y: y + amplitude * sin(x / length * 2 * .pi + phase)))
        }
        return path
    }
    // Only the top: the caption sits on them, the screenshot below.
    let band = size.height * 0.78
    for i in 0..<10 {
        let path = wave(amplitude: (80 + random.next() * 180) * scale, length: (500 + random.next() * 700) * scale,
                        phase: random.next() * 6.3, y: band + random.next() * size.height * 0.2)
        (i % 2 == 0 ? colour(0xC9A227, 0.35) : colour(0x2A9D9A, 0.35)).setStroke()
        path.lineWidth = 2 * scale
        path.stroke()
    }
    for _ in 0..<2 {
        let path = wave(amplitude: (100 + random.next() * 140) * scale, length: (600 + random.next() * 500) * scale,
                        phase: random.next() * 6.3, y: band + random.next() * size.height * 0.15)
        colour(0x6E44FF, 0.8).setStroke()
        path.lineWidth = 6 * scale
        path.lineCapStyle = .round
        path.stroke()
    }
    let family: [UInt32] = [0xFABB05, 0x29ABE2, 0xFF3B30, 0xFFCC00, 0x34C759, 0x6E44FF]
    for i in 0..<40 {
        let r = (3 + random.next() * 8) * scale
        let point = NSPoint(x: random.next() * size.width, y: size.height * 0.68 + random.next() * size.height * 0.32)
        colour(family[i % family.count], 0.5 + random.next() * 0.4).setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)).fill()
    }
}

func drawText(_ text: String, font: NSFont, colour: NSColor, in rect: NSRect) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineBreakMode = .byWordWrapping
    NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: colour, .paragraphStyle: style])
        .draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
}

func compose(shot: NSImage, headline: String, line: String, size: CGSize, seed: UInt32) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    drawBackground(size, seed: seed)

    // The caption: a headline on one line (smaller when long), and a line or two under it.
    let margin = size.width * 0.07
    let textWidth = size.width - 2 * margin
    var headlineSize = size.width * 0.074
    func headlineFont() -> NSFont { .systemFont(ofSize: headlineSize, weight: .heavy) }
    while (headline as NSString).size(withAttributes: [.font: headlineFont()]).width > textWidth, headlineSize > size.width * 0.045 {
        headlineSize -= 2
    }
    let lineFont = NSFont.systemFont(ofSize: size.width * 0.036, weight: .medium)
    let lineHeight = NSAttributedString(string: line, attributes: [.font: lineFont])
        .boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height
    let top = size.height - size.height * 0.04
    let headlineBox = headlineSize * 1.25
    drawText(headline, font: headlineFont(), colour: .white,
             in: NSRect(x: margin, y: top - headlineBox, width: textWidth, height: headlineBox))
    let lineTop = top - headlineBox - size.height * 0.006
    drawText(line, font: lineFont, colour: colour(0xC9C9D0),
             in: NSRect(x: margin, y: lineTop - lineHeight - 4, width: textWidth, height: lineHeight + 4))

    // The screenshot, rounded like the screen it came from, with a soft shadow.
    let captionBottom = lineTop - lineHeight - size.height * 0.022
    let available = captionBottom - size.height * 0.03
    let aspect = shot.size.height / shot.size.width
    var width = size.width * 0.8
    if width * aspect > available { width = available / aspect }
    let rect = NSRect(x: (size.width - width) / 2, y: captionBottom - width * aspect, width: width, height: width * aspect)
    let corner = width * 0.075
    let shape = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
    shadow.shadowBlurRadius = size.width * 0.04
    shadow.shadowOffset = NSSize(width: 0, height: -size.width * 0.01)
    shadow.set()
    colour(0x000000).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    shot.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    colour(0xFFFFFF, 0.12).setStroke()
    shape.lineWidth = size.width * 0.003
    shape.stroke()

    return rep.representation(using: .png, properties: [:])
}

var made = 0
for (folder, captionsFolder) in languages {
    let captionsURL = root.appendingPathComponent("AppStore/\(captionsFolder)/captions.json")
    guard let data = try? Data(contentsOf: captionsURL),
          let captions = try? JSONDecoder().decode([String: [String]].self, from: data) else { continue }
    for (device, size) in sizes {
        let source = shots.appendingPathComponent("\(folder)/\(device)")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: source.path) else { continue }
        let target = output.appendingPathComponent("\(folder)/\(device)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for name in names.sorted() where name.hasSuffix(".png") {
            let key = String(name.dropLast(4))
            guard let caption = captions[key], caption.count == 2,
                  let shot = NSImage(contentsOf: source.appendingPathComponent(name)) else {
                print("skipped \(folder)/\(device)/\(name): no caption")
                continue
            }
            let seed = UInt32(key.unicodeScalars.reduce(7) { $0 &* 31 &+ $1.value })
            guard let png = compose(shot: shot, headline: caption[0], line: caption[1], size: size, seed: seed) else { continue }
            try png.write(to: target.appendingPathComponent(name))
            made += 1
        }
    }
}
print("\(made) captioned screenshots in \(output.path)")
