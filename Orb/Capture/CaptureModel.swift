import AVFoundation
import Observation
import PanoCore
import UIKit

/// Drives a guided capture: lays the shot plan out around the starting heading, tracks where
/// the camera points, and fires the shutter when the reticle sits steadily on a target.
@Observable @MainActor
final class CaptureModel {
    enum Phase: Equatable {
        case starting
        case aiming
        case failed(String)
    }

    private(set) var phase: Phase = .starting
    private(set) var targets: [ShotTarget] = []
    /// World directions of the targets, once the starting heading is known.
    private(set) var targetDirections: [Vec3] = []
    private(set) var done: Set<Int> = []
    private(set) var shots: [ShotRecord] = []
    /// Camera-to-world rotations of the shots taken, for drawing their outlines.
    private(set) var shotRotations: [Mat3] = []
    /// Live camera-to-world rotation.
    private(set) var cameraRotation: Mat3?
    private(set) var nextTarget: Int?
    /// 0...1 while the reticle is held on a target; the shutter fires at 1.
    private(set) var hold: Double = 0
    private(set) var isShooting = false
    private(set) var shotCounter = 0
    private(set) var longFOV = 106.0 * .pi / 180
    let aspect = 4.0 / 3.0

    var shortFOV: Double { 2 * atan(tan(longFOV / 2) / aspect) }
    var isComplete: Bool { !targets.isEmpty && done.count == targets.count }
    var session: AVCaptureSession { camera.session }

    let id = UUID()
    private let directory: URL
    private let camera = CameraController()
    private let motion = MotionTracker()
    private var lens: Lens = .ultraWide
    private var lockExposure = true
    private var timer: Timer?
    private var lastTick = CACurrentMediaTime()
    private let haptics = UIImpactFeedbackGenerator(style: .medium)

    init() {
        directory = CaptureStore.directory(for: id)
    }

    func start(lens requested: Lens, density: ShotDensity, lockExposure: Bool) async {
        guard phase == .starting, timer == nil else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .video) { break }
            phase = .failed("Orb needs the camera. Allow it in Settings › Orb › Camera.")
            return
        default:
            phase = .failed("Orb needs the camera. Allow it in Settings › Orb › Camera.")
            return
        }
        guard motion.isAvailable else {
            phase = .failed("This device has no gyroscope, which guided capture needs.")
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let info = try await camera.configure(lens: requested)
            guard !Task.isCancelled else { return }  // screen closed while the camera opened
            lens = info.lens
            longFOV = info.longFOV
            self.lockExposure = lockExposure
            targets = ShotPlan(shortFOV: shortFOV, overlap: density.overlap).targets
            camera.start()
            motion.start()
            UIApplication.shared.isIdleTimerDisabled = true
            haptics.prepare()
            phase = .aiming
            lastTick = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        camera.stop()
        motion.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func discard() {
        stop()
        try? FileManager.default.removeItem(at: directory)
    }

    func makeRecord() -> CaptureRecord {
        CaptureRecord(id: id, date: Date(), lens: lens, longFOV: longFOV, plannedShots: targets.count,
                      shots: shots, panorama: nil, stitchError: nil)
    }

    func undoLast() {
        guard !isShooting, let last = shots.popLast() else { return }
        try? FileManager.default.removeItem(at: directory.appending(path: last.file))
        shotRotations.removeLast()
        done.remove(last.target)
        if shots.isEmpty && lockExposure { Task { await camera.setLocked(false) } }
    }

    // MARK: - Aiming

    private var alignTolerance: Double { min(3, degreesOf(shortFOV) * 0.04) * .pi / 180 }
    private let steadyRate = 0.08       // rad/s (~4.6°/s)
    private let holdTime = 0.3          // seconds on target before the shutter fires

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(0.1, now - lastTick)
        lastTick = now
        guard phase == .aiming, let sample = motion.latest else { return }
        let cam = sample.rotation * deviceFromBackCamera
        cameraRotation = cam
        let axis = cam.column(2)

        if targetDirections.isEmpty {
            // Longitude 0 of the plan is wherever the phone points when tracking starts.
            let turn = Mat3.yaw(-axis.longitude)
            targetDirections = targets.map { turn * $0.direction }
        }

        let pending = targets.indices.filter { !done.contains($0) }
        guard let next = pending.min(by: { axis.angle(to: targetDirections[$0]) < axis.angle(to: targetDirections[$1]) }) else {
            nextTarget = nil
            return
        }
        nextTarget = next
        guard !isShooting else { return }
        let onTarget = axis.angle(to: targetDirections[next]) < alignTolerance && sample.rate < steadyRate
        hold = onTarget ? min(1, hold + dt / holdTime) : max(0, hold - dt / 0.15)
        if hold >= 1 {
            Task { await shoot(next) }
        }
    }

    private func shoot(_ target: Int) async {
        guard !isShooting else { return }
        isShooting = true
        hold = 0
        defer { isShooting = false }

        if shots.isEmpty && lockExposure { await camera.setLocked(true) }
        guard timer != nil else { return }  // capture stopped meanwhile
        let shutterTime = ProcessInfo.processInfo.systemUptime
        let shutterRotation = motion.latest?.rotation
        haptics.impactOccurred()
        do {
            let photo = try await camera.capture()
            // Prefer the attitude at the exposure itself; fall back to the shutter press.
            let t = abs(photo.timestamp - shutterTime) < 1 ? photo.timestamp : shutterTime
            guard let rotation = motion.rotation(at: t) ?? shutterRotation else { return }
            let name = String(format: "shot-%02d.%@", shots.count, photo.fileExtension)
            try photo.data.write(to: directory.appending(path: name))
            shots.append(ShotRecord(file: name, target: target, deviceRotation: rotation.rowMajor, time: t))
            shotRotations.append(rotation * deviceFromBackCamera)
            done.insert(target)
            shotCounter += 1
            haptics.prepare()
        } catch {
            // A dropped frame just leaves the target pending; the user re-aims.
        }
    }
}

private func degreesOf(_ r: Double) -> Double { r * 180 / .pi }
