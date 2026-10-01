import AVFoundation
import Foundation
import HaishinKit
import Photos
import SRTHaishinKit
import UIKit
#if canImport(RTMPHaishinKit)
import RTMPHaishinKit
#endif

#if DEBUG
private func dlog(_ msg: String) { print("[Camera] \(msg)") }
#else
private func dlog(_ msg: String) {}
#endif

/// Wraps HaishinKit's MediaMixer + SRTStream/RTMPStream: camera+mic capture,
/// publish, camera controls and 1 Hz link statistics.
@MainActor
final class BroadcastEngine {
    let mixer = MediaMixer()

    private var srtConnection: SRTConnection?
    private var srtStream: SRTStream?
    #if canImport(RTMPHaishinKit)
    private var rtmpConnection: RTMPConnection?
    private var rtmpStream: RTMPStream?
    #endif
    private var webRtcTask: URLSessionWebSocketTask?

    private var currentPosition: AVCaptureDevice.Position = .back
    private var _currentCamera: AVCaptureDevice?
    var currentCamera: AVCaptureDevice? { _currentCamera }
    private var statsTimer: Timer?
    private var isStreamingRequested = false
    private var isMixerRunning = false
    private var mirrorFrontCamera = false
    private var talkback: TalkbackAudioPlayer?
    private var orientationObserver: NSObjectProtocol?

    // Recording support
    private var recordingStream: StreamRecorder?
    private var recordingFilePath: String?
    private var recordingFileURL: URL?
    private var recordingEnabled = false
    private var recordingSettings: RecordingConfig?

    /// Called with (state, message) on connection lifecycle changes.
    var onEvent: ((String, String?) -> Void)?
    /// Called with a flat stats map roughly once per second while live.
    var onStats: (([String: Any?]) -> Void)?
    /// Called with 256-bin luminance histogram data (~15 fps).
    var onHistogram: (([Int]) -> Void)?
    /// Called with recording events: recordingStarted, recordingStopped, recordingError
    var onRecording: ((String, String?) -> Void)?

    fileprivate let luminanceAnalyzer = LuminanceAnalyzer()

    private var pendingVideoSettings: VideoCodecSettings?
    private var pendingAudioSettings: AudioCodecSettings?

    struct RecordingConfig {
        let enabled: Bool
        let resolution: String
        let bitrateBps: Int
        let fps: Int
        let codec: String
    }

