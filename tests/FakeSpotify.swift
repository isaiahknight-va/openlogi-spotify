// Test build only (zsh build.sh --test OUT): a stand-in for the Spotify
// process. The module's real Apple event code builds and sends every event
// as it would to Spotify, and this answers it from a file, so the module can
// be driven end to end without touching the real app. Never part of the
// shipped binary.
//
// State lives in $FAKE_SPOTIFY_DIR/state.json, which tests edit:
//   {"installed": true, "running": true, "pid": 4242, "quitting": false, "quit_after": 3,
//    "exited": false, "silent": false,
//    "state": "playing" | "paused" | "stopped",
//    "id": "...", "name": "...", "artist": "...", "artwork": "/path/or/url",
//    "plays_needed": 3, "read_error": "message",
//    "shuffling": false, "repeating": false, "position": 12.5, "duration": 200000,
//    "album": "...", "dead_uris": ["..."], "uri_errors": ["..."]}
// `quitting` is a Spotify on its way out: still listed as running, but every
// event to it fails with -609, as a quitting app's do; `quit_after` makes it
// start quitting after that many more answered events (mid-read). An event to
// any pid but `pid` fails with -600, and so does every event once `exited`
// is set: Spotify is gone, though the running list still shows it, as macOS's
// does for a moment after an app exits. `silent` keeps that write of the file
// from standing in for a playback notification. `play track` with a URI in `dead_uris` is
// taken but plays nothing, as Spotify does with a URI it cannot play; one in
// `uri_errors` fails. Any other URI plays its first track, `liked:<uri>`, once
// `plays_needed` plays have been asked for since the last launch.
// `position` is in seconds and advances with the clock from the file's last
// write while playing; `duration` is in milliseconds, as Spotify reports it.
// Calls are appended to $FAKE_SPOTIFY_DIR/calls.log, one word per line: `read`
// for each player state read, `album`, `playpause`, `play`, `shuffle`,
// `repeat`, `seek-back`, `next-track`, `previous-track`, `play-uri:<uri>`,
// `launch` (Spotify opened), and `refused` for an event that failed because
// Spotify was quitting or gone.
// A change to state.json stands in for Spotify's playback notification.

import AppKit
import CoreText
import Foundation

/// Four letters back from a four-char code.
func fourLetters(_ code: FourCharCode) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .macOSRoman) ?? "????"
}

final class FakeSpotify: SpotifyProcess {
    // Watched for launch and quit; no real app has this id.
    let bundleID = "com.typ.openlogi.spotify.fake-target"
    let notification = Notification.Name("com.typ.openlogi.spotify.fake.PlaybackStateChanged")

    static var reconcileInterval: TimeInterval {
        Double(ProcessInfo.processInfo.environment["FAKE_SPOTIFY_RECONCILE"] ?? "") ?? 30
    }

    private let dir: String
    private var plays = 0
    private var answersLeft: Int?
    private var lastModified: Date?
    private var poll: Timer?

    init() {
        guard let dir = ProcessInfo.processInfo.environment["FAKE_SPOTIFY_DIR"], !dir.isEmpty else {
            die("FAKE_SPOTIFY_DIR is not set")
        }
        self.dir = dir
        lastModified = modified()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [unowned self] _ in
            let now = self.modified()
            if now != self.lastModified {
                self.lastModified = now
                let state = self.load()
                self.answersLeft = state["quit_after"] as? Int
                if state["silent"] as? Bool ?? false { return }
                DistributedNotificationCenter.default().postNotificationName(
                    self.notification, object: nil, userInfo: nil, deliverImmediately: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private var statePath: String { (dir as NSString).appendingPathComponent("state.json") }

    private func modified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: statePath))?[.modificationDate] as? Date
    }

