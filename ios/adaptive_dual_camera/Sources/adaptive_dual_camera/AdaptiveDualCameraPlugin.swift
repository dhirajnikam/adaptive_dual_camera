import AVFoundation
import Flutter
import UIKit

private let backKey = "back"
private let frontKey = "front"

/// A failure worth reporting to Dart with a specific error code.
struct CameraError: LocalizedError {
  let code: String
  let message: String
  var errorDescription: String? { message }

  static func failed(_ message: String) -> CameraError {
    CameraError(code: "capture_failed", message: message)
  }
}

/// Front + back capture on AVFoundation.
///
/// Holds both cameras open through an `AVCaptureMultiCamSession` where the
/// hardware supports it; otherwise runs one camera at a time and switches
/// between them. Each live camera streams into a Flutter texture so Dart can
/// draw a viewfinder.
public class AdaptiveDualCameraPlugin: NSObject, FlutterPlugin {
  private let queue = DispatchQueue(label: "adaptive_dual_camera")
  private var registry: (any FlutterTextureRegistry)?
  private var session: DualSession?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "adaptive_dual_camera", binaryMessenger: registrar.messenger())
    let instance = AdaptiveDualCameraPlugin()
    instance.registry = registrar.textures()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]

    switch call.method {
    case "isSimultaneousSupported":
      result(AVCaptureMultiCamSession.isMultiCamSupported)

    case "requestPermission":
      requestPermission(microphone: args["microphone"] as? Bool ?? false, result)

    case "initialize":
      // Read on the main thread, then hand the fixed value to the camera queue.
      let orientation = UIDevice.current.orientation
      background(result) {
        try self.requireCameraPermission()
        self.session?.release()
        guard let registry = self.registry else {
          throw CameraError.failed("Plugin was registered without a texture registry.")
        }
        let session = try DualSession(
          registry: registry,
          forceSequential: args["forceSequential"] as? Bool ?? false,
          orientation: orientation)
        self.session = session
        return try session.open()
      }

    case "activate":
      background(result) {
        try self.requireSession().activate(args["camera"] as? String ?? backKey)
      }

    case "capturePhoto":
      background(result) {
        try self.requireSession().capturePhoto(
          cameras: args["cameras"] as? [String] ?? [backKey, frontKey])
      }

    case "startRecording":
      background(result) {
        try self.requireSession().startRecording(
          cameras: args["cameras"] as? [String] ?? [backKey],
          audio: args["audio"] as? Bool ?? true)
      }

    case "stopRecording":
      background(result) { try self.requireSession().stopRecording() }

    case "release":
      background(result) {
        self.session?.release()
        self.session = nil
        return nil
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Runs `body` off the platform thread and answers `result` on it.
  private func background(_ result: @escaping FlutterResult, _ body: @escaping () throws -> Any?) {
    queue.async {
      do {
        let value = try body()
        DispatchQueue.main.async { result(value) }
      } catch let error as CameraError {
        DispatchQueue.main.async {
          result(FlutterError(code: error.code, message: error.message, details: nil))
        }
      } catch {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "capture_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func requireSession() throws -> DualSession {
    guard let session = session else {
      throw CameraError(code: "not_initialized", message: "initialize() has not been called.")
    }
    return session
  }

  private func requireCameraPermission() throws {
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
      throw CameraError(
        code: "permission_denied", message: "Camera permission has not been granted.")
    }
  }

  private func requestPermission(microphone: Bool, _ result: @escaping FlutterResult) {
    request(.video) { camera in
      guard camera, microphone else {
        DispatchQueue.main.async { result(camera) }
        return
      }
      self.request(.audio) { mic in
        DispatchQueue.main.async { result(mic) }
      }
    }
  }

  private func request(_ media: AVMediaType, _ done: @escaping (Bool) -> Void) {
    switch AVCaptureDevice.authorizationStatus(for: media) {
    case .authorized: done(true)
    case .notDetermined: AVCaptureDevice.requestAccess(for: media, completionHandler: done)
    default: done(false)
    }
  }
}

// MARK: - Session

/// The open cameras and their Flutter textures.
///
/// Multi-cam sessions keep a `Rig` per camera for their whole life. Sequential
/// sessions keep exactly one and swap it on `activate`, but the textures
/// persist either way so Dart's texture ids stay stable.
private final class DualSession {
  /// Time given to auto-exposure/white-balance after a camera starts.
  /// ponytail: fixed settle delay rather than KVO on `isAdjustingExposure`.
  /// Bump it if the first frame comes out dark on a slow sensor.
  static let settleDelay: TimeInterval = 0.35
  static let captureTimeout: TimeInterval = 8

  private let registry: any FlutterTextureRegistry
  private let orientation: UIDeviceOrientation

  private let backDevice: AVCaptureDevice
  private let frontDevice: AVCaptureDevice

  private var textures: [String: CameraTexture] = [:]
  private var rigs: [String: Rig] = [:]
  private var session: AVCaptureSession?
  private var audioInput: AVCaptureDeviceInput?
  private var recording: [String] = []

  private(set) var simultaneous: Bool
  private(set) var active = backKey

  init(
    registry: any FlutterTextureRegistry, forceSequential: Bool,
    orientation: UIDeviceOrientation
  ) throws {
    self.registry = registry
    self.orientation = orientation
    self.simultaneous = !forceSequential && AVCaptureMultiCamSession.isMultiCamSupported
    self.backDevice = try DualSession.device(at: .back)
    self.frontDevice = try DualSession.device(at: .front)
  }

  // MARK: Lifecycle

  func open() throws -> [String: Any] {
    for key in [backKey, frontKey] {
      let texture = CameraTexture()
      texture.id = registry.register(texture)
      texture.registry = registry
      textures[key] = texture
    }
    try build(cameras: simultaneous ? [backKey, frontKey] : [backKey], recorded: [], audio: false)
    return describe()
  }

  func release() {
    stopSession()
    for texture in textures.values {
      registry.unregisterTexture(texture.id)
    }
    textures.removeAll()
    rigs.removeAll()
  }

  /// Points the single live camera at `camera`. No-op when both are live.
  func activate(_ camera: String) throws -> [String: Any] {
    if simultaneous || camera == active { return describe() }
    guard recording.isEmpty else {
      throw CameraError(code: "busy", message: "Cannot switch cameras while recording.")
    }
    try build(cameras: [camera], recorded: [], audio: false)
    active = camera
    return describe()
  }

  // MARK: Photos

  /// Shoots `cameras`. Only a multi-cam session honours more than one per call —
  /// sequential callers ask for one at a time so Dart can say which photo is
  /// being taken.
  func capturePhoto(cameras: [String]) throws -> [String: Any] {
    guard recording.isEmpty else {
      throw CameraError(code: "busy", message: "Cannot take a photo while recording.")
    }

    let wanted = simultaneous ? cameras : [cameras.first ?? active]
    if !simultaneous, let only = wanted.first, only != active {
      _ = try activate(only)
    }

    // Fire every shutter before collecting, so a multi-cam pair goes off
    // together instead of one JPEG encode apart.
    var pending: [(String, PhotoCollector)] = []
    for key in wanted {
      guard let output = rigs[key]?.photo else {
        throw CameraError.failed("The \(key) camera has no photo output.")
      }
      let collector = PhotoCollector()
      pending.append((key, collector))
      output.capturePhoto(with: photoSettings(), delegate: collector)
    }

    var result: [String: Any] = ["mode": simultaneous ? "simultaneous" : "sequential"]
    for (key, collector) in pending {
      let data = try collector.wait(DualSession.captureTimeout)
      result[key] = try DualSession.write(data, key, "jpg")
    }
    return result
  }

  // MARK: Video

  /// Starts recording on `cameras`.
  ///
  /// A device can report multi-cam support yet fail to run two movie outputs.
  /// When that happens the session drops to sequential and records the back
  /// camera only — the returned mode says so, and Dart runs its second pass off
  /// that.
  func startRecording(cameras: [String], audio: Bool) throws -> [String: Any] {
    guard recording.isEmpty else {
      throw CameraError(code: "busy", message: "Already recording.")
    }
    if audio, AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
      throw CameraError(
        code: "permission_denied", message: "Microphone permission has not been granted.")
    }

    if simultaneous && cameras.count > 1 {
      do {
        try build(cameras: cameras, recorded: cameras, audio: audio)
        try beginWriting(cameras)
        recording = cameras
        return describe()
      } catch {
        // Two movie outputs wouldn't configure. Carry on one camera at a time.
        simultaneous = false
        active = backKey
      }
    }

    let camera = cameras.first ?? backKey
    try build(cameras: [camera], recorded: [camera], audio: audio && camera == backKey)
    active = camera
    try beginWriting([camera])
    recording = [camera]
    return describe()
  }

  func stopRecording() throws -> [String: Any] {
    guard !recording.isEmpty else {
      throw CameraError(code: "not_recording", message: "Not recording.")
    }
    let stopping = recording
    recording = []

    var collectors: [(String, MovieCollector)] = []
    for key in stopping {
      guard let rig = rigs[key], let movie = rig.movie, let collector = rig.movieCollector else {
        continue
      }
      collectors.append((key, collector))
      movie.stopRecording()
    }

    var result: [String: Any] = [:]
    var failure: Error?
    for (key, collector) in collectors {
      do {
        result[key] = try collector.wait(DualSession.captureTimeout).path
      } catch {
        failure = error
      }
    }

    // Back to preview + stills regardless of how the clips turned out.
    try? build(cameras: stopping, recorded: [], audio: false)

    if result.isEmpty, let failure = failure { throw failure }
    return result
  }

  private func beginWriting(_ cameras: [String]) throws {
    for key in cameras {
      guard let rig = rigs[key], let movie = rig.movie else {
        throw CameraError.failed("The \(key) camera has no movie output.")
      }
      let collector = MovieCollector()
      rig.movieCollector = collector
      movie.startRecording(to: DualSession.cacheURL(key, "mp4"), recordingDelegate: collector)
    }
  }

  // MARK: Session construction

  /// Rebuilds the whole capture session.
  ///
  /// `cameras` are the ones that stay live, `recorded` get a movie output
  /// instead of a photo output. Keeping it to one output per camera besides the
  /// preview stream is what lets the multi-cam path fit inside the hardware
  /// cost budget on more devices.
  private func build(cameras: [String], recorded: [String], audio: Bool) throws {
    stopSession()

    let multi = simultaneous && cameras.count > 1
    let session: AVCaptureSession = multi ? AVCaptureMultiCamSession() : AVCaptureSession()
    session.beginConfiguration()
    if !multi { session.sessionPreset = recorded.isEmpty ? .photo : .high }

    var built: [String: Rig] = [:]
    for key in cameras {
      let device = key == backKey ? backDevice : frontDevice
      if multi { try lockToMultiCamFormat(device) }
      built[key] = try attach(
        device: device, key: key, to: session, multi: multi, record: recorded.contains(key))
    }

    if audio, let mic = AVCaptureDevice.default(for: .audio) {
      let input = try AVCaptureDeviceInput(device: mic)
      // One audio track, on the back clip only — see DualRecording in Dart.
      if let target = built[backKey]?.movie ?? built[recorded.first ?? backKey]?.movie {
        if multi {
          session.addInputWithNoConnections(input)
          let ports = input.ports(for: .audio, sourceDeviceType: mic.deviceType, sourceDevicePosition: mic.position)
          let connection = AVCaptureConnection(inputPorts: ports, output: target)
          if session.canAddConnection(connection) { session.addConnection(connection) }
        } else if session.canAddInput(input) {
          session.addInput(input)
        }
      }
      audioInput = input
    }

    session.commitConfiguration()
    session.startRunning()
    guard session.isRunning else {
      throw CameraError.failed("Capture session did not start.")
    }

    self.session = session
    self.rigs = built
    Thread.sleep(forTimeInterval: DualSession.settleDelay)
  }

  private func stopSession() {
    if let session = session {
      for rig in rigs.values {
        rig.movie?.stopRecording()
        rig.videoData.setSampleBufferDelegate(nil, queue: nil)
      }
      session.stopRunning()
    }
    session = nil
    audioInput = nil
    rigs = [:]
    recording = []
  }

  private func attach(
    device: AVCaptureDevice, key: String, to session: AVCaptureSession, multi: Bool, record: Bool
  ) throws -> Rig {
    let input = try AVCaptureDeviceInput(device: device)
    guard let texture = textures[key] else {
      throw CameraError.failed("No texture registered for the \(key) camera.")
    }

    let videoData = AVCaptureVideoDataOutput()
    videoData.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    videoData.alwaysDiscardsLateVideoFrames = true
    videoData.setSampleBufferDelegate(texture, queue: texture.queue)

    let stills: AVCapturePhotoOutput? = record ? nil : AVCapturePhotoOutput()
    let movie: AVCaptureMovieFileOutput? = record ? AVCaptureMovieFileOutput() : nil

    // One output per camera besides the preview stream — that budget is what
    // keeps the multi-cam path configurable on more devices.
    var outputs: [AVCaptureOutput] = [videoData]
    if let stills = stills { outputs.append(stills) }
    if let movie = movie { outputs.append(movie) }

    if multi {
      guard session.canAddInput(input) else {
        throw CameraError.failed("Cannot use the \(key) camera.")
      }
      session.addInputWithNoConnections(input)
      let ports = input.ports(
        for: .video, sourceDeviceType: device.deviceType, sourceDevicePosition: device.position)

      for output in outputs {
        guard session.canAddOutput(output) else {
          throw CameraError.failed("Cannot add an output for the \(key) camera.")
        }
        session.addOutputWithNoConnections(output)
        let connection = AVCaptureConnection(inputPorts: ports, output: output)
        guard session.canAddConnection(connection) else {
          throw CameraError.failed("Device cannot run this combination of cameras and outputs.")
        }
        session.addConnection(connection)
        orient(connection, front: device.position == .front)
      }
    } else {
      guard session.canAddInput(input) else {
        throw CameraError.failed("Cannot use the \(key) camera.")
      }
      session.addInput(input)
      for output in outputs {
        guard session.canAddOutput(output) else {
          throw CameraError.failed("Cannot add an output for the \(key) camera.")
        }
        session.addOutput(output)
        if let connection = output.connection(with: .video) {
          orient(connection, front: device.position == .front)
        }
      }
    }

    let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
    let sideways = Int(uprightAngle) % 180 != 0
    return Rig(
      key: key,
      device: device,
      videoData: videoData,
      photo: stills,
      movie: movie,
      texture: texture,
      width: Int(sideways ? dims.height : dims.width),
      height: Int(sideways ? dims.width : dims.height))
  }

  /// Multi-cam only runs on formats that advertise `isMultiCamSupported`.
  private func lockToMultiCamFormat(_ device: AVCaptureDevice) throws {
    let best = device.formats.filter { $0.isMultiCamSupported }.max {
      DualSession.pixelCount($0) < DualSession.pixelCount($1)
    }
    guard let format = best else {
      throw CameraError.failed("Camera has no multi-cam capable format.")
    }
    try device.lockForConfiguration()
    device.activeFormat = format
    device.unlockForConfiguration()
  }

  // MARK: Geometry

  /// Degrees the connection must rotate for output to be upright.
  private var uprightAngle: CGFloat {
    switch orientation {
    case .landscapeLeft: return 0
    case .landscapeRight: return 180
    case .portraitUpsideDown: return 270
    default: return 90
    }
  }

  /// Rotates and mirrors at the connection, so the pixel buffers Flutter gets
  /// are already upright — Dart then reports `sensorOrientation: 0`.
  private func orient(_ connection: AVCaptureConnection, front: Bool) {
    if #available(iOS 17.0, *) {
      if connection.isVideoRotationAngleSupported(uprightAngle) {
        connection.videoRotationAngle = uprightAngle
      }
    } else if connection.isVideoOrientationSupported {
      switch orientation {
      case .landscapeLeft: connection.videoOrientation = .landscapeRight
      case .landscapeRight: connection.videoOrientation = .landscapeLeft
      case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
      default: connection.videoOrientation = .portrait
      }
    }
    if front, connection.isVideoMirroringSupported {
      connection.automaticallyAdjustsVideoMirroring = false
      connection.isVideoMirrored = true
    }
  }

  // MARK: Payloads

  private func describe() -> [String: Any] {
    var feeds: [String: Any] = [:]
    for (key, rig) in rigs {
      feeds[key] = [
        "textureId": rig.texture.id,
        "width": rig.width,
        "height": rig.height,
        // Already applied at the connection.
        "sensorOrientation": 0,
        "mirrored": false,
      ]
    }
    return ["mode": simultaneous ? "simultaneous" : "sequential", "feeds": feeds]
  }

  private func photoSettings() -> AVCapturePhotoSettings {
    AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
  }

  // MARK: Static helpers

  private static func device(at position: AVCaptureDevice.Position) throws -> AVCaptureDevice {
    let found = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: position
    ).devices.first
    guard let device = found else {
      throw CameraError(
        code: "no_camera",
        message: "This device has no \(position == .back ? "back" : "front") camera.")
    }
    return device
  }

  private static func pixelCount(_ format: AVCaptureDevice.Format) -> Int {
    let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    return Int(dims.width) * Int(dims.height)
  }

  static func cacheURL(_ label: String, _ ext: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "adc_\(label)_\(UInt64(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(8)).\(ext)"
    )
  }

  static func write(_ data: Data, _ label: String, _ ext: String) throws -> String {
    let url = cacheURL(label, ext)
    try data.write(to: url)
    return url.path
  }
}

