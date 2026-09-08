import Foundation
import CoreGraphics

enum KandyKaneConfig {
    static let appGroup = "group.kandykane"
    static let frameFilename = "latest-frame.jpg"
    static let captureInterval: TimeInterval = 8.0
    static let maxFrameDimension: CGFloat = 1024
    static let jpegQuality: CGFloat = 0.6
    static let apiKeyDefaultsKey = "anthropic_api_key"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    static var sharedContainerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        )
    }

    static var frameURL: URL? {
        sharedContainerURL?.appendingPathComponent(frameFilename)
    }
}
