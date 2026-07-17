import AVFoundation
import Flutter
import HaishinKit
import SRTHaishinKit
import UIKit

final class SrtPlayerPlatformView: NSObject, FlutterPlatformView {
    private let container: UIView
    private let viewId: Int64
    private var methodChannel: FlutterMethodChannel?
    private var connection: SRTConnection?
    private var stream: SRTStream?
    private var started = false
    private var audioOutput: AudioPlaybackOutput?
    private var _muted = false

    init(frame: CGRect, viewId: Int64, args: [String: Any?], binaryMessenger: FlutterBinaryMessenger) {
        self.viewId = viewId
        container = UIView(frame: frame)
        container.backgroundColor = .black
        super.init()

        setupMethodChannel(binaryMessenger: binaryMessenger)

        let url = args["url"] as? String ?? ""
        startPlayback(url: url, frame: frame)
    }

    func view() -> UIView { container }

    private func setupMethodChannel(binaryMessenger: FlutterBinaryMessenger) {
        methodChannel = FlutterMethodChannel(
            name: "tv.stationcast/srt_player_\(viewId)",
            binaryMessenger: binaryMessenger
        )
        methodChannel?.setMethodCallHandler { [weak self] call, result in
            self?.handleMethodCall(call, result: result)
        }
    }

    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "setVolume":
            if let args = call.arguments as? [String: Any], let volume = args["volume"] as? Double {
                _muted = volume == 0
                audioOutput?.setMuted(_muted)
            }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func startPlayback(url: String, frame: CGRect) {
        guard !started else { return }
        started = true

        let hkView = MTHKView(frame: frame)
        hkView.videoGravity = .resizeAspect
        hkView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hkView)

        NSLayoutConstraint.activate([
            hkView.topAnchor.constraint(equalTo: container.topAnchor),
            hkView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hkView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hkView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        let conn = SRTConnection()
        let str = SRTStream(connection: conn)
        connection = conn
        stream = str

        let audioOutput = AudioPlaybackOutput()
        self.audioOutput = audioOutput
        Task { @MainActor in
            await str.addOutput(audioOutput)
            await str.addOutput(hkView)
        }

        Task {
            do {
                guard let srtUrl = URL(string: url) else { return }
                try await conn.connect(srtUrl)
                await str.play()
            } catch {
                print("[SrtPlayer] Error: \(error)")
            }
        }
    }
}

final class AudioPlaybackOutput: NSObject, StreamOutput {
    private let engine: AVAudioEngine
    private let playerNode: AVAudioPlayerNode

    override init() {
        engine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        engine.connect(playerNode, to: engine.outputNode, format: format)
        try? engine.start()
        playerNode.play()
        super.init()
    }

    func setMuted(_ muted: Bool) {
        if muted {
            playerNode.pause()
        } else {
            playerNode.play()
        }
    }

    nonisolated func stream(_ stream: some StreamConvertible, didOutput audio: AVAudioBuffer, when: AVAudioTime) {
        guard let pcmBuffer = audio as? AVAudioPCMBuffer else { return }
        Task { @MainActor in
            self.playerNode.scheduleBuffer(pcmBuffer)
        }
    }

    nonisolated func stream(_ stream: some StreamConvertible, didOutput video: CMSampleBuffer) {
    }
}

final class SrtPlayerFactory: NSObject, FlutterPlatformViewFactory {
    private weak var binaryMessenger: FlutterBinaryMessenger?

    init(binaryMessenger: FlutterBinaryMessenger) {
        self.binaryMessenger = binaryMessenger
        super.init()
    }

    func create(
        withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?
    ) -> FlutterPlatformView {
        let creationArgs = args as? [String: Any?] ?? [:]
        guard let messenger = binaryMessenger else {
            fatalError("Binary messenger not available for SRT player")
        }
        return SrtPlayerPlatformView(frame: frame, viewId: viewId, args: creationArgs, binaryMessenger: messenger)
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }
}
