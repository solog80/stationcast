import Accelerate
import AVFoundation
import HaishinKit

final class LuminanceAnalyzer: NSObject, MediaMixerOutput {
    var videoTrackId: UInt8? { 0 }
    var audioTrackId: UInt8? { nil }
    var onHistogram: (([Int]) -> Void)?

    private var lastSendTime: CFAbsoluteTime = 0
    private let sendInterval: CFAbsoluteTime = 0.066

    func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastSendTime >= sendInterval else { return }
        lastSendTime = now

        guard let imageBuffer = sampleBuffer.imageBuffer else { return }
        guard let bins = computeLuminanceHistogram(from: imageBuffer) else { return }
        onHistogram?(bins)
    }

    func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {}
    func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) async {}

    private func computeLuminanceHistogram(from imageBuffer: CVImageBuffer) -> [Int]? {
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0) else { return nil }
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0)

        var source = vImage_Buffer(
            data: baseAddress,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: bytesPerRow
        )

        var bins = [vImagePixelCount](repeating: 0, count: 256)
        let error = vImageHistogramCalculation_Planar8(&source, &bins, UInt32(kvImageNoError))
        guard error == kvImageNoError else { return nil }

        let maxVal = bins.max() ?? 1
        return bins.map { Int(Double($0) / Double(maxVal) * 100.0) }
    }
}