    private func load() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: statePath),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private func save(_ state: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        FileManager.default.createFile(atPath: statePath, contents: data)
        lastModified = modified()
    }

    private func record(_ call: String) {
        let path = (dir as NSString).appendingPathComponent("calls.log")
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((call + "\n").utf8))
        handle.closeFile()
    }

    func isInstalled() -> Bool { load()["installed"] as? Bool ?? true }

    func running() -> (pid: pid_t, launched: Bool)? {
        let state = load()
        guard state["running"] as? Bool ?? false else { return nil }
        return (pid_t(state["pid"] as? Int ?? 4242), true)
    }

    /// The position now: the stored one, plus the time since the file was
    /// written while playing.
    private func position(_ state: [String: Any]) -> Double {
        let stored = (state["position"] as? NSNumber)?.doubleValue ?? 0
        guard state["state"] as? String == "playing", let written = modified() else { return stored }
        return stored + max(0, Date().timeIntervalSince(written))
    }

    /// The property a specifier the module built names, and whether it is the
    /// current track's; nil when the specifier is not one Spotify would take.
    private func property(_ specifier: NSAppleEventDescriptor?) -> (code: String, ofTrack: Bool)? {
        guard let specifier, specifier.descriptorType == fourCC("obj "),
              specifier.forKeyword(fourCC("want"))?.typeCodeValue == fourCC("prop"),
              specifier.forKeyword(fourCC("form"))?.enumCodeValue == fourCC("prop"),
              let code = specifier.forKeyword(fourCC("seld"))?.typeCodeValue,
              let from = specifier.forKeyword(fourCC("from")) else { return nil }
        if from.descriptorType == typeNull { return (fourLetters(code), false) }
        guard property(from).map({ $0.code == "pTrk" && !$0.ofTrack }) ?? false else { return nil }
        return (fourLetters(code), true)
    }

    private func reply(_ value: NSAppleEventDescriptor? = nil) -> NSAppleEventDescriptor {
        let answer = NSAppleEventDescriptor.appleEvent(
            withEventClass: fourCC("aevt"), eventID: fourCC("ansr"), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let value { answer.setParam(value, forKeyword: directObject) }
        return answer
    }

    /// Answers one event the way Spotify would, from the state file. An event
    /// to a pid that is not the running one fails with -600; one to a Spotify
    /// that is quitting (`quitting`, or `quit_after` events answered since the
    /// file changed) fails with -609. Neither ever starts anything.
    func send(_ event: NSAppleEventDescriptor, timeout: TimeInterval) throws -> NSAppleEventDescriptor {
        var state = load()
        // The address is a 'kpid' descriptor holding the pid, which does not
        // coerce to an integer.
        let target = event.attributeDescriptor(forKeyword: fourCC("addr")).flatMap { address -> Int32? in
            address.descriptorType == fourCC("kpid") && address.data.count == 4
                ? address.data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) } : nil
        }
        guard state["running"] as? Bool ?? false, !(state["exited"] as? Bool ?? false),
              target == Int32(state["pid"] as? Int ?? 4242) else {
            record("refused")
            throw EventError(number: -600, message: "no such process")
        }
        if state["quitting"] as? Bool ?? false || answersLeft == 0 {
            record("refused")
            throw EventError(number: -609, message: "connection invalid")
        }
        if let left = answersLeft { answersLeft = left - 1 }
        let direct = event.paramDescriptor(forKeyword: directObject)
        let player = state["state"] as? String ?? "stopped"
        switch (fourLetters(event.eventClass), fourLetters(event.eventID)) {
        case ("core", "getd"):
            guard let (code, ofTrack) = property(direct) else { throw EventError(number: -1728, message: "no such object") }
            if ofTrack {
                guard player != "stopped", !(state["id"] as? String ?? "").isEmpty else {
                    throw EventError(number: -1728, message: "no current track")
                }
                switch code {
                case "ID  ": return reply(NSAppleEventDescriptor(string: state["id"] as? String ?? ""))
                case "pnam": return reply(NSAppleEventDescriptor(string: state["name"] as? String ?? ""))
                case "pArt": return reply(NSAppleEventDescriptor(string: state["artist"] as? String ?? ""))
                case "aUrl": return reply(NSAppleEventDescriptor(string: state["artwork"] as? String ?? ""))
                case "pAlb":
                    record("album")
                    return reply(NSAppleEventDescriptor(string: state["album"] as? String ?? ""))
                case "pDur": return reply(NSAppleEventDescriptor(int32: Int32((state["duration"] as? NSNumber)?.intValue ?? 0)))
                default: break
                }
            } else {
                switch code {
                case "pPlS":
                    record("read")
                    if let message = state["read_error"] as? String { throw EventError(number: -1712, message: message) }
                    let codes = ["playing": "kPSP", "paused": "kPSp"]
                    return reply(NSAppleEventDescriptor(enumCode: fourCC(codes[player] ?? "kPSS")))
                case "pShu": return reply(NSAppleEventDescriptor(boolean: state["shuffling"] as? Bool ?? false))
                case "pRep": return reply(NSAppleEventDescriptor(boolean: state["repeating"] as? Bool ?? false))
                case "pPos": return reply(NSAppleEventDescriptor(double: position(state)))
                default: break
                }
            }
            throw EventError(number: -1728, message: "no such property \(code)")
        case ("core", "setd"):
            guard let (code, ofTrack) = property(direct), !ofTrack,
                  let value = event.paramDescriptor(forKeyword: fourCC("data")) else {
                throw EventError(number: -10006, message: "cannot set that")
            }
            switch code {
            case "pShu":
                record("shuffle")
                state["shuffling"] = value.booleanValue
            case "pRep":
                record("repeat")
                state["repeating"] = value.booleanValue
            case "pPos":
                record("seek-back")
                state["position"] = value.doubleValue
            default: throw EventError(number: -10006, message: "cannot set \(code)")
            }
            save(state)
            return reply()
        case ("spfy", "PlPs"):
            record("playpause")
            state["position"] = position(state)
            state["state"] = player == "playing" ? "paused" : "playing"
            save(state)
            return reply()
        case ("spfy", "Next"):
            record("next-track")
            return reply()
        case ("spfy", "Prev"):
            record("previous-track")
            return reply()
        case ("spfy", "Play"):
            record("play")
            plays += 1
            if plays >= state["plays_needed"] as? Int ?? 1 {
                state["state"] = "playing"
                save(state)
            }
            return reply()
        case ("spfy", "PCtx"):
            let uri = direct?.stringValue ?? ""
            record("play-uri:" + uri)
            if (state["uri_errors"] as? [String] ?? []).contains(uri) {
                throw EventError(number: -10000, message: "cannot play \(uri)")
            }
            plays += 1
            guard plays >= state["plays_needed"] as? Int ?? 1, !(state["dead_uris"] as? [String] ?? []).contains(uri) else {
                return reply()
            }
            state["state"] = "playing"
            state["id"] = "liked:" + uri
            state["name"] = "First Liked Song"
            state["position"] = 0
            save(state)
            return reply()
        default:
            throw EventError(number: -1708, message: "event not handled")
        }
    }

    func open() -> String? {
        record("launch")
        var state = load()
        state["running"] = true
        save(state)
        plays = 0
        return nil
    }
}

