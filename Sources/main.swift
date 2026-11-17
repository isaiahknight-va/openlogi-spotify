// Spotify Now Playing: an OpenLogi key module. It draws the current Spotify
// track on every MX Creative Keypad key bound to it and plays or pauses
// Spotify when one is pressed. It talks to OpenLogi only through the key
// module protocol (v1): newline-delimited JSON on stdin and stdout.
//
// Build: zsh build.sh   (swiftc -O, no dependencies, macOS 15+)

import AppKit
import CoreText
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Logging

let logStamp: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

/// Diagnostics go to stderr, never stdout: stdout carries protocol lines only.
func log(_ message: String) {
    let line = "\(logStamp.string(from: Date())) \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("spotify-module: \(message)\n".utf8))
    exit(2)
}

// MARK: - Configuration

let spotifyBundleID = "com.spotify.client"
let spotifyNotification = Notification.Name("com.spotify.client.PlaybackStateChanged")
let protocolVersion = 1
let defaultSize = 118
let sizeRange = 16...1024
let maxImageBytes = 4 * 1024 * 1024
let debounceDelay: TimeInterval = 0.25
let launchReadDelay: TimeInterval = 1
let artRetryInterval: TimeInterval = 60
let firstRetryDelay: TimeInterval = 1
let maxBackoff: TimeInterval = 10
let playTries = 40
let playTryInterval: TimeInterval = 0.25
let cacheLimit = 300
let cachePruneTarget = 250
// Part of every cache key: bump it when the tile design changes so old
// renders are not reused.
let renderVersion = "tile-v3"
let mosaicVersion = "mosaic-v1"
let controlVersion = "control-v1"
let tickInterval: TimeInterval = 1
let defaultBannerFps: Double = 3
let bannerFpsRange: ClosedRange<Double> = 0...8
// A page's nine grid keys in reading order; all nine bound on one page and
// one device make a mosaic.
let gridSlots = ["gridTopLeft", "gridTopMiddle", "gridTopRight", "gridMiddleLeft", "gridMiddle",
                 "gridMiddleRight", "gridBottomLeft", "gridBottomMiddle", "gridBottomRight"]
let centerIndex = 4
let defaultGapPercent: Double = 25
let gapPercentRange: ClosedRange<Double> = 0...60
let defaultStaggerMs: Double = 90
let staggerMsRange: ClosedRange<Double> = 0...1000

// MARK: - Artwork

/// Decodes image bytes, downscaled on decode so a huge file costs little.
func decodeImage(_ data: Data, maxPixels: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

/// Synchronous download with a short timeout. Nil on any failure.
func download(_ url: URL) -> Data? {
    let session = URLSession(configuration: {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 5
        c.timeoutIntervalForResource = 8
        return c
    }())
    defer { session.finishTasksAndInvalidate() }
    let done = DispatchSemaphore(value: 0)
    var result: Data?
    let task = session.dataTask(with: url) { data, response, _ in
        if let http = response as? HTTPURLResponse, http.statusCode == 200, let data, !data.isEmpty {
            result = data
        }
        done.signal()
    }
    task.resume()
    if done.wait(timeout: .now() + 9) == .timedOut {
        task.cancel()
        return nil
    }
    return result
}

/// Loads artwork from an http(s) URL or a local file path.
func loadArtwork(_ location: String, maxPixels: Int) -> CGImage? {
    let data: Data?
    if location.hasPrefix("http://") || location.hasPrefix("https://") {
        guard let url = URL(string: location) else { return nil }
        data = download(url)
    } else {
        data = FileManager.default.contents(atPath: (location as NSString).expandingTildeInPath)
    }
    guard let data else { return nil }
    return decodeImage(data, maxPixels: maxPixels)
}

// MARK: - Tile rendering

struct Tile {
    var title: String
    var artist: String
    var art: CGImage?
    var paused: Bool
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func white(_ alpha: CGFloat) -> CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }
func black(_ alpha: CGFloat) -> CGColor { CGColor(srgbRed: 0, green: 0, blue: 0, alpha: alpha) }

/// Draws `image` scaled to cover `rect`, centered, cropping the overflow.
func drawAspectFill(_ image: CGImage, in rect: CGRect, context: CGContext) {
    let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
    let w = CGFloat(image.width) * scale
    let h = CGFloat(image.height) * scale
    let target = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    context.saveGState()
    context.clip(to: rect)
    context.draw(image, in: target)
    context.restoreGState()
}

/// The art redrawn in grayscale at the tile's size.
func grayscale(_ image: CGImage, size: Int) -> CGImage? {
    guard let gray = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { return nil }
    gray.interpolationQuality = .high
    drawAspectFill(image, in: CGRect(x: 0, y: 0, width: size, height: size), context: gray)
    return gray.makeImage()
}

/// FNV-1a, stable across runs (Swift's hashValue is seeded per process).
func stableHash(_ text: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash
}

/// The no-artwork background: a deep two-tone gradient whose hue comes from
/// the title, so different tracks do not all look the same.
func drawFallbackBackground(_ seed: String, size: CGFloat, context: CGContext) {
    let hue = CGFloat(stableHash(seed) % 360) / 360
    let top = NSColor(calibratedHue: hue, saturation: 0.55, brightness: 0.34, alpha: 1)
    let bottom = NSColor(calibratedHue: fmod(hue + 0.08, 1), saturation: 0.6, brightness: 0.14, alpha: 1)
    let colors = [top.usingColorSpace(.sRGB)!.cgColor, bottom.usingColorSpace(.sRGB)!.cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: sRGB, colors: colors, locations: [0, 1])!
    context.drawLinearGradient(
        gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size * 0.6, y: 0),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func font(size: CGFloat, weight: NSFont.Weight) -> CTFont {
    NSFont.systemFont(ofSize: size, weight: weight) as CTFont
}

func attributed(_ text: String, font: CTFont, color: CGColor) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ])
}

/// Breaks `text` into at most `maxLines` lines no wider than `width`; the last
/// line takes the rest and ends in an ellipsis when it does not fit.
func layoutLines(_ text: NSAttributedString, width: CGFloat, maxLines: Int) -> [CTLine] {
    let typesetter = CTTypesetterCreateWithAttributedString(text)
    let length = text.length
    var lines: [CTLine] = []
    var start = 0
    while start < length, lines.count < maxLines {
        if lines.count == maxLines - 1 {
            let rest = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: length - start))
            if CGFloat(CTLineGetTypographicBounds(rest, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(rest)) <= width {
                lines.append(rest)
            } else {
                let attrs = text.attributes(at: max(0, length - 1), effectiveRange: nil)
                let token = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: attrs))
                lines.append(CTLineCreateTruncatedLine(rest, Double(width), .end, token) ?? rest)
            }
            break
        }
        let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
        guard count > 0 else { break }
        lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
        start += count
    }
    return lines
}

func cleaned(_ text: String) -> String {
    text.components(separatedBy: .newlines).joined(separator: " ")
        .trimmingCharacters(in: .whitespaces)
}

func renderTile(_ tile: Tile, size: Int) -> CGImage? {
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .high
    let s = CGFloat(size)
    let k = s / 118
    let full = CGRect(x: 0, y: 0, width: s, height: s)

    if let art = tile.art {
        if tile.paused, let gray = grayscale(art, size: size) {
            context.draw(gray, in: full)
        } else {
            drawAspectFill(art, in: full, context: context)
        }
    } else {
        drawFallbackBackground(tile.title + "\n" + tile.artist, size: s, context: context)
    }
    if tile.paused {
        context.setFillColor(black(0.42))
        context.fill(full)
    }

    // Text is laid out first so the shade can reach above a two-line title.
    let side = 9 * k
    let bottom = 9 * k
    let width = s - 2 * side
    let titleFont = font(size: 16 * k, weight: .bold)
    let artistFont = font(size: 12.5 * k, weight: .medium)
    let title = cleaned(tile.title).isEmpty ? "Unknown track" : cleaned(tile.title)
    let titleLines = layoutLines(attributed(title, font: titleFont, color: white(1)), width: width, maxLines: 2)
    let artist = cleaned(tile.artist)
    let artistLines = artist.isEmpty ? [] :
        layoutLines(attributed(artist, font: artistFont, color: white(0.8)), width: width, maxLines: 1)

    let titleAscent = CTFontGetAscent(titleFont)
    let titleDescent = CTFontGetDescent(titleFont)
    let titleStep = (titleAscent + titleDescent) * 0.96
    let artistAscent = CTFontGetAscent(artistFont)
    let artistDescent = CTFontGetDescent(artistFont)

    var baselines: [(CTLine, CGFloat)] = []
    var y = bottom
    for line in artistLines {
        y += artistDescent
        baselines.append((line, y))
        y += artistAscent + 2 * k
    }
    y += titleDescent
    for line in titleLines.reversed() {
        baselines.append((line, y))
        y += titleStep
    }
    let textTop = y - titleStep + titleAscent

    // Shade: clear at about 35% height (higher when the text needs it) to
    // roughly 85% black at the bottom edge.
    let shadeTop = min(max(0.35 * s, textTop + 16 * k), 0.82 * s)
    let shade = CGGradient(
        colorsSpace: sRGB,
        colors: [black(0.85), black(0.66), black(0.3), black(0)] as CFArray,
        locations: [0, 0.45, 0.78, 1])!
    context.drawLinearGradient(
        shade, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: shadeTop),
        options: [.drawsBeforeStartLocation])

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -0.75 * k), blur: 2.5 * k, color: black(0.7))
    for (line, baseline) in baselines {
        context.textPosition = CGPoint(x: side, y: baseline)
        CTLineDraw(line, context)
    }
    context.restoreGState()

    // The key is a play/pause button, so a paused tile shows the action a
    // press takes: play.
    if tile.paused {
        let center = CGPoint(x: s / 2, y: s - 24 * k)
        let radius = 16 * k
        context.setFillColor(black(0.55))
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        drawPlayTriangle(center: center, height: 16 * k, context: context)
    }
    return context.makeImage()
}

/// The art across the nine keys of a page, in reading order. The art covers a
/// canvas of three keys plus the two gaps between them, and each key shows its
/// own square of it, so the art under the gaps is skipped and lines stay
/// straight across keys. Paused: grayscale and dimmed like a tile, with the
/// play button on the center key only.
func renderMosaic(_ art: CGImage, paused: Bool, size: Int, gap: Int) -> [CGImage]? {
    let side = 3 * size + 2 * gap
    guard let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .high
    let s = CGFloat(side)
    let k = CGFloat(size) / 118
    let full = CGRect(x: 0, y: 0, width: s, height: s)
    if paused, let gray = grayscale(art, size: side) {
        context.draw(gray, in: full)
    } else {
        drawAspectFill(art, in: full, context: context)
    }
    if paused {
        context.setFillColor(black(0.42))
        context.fill(full)
        // The center key's center is the canvas's center.
        let center = CGPoint(x: s / 2, y: s / 2)
        let radius = 16 * k
        context.setFillColor(black(0.55))
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        drawPlayTriangle(center: center, height: 16 * k, context: context)
    }
    guard let canvas = context.makeImage() else { return nil }
    var tiles: [CGImage] = []
    for row in 0..<3 {
        for col in 0..<3 {
            // CGImage cropping counts from the top left.
            let rect = CGRect(x: col * (size + gap), y: row * (size + gap), width: size, height: size)
            guard let tile = canvas.cropping(to: rect) else { return nil }
            tiles.append(tile)
        }
    }
    return tiles
}