/// One camera's inputs and outputs for the current session configuration.
private final class Rig {
  init(
    key: String, device: AVCaptureDevice, videoData: AVCaptureVideoDataOutput,
    photo: AVCapturePhotoOutput?, movie: AVCaptureMovieFileOutput?, texture: CameraTexture,
    width: Int, height: Int
  ) {
    self.key = key
    self.device = device
    self.videoData = videoData
    self.photo = photo
    self.movie = movie
    self.texture = texture
    self.width = width
    self.height = height
  }

  let key: String
  let device: AVCaptureDevice
  let videoData: AVCaptureVideoDataOutput
  let photo: AVCapturePhotoOutput?
  let movie: AVCaptureMovieFileOutput?
  let texture: CameraTexture
  let width: Int
  let height: Int
  var movieCollector: MovieCollector?
}

// MARK: - Texture

/// Bridges an `AVCaptureVideoDataOutput` to a Flutter texture.
private final class CameraTexture: NSObject, FlutterTexture,
  AVCaptureVideoDataOutputSampleBufferDelegate
{
  let queue = DispatchQueue(label: "adaptive_dual_camera.texture")
  var id: Int64 = 0
  weak var registry: (any FlutterTextureRegistry)?

  private let lock = NSLock()
  private var latest: CVPixelBuffer?

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let buffer = latest else { return nil }
    return Unmanaged.passRetained(buffer)
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    lock.lock()
    latest = buffer
    lock.unlock()
    registry?.textureFrameAvailable(id)
  }
}