    private func bestCamera(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let camera: AVCaptureDevice?
        if let triple = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: position) {
            camera = triple
            dlog("Selected triple camera: \(triple.localizedName) zoomRange=\(triple.minAvailableVideoZoomFactor)-\(triple.maxAvailableVideoZoomFactor)")
        } else if let dual = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: position) {
            camera = dual
            dlog("Selected dual camera: \(dual.localizedName) zoomRange=\(dual.minAvailableVideoZoomFactor)-\(dual.maxAvailableVideoZoomFactor)")
        } else if let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) {
            camera = wide
            dlog("Selected wide camera: \(wide.localizedName) zoomRange=\(wide.minAvailableVideoZoomFactor)-\(wide.maxAvailableVideoZoomFactor)")
        } else {
            camera = nil
        }
        if let cam = camera {
            dlog("Virtual device switch-over points: \(cam.virtualDeviceSwitchOverVideoZoomFactors.map { $0.floatValue })")
        }
        return camera
    }

    func initialize(args: [String: Any?]) async throws {
        configureAudioSession()

        let width = (args["width"] as? NSNumber)?.intValue ?? 1280
        let height = (args["height"] as? NSNumber)?.intValue ?? 720
        let fps = (args["fps"] as? NSNumber)?.doubleValue ?? 30
        let videoBitrate = (args["videoBitrateBps"] as? NSNumber)?.intValue ?? 3_000_000
        let audioBitrate = (args["audioBitrateBps"] as? NSNumber)?.intValue ?? 128_000

        // Extract recording settings
        let recordingEnabled = (args["recordingEnabled"] as? NSNumber)?.boolValue ?? false
        let recordingResolution = (args["recordingResolution"] as? String) ?? "p1080"
        let recordingBitrateBps = (args["recordingBitrateBps"] as? NSNumber)?.intValue ?? 6_000_000
        let recordingFps = (args["recordingFps"] as? NSNumber)?.intValue ?? 25
        let recordingCodec = (args["recordingCodec"] as? String) ?? "h264"

        var videoSettings = VideoCodecSettings()
        videoSettings.videoSize = CGSize(width: width, height: height)
        videoSettings.bitRate = videoBitrate
        // HEVC not available in this HaishinKit build; defaults to H.264
        pendingVideoSettings = videoSettings

        var audioSettings = AudioCodecSettings()
        audioSettings.bitRate = audioBitrate
        pendingAudioSettings = audioSettings

        // Store recording config
        if recordingEnabled {
            self.recordingEnabled = recordingEnabled
            self.recordingSettings = RecordingConfig(
                enabled: recordingEnabled,
                resolution: recordingResolution,
                bitrateBps: recordingBitrateBps,
                fps: recordingFps,
                codec: recordingCodec
            )
        }

        if !isMixerRunning {
            let camera = bestCamera(position: currentPosition)
            _currentCamera = camera
            let orientation = currentVideoOrientation()
            try? await mixer.attachVideo(camera, track: 0) { [position = currentPosition, mirrorFrontCamera = self.mirrorFrontCamera, orientation] videoUnit in
                videoUnit.isVideoMirrored = position == .front && mirrorFrontCamera
                videoUnit.videoOrientation = orientation
            }
            try? await mixer.attachAudio(AVCaptureDevice.default(for: .audio))
            try? await mixer.setFrameRate(fps)
            await mixer.startRunning()
            await mixer.addOutput(luminanceAnalyzer)
            luminanceAnalyzer.onHistogram = { [weak self] bins in
                self?.onHistogram?(bins)
            }
            isMixerRunning = true
            setupOrientationObserver()
        } else {
            try? await mixer.setFrameRate(fps)
        }
    }

    func startStream(args: [String: Any?]) async throws {
        emit("connecting", nil)
        do {
            if (args["protocol"] as? String) == "rtmp" {
                try await startRtmp(args: args)
            } else if (args["protocol"] as? String) == "webrtc" {
                try await startWebrtc(args: args)
            } else {
                try await startSrt(args: args)
            }
            isStreamingRequested = true
            startStatsPolling()
            emit("live", nil)
        } catch {
            emit("failed", error.localizedDescription)
            throw error
        }
    }

    private func startSrt(args: [String: Any?]) async throws {
        guard let host = args["host"] as? String else {
            throw NSError(
                domain: "station_broadcast", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "host required"])
        }
        let port = (args["port"] as? NSNumber)?.intValue ?? 9000

        var components = URLComponents()
        components.scheme = "srt"
        components.host = host
        components.port = port
        var query: [URLQueryItem] = []
        // SRT live mode settings for low latency
        query.append(URLQueryItem(name: "transtype", value: "live"))
        query.append(URLQueryItem(name: "maxbw", value: "0"))
        query.append(URLQueryItem(name: "inputbw", value: String((args["videoBitrateBps"] as? NSNumber)?.intValue ?? 3_000_000)))
        if let streamId = args["streamId"] as? String, !streamId.isEmpty {
            query.append(URLQueryItem(name: "streamid", value: streamId))
        }
        if let passphrase = args["passphrase"] as? String, !passphrase.isEmpty {
            query.append(URLQueryItem(name: "passphrase", value: passphrase))
        }
        if let latency = (args["latencyMs"] as? NSNumber)?.intValue, latency > 0 {
            query.append(URLQueryItem(name: "latency", value: String(latency * 1000)))
        }
        if !query.isEmpty {
            components.queryItems = query
        }

        let connection = SRTConnection()
        let stream = SRTStream(connection: connection)
        if let videoSettings = pendingVideoSettings {
            try? await stream.setVideoSettings(videoSettings)
        }
        if let audioSettings = pendingAudioSettings {
            try? await stream.setAudioSettings(audioSettings)
        }
        await mixer.addOutput(stream)

        // Attach recorder if enabled (only if not already recording)
        if recordingEnabled, let config = recordingSettings, recordingStream == nil {
            await attachRecorder(to: stream, config: config)
        }

        try await connection.connect(components.url)
        await stream.publish()
        srtConnection = connection
        srtStream = stream
    }

    private func startRtmp(args: [String: Any?]) async throws {
        #if canImport(RTMPHaishinKit)
        guard let url = args["rtmpUrl"] as? String, let key = args["streamKey"] as? String else {
            throw NSError(
                domain: "station_broadcast", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "rtmpUrl and streamKey required"])
        }
        let connection = RTMPConnection()
        let stream = RTMPStream(connection: connection)
        if let videoSettings = pendingVideoSettings {
            try? await stream.setVideoSettings(videoSettings)
        }
        if let audioSettings = pendingAudioSettings {
            try? await stream.setAudioSettings(audioSettings)
        }
        await mixer.addOutput(stream)

        // Attach recorder if enabled (only if not already recording)
        if recordingEnabled, let config = recordingSettings, recordingStream == nil {
            await attachRecorder(to: stream, config: config)
        }

        _ = try await connection.connect(url)
        _ = try await stream.publish(key)
        rtmpConnection = connection
        rtmpStream = stream
        #else
        throw NSError(
            domain: "station_broadcast", code: 3,
            userInfo: [NSLocalizedDescriptionKey: "RTMP module not available in this build"])
        #endif
    }

    private func startWebrtc(args: [String: Any?]) async throws {
        guard let urlString = args["webrtcUrl"] as? String else {
            throw NSError(domain: "station_broadcast", code: 1, userInfo: [NSLocalizedDescriptionKey: "webrtcUrl required"])
        }
        var fullUrlString = urlString
        if !fullUrlString.contains("direction=") {
            fullUrlString += fullUrlString.contains("?") ? "&direction=whip" : "?direction=whip"
        }
        guard let url = URL(string: fullUrlString) else {
            throw NSError(domain: "station_broadcast", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid WebRTC URL: \(fullUrlString)"])
        }
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        task.resume()
        webRtcTask = task

        let requestOffer: [String: Any] = ["command": "request_offer"]
        if let jsonData = try? JSONSerialization.data(withJSONObject: requestOffer), let jsonString = String(data: jsonData, encoding: .utf8) {
            let message = URLSessionWebSocketTask.Message.string(jsonString)
            try await task.send(message)
            dlog("Sent request_offer to \(urlString)")
        }
    }

    func stopStream() async {
        isStreamingRequested = false
        statsTimer?.invalidate()
        statsTimer = nil

        // Stop recording if active
        if let recorder = recordingStream {
            do {
                try await recorder.stopRecording()
                onRecording?("recordingStopped", recordingFilePath)
                dlog("Recording stopped: \(recordingFilePath ?? "unknown")")

                // Save to Photo Library asynchronously if file exists
                if let fileURL = recordingFileURL {
                    Task {
                        await saveVideoToPhotoLibrary(fileURL)
                    }
                }

                recordingFilePath = nil
                recordingFileURL = nil
            } catch {
                onRecording?("recordingError", error.localizedDescription)
                dlog("Recording stop error: \(error)")
                recordingFileURL = nil
            }
            recordingStream = nil
        }

        if let stream = srtStream {
            await mixer.removeOutput(stream)
            await stream.close()
        }
        await srtConnection?.close()
        srtStream = nil
        srtConnection = nil
        #if canImport(RTMPHaishinKit)
        if let stream = rtmpStream {
            await mixer.removeOutput(stream)
            _ = try? await stream.close()
        }
        _ = try? await rtmpConnection?.close()
        rtmpStream = nil
        rtmpConnection = nil
        #endif
        emit("stopped", nil)
    }

    func switchCamera() async {
        currentPosition = currentPosition == .back ? .front : .back
        let camera = bestCamera(position: currentPosition)
        _currentCamera = camera
        let orientation = currentVideoOrientation()
        try? await mixer.attachVideo(camera, track: 0) { [position = currentPosition, mirrorFrontCamera = self.mirrorFrontCamera, orientation] videoUnit in
            videoUnit.isVideoMirrored = position == .front && mirrorFrontCamera
            videoUnit.videoOrientation = orientation
        }
    }

    func setTorch(enabled: Bool) async {
        await mixer.setTorchEnabled(enabled)
    }

    func setZoom(ratio: CGFloat) {
        let deviceType: AVCaptureDevice.DeviceType
        if ratio < 0.75 {
            deviceType = .builtInUltraWideCamera
        } else {
            deviceType = .builtInWideAngleCamera
        }
        if deviceType == .builtInUltraWideCamera || currentCamera?.deviceType != deviceType {
            if let camera = AVCaptureDevice.default(deviceType, for: .video, position: currentPosition) {
                Task { await switchToCamera(camera, zoom: ratio) }
                return
            }
        }
        guard let device = currentCamera else { return }
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = min(
                max(ratio, device.minAvailableVideoZoomFactor),
                device.maxAvailableVideoZoomFactor)
            device.unlockForConfiguration()
        } catch {
            // zoom is best-effort
        }
    }

    private func switchToCamera(_ camera: AVCaptureDevice, zoom: CGFloat? = nil) async {
        _currentCamera = camera
        let orientation = currentVideoOrientation()
        try? await mixer.attachVideo(camera, track: 0) { [position = currentPosition, mirrorFrontCamera = self.mirrorFrontCamera, orientation] videoUnit in
            videoUnit.isVideoMirrored = position == .front && mirrorFrontCamera
            videoUnit.videoOrientation = orientation
        }
        // Set zoom after switching
        if let z = zoom {
            try? camera.lockForConfiguration()
            camera.videoZoomFactor = min(max(z, camera.minAvailableVideoZoomFactor), camera.maxAvailableVideoZoomFactor)
            camera.unlockForConfiguration()
        }
        // Re-apply torch if active
        if case .on = camera.torchMode {
            try? camera.lockForConfiguration()
            try? camera.setTorchModeOn(level: 1.0)
            camera.unlockForConfiguration()
        }
    }

    func getMaxZoom() -> Double {
        min(Double(currentCamera?.maxAvailableVideoZoomFactor ?? 1.0), 10.0)
    }

    func getCameraResolution() -> [String: Double] {
        guard let device = currentCamera else { return [:] }

        // Try to find 16:9 resolution first
        let format16_9 = device.formats.first { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let ar = Double(dimensions.width) / Double(dimensions.height)
            return ar > 1.76 && ar < 1.80
        }

        let selectedFormat = format16_9 ?? device.formats.max { f1, f2 in
            let dim1 = CMVideoFormatDescriptionGetDimensions(f1.formatDescription)
            let dim2 = CMVideoFormatDescriptionGetDimensions(f2.formatDescription)
            return dim1.width * dim1.height < dim2.width * dim2.height
        }

        guard let format = selectedFormat else { return [:] }

        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let width = Double(dimensions.width)
        let height = Double(dimensions.height)
        return [
            "width": width,
            "height": height,
            "aspectRatio": width / height
        ]
    }

    private func configureDevice(_ block: @escaping (AVCaptureDevice) -> Void) {
        Task {
            do {
                try await mixer.configuration(video: 0) { unit in
                    guard let device = unit.device else {
                        dlog("configureDevice: no device")
                        return
                    }
                    try device.lockForConfiguration()
                    block(device)
                    device.unlockForConfiguration()
                }
            } catch {
                dlog("configureDevice error: \(error)")
            }
        }
    }

    func setCameraWhiteBalance(_ mode: String) {
        configureDevice { device in
            switch mode {
            case "auto":
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            default:
                let tempMapping: [String: Float] = [
                    "incandescent": 3200, "fluorescent": 4200, "warmFluorescent": 3000,
                    "daylight": 5500, "cloudyDaylight": 6500, "twilight": 8000, "shade": 7000,
                ]
                let temperature = tempMapping[mode] ?? 5500
                let gains = device.deviceWhiteBalanceGains(for: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temperature, tint: 0))
                if device.isWhiteBalanceModeSupported(.locked) {
                    device.whiteBalanceMode = .locked
                    device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                }
            }
        }
    }

    func setCameraExposure(_ ev: Int) {
        configureDevice { device in
            if device.isExposureModeSupported(.custom) {
                let bias = min(max(Float(ev) / 4.0, device.minExposureTargetBias), device.maxExposureTargetBias)
                device.setExposureTargetBias(bias)
            }
        }
    }

    func setCameraFocusMode(_ mode: String) {
        configureDevice { device in
            switch mode {
            case "auto":
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            case "continuous":
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            default:
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            }
        }
    }

    func setCameraIso(_ iso: Int) {
        configureDevice { device in
            if device.isExposureModeSupported(.custom) {
                device.setExposureModeCustom(
                    duration: device.exposureDuration,
                    iso: min(max(Float(iso), device.activeFormat.minISO), device.activeFormat.maxISO),
                    completionHandler: nil
                )
            }
        }
    }

    func setCameraVideoStabilization(_ enabled: Bool) {
        Task {
            try? await mixer.configuration(video: 0) { unit in
                unit.preferredVideoStabilizationMode = enabled ? .standard : .off
            }
        }
    }

    func applyAllCameraSettings(whiteBalance: String, exposure: Int, focus: String, iso: Int, flash: String) {
        configureDevice { device in
            // White balance
            switch whiteBalance {
            case "auto":
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            default:
                let tempMapping: [String: Float] = [
                    "incandescent": 3200, "fluorescent": 4200, "warmFluorescent": 3000,
                    "daylight": 5500, "cloudyDaylight": 6500, "twilight": 8000, "shade": 7000,
                ]
                let temperature = tempMapping[whiteBalance] ?? 5500
                let gains = device.deviceWhiteBalanceGains(for: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temperature, tint: 0))
                if device.isWhiteBalanceModeSupported(.locked) {
                    device.whiteBalanceMode = .locked
                    device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                }
            }

            // Exposure
            if device.isExposureModeSupported(.custom) {
                let bias = min(max(Float(exposure) / 4.0, device.minExposureTargetBias), device.maxExposureTargetBias)
                device.setExposureTargetBias(bias)
            }

            // Focus
            switch focus {
            case "auto":
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            case "continuous":
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            default:
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            }

            // ISO
            if device.isExposureModeSupported(.custom) {
                device.setExposureModeCustom(
                    duration: device.exposureDuration,
                    iso: min(max(Float(iso), device.activeFormat.minISO), device.activeFormat.maxISO),
                    completionHandler: nil
                )
            }

            // Flash
            if flash == "torch" {
                if device.isTorchModeSupported(.on) { try? device.setTorchModeOn(level: 1.0) }
            } else {
                device.torchMode = .off
            }
        }
    }

    func setCameraFlashMode(_ mode: String) {
        configureDevice { device in
            if mode == "torch" {
                if device.isTorchModeSupported(.on) { try? device.setTorchModeOn(level: 1.0) }
            } else {
                device.torchMode = .off
            }
        }
    }

    func setMuted(_ muted: Bool) async {
        var settings = await mixer.audioMixerSettings
        var track = settings.tracks[0] ?? .init()
        track.isMuted = muted
        settings.tracks[0] = track
        await mixer.setAudioMixerSettings(settings)
    }

    func setVideoBitrate(bps: Int) async {
        pendingVideoSettings?.bitRate = bps
        if let stream = srtStream, var settings = pendingVideoSettings {
            settings.bitRate = bps
            try? await stream.setVideoSettings(settings)
        }
        #if canImport(RTMPHaishinKit)
        if let stream = rtmpStream, var settings = pendingVideoSettings {
            settings.bitRate = bps
            try? await stream.setVideoSettings(settings)
        }
        #endif
    }

    func setMirrorFrontCamera(enabled: Bool) async {
        mirrorFrontCamera = enabled
    }

    // MARK: - Talkback

    func talkbackStart(url: String) async throws {
        await talkback?.stop()
        let player = TalkbackAudioPlayer()
        try await player.start(url: url)
        talkback = player
    }

    func talkbackStop() async {
        await talkback?.stop()
        talkback = nil
    }

    func listAudioDevices() -> [[String: String]] {
        let session = AVAudioSession.sharedInstance()
        return (session.availableInputs ?? []).map { input in
            [
                "id": input.uid,
                "name": input.portName,
                "type": portType(input.portType),
            ]
        }
    }

    func selectAudioDevice(id: String) {
        let session = AVAudioSession.sharedInstance()
        guard let input = session.availableInputs?.first(where: { $0.uid == id }) else { return }
        try? session.setPreferredInput(input)
    }

    func dispose() async {
        if let observer = orientationObserver {
            NotificationCenter.default.removeObserver(observer)
            orientationObserver = nil
        }
        await talkbackStop()
        await stopStream()
        await mixer.stopRunning()
        try? await mixer.attachVideo(nil, track: 0)
        try? await mixer.attachAudio(nil)
        isMixerRunning = false
    }

    // MARK: - Internals

    private func currentVideoOrientation() -> AVCaptureVideoOrientation {
        let orientation = UIDevice.current.orientation
        switch orientation {
        case .portrait, .unknown:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        case .faceUp, .faceDown:
            return .portrait
        @unknown default:
            return .portrait
        }
    }

    private func setupOrientationObserver() {
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let camera = self.currentCamera else { return }
                let orientation = self.currentVideoOrientation()
                try? await self.mixer.attachVideo(camera, track: 0) { [position = self.currentPosition, mirrorFrontCamera = self.mirrorFrontCamera, orientation] videoUnit in
                    videoUnit.isVideoMirrored = position == .front && mirrorFrontCamera
                    videoUnit.videoOrientation = orientation
                }
            }
        }
    }

    /// One shared session config for simultaneous mic capture (publish) and
    /// return-feed playback through speaker/headset.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord, mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            // Ensure microphone input is enabled
            try session.setPreferredInput(nil) // Use default mic
            print("[BroadcastEngine] Audio session configured with input: \(session.availableInputs?.count ?? 0) inputs")
        } catch {
            emit("failed", "Audio session error: \(error.localizedDescription)")
        }
    }

    private func startStatsPolling() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollStats()
            }
        }
    }

    private func pollStats() async {
        guard isStreamingRequested else { return }
        if let connection = srtConnection {
            let connected = await connection.connected
            if !connected {
                isStreamingRequested = false
                statsTimer?.invalidate()
                emit("failed", "Connection lost")
                return
            }
            guard let perf = await connection.performanceData else { return }
            onStats?([
                "bitrateBps": Int(perf.mbpsSendRate * 1_000_000),
                "rttMs": perf.msRTT,
                "packetsSent": Int(perf.pktSentTotal),
                "packetsDropped": Int(perf.pktSndDropTotal),
                "packetsRetransmitted": Int(perf.pktRetransTotal),
                "bandwidthMbps": perf.mbpsSendRate,
                "audioLevelDb": nil,
            ])
        }
    }

    private func portType(_ type: AVAudioSession.Port) -> String {
        switch type {
        case .builtInMic: return "builtin"
        case .headsetMic: return "wired"
        case .bluetoothHFP, .bluetoothLE: return "bluetooth"
        case .usbAudio: return "usb"
        default: return "unknown"
        }
    }

    // MARK: - Recording Support

    private func resolveRecordingDimensions(_ resolution: String) -> (width: UInt32, height: UInt32) {
        switch resolution {
        case "p720":
            return (1280, 720)
        case "p1080":
            return (1920, 1080)
        case "p1440":
            return (2560, 1440)
        default:
            return (1920, 1080)
        }
    }

    private func resolveVideoCodec(_ codec: String) -> AVVideoCodecType {
        switch codec {
        case "hevc":
            return .hevc
        case "h264":
            return .h264
        default:
            return .h264
        }
    }

    private func attachRecorder(to stream: some StreamConvertible, config: RecordingConfig) async {
        let recorder = StreamRecorder()
        let dimensions = resolveRecordingDimensions(config.resolution)
        let codecType = resolveVideoCodec(config.codec)

        // Configure recording settings
        var recordingSettings: [AVMediaType: [String: any Sendable]] = [
            .audio: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 0,        // Auto from input
                AVNumberOfChannelsKey: 0   // Auto from input
            ],
            .video: [
                AVVideoCodecKey: codecType,
                AVVideoHeightKey: Int(dimensions.height),
                AVVideoWidthKey: Int(dimensions.width),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: config.bitrateBps,
                    AVVideoExpectedSourceFrameRateKey: config.fps,
                    AVVideoMaxKeyFrameIntervalKey: config.fps  // Keyframe every 1 second
                ]
            ]
        ]

        // Create temp directory for recording (will move to Photos Library after)
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        let recordingDir = tempDir.appendingPathComponent("StationCastRecordings", isDirectory: true)

        do {
            try fileManager.createDirectory(at: recordingDir, withIntermediateDirectories: true)

            // Generate filename with timestamp
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
            let timestamp = dateFormatter.string(from: Date())
            let filename = "stationcast_\(timestamp).mp4"
            let recordingURL = recordingDir.appendingPathComponent(filename)

            // Start recording with configured settings
            try await recorder.startRecording(recordingURL, settings: recordingSettings)
            recordingFilePath = recordingURL.absoluteString
            recordingFileURL = recordingURL
            recordingStream = recorder

            // Attach recorder to stream
            await stream.addOutput(recorder)

            // Send event to Flutter
            onRecording?("recordingStarted", recordingFilePath)
            dlog("Recording started: \(recordingURL.path) (\(dimensions.width)x\(dimensions.height) \(config.fps)fps \(config.bitrateBps / 1_000_000)Mbps)")

        } catch {
            onRecording?("recordingError", error.localizedDescription)
            dlog("Recording setup error: \(error)")
        }
    }

    // MARK: - Photo Library Integration

    private func saveVideoToPhotoLibrary(_ fileURL: URL) async {
        // Step 1: Request permissions
        let authStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if authStatus == .notDetermined {
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard newStatus == .authorized else {
                dlog("Photo library permission denied")
                return
            }
        } else if authStatus == .denied || authStatus == .restricted {
            dlog("Photo library access denied or restricted")
            return
        }

        // Step 2: Validate file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            dlog("Recording file not found at: \(fileURL.path)")
            return
        }

        // Step 3: Attempt save with retry logic
        do {
            try await saveWithRetry(fileURL: fileURL, maxRetries: 3)
            dlog("Video saved to Photo Library: \(fileURL.lastPathComponent)")
        } catch {
            dlog("Failed to save video to Photo Library: \(error.localizedDescription)")
        }
    }

    private func saveWithRetry(fileURL: URL, maxRetries: Int) async throws {
        var lastError: Error?

        for attempt in 0..<maxRetries {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                }
                return // Success!
            } catch {
                lastError = error
                if attempt < maxRetries - 1 {
                    // Exponential backoff: 1s, 2s, 4s
                    let delayNanoseconds = UInt64(1 << attempt) * 1_000_000_000
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                }
            }
        }

        if let error = lastError {
            throw error
        }
    }

    private func emit(_ state: String, _ message: String?) {
        onEvent?(state, message)
    }
}
