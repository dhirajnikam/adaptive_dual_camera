import AVFoundation
import Flutter

/// The package's only native code, and it covers only the simultaneous path:
/// report whether this device can hold both cameras open, and if so run that
/// concurrent session. The sequential path is pure Dart on top of the
/// official `camera` plugin and never reaches this class.
public class AdaptiveDualCameraPlugin: NSObject, FlutterPlugin {
  private let registry: FlutterTextureRegistry
  private var session: AnyObject?

  init(registry: FlutterTextureRegistry) {
    self.registry = registry
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "adaptive_dual_camera/support",
      binaryMessenger: registrar.messenger()
    )
    let instance = AdaptiveDualCameraPlugin(registry: registrar.textures())
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "supportsConcurrentCameras":
      // AVCaptureMultiCamSession is iOS 13+ / A12+; anything older is a no.
      if #available(iOS 13.0, *) {
        result(AVCaptureMultiCamSession.isMultiCamSupported)
      } else {
        result(false)
      }

    case "ensureCameraPermission":
      // The native session drives AVFoundation directly, so nothing else on
      // the simultaneous path ever triggers the OS permission prompt — this
      // does, before the first session start.
      switch AVCaptureDevice.authorizationStatus(for: .video) {
      case .authorized:
        result(true)
      case .notDetermined:
        AVCaptureDevice.requestAccess(for: .video) { granted in
          DispatchQueue.main.async { result(granted) }
        }
      default:
        result(false)
      }

    case "startConcurrent":
      guard #available(iOS 13.0, *) else {
        result(FlutterError(code: "unsupported", message: "Needs iOS 13+", details: nil))
        return
      }
      (session as? ConcurrentCaptureSession)?.stop()
      let fresh = ConcurrentCaptureSession(registry: registry)
      session = fresh
      fresh.start(
        onReady: { result($0) },
        onError: { [weak self] message in
          self?.session = nil
          result(FlutterError(code: "startFailed", message: message, details: nil))
        }
      )

    case "captureBoth":
      guard #available(iOS 13.0, *), let running = session as? ConcurrentCaptureSession
      else {
        result(FlutterError(code: "notRunning", message: "No session", details: nil))
        return
      }
      running.captureBoth(
        onResult: { result($0) },
        onError: { message in
          result(FlutterError(code: "captureFailed", message: message, details: nil))
        }
      )

    case "stopConcurrent":
      if #available(iOS 13.0, *) {
        (session as? ConcurrentCaptureSession)?.stop()
      }
      session = nil
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