func renderBlackTile(size: Int) -> CGImage? {
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.setFillColor(black(1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    return context.makeImage()
}

// MARK: - Control keys

/// What a bound key shows and does. `art` is the full tile; the rest make up
/// a control page (settings `keys`).
enum Role: String {
    case art, title, shuffle, `repeat`, time, previous, next, song, artist, album

    /// The command a press sends; nil for the play/pause keys.
    var command: PlayerCommand? {
        switch self {
        case .shuffle: return .toggleShuffle
        case .repeat: return .toggleRepeat
        case .time: return .seekBack
        case .previous: return .previous
        case .next: return .next
        case .art, .title, .song, .artist, .album: return nil
        }
    }

    /// One key of words: the song, artist, or album name.
    var isText: Bool { self == .song || self == .artist || self == .album }
}

let neutralAccent = CGColor(srgbRed: 0.82, green: 0.82, blue: 0.84, alpha: 1)
let scrollSpeed: CGFloat = 30      // pixels a second on a 118 px key
let scrollPause: Double = 2
let textScrim: CGFloat = 0.35      // black over a song, artist, or album key

func hsv(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
    let high = max(r, g, b)
    let d = high - min(r, g, b)
    guard d > 0 else { return (0, 0, high) }
    var h = high == r ? (g - b) / d : high == g ? 2 + (b - r) / d : 4 + (r - g) / d
    h /= 6
    if h < 0 { h += 1 }
    return (h, d / high, high)
}

func rgb(_ h: Double, _ s: Double, _ v: Double) -> CGColor {
    let i = Int(h * 6) % 6
    let f = h * 6 - Double(Int(h * 6))
    let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
    let (r, g, b) = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i]
    return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

/// The cover drawn small and box-blurred (smooth once scaled up, and cheap),
/// plus its accent: the average color of its strongest saturated hue,
/// brightened to read on a dark key. A gray cover gets the neutral accent.
func coverSample(_ art: CGImage) -> (blurred: CGImage, accent: CGColor)? {
    let side = 36
    guard let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let data = context.data else { return nil }
    context.interpolationQuality = .high
    drawAspectFill(art, in: CGRect(x: 0, y: 0, width: side, height: side), context: context)
    let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

    var weights = [Double](repeating: 0, count: 12)
    var sums = [[Double]](repeating: [0, 0, 0], count: 12)
    for i in 0..<(side * side) {
        let r = Double(pixels[i * 4]) / 255, g = Double(pixels[i * 4 + 1]) / 255, b = Double(pixels[i * 4 + 2]) / 255
        let color = hsv(r, g, b)
        guard color.s > 0.3, color.v > 0.25 else { continue }
        let bucket = min(11, Int(color.h * 12))
        let weight = color.s * color.v
        weights[bucket] += weight
        sums[bucket] = [sums[bucket][0] + r * weight, sums[bucket][1] + g * weight, sums[bucket][2] + b * weight]
    }
    var accent = neutralAccent
    if let best = weights.indices.max(by: { weights[$0] < weights[$1] }), weights[best] >= Double(side * side) * 0.03 {
        let w = weights[best]
        let color = hsv(sums[best][0] / w, sums[best][1] / w, sums[best][2] / w)
        accent = rgb(color.h, min(max(color.s, 0.55), 0.85), max(color.v, 0.92))
    }

    var values = (0..<(side * side * 4)).map { Float(pixels[$0]) }
    let radius = 2
    func pass(horizontal: Bool) {
        var out = values
        for y in 0..<side {
            for x in 0..<side {
                for c in 0..<4 {
                    var total: Float = 0
                    for d in -radius...radius {
                        let xx = horizontal ? min(max(x + d, 0), side - 1) : x
                        let yy = horizontal ? y : min(max(y + d, 0), side - 1)
                        total += values[(yy * side + xx) * 4 + c]
                    }
                    out[(y * side + x) * 4 + c] = total / Float(2 * radius + 1)
                }
            }
        }
        values = out
    }
    for _ in 0..<3 {
        pass(horizontal: true)
        pass(horizontal: false)
    }
    for i in values.indices { pixels[i] = UInt8(min(255, max(0, values[i].rounded()))) }
    guard let blurred = context.makeImage() else { return nil }
    return (blurred, accent)
}

/// The background of a control page: the cover blurred and darkened over the
/// canvas of nine keys and their gaps (like a mosaic), so each key shows its
/// own part of it and a banner runs straight across its keys. Without a
/// cover: the title's gradient, or plain dark when nothing is loaded. Paused:
/// grayscale and dimmed like a tile.
func renderControlBackground(art: CGImage?, seed: String?, paused: Bool, side: Int) -> (canvas: CGImage, accent: CGColor)? {
    guard let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .high
    let s = CGFloat(side)
    let full = CGRect(x: 0, y: 0, width: s, height: s)
    var accent = neutralAccent
    if let art, let sample = coverSample(art) {
        accent = sample.accent
        context.draw(sample.blurred, in: full)
    } else if let seed {
        drawFallbackBackground(seed, size: s, context: context)
    } else {
        let plain = CGGradient(
            colorsSpace: sRGB,
            colors: [CGColor(srgbRed: 0.14, green: 0.14, blue: 0.15, alpha: 1),
                     CGColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 1)] as CFArray,
            locations: [0, 1])!
        context.drawLinearGradient(plain, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    }
    context.setFillColor(black(0.4))
    context.fill(full)
    guard var canvas = context.makeImage() else { return nil }
    if paused, let gray = grayscale(canvas, size: side) {
        context.draw(gray, in: full)
        context.setFillColor(black(0.42))
        context.fill(full)
        canvas = context.makeImage() ?? canvas
    }
    return (canvas, accent)
}

/// The part of a page canvas under grid key `index` (and the `count` - 1
/// keys to its right, for a banner), gaps included.
func pageCrop(_ canvas: CGImage, index: Int, count: Int = 1, size: Int, gap: Int) -> CGImage? {
    let row = index / 3, col = index % 3
    return canvas.cropping(to: CGRect(x: col * (size + gap), y: row * (size + gap),
                                      width: count * size + (count - 1) * gap, height: size))
}

func formatTime(_ seconds: Int) -> String {
    let h = seconds / 3600, m = seconds / 60 % 60, s = seconds % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// What a control key shows; `key` names it for caching and change checks.
struct ControlState {
    var role: Role
    var enabled = false          // a track is loaded
    var on = false               // shuffle or repeat
    var elapsed = 0              // seconds
    var duration = 0.0           // seconds
    var text = ""                // song, artist, or album

    var key: String { "\(role.rawValue) \(enabled) \(on) \(elapsed) \(Int(duration))" + (text.isEmpty ? "" : "\n\(text)") }
}

/// The words on a song, artist, or album key; nil `track` is nothing loaded.
func tileText(_ role: Role, _ track: Track?) -> String {
    guard let track else { return role == .song ? "Nothing playing" : "" }
    switch role {
    case .song: return cleaned(track.title).isEmpty ? "Unknown track" : cleaned(track.title)
    case .artist: return cleaned(track.artist)
    case .album: return cleaned(track.album)
    default: return ""
    }
}

/// A line's width without its trailing spaces.
func visibleWidth(_ line: CTLine) -> CGFloat {
    CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
}

/// `text` wrapped to at most 3 lines inside `box`, at the largest size from
/// 28 down to 15 (per 118 px key) where it fits with no word broken; failing
/// that, at 15 with the last line ending in an ellipsis. Only a word wider
/// than the box at 15 is broken. `size` is per 118 px key.
func fitText(_ text: String, weight: NSFont.Weight, color: CGColor, box: CGSize, k: CGFloat)
    -> (lines: [CTLine], font: CTFont, size: CGFloat, truncated: Bool) {
    let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    var size: CGFloat = 28
    while true {
        let textFont = font(size: size * k, weight: weight)
        let string = attributed(text, font: textFont, color: color)
        let lines = layoutLines(string, width: box.width, maxLines: .max)
        let height = CTFontGetAscent(textFont) + CTFontGetDescent(textFont)
        let fits = lines.count <= 3 && height * (1 + 0.96 * CGFloat(max(0, lines.count - 1))) <= box.height
            && words.allSatisfy {
                visibleWidth(CTLineCreateWithAttributedString(attributed($0, font: textFont, color: color))) <= box.width
            }
        if fits { return (lines, textFont, size, false) }
        if size <= 15 {
            return (layoutLines(string, width: box.width, maxLines: 3), textFont, size, lines.count > 3)
        }
        size -= 1
    }
}

func strokeIcon(_ path: CGPath, color: CGColor, width: CGFloat, context: CGContext) {
    context.setStrokeColor(color)
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(path)
    context.strokePath()
}

/// A chevron whose tip is `tip`, pointing right (or left).
func addArrowhead(_ path: CGMutablePath, tip: CGPoint, length: CGFloat, pointingLeft: Bool = false) {
    let back = pointingLeft ? length : -length
    path.move(to: CGPoint(x: tip.x + back, y: tip.y + length))
    path.addLine(to: tip)
    path.addLine(to: CGPoint(x: tip.x + back, y: tip.y - length))
}

func drawShuffleIcon(center: CGPoint, k: CGFloat, color: CGColor, context: CGContext) {
    let w = 40 * k, h = 24 * k
    let left = center.x - w / 2, right = center.x + w / 2
    let path = CGMutablePath()
    for (from, to) in [(center.y - h / 2, center.y + h / 2), (center.y + h / 2, center.y - h / 2)] {
        path.move(to: CGPoint(x: left, y: from))
        path.addLine(to: CGPoint(x: left + w * 0.2, y: from))
        path.addCurve(to: CGPoint(x: right - w * 0.2, y: to),
                      control1: CGPoint(x: left + w * 0.5, y: from), control2: CGPoint(x: right - w * 0.5, y: to))
        path.addLine(to: CGPoint(x: right, y: to))
        addArrowhead(path, tip: CGPoint(x: right, y: to), length: 6.5 * k)
    }
    strokeIcon(path, color: color, width: 3.4 * k, context: context)
}

func drawRepeatIcon(center: CGPoint, k: CGFloat, color: CGColor, context: CGContext) {
    let w = 38 * k, h = 24 * k
    let rect = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
    let path = CGMutablePath(roundedRect: rect, cornerWidth: 9 * k, cornerHeight: 9 * k, transform: nil)
    addArrowhead(path, tip: CGPoint(x: rect.midX + 5 * k, y: rect.maxY), length: 6 * k)
    addArrowhead(path, tip: CGPoint(x: rect.midX - 5 * k, y: rect.minY), length: 6 * k, pointingLeft: true)
    strokeIcon(path, color: color, width: 3.4 * k, context: context)
}

/// Two triangles and a bar: next, or mirrored, previous.
func drawSkipIcon(forward: Bool, center: CGPoint, k: CGFloat, color: CGColor, context: CGContext) {
    context.saveGState()
    if !forward {
        context.translateBy(x: 2 * center.x, y: 0)
        context.scaleBy(x: -1, y: 1)
    }
    let w = 16 * k, h = 22 * k, bar = 4.5 * k
    let left = center.x - (2 * w + bar) / 2
    let path = CGMutablePath()
    for i in 0..<2 {
        let x = left + CGFloat(i) * w
        path.move(to: CGPoint(x: x, y: center.y + h / 2))
        path.addLine(to: CGPoint(x: x + w, y: center.y))
        path.addLine(to: CGPoint(x: x, y: center.y - h / 2))
        path.closeSubpath()
    }
    path.addRect(CGRect(x: left + 2 * w, y: center.y - h / 2, width: bar, height: h))
    context.setFillColor(color)
    context.addPath(path)
    context.fillPath()
    context.restoreGState()
}

/// One control key: its icon (or the time and its ring, or its words) over
/// its part of the page background. White; shuffle and repeat in the accent
/// when on and faint when off; everything dimmed with nothing loaded.
func renderControl(_ state: ControlState, background: CGImage, accent: CGColor, size: Int) -> CGImage? {
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .high
    let s = CGFloat(size)
    let k = s / 118
    context.draw(background, in: CGRect(x: 0, y: 0, width: s, height: s))
    let toggle = state.role == .shuffle || state.role == .repeat
    let color = !state.enabled ? white(0.3) : !toggle ? white(1) : state.on ? accent : white(0.5)

    func label(_ text: String) {
        let line = CTLineCreateWithAttributedString(attributed(text, font: font(size: 13 * k, weight: .medium), color: color))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.textPosition = CGPoint(x: (s - width) / 2, y: 22 * k)
        CTLineDraw(line, context)
        if state.on && state.enabled {
            let bar = CGRect(x: s / 2 - 11 * k, y: 13 * k, width: 22 * k, height: 2.5 * k)
            context.setFillColor(accent)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: 1.25 * k, cornerHeight: 1.25 * k, transform: nil))
            context.fillPath()
        }
    }

    let iconCenter = CGPoint(x: s / 2, y: s * 0.6)
    switch state.role {
    case .shuffle:
        drawShuffleIcon(center: iconCenter, k: k, color: color, context: context)
        label("Shuffle")
    case .repeat:
        drawRepeatIcon(center: iconCenter, k: k, color: color, context: context)
        label("Repeat")
    case .previous, .next:
        drawSkipIcon(forward: state.role == .next, center: CGPoint(x: s / 2, y: s / 2), k: k, color: color, context: context)
    case .time:
        let center = CGPoint(x: s / 2, y: s / 2)
        let radius = 41 * k
        context.setLineWidth(5 * k)
        context.setLineCap(.round)
        context.setStrokeColor(white(0.16))
        context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        let progress = state.duration > 0 ? min(1, Double(state.elapsed) / state.duration) : 0
        if state.enabled && progress > 0 {
            context.setStrokeColor(accent)
            context.addArc(center: center, radius: radius, startAngle: .pi / 2,
                           endAngle: .pi / 2 - 2 * .pi * CGFloat(progress), clockwise: true)
            context.strokePath()
        }
        let text = formatTime(state.enabled ? state.elapsed : 0)
        let line = CTLineCreateWithAttributedString(attributed(
            text, font: font(size: (text.count > 5 ? 19 : 25) * k, weight: .bold), color: state.enabled ? white(1) : white(0.3)))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.textPosition = CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY)
        CTLineDraw(line, context)
    case .song, .artist, .album:
        // A scrim over the whole key keeps white words readable on a light cover.
        context.setFillColor(black(textScrim))
        context.fill(CGRect(x: 0, y: 0, width: s, height: s))
        let weight: NSFont.Weight = state.role == .song ? .bold : state.role == .artist ? .semibold : .medium
        let pad = 10 * k
        let fit = fitText(state.text, weight: weight, color: color, box: CGSize(width: s - 2 * pad, height: s - 2 * pad), k: k)
        let ascent = CTFontGetAscent(fit.font)
        let step = (ascent + CTFontGetDescent(fit.font)) * 0.96
        let height = ascent + CTFontGetDescent(fit.font) + step * CGFloat(max(0, fit.lines.count - 1))
        var baseline = (s + height) / 2 - ascent
        context.setShadow(offset: CGSize(width: 0, height: -0.75 * k), blur: 2.5 * k, color: black(0.7))
        for line in fit.lines {
            context.textPosition = CGPoint(x: (s - visibleWidth(line)) / 2, y: baseline)
            CTLineDraw(line, context)
            baseline -= step
        }
    case .art, .title:
        break
    }
    return context.makeImage()
}

