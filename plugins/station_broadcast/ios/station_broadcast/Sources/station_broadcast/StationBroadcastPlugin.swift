import AVFoundation
import Flutter
import UIKit

public class StationBroadcastPlugin: NSObject, FlutterPlugin {
    private let engine: BroadcastEngine
    private var eventSink: FlutterEventSink?
    private var statsSink: FlutterEventSink?
    private var histogramSink: FlutterEventSink?

    @MainActor
    override init() {
        engine = BroadcastEngine()
        super.init()
        engine.onEvent = { [weak self] state, message in
            self?.eventSink?(["state": state, "message": message as Any])
        }
        engine.onStats = { [weak self] stats in
            self?.statsSink?(stats)
        }
        engine.onHistogram = { [weak self] bins in
            self?.histogramSink?(bins)
        }
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = MainActor.assumeIsolated { StationBroadcastPlugin() }

        let channel = FlutterMethodChannel(
            name: "tv.stationcast/broadcast", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: channel)

        let eventsChannel = FlutterEventChannel(
            name: "tv.stationcast/broadcast/events", binaryMessenger: registrar.messenger())
        eventsChannel.setStreamHandler(
            ChannelStreamHandler { sink in instance.eventSink = sink })

        let statsChannel = FlutterEventChannel(
            name: "tv.stationcast/broadcast/stats", binaryMessenger: registrar.messenger())
        statsChannel.setStreamHandler(
            ChannelStreamHandler { sink in instance.statsSink = sink })

        let histogramChannel = FlutterEventChannel(
            name: "tv.stationcast/broadcast/histogram", binaryMessenger: registrar.messenger())
        histogramChannel.setStreamHandler(
            ChannelStreamHandler { sink in instance.histogramSink = sink })

        let cameraFactory = MainActor.assumeIsolated { CameraPreviewFactory(engine: instance.engine) }
        registrar.register(cameraFactory, withId: "tv.stationcast/camera_preview")

        let srtPlayerFactory = MainActor.assumeIsolated { SrtPlayerFactory(binaryMessenger: registrar.messenger()) }
        registrar.register(srtPlayerFactory, withId: "tv.stationcast/srt_player")
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any?] ?? [:]
        Task { @MainActor in
            do {
                switch call.method {
                case "initialize":
                    try await engine.initialize(args: args)
                    result(nil)
                case "startStream":
                    try await engine.startStream(args: args)
                    result(nil)
                case "stopStream":
                    await engine.stopStream()
                    result(nil)
                case "switchCamera":
                    await engine.switchCamera()
                    result(nil)
                case "setTorch":
                    await engine.setTorch(enabled: args["enabled"] as? Bool ?? false)
                    result(nil)
                case "setZoom":
                    engine.setZoom(ratio: CGFloat((args["ratio"] as? NSNumber)?.doubleValue ?? 1.0))
                    result(nil)
                case "setMuted":
                    await engine.setMuted(args["muted"] as? Bool ?? false)
                    result(nil)
                case "setVideoBitrate":
                    if let bps = (args["bps"] as? NSNumber)?.intValue {
                        await engine.setVideoBitrate(bps: bps)
                    }
                    result(nil)
                case "getMaxZoom":
                    result(engine.getMaxZoom())
                case "getCameraResolution":
                    result(engine.getCameraResolution())
                case "getAudioDevices":
                    result(engine.listAudioDevices())
                case "selectAudioDevice":
                    if let id = args["id"] as? String {
                        engine.selectAudioDevice(id: id)
                    }
                    result(nil)
                case "dispose":
                    await engine.dispose()
                    result(nil)
                case "setMirrorFrontCamera":
                    await engine.setMirrorFrontCamera(enabled: args["enabled"] as? Bool ?? false)
                    result(nil)
                case "camera2SetZoom":
                    let ratio = CGFloat((args["ratio"] as? NSNumber)?.doubleValue ?? 1.0)
                    engine.setZoom(ratio: ratio)
                    result(nil)
                case "applyAllCameraSettings":
                    let wb = args["whiteBalance"] as? String ?? "auto"
                    let ev = (args["exposure"] as? NSNumber)?.intValue ?? 0
                    let focus = args["focus"] as? String ?? "auto"
                    let iso = (args["iso"] as? NSNumber)?.intValue ?? 100
                    let flash = args["flash"] as? String ?? "off"
                    engine.applyAllCameraSettings(whiteBalance: wb, exposure: ev, focus: focus, iso: iso, flash: flash)
                    result(nil)
                case "camera2GetCapabilities":
                    let camera = engine.currentCamera
                    let switchOverFactors = camera?.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue } ?? []
                    let minZoom = camera?.minAvailableVideoZoomFactor ?? 1.0
                    result([
                        "maxZoom": engine.getMaxZoom(),
                        "minZoom": Double(minZoom),
                        "switchOverPoints": switchOverFactors,
                    ])
                case "camera2SetWhiteBalance":
                    if let mode = args["mode"] as? String { engine.setCameraWhiteBalance(mode) }
                    result(nil)
                case "camera2SetExposureCompensation":
                    if let ev = (args["ev"] as? NSNumber)?.intValue { engine.setCameraExposure(ev) }
                    result(nil)
                case "camera2SetFocusMode":
                    if let mode = args["mode"] as? String { engine.setCameraFocusMode(mode) }
                    result(nil)
                case "camera2SetIsoSensitivity":
                    if let iso = (args["iso"] as? NSNumber)?.intValue { engine.setCameraIso(iso) }
                    result(nil)
                case "camera2SetVideoStabilization":
                    if let enabled = args["enabled"] as? Bool { engine.setCameraVideoStabilization(enabled) }
                    result(nil)
                case "camera2SetFlashMode":
                    if let mode = args["mode"] as? String { engine.setCameraFlashMode(mode) }
                    result(nil)
                case "talkbackStart":
                    if let url = args["url"] as? String {
                        try await engine.talkbackStart(url: url)
                    }
                    result(nil)
                case "talkbackStop":
                    await engine.talkbackStop()
                    result(nil)
                default:
                    result(FlutterMethodNotImplemented)
                }
            } catch {
                result(
                    FlutterError(
                        code: "broadcast_error", message: error.localizedDescription, details: nil))
            }
        }
    }
}

/// Minimal FlutterStreamHandler that hands the sink to a closure.
final class ChannelStreamHandler: NSObject, FlutterStreamHandler {
    private let assign: (FlutterEventSink?) -> Void

    init(_ assign: @escaping (FlutterEventSink?) -> Void) {
        self.assign = assign
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
        -> FlutterError?
    {
        assign(events)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        assign(nil)
        return nil
    }
}
