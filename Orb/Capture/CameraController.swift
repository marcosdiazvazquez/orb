import AVFoundation
import Foundation

enum CameraError: LocalizedError {
    case noCamera
    case cannotConfigure
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .noCamera: "This device has no back camera."
        case .cannotConfigure: "The camera could not be set up."
        case .captureFailed: "The photo could not be taken."
        }
    }
}

/// The back camera and a photo output. All session work runs on a private serial queue.
final class CameraController: NSObject, @unchecked Sendable {
    struct Info: Sendable {
        var lens: Lens
        /// Field of view across the photo's long side, radians.
        var longFOV: Double
    }

    struct Photo: Sendable {
        var data: Data
        var fileExtension: String
        /// Host-clock seconds (same clock as Core Motion timestamps).
        var timestamp: TimeInterval
    }

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "orb.camera")
    private var device: AVCaptureDevice?
    private var inFlight: [Int64: PhotoDelegate] = [:]

    func configure(lens: Lens) async throws -> Info {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try self.configureOnQueue(lens)) } catch { cont.resume(throwing: error) }
            }
        }
    }

    private func configureOnQueue(_ lens: Lens) throws -> Info {
        let ultra = lens == .ultraWide
            ? AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) : nil
        guard let dev = ultra ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: dev)

        session.beginConfiguration()
        session.sessionPreset = .photo
        for old in session.inputs { session.removeInput(old) }
        guard session.canAddInput(input) else { session.commitConfiguration(); throw CameraError.cannotConfigure }
        session.addInput(input)
        if !session.outputs.contains(output) {
            guard session.canAddOutput(output) else { session.commitConfiguration(); throw CameraError.cannotConfigure }
            session.addOutput(output)
        }
        output.maxPhotoQualityPrioritization = .balanced
        // Photos come out upright for a portrait-held phone whatever its real orientation;
        // the motion data carries the actual attitude.
        if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        session.commitConfiguration()

        try dev.lockForConfiguration()
        if dev.isGeometricDistortionCorrectionSupported { dev.isGeometricDistortionCorrectionEnabled = true }
        if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
        if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
        if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { dev.whiteBalanceMode = .continuousAutoWhiteBalance }
        dev.unlockForConfiguration()
        device = dev

        let format = dev.activeFormat
        let degrees = dev.isGeometricDistortionCorrectionEnabled
            ? format.geometricDistortionCorrectedVideoFieldOfView : format.videoFieldOfView
        return Info(lens: dev.deviceType == .builtInUltraWideCamera ? .ultraWide : .wide,
                    longFOV: Double(degrees) * .pi / 180)
    }

    func start() { queue.async { if !self.session.isRunning { self.session.startRunning() } } }
    func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }

    /// Freezes (or releases) exposure, white balance and focus at their current values, so
    /// every shot of a sphere is exposed alike.
    func setLocked(_ locked: Bool) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                defer { cont.resume() }
                guard let dev = self.device, (try? dev.lockForConfiguration()) != nil else { return }
                if locked {
                    if dev.isExposureModeSupported(.locked) { dev.exposureMode = .locked }
                    if dev.isWhiteBalanceModeSupported(.locked) { dev.whiteBalanceMode = .locked }
                    if dev.isFocusModeSupported(.locked) { dev.focusMode = .locked }
                } else {
                    if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
                    if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { dev.whiteBalanceMode = .continuousAutoWhiteBalance }
                    if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
                }
                dev.unlockForConfiguration()
            }
        }
    }

    func capture() async throws -> Photo {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard self.session.isRunning, self.output.connection(with: .video)?.isActive == true else {
                    cont.resume(throwing: CameraError.captureFailed)
                    return
                }
                let hevc = self.output.availablePhotoCodecTypes.contains(.hevc)
                let settings = hevc ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                                    : AVCapturePhotoSettings()
                // Least multi-frame processing: neighbouring shots then get the same tone curve.
                settings.photoQualityPrioritization = .speed
                let id = settings.uniqueID
                let delegate = PhotoDelegate(fileExtension: hevc ? "heic" : "jpg") { result in
                    self.queue.async { self.inFlight[id] = nil }
                    cont.resume(with: result)
                }
                self.inFlight[id] = delegate
                self.output.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }
}

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let fileExtension: String
    private let completion: (Result<CameraController.Photo, Error>) -> Void
    private var result: Result<CameraController.Photo, Error>?

    init(fileExtension: String, completion: @escaping (Result<CameraController.Photo, Error>) -> Void) {
        self.fileExtension = fileExtension
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            result = .failure(error)
        } else if let data = photo.fileDataRepresentation() {
            result = .success(.init(data: data, fileExtension: fileExtension, timestamp: photo.timestamp.seconds))
        } else {
            result = .failure(CameraError.captureFailed)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        completion(result ?? .failure(error ?? CameraError.captureFailed))
    }
}