/// The title at the largest size from 30 down to 19 (per 118 px key) that
/// fits `width`, and how wide it is there.
func fitTitle(_ title: String, width: CGFloat, k: CGFloat) -> (font: CTFont, width: CGFloat) {
    var size: CGFloat = 30
    while true {
        let titleFont = font(size: size * k, weight: .bold)
        let line = CTLineCreateWithAttributedString(attributed(title, font: titleFont, color: white(1)))
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if lineWidth <= width || size <= 19 { return (titleFont, lineWidth) }
        size -= 1
    }
}

/// Where a scrolling title is `elapsed` seconds into its cycle: still for
/// 2 s, then `speed` pixels a second to its end, still for 2 s, and back.
func scrollOffset(elapsed: Double, distance: CGFloat, speed: CGFloat) -> CGFloat {
    let travel = Double(distance / speed)
    let t = elapsed.truncatingRemainder(dividingBy: scrollPause + travel + scrollPause)
    if t < scrollPause { return 0 }
    if t < scrollPause + travel { return CGFloat(t - scrollPause) * speed }
    return distance
}

/// A title banner across `count` keys of a row: the title over the artist,
/// left aligned. The canvas is the keys side by side with no gaps (cut it at
/// multiples of `size`), so no letter is lost under a gap; the background is
/// the banner's part of the page background, gaps included, each key's own
/// piece put in place. With `offset` the title is drawn that far left,
/// clipped to the banner, to scroll; without it a title too long at the
/// smallest size ends in an ellipsis. The artist truncates.
func renderBanner(title: String, artist: String, background: CGImage, size: Int, count: Int, gap: Int,
                  offset: CGFloat?) -> CGImage? {
    let width = count * size
    guard let context = CGContext(
        data: nil, width: width, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    let s = CGFloat(size)
    let k = s / 118
    let w = CGFloat(width)
    for i in 0..<count {
        guard let piece = background.cropping(to: CGRect(x: i * (size + gap), y: 0, width: size, height: size)) else { return nil }
        context.draw(piece, in: CGRect(x: CGFloat(i * size), y: 0, width: s, height: s))
    }
    let pad = 12 * k
    let available = w - 2 * pad
    let fit = fitTitle(title, width: available, k: k)
    var titleLine = CTLineCreateWithAttributedString(attributed(title, font: fit.font, color: white(1)))
    if fit.width > available && offset == nil {
        let token = CTLineCreateWithAttributedString(attributed("\u{2026}", font: fit.font, color: white(1)))
        titleLine = CTLineCreateTruncatedLine(titleLine, Double(available), .end, token) ?? titleLine
    }
    let artistFont = font(size: 17 * k, weight: .regular)
    let artistLines = artist.isEmpty ? [] :
        layoutLines(attributed(artist, font: artistFont, color: white(0.85)), width: available, maxLines: 1)

    let titleHeight = CTFontGetAscent(fit.font) + CTFontGetDescent(fit.font)
    let artistHeight = artistLines.isEmpty ? 0 : CTFontGetAscent(artistFont) + CTFontGetDescent(artistFont) + 3 * k
    let bottom = (s - titleHeight - artistHeight) / 2
    context.setShadow(offset: CGSize(width: 0, height: -0.75 * k), blur: 2.5 * k, color: black(0.7))
    for line in artistLines {
        context.textPosition = CGPoint(x: pad, y: bottom + CTFontGetDescent(artistFont))
        CTLineDraw(line, context)
    }
    context.saveGState()
    if offset != nil { context.clip(to: CGRect(x: pad / 2, y: 0, width: w - pad, height: s)) }
    context.textPosition = CGPoint(x: pad - (offset ?? 0), y: bottom + artistHeight + CTFontGetDescent(fit.font))
    CTLineDraw(titleLine, context)
    context.restoreGState()
    return context.makeImage()
}

/// A white play triangle with softened corners, nudged right of `center` so
/// it looks centered (its visual mass sits left of its bounding box's middle).
func drawPlayTriangle(center: CGPoint, height: CGFloat, context: CGContext) {
    let width = height * 0.88
    let left = center.x - width / 2 + height * 0.08
    let path = CGMutablePath()
    let points = [
        CGPoint(x: left, y: center.y + height / 2),
        CGPoint(x: left + width, y: center.y),
        CGPoint(x: left, y: center.y - height / 2),
    ]
    let corner = height * 0.1
    path.move(to: CGPoint(x: (points[0].x + points[2].x) / 2, y: (points[0].y + points[2].y) / 2))
    for i in 0..<3 {
        path.addArc(tangent1End: points[i], tangent2End: points[(i + 1) % 3], radius: corner)
    }
    path.closeSubpath()
    context.setFillColor(white(1))
    context.addPath(path)
    context.fillPath()
}

/// The stand-in for the app icon tile when Spotify's icon cannot be read:
/// dark, a large play triangle, and the word Spotify. No logo or brand colors.
func renderGenericTile(size: Int) -> CGImage? {
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    let s = CGFloat(size)
    let k = s / 118
    let background = CGGradient(
        colorsSpace: sRGB,
        colors: [CGColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 1),
                 CGColor(srgbRed: 0.06, green: 0.06, blue: 0.07, alpha: 1)] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(
        background, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    let center = CGPoint(x: s / 2, y: s * 0.6)
    let radius = 27 * k
    context.setFillColor(white(0.12))
    context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
    drawPlayTriangle(center: center, height: 28 * k, context: context)

    let line = CTLineCreateWithAttributedString(
        attributed("Spotify", font: font(size: 17 * k, weight: .bold), color: white(0.92)))
    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    context.textPosition = CGPoint(x: (s - width) / 2, y: 17 * k)
    CTLineDraw(line, context)
    return context.makeImage()
}

/// Spotify's own app icon, read from the user's install at runtime (nothing
/// of Spotify's ships with this module), drawn at 86% of the side so the
/// visible shape, inside the icon's built-in padding, fills about 70%. Nil
/// when Spotify is not installed or the icon cannot be read.
func renderAppIconTile(size: Int) -> CGImage? {
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: spotifyBundleID) else { return nil }
    let icon = NSWorkspace.shared.icon(forFile: app.path)
    let side = (CGFloat(size) * 0.86).rounded()
    var proposed = CGRect(x: 0, y: 0, width: side * 2, height: side * 2)
    guard let image = icon.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
          let context = CGContext(
              data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
              space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.setFillColor(black(1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let origin = (CGFloat(size) - side) / 2
    context.draw(image, in: CGRect(x: origin, y: origin, width: side, height: side))
    return context.makeImage()
}

func pngData(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

// MARK: - AppleScript

struct ScriptError: Error {
    var number: Int?
    var message: String

    var description: String {
        if number == -1743 {
            return "not allowed to control Spotify (System Settings > Privacy & Security > Automation) [-1743]"
        }
        return "\(message) [\(number.map(String.init) ?? "?")]"
    }
}

/// One AppleScript, compiled on first use and kept. A -1712 (the event timed
/// out, usually because an Automation prompt is still waiting for an answer)
/// leaves the instance stuck, so it is dropped and compiled again before the
/// next run. NSAppleScript is main-thread only: call `run` on the main queue.
final class Script {
    let source: String
    private var compiled: NSAppleScript?
    private(set) var compiles = 0

    init(_ source: String) {
        self.source = source
    }

    func run() -> Result<NSAppleEventDescriptor, ScriptError> {
        if compiled == nil {
            let script = NSAppleScript(source: source)
            var error: NSDictionary?
            compiles += 1
            guard let script, script.compileAndReturnError(&error) else {
                return .failure(scriptError(error, prefix: "AppleScript compile failed: "))
            }
            compiled = script
        }
        var error: NSDictionary?
        guard let result = compiled?.executeAndReturnError(&error), error == nil else {
            let failure = scriptError(error, prefix: "")
            if failure.number == -1712 { compiled = nil }
            return .failure(failure)
        }
        return .success(result)
    }

    private func scriptError(_ error: NSDictionary?, prefix: String) -> ScriptError {
        let number = error?[NSAppleScript.errorNumber] as? Int
        let message = error?[NSAppleScript.errorMessage] as? String ?? "no message"
        return ScriptError(number: number, message: prefix + message)
    }
}

// MARK: - Spotify

struct Track {
    var id: String
    var title: String
    var artist: String
    var artworkURL: String
    var playing: Bool
    // Read only while a shuffle, repeat, or time key is bound.
    var shuffling = false
    var repeating = false
    var position: Double = 0     // seconds
    var duration: Double = 0     // seconds
    var album = ""               // read only while an album key is bound
}

enum SpotifyState {
    case notRunning
    case idle            // running, but stopped or no current track
    case track(Track)
    case failed(String)
}

enum CommandOutcome {
    case done
    case notRunning
    case failed(String)
}

/// What the control keys ask of Spotify; each one only while it is running.
enum PlayerCommand: String {
    case toggleShuffle = "shuffle"
    case toggleRepeat = "repeat"
    case seekBack = "seek back"
    case previous = "previous track"
    case next = "next track"
}

/// Everything the module asks of Spotify. The test build swaps in a fake.
protocol SpotifyBackend: AnyObject {
    /// The app whose launch and quit the module watches.
    var bundleID: String { get }
    /// Posted by the app on track changes and play/pause; only a wake-up.
    var notification: Notification.Name { get }
    func isInstalled() -> Bool
    func isRunning() -> Bool
    /// `extended` also reads shuffle, repeat, position, and duration; `album`
    /// the album name.
    func read(extended: Bool, album: Bool) -> SpotifyState
    func playPause() -> CommandOutcome
    func command(_ command: PlayerCommand) -> CommandOutcome
    func launch() -> CommandOutcome
    /// One `play`; true once the player reports playing.
    func tryPlay() -> Bool
}

// Every script below starts with an `is running` guard where a bare `tell`
// would launch Spotify, and carries a timeout so a busy or still-launching
// Spotify cannot hold the main queue for the default 2 minutes.
// Variable names avoid `st` and other words Spotify's dictionary reserves.
let readReturn = "return {stateText, trackID, trackName, trackArtist, artworkURL}"
let readSource = """
if application id "com.spotify.client" is running then
  with timeout of 5 seconds
    tell application id "com.spotify.client"
        set stateText to "stopped"
        if player state is playing then
            set stateText to "playing"
        else if player state is paused then
            set stateText to "paused"
        end if
        set trackID to ""
        set trackName to ""
        set trackArtist to ""
        set artworkURL to ""
        try
            set theTrack to current track
            set trackID to (id of theTrack) as text
            set trackName to (name of theTrack) as text
            set trackArtist to (artist of theTrack) as text
        end try
        try
            set artworkURL to (artwork url of current track) as text
        end try
        \(readReturn)
    end tell
  end timeout
end if
return {}
"""

// The same read plus shuffle, repeat, position (seconds), and duration
// (milliseconds, whatever Spotify's dictionary says).
let readExtendedSource = readSource.replacingOccurrences(of: readReturn, with: """
set shuffleState to false
        set repeatState to false
        set positionSeconds to 0
        set durationValue to 0
        try
            set shuffleState to shuffling
            set repeatState to repeating
            set positionSeconds to player position
        end try
        try
            set durationValue to duration of current track
        end try
        return {stateText, trackID, trackName, trackArtist, artworkURL, shuffleState, repeatState, positionSeconds, durationValue}
""")

/// `source` (either read above) with the album name read too, returned last.
func withAlbum(_ source: String) -> String {
    let start = source.range(of: "return {stateText")!
    let end = source.range(of: "}", range: start.upperBound..<source.endIndex)!
    let albumLines = """
    set trackAlbum to ""
            try
                set trackAlbum to (album of current track) as text
            end try

    """
    return String(source[..<start.lowerBound]) + albumLines + "        " + String(source[start.lowerBound..<end.lowerBound])
        + ", trackAlbum}" + String(source[end.upperBound...])
}

let readAlbumSource = withAlbum(readSource)
let readExtendedAlbumSource = withAlbum(readExtendedSource)

func commandSource(_ command: PlayerCommand) -> String {
    let body: String
    switch command {
    case .toggleShuffle: body = "set shuffling to not shuffling"
    case .toggleRepeat: body = "set repeating to not repeating"
    case .seekBack:
        body = """
        set newPosition to (player position) - 15
              if newPosition < 0 then set newPosition to 0
              set player position to newPosition
        """
    case .previous: body = "previous track"
    case .next: body = "next track"
    }
    return """
    if application id "com.spotify.client" is running then
      with timeout of 5 seconds
        tell application id "com.spotify.client"
          \(body)
        end tell
      end timeout
      return "done"
    end if
    return "not running"
    """
}

let playPauseSource = """
if application id "com.spotify.client" is running then
  with timeout of 5 seconds
    tell application id "com.spotify.client" to playpause
  end timeout
  return "done"
end if
return "not running"
"""

let launchSource = """
with timeout of 10 seconds
  tell application id "com.spotify.client" to launch
end timeout
"""

let tryPlaySource = """
if application id "com.spotify.client" is running then
  with timeout of 2 seconds
    tell application id "com.spotify.client"
        play
        if player state is playing then return "playing"
    end tell
  end timeout
end if
return "waiting"
"""

final class SpotifyReader: SpotifyBackend {
    let bundleID = spotifyBundleID
    let notification = spotifyNotification
    private let reader = Script(readSource)
    private let extendedReader = Script(readExtendedSource)
    private let albumReader = Script(readAlbumSource)
    private let extendedAlbumReader = Script(readExtendedAlbumSource)
    private var commandScripts: [String: Script] = [:]
    private let playPauseScript = Script(playPauseSource)
    private let launchScript = Script(launchSource)
    private let tryPlayScript = Script(tryPlaySource)

    func isInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: spotifyBundleID) != nil
    }

    func isRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: spotifyBundleID)
            .contains { !$0.isTerminated }
    }

    func read(extended: Bool, album: Bool) -> SpotifyState {
        guard isRunning() else { return .notRunning }
        let script = album ? (extended ? extendedAlbumReader : albumReader) : (extended ? extendedReader : reader)
        switch script.run() {
        case .failure(let error):
            // -600 and -609: Spotify quit between the running check and the
            // read (it posts one last playback notification as it quits).
            if error.number == -600 || error.number == -609 || !isRunning() { return .notRunning }
            return .failed("AppleScript failed: \(error.description)")
        case .success(let result):
            guard result.numberOfItems >= 5 else { return .notRunning }
            func item(_ i: Int) -> String { result.atIndex(i)?.stringValue ?? "" }
            let state = item(1)
            let id = item(2)
            guard state != "stopped", !id.isEmpty else { return .idle }
            var track = Track(id: id, title: item(3), artist: item(4), artworkURL: item(5), playing: state == "playing")
            if extended, result.numberOfItems >= 9 {
                track.shuffling = result.atIndex(6)?.booleanValue ?? false
                track.repeating = result.atIndex(7)?.booleanValue ?? false
                track.position = max(0, result.atIndex(8)?.doubleValue ?? 0)
                // Milliseconds in practice; taken as seconds only when that
                // would put the position past the end.
                let duration = result.atIndex(9)?.doubleValue ?? 0
                track.duration = duration / 1000 >= track.position ? duration / 1000 : duration
            }
            let albumIndex = extended ? 10 : 6
            if album, result.numberOfItems >= albumIndex {
                track.album = item(albumIndex)
            }
            return .track(track)
        }
    }

    func command(_ command: PlayerCommand) -> CommandOutcome {
        let script = commandScripts[command.rawValue] ?? Script(commandSource(command))
        commandScripts[command.rawValue] = script
        switch script.run() {
        case .failure(let error):
            if error.number == -600 || error.number == -609 { return .notRunning }
            return .failed(error.description)
        case .success(let result):
            return result.stringValue == "done" ? .done : .notRunning
        }
    }

    func playPause() -> CommandOutcome {
        switch playPauseScript.run() {
        case .failure(let error):
            if error.number == -600 || error.number == -609 { return .notRunning }
            return .failed(error.description)
        case .success(let result):
            return result.stringValue == "done" ? .done : .notRunning
        }
    }

    func launch() -> CommandOutcome {
        switch launchScript.run() {
        case .failure(let error): return .failed(error.description)
        case .success: return .done
        }
    }

    func tryPlay() -> Bool {
        // Errors while Spotify is still starting are expected; the next try
        // asks again, as the tested script's `try` block did.
        if case .success(let result) = tryPlayScript.run() { return result.stringValue == "playing" }
        return false
    }
}

// MARK: - Render cache

/// Rendered tiles on disk, one PNG per (track id, playing or paused, size),
/// named by the SHA-256 of that tuple. Least recently used files go first
/// when the folder outgrows its limit.
final class RenderCache {
    let directory: String

    init(directory chosen: String? = nil) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
        var directory = chosen ?? caches.appendingPathComponent("com.typ.openlogi.spotify").path
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        } catch {
            let fallback = (NSTemporaryDirectory() as NSString).appendingPathComponent("com.typ.openlogi.spotify-cache")
            log("error creating cache \(directory): \(error.localizedDescription); using \(fallback)")
            try? FileManager.default.createDirectory(atPath: fallback, withIntermediateDirectories: true)
            directory = fallback
        }
        self.directory = directory
    }

    func path(for key: TrackKey, size: Int) -> String {
        path(for: "\(key.id)\n\(key.playing ? "playing" : "paused")", size: size)
    }

    /// The app icon tile and its stand-in each have their own entry.
    func appIconPath(size: Int) -> String {
        path(for: "app-icon", size: size)
    }

    func genericPath(size: Int) -> String {
        path(for: "generic", size: size)
    }

    /// One key of a mosaic: track, art, playing or paused, gap, and position
    /// (0 to 8 in reading order), plus the size.
    func mosaicPath(for key: TrackKey, art: String, gap: Int, position: Int, size: Int) -> String {
        path(for: "\(mosaicVersion)\n\(key.id)\n\(art)\n\(key.playing ? "playing" : "paused")\n\(gap)\n\(position)",
             size: size)
    }

    /// A control key face, named by everything it shows.
    func controlPath(_ name: String, size: Int) -> String {
        path(for: "\(controlVersion)\n\(name)", size: size)
    }

    private func path(for name: String, size: Int) -> String {
        let tuple = "\(renderVersion)\n\(name)\n\(size)"
        let hex = SHA256.hash(data: Data(tuple.utf8)).map { String(format: "%02x", $0) }.joined()
        return (directory as NSString).appendingPathComponent("\(hex).png")
    }

    /// The cached PNG, its modification date bumped so pruning keeps it.
    func load(_ path: String) -> Data? {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return nil }
        touch(path)
        return data
    }

    func touch(_ path: String) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
    }

    /// Writes through a hidden temp file and a rename, so a reader never sees
    /// a half-written PNG.
    func store(_ data: Data, at path: String) -> Bool {
        let temp = (directory as NSString).appendingPathComponent(".\((path as NSString).lastPathComponent).tmp")
        guard FileManager.default.createFile(atPath: temp, contents: data) else { return false }
        guard rename(temp, path) == 0 else {
            unlink(temp)
            return false
        }
        return true
    }

    /// Over `cacheLimit` tiles, deletes the oldest by modification date down
    /// to `cachePruneTarget`. Returns how many were deleted. Only PNGs count.
    @discardableResult
    func prune() -> Int {
        let url = URL(fileURLWithPath: directory)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        let tiles = files.filter { $0.pathExtension == "png" }
        guard tiles.count > cacheLimit else { return 0 }
        let oldestFirst = tiles.map { file in
            (file, (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 < $1.1 }
        var removed = 0
        for (file, _) in oldestFirst.prefix(tiles.count - cachePruneTarget) {
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }
}

// MARK: - Protocol output

/// Writes protocol lines to stdout. One lock covers each whole line, so lines
/// never interleave; FileHandle writes are unbuffered, so each line is flushed
/// as it is written. Nothing is written before `ready`.
final class Output {
    private let lock = NSLock()
    private var isReady = false
    private let out = FileHandle.standardOutput

    func ready() {
        lock.lock()
        defer { lock.unlock() }
        guard !isReady else { return }
        write(["type": "ready", "protocol": protocolVersion])
        isReady = true
    }

    func send(_ message: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        guard isReady else { return }
        write(message)
    }

    /// A message for the agent's log, at "debug", "info", "warn", or "error".
    /// Before `ready` it goes to stderr only.
    func report(_ level: String, _ message: String) {
        log("\(level): \(message)")
        send(["type": "log", "level": level, "message": message])
    }

    /// Exits once no line is half written (waiting at most half a second).
    func exitNow(_ code: Int32) -> Never {
        _ = lock.lock(before: Date().addingTimeInterval(0.5))
        exit(code)
    }

    private func write(_ message: [String: Any]) {
        guard var line = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else {
            log("error encoding a protocol message")
            return
        }
        line.append(0x0A)
        do {
            try out.write(contentsOf: line)
        } catch {
            // The host closed our stdout: it is gone or stopping us.
            log("stdout closed (\(error.localizedDescription)), exiting")
            exit(1)
        }
    }
}

// MARK: - Controller

struct TrackKey: Equatable {
    var id: String
    var playing: Bool
}

/// What the keys should show: a Spotify track, or (Spotify not running, or
/// running with no track) Spotify's app icon.
enum Display {
    case track(Track)
    case appIcon
}

enum Shown: Equatable {
    case unknown
    case appIcon
    case track(TrackKey)
}

struct Slot: Equatable {
    var device: String
    var slot: String
    var size: Int
}

/// All nine grid keys of one page on one device: drawn as one picture.
struct MosaicGroup: Hashable {
    var device: String
    var page: String        // "" on page 1, "page2:" and so on after
    var size: Int           // the center key's

    var slots: [String] { gridSlots.map { page + $0 } }
}

/// A run of `title` keys side by side in one row of one page: one banner.
struct Banner: Hashable {
    var device: String
    var page: String
    var first: Int          // grid index of its leftmost key
    var count: Int          // 1 to 3
    var size: Int

    var slots: [String] { (first..<first + count).map { page + gridSlots[$0] } }
}

/// A shuffle, repeat, time, previous, next, song, artist, or album key.
struct Control: Hashable {
    var device: String
    var slot: String
    var size: Int
    var role: Role
    var index: Int          // its grid position
}

/// "page2:gridMiddle" is ("page2:", "gridMiddle"); "gridMiddle" is ("", "gridMiddle").
func splitSlot(_ slot: String) -> (page: String, name: String) {
    guard let colon = slot.firstIndex(of: ":") else { return ("", slot) }
    return (String(slot[...colon]), String(slot[slot.index(after: colon)...]))
}

struct Layout {
    var mosaics: [MosaicGroup] = []
    var singles: [Slot] = []
    var banners: [Banner] = []
    var controls: [Control] = []
}

/// Sorts the bound keys: full pages whose keys are all `art` (mosaics), title
/// banners, control keys, and the rest, which keep one full tile each. Roles
/// apply to grid slots only. Mosaics come in the order their pages first appear.
func groupSlots(_ slots: [Slot], roles: [String: Role] = [:]) -> Layout {
    func role(_ slot: Slot) -> Role {
        gridSlots.contains(splitSlot(slot.slot).name) ? roles[slot.slot] ?? .art : .art
    }
    var pages: [String: [String: Slot]] = [:]
    var order: [(device: String, page: String)] = []
    for slot in slots {
        let (page, name) = splitSlot(slot.slot)
        guard gridSlots.contains(name) else { continue }
        let id = slot.device + "\n" + page
        if pages[id] == nil { order.append((slot.device, page)) }
        pages[id, default: [:]][name] = slot
    }
    var layout = Layout()
    var taken: Set<String> = []
    for (device, page) in order {
        let keys = pages[device + "\n" + page] ?? [:]
        guard keys.count == gridSlots.count, let center = keys[gridSlots[centerIndex]],
              keys.values.allSatisfy({ role($0) == .art }) else { continue }
        layout.mosaics.append(MosaicGroup(device: device, page: page, size: center.size))
        for name in gridSlots { taken.insert(device + "\n" + page + name) }
    }
    var titles: [String: [(index: Int, slot: Slot)]] = [:]
    var titleOrder: [String] = []
    for slot in slots where !taken.contains(slot.device + "\n" + slot.slot) {
        let (page, name) = splitSlot(slot.slot)
        let slotRole = role(slot)
        guard slotRole != .art, let index = gridSlots.firstIndex(of: name) else {
            layout.singles.append(slot)
            continue
        }
        if slotRole == .title {
            let row = slot.device + "\n" + page + "\n\(index / 3)"
            if titles[row] == nil { titleOrder.append(row) }
            titles[row, default: []].append((index, slot))
        } else {
            layout.controls.append(Control(device: slot.device, slot: slot.slot, size: slot.size, role: slotRole, index: index))
        }
    }
    for row in titleOrder {
        for (index, slot) in titles[row]!.sorted(by: { $0.index < $1.index }) {
            let page = splitSlot(slot.slot).page
            if var last = layout.banners.last, last.device == slot.device, last.page == page,
               last.first + last.count == index, index % 3 != 0 {
                last.count += 1
                layout.banners[layout.banners.count - 1] = last
            } else {
                layout.banners.append(Banner(device: slot.device, page: page, first: index, count: 1, size: slot.size))
            }
        }
    }
    return layout
}

struct Settings {
    var gapPercent = defaultGapPercent
    var staggerMs = defaultStaggerMs
    var bannerFps = defaultBannerFps
    var roles: [String: Role] = [:]
}

/// The `settings` table from `hello`. A missing key takes its default; a
/// value that is not a number takes the default and one out of range is
/// clamped; a `keys` role that is not a role is `art`. Each problem, and
/// each unknown key, is listed in `problems`.
func parseSettings(_ value: Any?) -> (settings: Settings, problems: [String]) {
    var settings = Settings()
    var problems: [String] = []
    guard let value, !(value is NSNull) else { return (settings, problems) }
    guard let table = value as? [String: Any] else {
        return (settings, ["settings is not a table; using the defaults"])
    }
    func number(_ key: String, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
        guard let raw = table[key] else { return fallback }
        // JSON true and false arrive as NSNumber too.
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else {
            problems.append("\(key) \(raw) is not a number; using \(Int(fallback))")
            return fallback
        }
        let clamped = min(max(n.doubleValue, range.lowerBound), range.upperBound)
        if clamped != n.doubleValue {
            problems.append("\(key) \(n) is outside \(Int(range.lowerBound)) to \(Int(range.upperBound)); using \(Int(clamped))")
        }
        return clamped
    }
    settings.gapPercent = number("mosaic_gap_percent", gapPercentRange, defaultGapPercent)
    settings.staggerMs = number("mosaic_stagger_ms", staggerMsRange, defaultStaggerMs)
    settings.bannerFps = number("banner_fps", bannerFpsRange, defaultBannerFps)
    if let raw = table["keys"] {
        if let map = raw as? [String: Any] {
            for slot in map.keys.sorted() {
                if let name = map[slot] as? String, let role = Role(rawValue: name) {
                    settings.roles[slot] = role
                } else {
                    problems.append("keys \(slot) = \(map[slot]!) is not a role; using art")
                }
            }
        } else {
            problems.append("keys is not a table; using art for every key")
        }
    }
    let known: Set = ["mosaic_gap_percent", "mosaic_stagger_ms", "banner_fps", "keys"]
    for key in table.keys.sorted() where !known.contains(key) {
        problems.append("ignoring unknown setting \(key)")
    }
    return (settings, problems)
}

/// All Spotify reads, presses, and renders run on the main queue, which is
/// serial, so they never overlap; NSAppleScript also wants the main thread.
final class Controller {
    let backend: SpotifyBackend
    let cache: RenderCache
    let output: Output
    let reconcileInterval: TimeInterval

    var slots: [Slot] = []
    var mosaics: [MosaicGroup] = []
    var singles: [Slot] = []
    var banners: [Banner] = []
    var controls: [Control] = []
    var size = defaultSize
    var active: Bool { !slots.isEmpty }
    var settings = Settings()
    var hasRoles: Bool { !banners.isEmpty || !controls.isEmpty }
    /// Keys drawn one by one rather than with one image_all.
    var perKey: Bool { !mosaics.isEmpty || hasRoles }
    var needsExtendedRead: Bool { controls.contains { $0.role == .shuffle || $0.role == .repeat || $0.role == .time } }
    var needsAlbumRead: Bool { controls.contains { $0.role == .album } }

    var shown = Shown.unknown
    var shownDisplay: Display?
    var shownPNG: Data?
    var shownTiles: [MosaicGroup: [Data]] = [:]
    var shownIsFallback = false
    var revealItems: [DispatchWorkItem] = []
    var roleDisplay: Display?
    var roleFaces: [String: (key: String, png: Data)] = [:]    // by device and slot
    var palettes: [String: (canvas: CGImage, accent: CGColor)] = [:]
    var scrollStarts: [Banner: (title: String, at: Date)] = [:]
    var bannerTimer: Timer?
    var trackLoaded = false
    var failures = 0
    var nextAttemptAt = Date.distantPast
    var lastReadError: String?
    var lastReadErrorAt = Date.distantPast
    var unknownTypes: Set<String> = []

    var artURL: String?
    var artImage: CGImage?
    var artPixels = 0
    var artFailedURL: String?
    var artFailedAt = Date.distantPast

    var launching = false
    var pending: DispatchWorkItem?
    var pendingAt = Date.distantFuture
    var pendingReconcile = false
    var observers: [(NotificationCenter, NSObjectProtocol)] = []
    var reconcileTimer: Timer?
    var tickTimer: Timer?

    init(backend: SpotifyBackend, cache: RenderCache, output: Output, reconcileInterval: TimeInterval) {
        self.backend = backend
        self.cache = cache
        self.output = output
        self.reconcileInterval = reconcileInterval
    }

    // MARK: Protocol

    func hello(_ message: [String: Any]) {
        if let version = message["protocol"] as? Int, version != protocolVersion {
            output.report("warn", "host speaks protocol \(version); this module speaks \(protocolVersion)")
        }
        log("hello from \(message["host"] as? String ?? "?") \(message["host_version"] as? String ?? "?"), cache \(cache.directory)")
        let parsed = parseSettings(message["settings"])
        settings = parsed.settings
        if !parsed.problems.isEmpty { output.report("warn", "settings: " + parsed.problems.joined(separator: "; ")) }
        log("mosaic gap \(settings.gapPercent)%, stagger \(settings.staggerMs) ms, banner \(settings.bannerFps) fps, "
            + "\(settings.roles.count) key roles")
        start()
    }

    func handle(_ type: String, _ message: [String: Any]) {
        switch type {
        case "keys": updateKeys(message["keys"])
        case "pressed": press(slot: message["slot"] as? String)
        default:
            if unknownTypes.insert(type).inserted { log("ignoring unknown message type \(type)") }
        }
    }

    func updateKeys(_ value: Any?) {
        var next: [Slot] = []
        for entry in value as? [[String: Any]] ?? [] {
            guard let device = entry["device"] as? String, let slot = entry["slot"] as? String else { continue }
            var size = entry["size"] as? Int ?? defaultSize
            if !sizeRange.contains(size) {
                log("slot \(slot) has size \(size), outside \(sizeRange); drawing at \(defaultSize)")
                size = defaultSize
            }
            next.append(Slot(device: device, slot: slot, size: size))
        }
        let wasActive = active
        let hadPerKey = perKey
        guard next != slots else { return }
        slots = next
        let layout = groupSlots(slots, roles: settings.roles)
        (mosaics, singles, banners, controls) = (layout.mosaics, layout.singles, layout.banners, layout.controls)
        // A keys message wants every key drawn again.
        roleFaces = [:]
        if !hasRoles { setBannerTimer(false) }
        log("keys: \(slots.isEmpty ? "none" : slots.map { "\($0.slot)@\($0.size)" }.joined(separator: " "))"
            + mosaics.map { " (mosaic \($0.device) \($0.page.isEmpty ? "page1:" : $0.page))" }.joined()
            + (hasRoles ? " (\(banners.count) banners, \(controls.count) controls)" : ""))
        guard let first = singles.first ?? slots.first else {
            deactivate()
            return
        }
        if !wasActive || first.size != size {
            // Nothing was tracked while idle, and a new size needs a new render.
            size = first.size
            forgetShown()
        } else if hadPerKey || perKey, let display = shownDisplay {
            // A page that became or stopped being a mosaic is drawn again at
            // once, all nine keys together.
            show(display, quiet: true, now: Date())
        } else if let png = shownPNG {
            // A newly bound slot gets the current face at once.
            sendImage(png)
        }
        if hasRoles, let display = roleDisplay { updateRoles(display, force: true, now: Date()) }
        schedule(after: 0, reconcile: false)
    }

    /// No slots: no reads and no renders until slots arrive again.
    func deactivate() {
        pending?.cancel()
        pending = nil
        pendingAt = .distantFuture
        pendingReconcile = false
        forgetShown()
    }

    func forgetShown() {
        cancelReveal()
        shown = .unknown
        shownDisplay = nil
        shownPNG = nil
        shownTiles = [:]
        roleDisplay = nil
        roleFaces = [:]
        scrollStarts = [:]
        setBannerTimer(false)
    }

    func sendImage(_ png: Data) {
        output.send(["type": "image_all", "png": png.base64EncodedString()])
    }

    func sendImage(_ png: Data, device: String, slot: String) {
        output.send(["type": "image", "device": device, "slot": slot, "png": png.base64EncodedString()])
    }

    func cancelReveal() {
        for item in revealItems { item.cancel() }
        revealItems = []
    }

    /// Sends a face: one image_all while no page is a mosaic, as always;
    /// otherwise one image per key. Mosaics in `reveal` go one key at a time
    /// in reading order, the stagger apart; every paint cancels the rest of a
    /// reveal still under way.
    func paint(single: Data?, tiles: [MosaicGroup: [Data]], reveal: Set<MosaicGroup>) {
        cancelReveal()
        if !perKey {
            if let single { sendImage(single) }
            return
        }
        if let single {
            for slot in singles { sendImage(single, device: slot.device, slot: slot.slot) }
        }
        var later: [(MosaicGroup, [Data])] = []
        for group in mosaics {
            guard let pngs = tiles[group] else { continue }
            if reveal.contains(group) && settings.staggerMs > 0 {
                later.append((group, pngs))
            } else {
                for (i, name) in group.slots.enumerated() { sendImage(pngs[i], device: group.device, slot: name) }
            }
        }
        guard !later.isEmpty else { return }
        let step = settings.staggerMs / 1000
        for i in 0..<gridSlots.count {
            let send = { [unowned self] in
                for (group, pngs) in later { self.sendImage(pngs[i], device: group.device, slot: group.slots[i]) }
            }
            if i == 0 {
                send()
                continue
            }
            let item = DispatchWorkItem { [unowned self] in
                send()
                if i == gridSlots.count - 1 { self.revealItems = [] }
            }
            revealItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * step, execute: item)
        }
    }

    /// The unchanged face again, all at once. A reveal under way sends the
    /// rest of the mosaic keys itself.
    func resend() {
        if !perKey {
            if let png = shownPNG { sendImage(png) }
            return
        }
        if let png = shownPNG {
            for slot in singles { sendImage(png, device: slot.device, slot: slot.slot) }
        }
        guard revealItems.isEmpty else { return }
        for group in mosaics {
            guard let pngs = shownTiles[group] else { continue }
            for (i, name) in group.slots.enumerated() { sendImage(pngs[i], device: group.device, slot: name) }
        }
    }

    // MARK: Events

    func start() {
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, backend.notification) { [unowned self] _ in
            self.schedule(after: debounceDelay, reconcile: false)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didLaunchApplicationNotification) { [unowned self] note in
            guard self.isWatched(note) else { return }
            self.schedule(after: launchReadDelay, reconcile: false)
        }
        observe(workspace, NSWorkspace.didTerminateApplicationNotification) { [unowned self] note in
            guard self.isWatched(note), self.active else { return }
            self.trackLoaded = false
            self.apply(.appIcon, reconcile: false, now: Date())
        }
        let timer = Timer(timeInterval: reconcileInterval, repeats: true) { [unowned self] _ in
            self.schedule(after: 0, reconcile: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        reconcileTimer = timer
        // Shuffle, repeat, and the time follow Spotify once a second while
        // such a key is bound and a track is loaded.
        let tick = Timer(timeInterval: tickInterval, repeats: true) { [unowned self] _ in
            if self.needsExtendedRead && self.trackLoaded { self.schedule(after: 0, reconcile: false) }
        }
        RunLoop.main.add(tick, forMode: .common)
        tickTimer = tick
    }

    func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping (Notification) -> Void) {
        observers.append((center, center.addObserver(forName: name, object: nil, queue: .main, using: handler)))
    }

    func isWatched(_ note: Notification) -> Bool {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier == backend.bundleID
    }

    /// One read after `delay`, never before the failure backoff allows. A read
    /// already pending at or before that time absorbs this request, which is
    /// what turns a burst of notifications into a single read. Nothing is
    /// read while no slot is bound.
    func schedule(after delay: TimeInterval, reconcile: Bool) {
        guard active else { return }
        let now = Date()
        let at = max(now.addingTimeInterval(delay), nextAttemptAt)
        pendingReconcile = pendingReconcile || reconcile
        if pending != nil, pendingAt <= at { return }
        pending?.cancel()
        let item = DispatchWorkItem { [unowned self] in
            let reconcile = self.pendingReconcile
            self.pending = nil
            self.pendingAt = .distantFuture
            self.pendingReconcile = false
            self.perform(reconcile: reconcile)
        }
        pending = item
        pendingAt = at
        DispatchQueue.main.asyncAfter(deadline: .now() + at.timeIntervalSince(now), execute: item)
    }

    // MARK: Presses

    /// A control key sends its command, only while Spotify is running, and
    /// is drawn again from a fresh read; every other key plays or pauses.
    func press(slot: String?) {
        guard let slot, gridSlots.contains(splitSlot(slot).name),
              let role = settings.roles[slot], let command = role.command else {
            press()
            return
        }
        guard backend.isRunning() else {
            log("press ignored: \(role.rawValue) needs Spotify running")
            return
        }
        switch backend.command(command) {
        case .done:
            log("press: \(command.rawValue)")
            schedule(after: 0, reconcile: false)
        case .notRunning:
            log("press ignored: \(role.rawValue) needs Spotify running")
        case .failed(let message):
            output.report("error", "\(command.rawValue) failed: \(message)")
        }
    }

    /// Spotify running: play/pause. Not running: launch it and press play
    /// until it reports playing (40 tries, 0.25 s apart), one try per main
    /// queue turn so messages keep flowing while it starts.
    func press() {
        if launching {
            log("press ignored: Spotify is still starting")
            return
        }
        if backend.isRunning() {
            switch backend.playPause() {
            case .done:
                log("press: play/pause")
                schedule(after: 0, reconcile: false)
                return
            case .failed(let message):
                output.report("error", "play/pause failed: \(message)")
                return
            case .notRunning:
                break
            }
        }
        guard backend.isInstalled() else {
            output.report("warn", "press ignored: Spotify is not installed")
            return
        }
        if case .failed(let message) = backend.launch() {
            output.report("error", "launching Spotify failed: \(message)")
            return
        }
        log("press: launching Spotify to play")
        launching = true
        tryPlay(attempt: 1)
    }

    func tryPlay(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + playTryInterval) { [unowned self] in
            if self.backend.tryPlay() {
                self.launching = false
                log("Spotify started playing (try \(attempt))")
                self.schedule(after: 0, reconcile: false)
            } else if attempt >= playTries {
                self.launching = false
                self.output.report("warn", "Spotify did not start playing after \(playTries) tries")
                self.schedule(after: 0, reconcile: false)
            } else {
                self.tryPlay(attempt: attempt + 1)
            }
        }
    }

    // MARK: Read and show

    /// Reads Spotify once and brings the keys in line.
    func perform(reconcile: Bool, now: Date = Date()) {
        guard active, now >= nextAttemptAt else { return }
        switch backend.read(extended: needsExtendedRead, album: needsAlbumRead) {
        case .failed(let message):
            // The same AppleScript error on every reconcile would flood the log.
            if message != lastReadError || now.timeIntervalSince(lastReadErrorAt) >= artRetryInterval {
                output.report("error", "reading Spotify: \(message)")
                lastReadError = message
                lastReadErrorAt = now
            }
        case .notRunning, .idle:
            lastReadError = nil
            trackLoaded = false
            apply(.appIcon, reconcile: reconcile, now: now)
        case .track(let track):
            lastReadError = nil
            trackLoaded = true
            apply(.track(track), reconcile: reconcile, now: now)
        }
    }

    /// Sends `display` when it differs from what is shown. A reconcile also
    /// re-sends an unchanged face, which restores it after the host restarts
    /// its keypad panel; a face drawn without its art is rendered again
    /// instead, so the art gets another chance.
    func apply(_ display: Display, reconcile: Bool, now: Date) {
        let target: Shown
        switch display {
        case .track(let track): target = .track(TrackKey(id: track.id, playing: track.playing))
        case .appIcon: target = .appIcon
        }
        if shown != target {
            show(display, quiet: false, now: now)
        } else if reconcile {
            if shownIsFallback || faceMissing {
                show(display, quiet: true, now: now)
            } else {
                resend()
            }
        }
        if hasRoles { updateRoles(display, force: reconcile, now: now) }
    }

    var faceMissing: Bool {
        ((!perKey || !singles.isEmpty) && shownPNG == nil) || mosaics.contains { shownTiles[$0] == nil }
    }

    func succeeded() {
        failures = 0
        nextAttemptAt = .distantPast
    }

    /// Retries after 1 s, doubling up to once per 10 s while it keeps failing.
    func failed(_ what: String, now: Date) {
        failures += 1
        let delay = min(maxBackoff, firstRetryDelay * pow(2, Double(failures - 1)))
        nextAttemptAt = now.addingTimeInterval(delay)
        output.report("error", "\(what) (failure \(failures), next try in \(String(format: "%.0f", delay)) s)")
        schedule(after: delay, reconcile: true)
    }

    /// Cached by URL (the current one only). A failed URL is not fetched
    /// again for a minute, so retries do not each wait on the network.
    func artwork(for url: String, now: Date) -> CGImage? {
        if url.isEmpty { return nil }
        // A mosaic needs the art at its whole canvas size.
        let pixels = mosaics.map { 3 * $0.size + 2 * mosaicGap(size: $0.size) }.reduce(size * 3, max)
        if url == artURL, let artImage, artPixels >= pixels { return artImage }
        if url == artFailedURL, now.timeIntervalSince(artFailedAt) < artRetryInterval { return nil }
        let image = loadArtwork(url, maxPixels: pixels)
        if let image {
            artURL = url
            artImage = image
            artPixels = pixels
        } else {
            artFailedURL = url
            artFailedAt = now
            output.report("warn", "artwork download failed, using plain tile: \(url)")
        }
        return image
    }

    /// One full tile at `size`: a cached tile is used as is; otherwise the
    /// art is fetched and the tile rendered into the cache. A tile whose art
    /// failed to download is not cached, so a later reconcile or play retries
    /// it. When the app icon cannot be read, the generic tile stands in (cached
    /// under its own key) and counts as a fallback, so reconciles retry the
    /// icon. Nil after a failure, which `failed` has already handled.
    func face(_ display: Display, size: Int, now: Date) -> (png: Data, fallback: Bool, source: String)? {
        let target: Shown
        var cached: String
        var fallback = false
        var image: CGImage?
        var source = "cached"
        switch display {
        case .track(let track):
            let key = TrackKey(id: track.id, playing: track.playing)
            target = .track(key)
            cached = cache.path(for: key, size: size)
        case .appIcon:
            target = .appIcon
            cached = cache.appIconPath(size: size)
            if !FileManager.default.fileExists(atPath: cached) {
                image = renderAppIconTile(size: size)
                if image == nil {
                    fallback = true
                    source = "generic, app icon unavailable"
                    cached = cache.genericPath(size: size)
                }
            }
        }
        var png: Data?
        if image == nil { png = cache.load(cached) }
        if png == nil {
            switch display {
            case .track(let track):
                let art = artwork(for: track.artworkURL, now: now)
                fallback = art == nil && !track.artworkURL.isEmpty
                source = art == nil ? "no artwork" : "rendered"
                image = renderTile(Tile(title: track.title, artist: track.artist, art: art, paused: !track.playing),
                                   size: size)
            case .appIcon:
                if fallback {
                    image = renderGenericTile(size: size)
                } else {
                    source = "rendered"
                }
            }
            guard let image, let data = pngData(image) else {
                failed("rendering the \(target == .appIcon ? "app icon" : "track") tile", now: now)
                return nil
            }
            png = data
            // The generic stand-in caches under its own key; only a track
            // tile drawn without its art stays out of the cache.
            if !(fallback && target != .appIcon) {
                if !cache.store(data, at: cached) { log("error writing cache file \(cached)") }
                let removed = cache.prune()
                if removed > 0 { log("cache pruned \(removed) old tiles") }
            }
        }
        guard let png, png.count <= maxImageBytes else {
            failed("tile is larger than the host's \(maxImageBytes) byte limit", now: now)
            return nil
        }
        return (png, fallback, source)
    }

    func mosaicGap(size: Int) -> Int {
        Int((Double(size) * settings.gapPercent / 100).rounded())
    }

    /// The nine keys of a mosaic page, in reading order, cached per key like
    /// tiles. With no art to cut (Spotify not running, nothing loaded, or the
    /// download failed) the center key shows the full tile and the rest are
    /// black.
    func mosaicFace(_ display: Display, group: MosaicGroup, now: Date) -> (pngs: [Data], fallback: Bool, source: String)? {
        if case .track(let track) = display, !track.artworkURL.isEmpty {
            let key = TrackKey(id: track.id, playing: track.playing)
            let gap = mosaicGap(size: group.size)
            let paths = gridSlots.indices.map {
                cache.mosaicPath(for: key, art: track.artworkURL, gap: gap, position: $0, size: group.size)
            }
            let loaded = paths.compactMap { cache.load($0) }
            if loaded.count == paths.count { return (loaded, false, "cached") }
            if let art = artwork(for: track.artworkURL, now: now) {
                let pngs = renderMosaic(art, paused: !track.playing, size: group.size, gap: gap)?.compactMap(pngData) ?? []
                guard pngs.count == paths.count else {
                    failed("rendering the mosaic", now: now)
                    return nil
                }
                guard pngs.allSatisfy({ $0.count <= maxImageBytes }) else {
                    failed("mosaic tile is larger than the host's \(maxImageBytes) byte limit", now: now)
                    return nil
                }
                for (png, path) in zip(pngs, paths) where !cache.store(png, at: path) {
                    log("error writing cache file \(path)")
                }
                let removed = cache.prune()
                if removed > 0 { log("cache pruned \(removed) old tiles") }
                return (pngs, false, "rendered")
            }
        }
        guard let center = face(display, size: group.size, now: now) else { return nil }
        guard let image = renderBlackTile(size: group.size), let black = pngData(image) else {
            failed("rendering the mosaic", now: now)
            return nil
        }
        var pngs = Array(repeating: black, count: gridSlots.count)
        pngs[centerIndex] = center.png
        return (pngs, center.fallback, center.source)
    }

    /// The change path: renders (or loads) the face for every bound key and
    /// sends it. A new track on a mosaic already showing is revealed key by
    /// key; everything else is sent at once.
    func show(_ display: Display, quiet: Bool, now: Date) {
        let target: Shown
        switch display {
        case .track(let track): target = .track(TrackKey(id: track.id, playing: track.playing))
        case .appIcon: target = .appIcon
        }
        var single: Data?
        var fallback = false
        var source = "cached"
        if !perKey || !singles.isEmpty {
            guard let face = face(display, size: size, now: now) else { return }
            (single, fallback, source) = (face.png, face.fallback, face.source)
        }
        var tiles: [MosaicGroup: [Data]] = [:]
        for group in mosaics {
            guard let face = mosaicFace(display, group: group, now: now) else { return }
            tiles[group] = face.pngs
            fallback = fallback || face.fallback
            if single == nil { source = face.source }
        }
        var reveal: Set<MosaicGroup> = []
        if case .track(let old)? = shownDisplay, case .track(let new) = display,
           old.id != new.id || old.artworkURL != new.artworkURL {
            reveal = Set(shownTiles.keys)
        }
        paint(single: single, tiles: tiles, reveal: reveal)
        let artRecovered = shownIsFallback && !fallback
        succeeded()
        shown = target
        shownDisplay = display
        shownPNG = single
        shownTiles = tiles
        shownIsFallback = fallback
        if !quiet || artRecovered {
            switch display {
            case .track(let track):
                let state = track.playing ? "playing" : "paused"
                log("show \(state): \(track.title) / \(track.artist) (\(source))")
            case .appIcon:
                log("show app icon (\(source))")
            }
        }
    }

    // MARK: Control keys

    /// The page background and accent for control keys at `size`, kept per
    /// cover, paused state, and size.
    func palette(_ display: Display, size: Int, now: Date) -> (key: String, canvas: CGImage, accent: CGColor)? {
        var art: CGImage?
        var seed: String?
        var name = "none"
        var paused = false
        if case .track(let track) = display {
            art = artwork(for: track.artworkURL, now: now)
            seed = track.title + "\n" + track.artist
            name = art != nil ? "art \(track.artworkURL)" : "seed \(track.title)\n\(track.artist)"
            paused = !track.playing
        }
        let gap = mosaicGap(size: size)
        let key = "\(name)\n\(paused)\n\(size)\n\(gap)"
        if let hit = palettes[key] { return (key, hit.canvas, hit.accent) }
        guard let made = renderControlBackground(art: art, seed: seed, paused: paused, side: 3 * size + 2 * gap) else {
            failed("rendering the control background", now: now)
            return nil
        }
        if palettes.count >= 8 { palettes = [:] }
        palettes[key] = made
        return (key, made.canvas, made.accent)
    }

    func controlState(_ role: Role, _ display: Display) -> ControlState {
        var state = ControlState(role: role)
        var track: Track?
        if case .track(let loaded) = display { track = loaded }
        if role.isText { state.text = tileText(role, track) }
        guard let track else { return state }
        state.enabled = true
        state.on = role == .shuffle ? track.shuffling : role == .repeat ? track.repeating : false
        if role == .time {
            state.elapsed = Int(track.position)
            state.duration = track.duration
        }
        return state
    }

    /// Sends `png` to a title or control key and remembers it under `key`.
    func sendRole(device: String, slot: String, key: String, png: Data) {
        roleFaces[device + "\n" + slot] = (key, png)
        sendImage(png, device: device, slot: slot)
    }

    /// True when the key already shows `key`; with `force` it is sent again.
    func roleUnchanged(device: String, slot: String, key: String, force: Bool) -> Bool {
        guard let last = roleFaces[device + "\n" + slot], last.key == key else { return false }
        if force { sendImage(last.png, device: device, slot: slot) }
        return true
    }

    /// Brings every title and control key in line with `display`, rendering
    /// and sending only the keys whose face changed (every key when `force`).
    /// Static control faces are cached like tiles; the time and banner frames
    /// are not.
    func updateRoles(_ display: Display, force: Bool, now: Date) {
        roleDisplay = display
        var scrolling = false
        for control in controls {
            guard let palette = palette(display, size: control.size, now: now) else { return }
            let state = controlState(control.role, display)
            let gap = mosaicGap(size: control.size)
            let key = "\(state.key)\n\(palette.key)\n\(control.index)"
            if roleUnchanged(device: control.device, slot: control.slot, key: key, force: force) { continue }
            let cached = control.role == .time ? nil : cache.controlPath(key, size: control.size)
            var png = cached.flatMap { cache.load($0) }
            if png == nil {
                guard let background = pageCrop(palette.canvas, index: control.index, size: control.size, gap: gap),
                      let image = renderControl(state, background: background, accent: palette.accent, size: control.size),
                      let data = pngData(image) else {
                    failed("rendering the \(control.role.rawValue) key", now: now)
                    return
                }
                png = data
                if let cached {
                    if !cache.store(data, at: cached) { log("error writing cache file \(cached)") }
                    let removed = cache.prune()
                    if removed > 0 { log("cache pruned \(removed) old tiles") }
                }
            }
            if let png { sendRole(device: control.device, slot: control.slot, key: key, png: png) }
        }
        for banner in banners {
            guard let palette = palette(display, size: banner.size, now: now) else { return }
            var title = "Nothing playing"
            var artist = ""
            var playing = false
            if case .track(let track) = display {
                title = cleaned(track.title).isEmpty ? "Unknown track" : cleaned(track.title)
                artist = cleaned(track.artist)
                playing = track.playing
            }
            let gap = mosaicGap(size: banner.size)
            let k = CGFloat(banner.size) / 118
            let available = CGFloat(banner.count * banner.size) - 24 * k
            let distance = fitTitle(title, width: available, k: k).width - available
            var offset: CGFloat?
            if distance > 0 && playing && settings.bannerFps > 0 {
                let start = scrollStarts[banner].flatMap { $0.title == title ? $0.at : nil } ?? now
                scrollStarts[banner] = (title, start)
                offset = scrollOffset(elapsed: now.timeIntervalSince(start), distance: distance, speed: scrollSpeed * k).rounded()
                scrolling = true
            }
            let key = "\(title)\n\(artist)\n\(palette.key)\n\(offset.map { "\($0)" } ?? "still")\n\(banner.first) \(banner.count)"
            let unchanged = banner.slots.enumerated().map { i, slot in
                roleFaces[banner.device + "\n" + slot]?.key == "\(key)\n\(i)"
            }
            if !unchanged.contains(false) {
                for slot in banner.slots where force {
                    if let last = roleFaces[banner.device + "\n" + slot] { sendImage(last.png, device: banner.device, slot: slot) }
                }
                continue
            }
            guard let background = pageCrop(palette.canvas, index: banner.first, count: banner.count, size: banner.size, gap: gap),
                  let canvas = renderBanner(title: title, artist: artist, background: background, size: banner.size,
                                            count: banner.count, gap: gap, offset: offset)
            else {
                failed("rendering the title banner", now: now)
                return
            }
            for (i, slot) in banner.slots.enumerated() {
                let rect = CGRect(x: i * banner.size, y: 0, width: banner.size, height: banner.size)
                guard let tile = canvas.cropping(to: rect), let png = pngData(tile) else {
                    failed("rendering the title banner", now: now)
                    return
                }
                // A key whose part of the banner did not change is not sent.
                if !force, roleFaces[banner.device + "\n" + slot]?.png == png {
                    roleFaces[banner.device + "\n" + slot] = ("\(key)\n\(i)", png)
                    continue
                }
                sendRole(device: banner.device, slot: slot, key: "\(key)\n\(i)", png: png)
            }
        }
        setBannerTimer(scrolling)
    }

    /// Redraws the banners `banner_fps` times a second while one scrolls.
    func setBannerTimer(_ on: Bool) {
        if on, bannerTimer == nil {
            let timer = Timer(timeInterval: 1 / settings.bannerFps, repeats: true) { [unowned self] _ in
                guard let display = self.roleDisplay else { return }
                self.updateRoles(display, force: false, now: Date())
            }
            RunLoop.main.add(timer, forMode: .common)
            bannerTimer = timer
        } else if !on {
            bannerTimer?.invalidate()
            bannerTimer = nil
        }
    }
}

