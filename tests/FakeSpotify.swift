// Test build only (zsh build.sh --test OUT): a stand-in for Spotify, so the
// module can be driven end to end without touching the real app. Never part
// of the shipped binary.
//
// State lives in $FAKE_SPOTIFY_DIR/state.json, which tests edit:
//   {"installed": true, "running": true, "state": "playing" | "paused" | "stopped",
//    "id": "...", "name": "...", "artist": "...", "artwork": "/path/or/url",
//    "plays_needed": 3, "read_error": "message",
//    "shuffling": false, "repeating": false, "position": 12.5, "duration": 200000}
// `position` is in seconds and advances with the clock from the file's last
// write while playing; `duration` is in milliseconds, as Spotify reports it.
// Every call is appended to $FAKE_SPOTIFY_DIR/calls.log, one word per line.
// A change to state.json stands in for Spotify's playback notification.

import Foundation

final class FakeSpotify: SpotifyBackend {
    // Watched for launch and quit; no real app has this id.
    let bundleID = "com.typ.openlogi.spotify.fake-target"
    let notification = Notification.Name("com.typ.openlogi.spotify.fake.PlaybackStateChanged")

    static var reconcileInterval: TimeInterval {
        Double(ProcessInfo.processInfo.environment["FAKE_SPOTIFY_RECONCILE"] ?? "") ?? 30
    }

    private let dir: String
    private var plays = 0
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

    func isRunning() -> Bool { load()["running"] as? Bool ?? false }

    /// The position now: the stored one, plus the time since the file was
    /// written while playing.
    private func position(_ state: [String: Any]) -> Double {
        let stored = (state["position"] as? NSNumber)?.doubleValue ?? 0
        guard state["state"] as? String == "playing", let written = modified() else { return stored }
        return stored + max(0, Date().timeIntervalSince(written))
    }

    func read(extended: Bool) -> SpotifyState {
        record("read")
        let state = load()
        guard state["running"] as? Bool ?? false else { return .notRunning }
        if let message = state["read_error"] as? String { return .failed(message) }
        let player = state["state"] as? String ?? "stopped"
        let id = state["id"] as? String ?? ""
        guard player != "stopped", !id.isEmpty else { return .idle }
        var track = Track(id: id, title: state["name"] as? String ?? "", artist: state["artist"] as? String ?? "",
                          artworkURL: state["artwork"] as? String ?? "", playing: player == "playing")
        if extended {
            track.shuffling = state["shuffling"] as? Bool ?? false
            track.repeating = state["repeating"] as? Bool ?? false
            track.position = position(state)
            track.duration = ((state["duration"] as? NSNumber)?.doubleValue ?? 0) / 1000
        }
        return .track(track)
    }

    func playPause() -> CommandOutcome {
        record("playpause")
        var state = load()
        guard state["running"] as? Bool ?? false else { return .notRunning }
        state["position"] = position(state)
        state["state"] = (state["state"] as? String) == "playing" ? "paused" : "playing"
        save(state)
        return .done
    }

    func command(_ command: PlayerCommand) -> CommandOutcome {
        record(command.rawValue.replacingOccurrences(of: " ", with: "-"))
        var state = load()
        guard state["running"] as? Bool ?? false else { return .notRunning }
        switch command {
        case .toggleShuffle: state["shuffling"] = !(state["shuffling"] as? Bool ?? false)
        case .toggleRepeat: state["repeating"] = !(state["repeating"] as? Bool ?? false)
        case .seekBack: state["position"] = max(0, position(state) - 15)
        case .previous, .next: return .done
        }
        save(state)
        return .done
    }

    func launch() -> CommandOutcome {
        record("launch")
        var state = load()
        state["running"] = true
        save(state)
        plays = 0
        return .done
    }

    func tryPlay() -> Bool {
        record("play")
        var state = load()
        plays += 1
        guard plays >= state["plays_needed"] as? Int ?? 1 else { return false }
        state["state"] = "playing"
        save(state)
        return true
    }
}

/// Checks the Script wrapper with scripts that need no app, so no Automation
/// prompt can appear: a -1712 drops the compiled script, any other error
/// keeps it. Prints PASS or FAIL lines and exits non-zero on any failure.
func runSelfTest() -> Never {
    var failures = 0
    func check(_ name: String, _ condition: Bool) {
        print("\(condition ? "PASS" : "FAIL") \(name)")
        if !condition { failures += 1 }
    }
    let timeout = Script("error \"timed out\" number -1712")
    _ = timeout.run()
    _ = timeout.run()
    _ = timeout.run()
    check("a -1712 recompiles before the next run (3 runs, 3 compiles)", timeout.compiles == 3)
    if case .failure(let error) = timeout.run() {
        check("the -1712 error number is reported", error.number == -1712)
    } else {
        check("the -1712 error number is reported", false)
    }

    let other = Script("error \"something else\" number -2700")
    _ = other.run()
    _ = other.run()
    check("another error keeps the compiled script (2 runs, 1 compile)", other.compiles == 1)

    let ok = Script("return \"fine\"")
    _ = ok.run()
    if case .success(let result) = ok.run() {
        check("a good script runs and is compiled once", result.stringValue == "fine" && ok.compiles == 1)
    } else {
        check("a good script runs and is compiled once", false)
    }

    let permission = ScriptError(number: -1743, message: "x")
    check("-1743 explains the Automation setting", permission.description.contains("Automation"))
    exit(failures == 0 ? 0 : 1)
}
