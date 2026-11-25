#!/usr/bin/env swift
import AppKit
import Foundation

// Draws Qdown's application icon with CoreGraphics, renders every size the
// macOS icns format needs, and assembles it with `iconutil`.
//
// Usage:
//   swift scripts/generate_icon.swift \
//     --output Qdown/Resources/AppIcon.icns \
//     --preview /path/to/icon-preview.png \
//     [--sizes-preview /path/to/icon-sizes.png]

struct Options {
    var output = "Qdown/Resources/AppIcon.icns"
    var preview: String?
    var sizesPreview: String?
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while let argument = arguments.first {
        arguments.removeFirst()
        switch argument {
        case "--output":
            if let value = arguments.first {
                options.output = value
                arguments.removeFirst()
            }
        case "--preview":
            if let value = arguments.first {
                options.preview = value
                arguments.removeFirst()
            }
        case "--sizes-preview":
            if let value = arguments.first {
                options.sizesPreview = value
                arguments.removeFirst()
            }
        default:
            FileHandle.standardError.write("unknown argument: \(argument)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    return options
}

func color(_ hex: UInt32, alpha: CGFloat = 1.0) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha)
}

let backgroundTop = color(0xFBFAFF)
let backgroundBottom = color(0xE6E2F2)
let border = color(0x705697, alpha: 0.16)
let accentLight = color(0x9C7BCF)
let accentDark = color(0x66479A)

let colorSpace = CGColorSpaceCreateDeviceRGB()
let accentGradient = CGGradient(colorsSpace: colorSpace,
                                colors: [accentLight, accentDark] as CFArray,
                                locations: [0.0, 1.0])!

func makeContext(size: Int) -> (NSBitmapImageRep, CGContext) {
    makeContext(width: size, height: size)
}

func makeContext(width: Int, height: Int) -> (NSBitmapImageRep, CGContext) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: width,
                                     pixelsHigh: height,
                                     bitsPerSample: 8,
                                     samplesPerPixel: 4,
                                     hasAlpha: true,
                                     isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0,
                                     bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("cannot create a \(width)x\(height) bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.setAllowsAntialiasing(true)
    cg.setShouldAntialias(true)
    cg.clear(CGRect(x: 0, y: 0, width: width, height: height))
    return (rep, cg)
}

func fillStroked(_ path: CGPath,
                 lineWidth: CGFloat,
                 lineCap: CGLineCap = .round,
                 lineJoin: CGLineJoin = .round,
                 in cg: CGContext) {
    cg.saveGState()
    cg.addPath(path)
    cg.setLineWidth(lineWidth)
    cg.setLineCap(lineCap)
    cg.setLineJoin(lineJoin)
    cg.replacePathWithStrokedPath()
    cg.clip()
    cg.drawLinearGradient(accentGradient,
                          start: CGPoint(x: 0, y: CGFloat(cg.height)),
                          end: CGPoint(x: CGFloat(cg.width), y: 0),
                          options: [])
    cg.restoreGState()
}

func drawIcon(size: Int) -> NSBitmapImageRep {
    let (rep, cg) = makeContext(size: size)
    let s = CGFloat(size)

    // macOS icon grid: transparent margin with a rounded-square tile.
    let inset = s * 0.075
    let tile = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = s * 0.215
    let tilePath = CGPath(roundedRect: tile,
                          cornerWidth: radius,
                          cornerHeight: radius,
                          transform: nil)

    cg.saveGState()
    cg.addPath(tilePath)
    cg.clip()
    let backgroundGradient = CGGradient(colorsSpace: colorSpace,
                                        colors: [backgroundBottom, backgroundTop] as CFArray,
                                        locations: [0.0, 1.0])!
    cg.drawLinearGradient(backgroundGradient,
                          start: CGPoint(x: tile.midX, y: tile.minY),
                          end: CGPoint(x: tile.midX, y: tile.maxY),
                          options: [])
    cg.restoreGState()

    // Hairline edge keeps the light tile readable on a light Dock background.
    cg.saveGState()
    cg.addPath(tilePath)
    cg.setStrokeColor(border)
    cg.setLineWidth(max(s * 0.005, 0.6))
    cg.strokePath()
    cg.restoreGState()

    // Q letterform: a thick ring plus a tail that turns into a downward arrow.
    let center = CGPoint(x: s * 0.49, y: s * 0.555)
    let ringRadius = s * 0.225
    let ringWidth = size <= 32 ? s * 0.150 : s * 0.108
    let ringPath = CGPath(ellipseIn: CGRect(x: center.x - ringRadius,
                                            y: center.y - ringRadius,
                                            width: ringRadius * 2,
                                            height: ringRadius * 2),
                          transform: nil)
    fillStroked(ringPath, lineWidth: ringWidth, in: cg)

    let tailX = s * 0.655
    let tailTop = CGPoint(x: center.x + ringRadius * 0.68, y: center.y - ringRadius * 0.74)
    let tailBottom = CGPoint(x: tailX, y: size <= 32 ? s * 0.105 : s * 0.145)
    let tailWidth = ringWidth * (size <= 32 ? 0.92 : 0.74)
    let tail = CGMutablePath()
    tail.move(to: tailTop)
    tail.addLine(to: tailBottom)
    fillStroked(tail, lineWidth: tailWidth, in: cg)

    // Arrowhead at the bottom of the tail. It is deliberately chunky so the
    // "down" cue survives at 16 px.
    let headHalf = size <= 32 ? s * 0.095 : s * 0.066
    let headRise = size <= 32 ? s * 0.105 : s * 0.078
    let head = CGMutablePath()
    head.move(to: CGPoint(x: tailX - headHalf, y: tailBottom.y + headRise))
    head.addLine(to: tailBottom)
    head.addLine(to: CGPoint(x: tailX + headHalf, y: tailBottom.y + headRise))
    fillStroked(head, lineWidth: tailWidth * 0.92, in: cg)

    // Markdown/document hint: three short text rules inside the Q counter.
    // They are omitted at small sizes, where they would only muddy the shape.
    if size >= 128 {
        cg.saveGState()
        cg.setStrokeColor(color(0x66479A, alpha: 0.55))
        cg.setLineCap(.round)
        let ruleWidth = max(s * 0.018, 2.0)
        let rules: [(CGFloat, CGFloat)] = [
            (s * 0.640, s * 0.150),
            (s * 0.590, s * 0.105),
            (s * 0.540, s * 0.130),
        ]
        let ruleLeft = center.x - s * 0.080
        for (y, width) in rules {
            cg.setLineWidth(ruleWidth)
            cg.move(to: CGPoint(x: ruleLeft, y: y))
            cg.addLine(to: CGPoint(x: ruleLeft + width, y: y))
            cg.strokePath()
        }
        cg.restoreGState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func pngData(_ rep: NSBitmapImageRep) -> Data {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("cannot encode icon PNG")
    }
    return data
}

func write(_ rep: NSBitmapImageRep, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try pngData(rep).write(to: url)
}

/// A contact sheet that shows the 16 px and 32 px renderings enlarged with
/// nearest-neighbour interpolation next to the large icon.
func writeSizesPreview() -> NSBitmapImageRep {
    let width = 1024
    let height = 512
    let (rep, cg) = makeContext(width: width, height: height)
    cg.setFillColor(color(0xF0F0F7))
    cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let panels: [(Int, CGFloat)] = [(16, 6), (32, 6), (128, 1), (512, 1)]
    let gap: CGFloat = 12
    let total = panels.reduce(CGFloat(0)) { sum, panel in
        sum + CGFloat(panel.0) * panel.1
    } + gap * CGFloat(panels.count - 1)
    var x = (CGFloat(width) - total) / 2
    for (pixelSize, scale) in panels {
        let icon = drawIcon(size: pixelSize)
        let panelWidth = CGFloat(pixelSize) * scale
        cg.saveGState()
        cg.interpolationQuality = .none
        cg.translateBy(x: x, y: (CGFloat(height) - panelWidth) / 2)
        cg.draw(icon.cgImage!, in: CGRect(x: 0, y: 0, width: panelWidth, height: panelWidth))
        cg.restoreGState()
        x += panelWidth + gap
    }
    return rep
}

let options = parseOptions()
let outputURL = URL(fileURLWithPath: options.output).standardizedFileURL

let temporaryRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("qdown-icon-\(UUID().uuidString)", isDirectory: true)
let iconsetURL = temporaryRoot.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporaryRoot) }

let uniqueSizes = [16, 32, 64, 128, 256, 512, 1024]
var rendered: [Int: NSBitmapImageRep] = [:]
for size in uniqueSizes {
    rendered[size] = drawIcon(size: size)
}

// iconutil's required iconset layout.
let files: [(pixels: Int, name: String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]
for (pixels, name) in files {
    guard let rep = rendered[pixels] else { fatalError("missing \(pixels) rendering") }
    try pngData(rep).write(to: iconsetURL.appendingPathComponent(name))
}

try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed with status \(iconutil.terminationStatus)\n".data(using: .utf8)!)
    exit(1)
}

if let preview = options.preview, let rep = rendered[1024] {
    try write(rep, to: URL(fileURLWithPath: preview).standardizedFileURL)
}

if let sizesPreview = options.sizesPreview {
    try write(writeSizesPreview(), to: URL(fileURLWithPath: sizesPreview).standardizedFileURL)
}

let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
let icnsSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
print("wrote \(outputURL.path) (\(icnsSize) bytes)")