// MARK: - Input

/// Reads host messages on a background thread and hands them to the main
/// queue. `ready` and `shutdown` are answered here, so a main queue busy with
/// a slow Spotify read can never delay either.
func startInput(controller: Controller, output: Output) {
    let thread = Thread {
        var helloSeen = false
        while let line = readLine(strippingNewline: true) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let message = object as? [String: Any],
                  let type = message["type"] as? String
            else {
                log("ignoring a line that is not a protocol message (\(line.utf8.count) bytes)")
                continue
            }
            switch type {
            case "shutdown":
                log("shutdown")
                output.exitNow(0)
            case "hello":
                guard !helloSeen else {
                    log("ignoring a second hello")
                    continue
                }
                helloSeen = true
                output.ready()
                DispatchQueue.main.async { controller.hello(message) }
            default:
                guard helloSeen else {
                    log("ignoring \(type) before hello")
                    continue
                }
                DispatchQueue.main.async { controller.handle(type, message) }
            }
        }
        log("stdin closed, exiting")
        output.exitNow(0)
    }
    thread.name = "protocol-input"
    thread.start()
}

// MARK: - Preview

struct PreviewConfig {
    var output: String?
    var title: String?
    var artist: String?
    var album: String?
    var artwork: String?
    var paused = false
    var appIcon = false
    var size = defaultSize
    var role: Role?
    var slot = "gridMiddle"
    var on = false
    var position = 0.0
    var duration = 0.0
}

