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

/// Everything the module asks of Spotify. The test build swaps in a fake.
protocol SpotifyBackend: AnyObject {
    /// The app whose launch and quit the module watches.
    var bundleID: String { get }
    /// Posted by the app on track changes and play/pause; only a wake-up.
    var notification: Notification.Name { get }
    func isInstalled() -> Bool
    func isRunning() -> Bool
    func read() -> SpotifyState
    func playPause() -> CommandOutcome
    func launch() -> CommandOutcome
    /// One `play`; true once the player reports playing.
    func tryPlay() -> Bool
}

// Every script below starts with an `is running` guard where a bare `tell`
// would launch Spotify, and carries a timeout so a busy or still-launching
// Spotify cannot hold the main queue for the default 2 minutes.
// Variable names avoid `st` and other words Spotify's dictionary reserves.
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
        return {stateText, trackID, trackName, trackArtist, artworkURL}
    end tell
  end timeout
end if
return {}
"""

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

    func read() -> SpotifyState {
        guard isRunning() else { return .notRunning }
        switch reader.run() {
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
            return .track(Track(id: id, title: item(3), artist: item(4), artworkURL: item(5), playing: state == "playing"))
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

/// All Spotify reads, presses, and renders run on the main queue, which is
/// serial, so they never overlap; NSAppleScript also wants the main thread.
final class Controller {
    let backend: SpotifyBackend
    let cache: RenderCache
    let output: Output
    let reconcileInterval: TimeInterval

    var slots: [Slot] = []
    var size = defaultSize
    var active: Bool { !slots.isEmpty }

    var shown = Shown.unknown
    var shownPNG: Data?
    var shownIsFallback = false
    var failures = 0
    var nextAttemptAt = Date.distantPast
    var lastReadError: String?
    var lastReadErrorAt = Date.distantPast
    var unknownTypes: Set<String> = []

    var artURL: String?
    var artImage: CGImage?
    var artFailedURL: String?
    var artFailedAt = Date.distantPast

    var launching = false
    var pending: DispatchWorkItem?
    var pendingAt = Date.distantFuture
    var pendingReconcile = false
    var observers: [(NotificationCenter, NSObjectProtocol)] = []
    var reconcileTimer: Timer?

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
        start()
    }

    func handle(_ type: String, _ message: [String: Any]) {
        switch type {
        case "keys": updateKeys(message["keys"])
        case "pressed": press()
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
        guard next != slots else { return }
        slots = next
        log("keys: \(slots.isEmpty ? "none" : slots.map { "\($0.slot)@\($0.size)" }.joined(separator: " "))")
        guard let first = slots.first else {
            deactivate()
            return
        }
        if !wasActive || first.size != size {
            // Nothing was tracked while idle, and a new size needs a new render.
            size = first.size
            shown = .unknown
            shownPNG = nil
        } else if let png = shownPNG {
            // A newly bound slot gets the current face at once.
            sendImage(png)
        }
        schedule(after: 0, reconcile: false)
    }

    /// No slots: no reads and no renders until slots arrive again.
    func deactivate() {
        pending?.cancel()
        pending = nil
        pendingAt = .distantFuture
        pendingReconcile = false
        shown = .unknown
        shownPNG = nil
    }

    func sendImage(_ png: Data) {
        output.send(["type": "image_all", "png": png.base64EncodedString()])
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
            self.apply(.appIcon, reconcile: false, now: Date())
        }
        let timer = Timer(timeInterval: reconcileInterval, repeats: true) { [unowned self] _ in
            self.schedule(after: 0, reconcile: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        reconcileTimer = timer
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
        switch backend.read() {
        case .failed(let message):
            // The same AppleScript error on every reconcile would flood the log.
            if message != lastReadError || now.timeIntervalSince(lastReadErrorAt) >= artRetryInterval {
                output.report("error", "reading Spotify: \(message)")
                lastReadError = message
                lastReadErrorAt = now
            }
        case .notRunning, .idle:
            lastReadError = nil
            apply(.appIcon, reconcile: reconcile, now: now)
        case .track(let track):
            lastReadError = nil
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
            if shownIsFallback || shownPNG == nil {
                show(display, quiet: true, now: now)
            } else if let png = shownPNG {
                sendImage(png)
            }
        }
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
        if url == artURL, let artImage { return artImage }
        if url == artFailedURL, now.timeIntervalSince(artFailedAt) < artRetryInterval { return nil }
        let image = loadArtwork(url, maxPixels: size * 3)
        if let image {
            artURL = url
            artImage = image
        } else {
            artFailedURL = url
            artFailedAt = now
            output.report("warn", "artwork download failed, using plain tile: \(url)")
        }
        return image
    }

    /// The change path: a cached tile is sent as is; otherwise the art is
    /// fetched and the tile rendered into the cache. A tile whose art failed
    /// to download is not cached, so a later reconcile or play retries it.
    /// When the app icon cannot be read, the generic tile stands in (cached
    /// under its own key) and counts as a fallback, so reconciles retry the icon.
    func show(_ display: Display, quiet: Bool, now: Date) {
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
                return
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
            return
        }
        sendImage(png)
        let artRecovered = shownIsFallback && !fallback
        succeeded()
        shown = target
        shownPNG = png
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
    var artwork: String?
    var paused = false
    var appIcon = false
    var size = defaultSize
}

let usage = """
usage: spotify-module
       spotify-module --preview OUT.png [--title T --artist A
                      [--artwork FILE_OR_URL] [--paused] | --app-icon] [--size PIXELS]

  With no arguments it runs as an OpenLogi key module, speaking the module
  protocol on stdin and stdout; OpenLogi starts it that way.

  --preview  render one tile to OUT.png and exit; touches neither Spotify
             nor OpenLogi. With --app-icon it renders the Spotify-not-running
             tile; without --title or --app-icon, the generic stand-in.
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
        case "--artwork": config.artwork = value(flag)
        case "--paused": config.paused = true
        case "--app-icon": config.appIcon = true
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
    let image: CGImage?
    if let title = config.title {
        var art: CGImage?
        if let location = config.artwork {
            art = loadArtwork(location, maxPixels: config.size * 3)
            if art == nil { log("artwork could not be loaded, using plain tile: \(location)") }
        }
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
