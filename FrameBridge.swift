import Foundation

enum FrameBridge {

    static func write(_ jpegData: Data) {
        guard let url = KandyKaneConfig.frameURL else {
            NSLog("FrameBridge: no shared container for \(KandyKaneConfig.appGroup). Check the App Group entitlement.")
            return
        }
        do {
            try jpegData.write(to: url, options: .atomic)
        } catch {
            NSLog("FrameBridge write failed: \(error.localizedDescription)")
        }
    }

    static func readLatest() -> Data? {
        guard let url = KandyKaneConfig.frameURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    // Read the file's own modification date instead of a UserDefaults value.
    // UserDefaults written by the extension can reach the app late, so the
    // app would miss frames. The file in the shared container is the source
    // of truth.
    static var latestTimestamp: TimeInterval {
        guard let url = KandyKaneConfig.frameURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else {
            return 0
        }
        return modified.timeIntervalSince1970
    }

    static func hasNewFrame(since previous: TimeInterval) -> Bool {
        latestTimestamp > previous
    }

    static func clear() {
        guard let url = KandyKaneConfig.frameURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // ReplayKit only delivers frames while the screen changes, so frame
    // timestamps can't tell the app whether a broadcast is running. The
    // extension keeps a marker file for that instead.
    static func setLive(_ live: Bool) {
        setMarker(KandyKaneConfig.liveMarkerURL, live)
    }

    static var isLive: Bool {
        markerExists(KandyKaneConfig.liveMarkerURL)
    }

    // Refreshed by the app while it's on screen, so the extension doesn't pay
    // to scan the app's own preview. A stale marker (say, after the app
    // crashed) is ignored.
    static func setAppVisible(_ visible: Bool) {
        setMarker(KandyKaneConfig.appVisibleMarkerURL, visible)
    }

    static var isAppVisible: Bool {
        guard let url = KandyKaneConfig.appVisibleMarkerURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else {
            return false
        }
        return Date().timeIntervalSince(modified) < 3
    }

    private static func setMarker(_ url: URL?, _ on: Bool) {
        guard let url else { return }
        if on {
            try? Data().write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func markerExists(_ url: URL?) -> Bool {
        guard let url else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}

// What the extension is doing and the answers it has given this broadcast.
// The extension writes it; the app only reads it.
struct SessionSnapshot: Codable {
    struct Answer: Codable {
        let question: String
        let answer: String
    }

    var status = "Watching"
    var error: String?
    var answers: [Answer] = []
}

enum SessionState {

    static func write(_ snapshot: SessionSnapshot) {
        guard let url = KandyKaneConfig.sessionURL,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func read() -> SessionSnapshot? {
        guard let url = KandyKaneConfig.sessionURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    static func clear() {
        guard let url = KandyKaneConfig.sessionURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