let usage = """
usage: spotify-module
       spotify-module --preview OUT.png [--title T --artist A
                      [--artwork FILE_OR_URL] [--paused] | --app-icon] [--size PIXELS]
                      [--role ROLE [--slot SLOT] [--album A] [--on] [--position S] [--duration S]]

  With no arguments it runs as an OpenLogi key module, speaking the module
  protocol on stdin and stdout; OpenLogi starts it that way.

  --preview  render one tile to OUT.png and exit; touches neither Spotify
             nor OpenLogi. With --app-icon it renders the Spotify-not-running
             tile; without --title or --app-icon, the generic stand-in.
  --role     render a control key instead (shuffle, repeat, time, previous,
             next, song, artist, album) as it looks at grid SLOT (default
             gridMiddle) of a control page, or with title the banner across
             the top row. Without --title or --artwork it is drawn as with
             nothing loaded.
"""

func runPreview(_ args: [String]) -> Never {
    var config = PreviewConfig()
    var index = 0
    func value(_ flag: String) -> String {
        index += 1
        guard index < args.count else { die("\(flag) needs a value\n\(usage)") }
        return args[index]
    }
    while index < args.count {
        let flag = args[index]
        switch flag {
        case "--preview": config.output = value(flag)
        case "--title": config.title = value(flag)
        case "--artist": config.artist = value(flag)
        case "--album": config.album = value(flag)
        case "--artwork": config.artwork = value(flag)
        case "--paused": config.paused = true
        case "--app-icon": config.appIcon = true
        case "--role":
            guard let role = Role(rawValue: value(flag)), role != .art else { die("--role must be a control role\n\(usage)") }
            config.role = role
        case "--slot":
            config.slot = value(flag)
            guard gridSlots.contains(config.slot) else { die("--slot must be a grid slot such as gridMiddle") }
        case "--on": config.on = true
        case "--position", "--duration":
            guard let seconds = Double(value(flag)), seconds >= 0 else { die("\(flag) must be a number of seconds") }
            if flag == "--position" { config.position = seconds } else { config.duration = seconds }
        case "--size":
            guard let pixels = Int(value(flag)), sizeRange.contains(pixels) else {
                die("--size must be a whole number of pixels from \(sizeRange.lowerBound) to \(sizeRange.upperBound)")
            }
            config.size = pixels
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            die("unknown argument \(flag)\n\(usage)")
        }
        index += 1
    }
    guard let output = config.output else { die("--preview OUT.png is required\n\(usage)") }
    var art: CGImage?
    if let location = config.artwork {
        art = loadArtwork(location, maxPixels: config.size * 3)
        if art == nil { log("artwork could not be loaded, using plain tile: \(location)") }
    }
    let image: CGImage?
    if let role = config.role {
        let loaded = config.title != nil || config.artwork != nil
        let gap = Int((Double(config.size) * defaultGapPercent / 100).rounded())
        let seed = loaded ? (config.title ?? "") + "\n" + (config.artist ?? "") : nil
        let index = role == .title ? 0 : gridSlots.firstIndex(of: config.slot)!
        guard let palette = renderControlBackground(art: art, seed: seed, paused: config.paused && loaded,
                                                    side: 3 * config.size + 2 * gap),
              let background = pageCrop(palette.canvas, index: index, count: role == .title ? 3 : 1, size: config.size, gap: gap)
        else { die("could not render the control background") }
        if role == .title {
            image = renderBanner(title: loaded ? config.title ?? "Unknown track" : "Nothing playing",
                                 artist: config.artist ?? "", background: background, size: config.size,
                                 count: 3, gap: gap, offset: nil)
        } else {
            var state = ControlState(role: role)
            state.enabled = loaded
            state.on = config.on
            state.elapsed = Int(config.position)
            state.duration = config.duration
            if role.isText {
                state.text = tileText(role, loaded ? Track(id: "", title: config.title ?? "", artist: config.artist ?? "",
                                                           artworkURL: "", playing: !config.paused, album: config.album ?? "") : nil)
            }
            image = renderControl(state, background: background, accent: palette.accent, size: config.size)
        }
    } else if let title = config.title {
        image = renderTile(Tile(title: title, artist: config.artist ?? "", art: art, paused: config.paused),
                           size: config.size)
    } else if config.appIcon, let icon = renderAppIconTile(size: config.size) {
        image = icon
    } else {
        if config.appIcon { log("Spotify's app icon is unavailable, using the generic tile") }
        image = renderGenericTile(size: config.size)
    }
    guard let image, let data = pngData(image), FileManager.default.createFile(atPath: output, contents: data) else {
        die("could not render or write \(output)")
    }
    print(output)
    exit(0)
}

// MARK: - Main

let arguments = Array(CommandLine.arguments.dropFirst())
let cacheOverride = ProcessInfo.processInfo.environment["SPOTIFY_MODULE_CACHE_DIR"].flatMap { $0.isEmpty ? nil : $0 }

#if FAKE_SPOTIFY
// Test build only (build.sh --test): tests/FakeSpotify.swift supplies these.
if arguments == ["--self-test"] { runSelfTest() }
let backend: SpotifyBackend = FakeSpotify()
let reconcileInterval = FakeSpotify.reconcileInterval
#else
let backend: SpotifyBackend = SpotifyReader()
let reconcileInterval: TimeInterval = 30
#endif

if !arguments.isEmpty { runPreview(arguments) }

// The host closing our stdout must surface as a write error, not a SIGPIPE.
signal(SIGPIPE, SIG_IGN)
let output = Output()
let controller = Controller(backend: backend, cache: RenderCache(directory: cacheOverride),
                            output: output, reconcileInterval: reconcileInterval)
startInput(controller: controller, output: output)
RunLoop.main.run()
