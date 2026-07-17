import AVFoundation
import HaishinKit
import SRTHaishinKit

@MainActor
final class TalkbackAudioPlayer {
    private var connection: SRTConnection?
    private var stream: SRTStream?
    private let audioOutput = AudioPlaybackOutput()

    func start(url: String) async throws {
        guard let srtURL = URL(string: url) else {
            throw NSError(domain: "talkback", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let conn = SRTConnection()
        let str = SRTStream(connection: conn)
        await str.addOutput(audioOutput)

        try await conn.connect(srtURL)
        await str.play()
        connection = conn
        stream = str
    }

    func stop() async {
        await stream?.close()
        await connection?.close()
        stream = nil
        connection = nil
    }
}
