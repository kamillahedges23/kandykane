import Foundation

enum FrameBridge {

    private static let timestampKey = "latest_frame_timestamp"

    static func write(_ jpegData: Data) {
        guard let url = KandyKaneConfig.frameURL else { return }
        do {
            try jpegData.write(to: url, options: .atomic)
            KandyKaneConfig.sharedDefaults?.set(
                Date().timeIntervalSince1970,
                forKey: timestampKey
            )
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

    static var latestTimestamp: TimeInterval {
        KandyKaneConfig.sharedDefaults?.double(forKey: timestampKey) ?? 0
    }

    static func hasNewFrame(since previous: TimeInterval) -> Bool {
        latestTimestamp > previous
    }

    static func clear() {
        guard let url = KandyKaneConfig.frameURL else { return }
        try? FileManager.default.removeItem(at: url)
        KandyKaneConfig.sharedDefaults?.removeObject(forKey: timestampKey)
    }
}
