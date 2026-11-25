import AVFoundation
import Flutter

/// Holds the front and back cameras open at the same time and takes one still
/// from each, together.
///
/// Deliberately *not* a compositor: each preview is published as its own
/// Flutter texture and each still is written as its own JPEG. Composing the
/// two into the final layout is the Dart side's job, which keeps this class
/// small and keeps the saved image identical to the sequential path's.
@available(iOS 13.0, *)
final class ConcurrentCaptureSession: NSObject {
  private let session = AVCaptureMultiCamSession()
  private let registry: FlutterTextureRegistry
  private let sessionQueue = DispatchQueue(label: "adaptive_dual_camera.session")

  private let backTexture = PreviewTexture()
  private let frontTexture = PreviewTexture()
  private var backTextureId: Int64 = 0
  private var frontTextureId: Int64 = 0

  private let backPhoto = AVCapturePhotoOutput()
  private let frontPhoto = AVCapturePhotoOutput()

  /// One in-flight `captureBoth`, holding both halves until they land.
  private var pending: PendingCapture?

  private(set) var isRunning = false

  init(registry: FlutterTextureRegistry) {
    self.registry = registry
    super.init()
  }

  // MARK: - Lifecycle

  func start(
    onReady: @escaping ([String: Any]) -> Void,
    onError: @escaping (String) -> Void
  ) {
    guard AVCaptureMultiCamSession.isMultiCamSupported else {
      onError("This device does not support AVCaptureMultiCamSession")
      return
    }
    sessionQueue.async { [weak self] in
      guard let self else { return }
      do {
        try self.configure()
        self.session.startRunning()
        self.isRunning = true

        // Registering after configuration so the first frame has somewhere
        // to land.
        self.backTextureId = self.registry.register(self.backTexture)
        self.frontTextureId = self.registry.register(self.frontTexture)
        self.backTexture.onFrame = { [weak self] in
          guard let self else { return }
          self.registry.textureFrameAvailable(self.backTextureId)
        }
        self.frontTexture.onFrame = { [weak self] in
          guard let self else { return }
          self.registry.textureFrameAvailable(self.frontTextureId)
        }

        DispatchQueue.main.async {
          onReady([
            "backTextureId": self.backTextureId,
            "frontTextureId": self.frontTextureId,
            // iOS delivers portrait-corrected buffers via the connection's
            // videoOrientation, so Dart needs no extra rotation.
            "backRotation": 0,
            "frontRotation": 0,
          ])
        }
      } catch {
        self.stop()
        DispatchQueue.main.async { onError("\(error)") }
      }
    }
  }

  private func configure() throws {
    session.beginConfiguration()
    defer { session.commitConfiguration() }

    try add(position: .back, output: backPhoto, texture: backTexture)
    try add(position: .front, output: frontPhoto, texture: frontTexture)
  }

  /// MultiCam sessions must wire every connection manually — the convenience
  /// `addInput`/`addOutput` pair would claim exclusive use of the device.
  private func add(
    position: AVCaptureDevice.Position,
    output: AVCapturePhotoOutput,
    texture: PreviewTexture
  ) throws {
    guard
      let device = AVCaptureDevice.default(
        .builtInWideAngleCamera, for: .video, position: position)
    else {
      throw SessionError.noCamera(position == .front ? "front" : "back")
    }

    // Pick a multi-cam-capable format; the hardware refuses to run otherwise.
    if let format = device.formats.first(where: { $0.isMultiCamSupported }) {
      try device.lockForConfiguration()
      device.activeFormat = format
      device.unlockForConfiguration()
    }

    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else { throw SessionError.cannotAddInput }
    session.addInputWithNoConnections(input)

    guard session.canAddOutput(output) else { throw SessionError.cannotAddOutput }
    session.addOutputWithNoConnections(output)

    let videoOutput = AVCaptureVideoDataOutput()
    videoOutput.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    videoOutput.setSampleBufferDelegate(texture, queue: sessionQueue)
    guard session.canAddOutput(videoOutput) else { throw SessionError.cannotAddOutput }
    session.addOutputWithNoConnections(videoOutput)

    guard
      let port = input.ports(
        for: .video, sourceDeviceType: device.deviceType, sourceDevicePosition: position
      ).first
    else {
      throw SessionError.noPort
    }

    for connection in [
      AVCaptureConnection(inputPorts: [port], output: videoOutput),
      AVCaptureConnection(inputPorts: [port], output: output),
    ] {
      guard session.canAddConnection(connection) else {
        throw SessionError.cannotAddConnection
      }
      connection.videoOrientation = .portrait
      if position == .front, connection.isVideoMirroringSupported {
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
      }
      session.addConnection(connection)
    }
  }