// MARK: - One-shot delegates

/// Turns the one-shot photo callback into a blocking wait.
/// `AVCapturePhotoOutput` does not retain its delegate, so callers keep this alive.
private final class PhotoCollector: NSObject, AVCapturePhotoCaptureDelegate {
  private let ready = DispatchSemaphore(value: 0)
  private var data: Data?
  private var error: Error?

  func photoOutput(
    _ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?
  ) {
    self.error = error
    self.data = photo.fileDataRepresentation()
    ready.signal()
  }

  func wait(_ timeout: TimeInterval) throws -> Data {
    guard ready.wait(timeout: .now() + timeout) == .success else {
      throw CameraError.failed("Timed out waiting for a photo.")
    }
    if let error = error { throw error }
    guard let data = data else { throw CameraError.failed("Photo produced no JPEG data.") }
    return data
  }
}

/// Turns the movie-finished callback into a blocking wait.
private final class MovieCollector: NSObject, AVCaptureFileOutputRecordingDelegate {
  private let ready = DispatchSemaphore(value: 0)
  private var url: URL?
  private var error: Error?

  func fileOutput(
    _ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection], error: Error?
  ) {
    // A non-nil error can still mean a usable file (max duration/file size).
    let salvageable =
      ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
    self.error = salvageable ? nil : error
    self.url = outputFileURL
    ready.signal()
  }

  func wait(_ timeout: TimeInterval) throws -> URL {
    guard ready.wait(timeout: .now() + timeout) == .success else {
      throw CameraError.failed("Timed out waiting for a recording.")
    }
    if let error = error { throw error }
    guard let url = url else { throw CameraError.failed("Recording produced no file.") }
    return url
  }
}
