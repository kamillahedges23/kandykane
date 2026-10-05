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
        guard let url = KandyKaneConfig.liveMarkerURL else { return }
        if live {
            try? Data().write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static var isLive: Bool {
        guard let url = KandyKaneConfig.liveMarkerURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