  func stop() {
    if session.isRunning { session.stopRunning() }
    isRunning = false
    if backTextureId != 0 { registry.unregisterTexture(backTextureId) }
    if frontTextureId != 0 { registry.unregisterTexture(frontTextureId) }
    backTextureId = 0
    frontTextureId = 0
    pending = nil
  }

  // MARK: - Capture

  /// Fire both shutters and reply once both JPEGs are on disk. Either failing
  /// fails the whole capture — a half-simultaneous result is worse than
  /// falling back.
  func captureBoth(
    onResult: @escaping ([String: String]) -> Void,
    onError: @escaping (String) -> Void
  ) {
    guard isRunning else {
      onError("Session is not running")
      return
    }
    guard pending == nil else {
      onError("A capture is already in flight")
      return
    }
    pending = PendingCapture(onResult: onResult, onError: onError)

    // Both requests go out before either delegate callback can land.
    let settings = { AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]) }
    backPhoto.capturePhoto(with: settings(), delegate: self)
    frontPhoto.capturePhoto(with: settings(), delegate: self)
  }

  private enum SessionError: Error {
    case noCamera(String)
    case cannotAddInput
    case cannotAddOutput
    case cannotAddConnection
    case noPort
  }

  private final class PendingCapture {
    let onResult: ([String: String]) -> Void
    let onError: (String) -> Void
    var backPath: String?
    var frontPath: String?
    var failure: String?
    var settled = 0

    init(
      onResult: @escaping ([String: String]) -> Void,
      onError: @escaping (String) -> Void
    ) {
      self.onResult = onResult
      self.onError = onError
    }
  }
}

// MARK: - Photo delegate

@available(iOS 13.0, *)
extension ConcurrentCaptureSession: AVCapturePhotoCaptureDelegate {
  func photoOutput(
    _ output: AVCapturePhotoOutput,
    didFinishProcessingPhoto photo: AVCapturePhoto,
    error: Error?
  ) {
    guard let pending else { return }
    let isFront = output === frontPhoto

    if let error {
      pending.failure = "\(error)"
    } else if let data = photo.fileDataRepresentation() {
      let stamp = Int(Date().timeIntervalSince1970 * 1000)
      let name = "ADC_\(isFront ? "front" : "back")_\(stamp).jpg"
      let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
      do {
        try data.write(to: url)
        if isFront { pending.frontPath = url.path } else { pending.backPath = url.path }
      } catch {
        pending.failure = "\(error)"
      }
    } else {
      pending.failure = "Photo produced no data"
    }

    pending.settled += 1
    guard pending.settled == 2 else { return }
    self.pending = nil

    DispatchQueue.main.async {
      if let failure = pending.failure {
        pending.onError(failure)
      } else if let back = pending.backPath, let front = pending.frontPath {
        pending.onResult(["backPath": back, "frontPath": front])
      } else {
        pending.onError("One of the two photos is missing")
      }
    }
  }
}

/// Publishes one camera's frames as a Flutter texture.
final class PreviewTexture: NSObject, FlutterTexture,
  AVCaptureVideoDataOutputSampleBufferDelegate
{
  private var latest: CVPixelBuffer?
  private let lock = NSLock()
  var onFrame: (() -> Void)?

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let latest else { return nil }
    return Unmanaged.passRetained(latest)
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    lock.lock()
    latest = buffer
    lock.unlock()
    onFrame?()
  }
}
