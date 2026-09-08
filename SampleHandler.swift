import ReplayKit
import CoreImage
import UIKit

class SampleHandler: RPBroadcastSampleHandler {

    private let context = CIContext()
    private var lastCapture = Date.distantPast

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        FrameBridge.clear()
        lastCapture = Date.distantPast
    }

    override func broadcastPaused() {}
    override func broadcastResumed() {}

    override func broadcastFinished() {
        FrameBridge.clear()
    }

    override func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        with sampleBufferType: RPSampleBufferType
    ) {
        guard sampleBufferType == .video else { return }

        let now = Date()
        guard now.timeIntervalSince(lastCapture) >= KandyKaneConfig.captureInterval else {
            return
        }
        lastCapture = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        if let jpeg = makeJPEG(from: pixelBuffer) {
            FrameBridge.write(jpeg)
        }
    }

    private func makeJPEG(from pixelBuffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)

        let longest = max(image.extent.width, image.extent.height)
        let scale = longest > KandyKaneConfig.maxFrameDimension
            ? KandyKaneConfig.maxFrameDimension / longest
            : 1.0

        let scaled = image.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
            .jpegData(compressionQuality: KandyKaneConfig.jpegQuality)
    }
}