/// Checks that need neither Spotify nor OpenLogi. Prints PASS or FAIL lines
/// and exits non-zero on any failure.
func runSelfTest() -> Never {
    var failures = 0
    func check(_ name: String, _ condition: Bool) {
        print("\(condition ? "PASS" : "FAIL") \(name)")
        if !condition { failures += 1 }
    }
    let permission = EventError(number: -1743, message: "x")
    check("-1743 explains the Automation setting", permission.description.contains("Automation"))

    // The real send, to a process that has exited: it fails as gone, and
    // nothing is launched (no app is named, so none could be).
    let exited = Process()
    exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try? exited.run()
    exited.waitUntilExit()
    var gone = false
    do {
        _ = try RealSpotify().send(appleEvent("spfy", "PlPs", to: exited.processIdentifier), timeout: 2)
    } catch let error as EventError {
        gone = error.meansGone
    } catch {}
    check("an event to an exited process fails as gone", gone)

    let specifier = property("aUrl", of: property("pTrk"))
    check("a property specifier names its property and its container",
          specifier.descriptorType == fourCC("obj ")
          && specifier.forKeyword(fourCC("seld"))?.typeCodeValue == fourCC("aUrl")
          && specifier.forKeyword(fourCC("from"))?.forKeyword(fourCC("seld"))?.typeCodeValue == fourCC("pTrk")
          && specifier.forKeyword(fourCC("from"))?.forKeyword(fourCC("from"))?.descriptorType == typeNull)

    // The song, artist, and album keys' text at 118 px: 98 px inside the padding.
    let box = CGSize(width: 98, height: 98)
    func fit(_ text: String, _ weight: NSFont.Weight = .bold) -> (lines: [CTLine], font: CTFont, size: CGFloat, truncated: Bool) {
        fitText(text, weight: weight, color: white(1), box: box, k: 1)
    }
    let short = fit("Take a Walk")
    let long = fit("Golden Hour Drive Home")
    let stress = fit("Supercalifragilisticexpialidocious (From Mary Poppins Original Soundtrack)")
    let album = fit("Mary Poppins (Original Motion Picture Soundtrack / Deluxe Edition)", .medium)
    let all = [short, long, stress, album, fit("Walkin' On The Sun"), fit("Judah & the Lion", .semibold), fit("Gossamer", .medium)]
    check("text keys wrap to at most 3 lines", all.allSatisfy { !$0.lines.isEmpty && $0.lines.count <= 3 })
    check("text key lines fit inside the padding", all.allSatisfy { $0.lines.allSatisfy { visibleWidth($0) <= box.width } })
    check("a long title gets a smaller size than a short one", long.size < short.size && short.size <= 28 && long.size >= 15)
    check("a title that fits is not ellipsized", !short.truncated && !long.truncated)
    func endsInEllipsis(_ result: (lines: [CTLine], font: CTFont, size: CGFloat, truncated: Bool)) -> Bool {
        var ellipsis = CGGlyph(0)
        var character: UniChar = 0x2026
        guard let last = result.lines.last, CTFontGetGlyphsForCharacters(result.font, &character, &ellipsis, 1),
              let run = (CTLineGetGlyphRuns(last) as? [CTRun])?.last, CTRunGetGlyphCount(run) > 0 else { return false }
        var glyph = CGGlyph(0)
        CTRunGetGlyphs(run, CFRange(location: CTRunGetGlyphCount(run) - 1, length: 1), &glyph)
        return glyph == ellipsis
    }
    check("an over-long title is ellipsized at size 15",
          stress.truncated && album.truncated && stress.size == 15 && album.size == 15
          && stress.lines.count == 3 && album.lines.count == 3 && endsInEllipsis(stress) && endsInEllipsis(album)
          && !endsInEllipsis(short) && !endsInEllipsis(long))
    check("an empty text key has no lines", fit("").lines.isEmpty)

    // spotify_profile: every way to give a profile, and things that are not one.
    let accepted: [(String, String)] = [
        ("https://open.spotify.com/user/your-username?si=abc123", "your-username"),
        ("https://open.spotify.com/user/your-username/", "your-username"),
        ("http://open.spotify.com/user/test.user_1", "test.user_1"),
        ("open.spotify.com/user/your-username", "your-username"),
        ("https://open.spotify.com/intl-de/user/your-username?si=x", "your-username"),
        ("https://open.spotify.com/user/your-username#top", "your-username"),
        ("spotify:user:your-username", "your-username"),
        ("your-username", "your-username"),
        ("  test.user_1  ", "test.user_1"),
    ]
    check("spotify_profile accepts a link, a URI, or a bare name",
          accepted.allSatisfy { profileUser($0.0) == $0.1 })
    let rejected: [Any] = [
        "https://open.spotify.com/playlist/abc123DEF456",
        "https://open.spotify.com/track/xyz789GHI012?si=1",
        "spotify:user:your-username:playlist:abc",
        "https://example.com/user/your-username",
        "https://open.spotify.com/user/",
        "your user", "your\"user", "your'user", "", String(repeating: "a", count: 65), "not a link at all!", 42,
    ]
    check("spotify_profile rejects anything else", rejected.allSatisfy { profileUser($0) == nil })
    exit(failures == 0 ? 0 : 1)
}
