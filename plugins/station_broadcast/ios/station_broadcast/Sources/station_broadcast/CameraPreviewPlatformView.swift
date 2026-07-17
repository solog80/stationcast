import Flutter
import HaishinKit
import UIKit

/// Hosts HaishinKit's MTHKView and connects it to the engine's mixer.
final class CameraPreviewPlatformView: NSObject, FlutterPlatformView {
    private let previewView: MTHKView

    @MainActor
    init(frame: CGRect, engine: BroadcastEngine) {
        previewView = MTHKView(frame: frame)
        previewView.videoGravity = .resizeAspectFill
        super.init()
        Task { @MainActor in
            await engine.mixer.addOutput(previewView)
        }
    }

    func view() -> UIView { previewView }
}

final class CameraPreviewFactory: NSObject, FlutterPlatformViewFactory {
    private let engine: BroadcastEngine

    init(engine: BroadcastEngine) {
        self.engine = engine
        super.init()
    }

    func create(
        withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?
    ) -> FlutterPlatformView {
        MainActor.assumeIsolated {
            CameraPreviewPlatformView(frame: frame, engine: engine)
        }
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }
}
