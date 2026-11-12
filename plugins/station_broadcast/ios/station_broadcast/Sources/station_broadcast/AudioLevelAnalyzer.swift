import AVFoundation
import HaishinKit

final class AudioLevelAnalyzer: NSObject, MediaMixerOutput {
    var videoTrackId: UInt8? { nil }
    var audioTrackId: UInt8? { 0 }

    var onLevels: (([Double]) -> Void)?

    private let sendInterval: CFAbsoluteTime = 0.05
    private var lastSendTime: CFAbsoluteTime = 0

    func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {}

    func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastSendTime >= sendInterval else { return }
        lastSendTime = now

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0, let channelData = buffer.floatChannelData else { return }

        let channelCount = max(1, min(Int(buffer.format.channelCount), 2))
        let isInterleaved = buffer.format.isInterleaved
        var levels = [Double](repeating: -60, count: channelCount)

        for channel in 0..<channelCount {
            let samples = channelData[isInterleaved ? 0 : channel]
            var sum: Double = 0
            if isInterleaved {
                for frame in 0..<frameLength {
                    let value = Double(samples[frame * channelCount + channel])
                    sum += value * value
                }
            } else {
                for frame in 0..<frameLength {
                    let value = Double(samples[frame])
                    sum += value * value
                }
            }

            let rms = sqrt(sum / Double(frameLength))
            let db = 20 * log10(max(rms, 0.000001))
            levels[channel] = min(0, max(-60, db))
        }

        DispatchQueue.main.async { [weak self] in
            self?.onLevels?(levels)
        }
    }

    func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) async {}
}
