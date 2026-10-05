import Foundation
import CoreGraphics

enum KandyKaneConfig {
    static let appGroup = "group.kandykane"
    static let frameFilename = "latest-frame.jpg"
    static let liveMarkerFilename = "broadcast-live"
    // How often the extension writes a frame for the live preview.
    static let previewInterval: TimeInterval = 1.0
    // Minimum time between screenshots sent to Claude.
    static let analysisInterval: TimeInterval = 8.0
    static let maxFrameDimension: CGFloat = 1024
    static let jpegQuality: CGFloat = 0.6

    static var anthropicAPIKey: String {
        KandyKaneSecrets.anthropicAPIKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var sharedContainerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        )
    }

    static var frameURL: URL? {
        sharedContainerURL?.appendingPathComponent(frameFilename)
    }

    static var liveMarkerURL: URL? {
        sharedContainerURL?.appendingPathComponent(liveMarkerFilename)
    }
}
