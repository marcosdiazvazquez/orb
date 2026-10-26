import CoreMotion
import Foundation
import PanoCore

/// Device attitude from Core Motion as a device-to-world rotation (world Z up, X arbitrary but
/// fixed while running, or north in a compass frame), with a short history so a photo can be
/// matched to the attitude at the instant it was exposed.
final class MotionTracker: @unchecked Sendable {
    struct Sample {
        let time: TimeInterval      // seconds since boot, same clock as AVCapturePhoto.timestamp
        let rotation: Mat3          // device -> world
        let rate: Double            // angular speed, rad/s
        /// Whether Core Motion counts the compass as calibrated; always false in a frame that
        /// doesn't use it.
        let compassCalibrated: Bool
    }

    private let manager = CMMotionManager()
    private let frame: CMAttitudeReferenceFrame
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()
    private let lock = NSLock()
    private var samples: [Sample] = []
    /// Whether CMQuaternion maps world to device rather than device to world. Settled from the
    /// first tilted sample by checking which reading reproduces the measured gravity.
    private var transposed: Bool?

    /// The default is a gyroscope-only heading. With the compass correcting it
    /// (.xArbitraryCorrectedZVertical), steel and wiring indoors swung the heading by up to 13°
    /// during a capture (tilt stayed within 3°); the gyroscope alone drifts far less over a minute
    /// or two. `Compass` uses a north frame to find north in that one.
    init(frame: CMAttitudeReferenceFrame = .xArbitraryZVertical) {
        self.frame = frame
    }

    var isAvailable: Bool {
        manager.isDeviceMotionAvailable && CMMotionManager.availableAttitudeReferenceFrames().contains(frame)
    }

    func start(hz: Double = 100) {
        guard isAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1 / hz
        manager.startDeviceMotionUpdates(using: frame, to: queue) { [weak self] motion, _ in
            if let motion { self?.record(motion) }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        lock.lock(); samples.removeAll(); lock.unlock()
    }

    var latest: Sample? {
        lock.lock(); defer { lock.unlock() }
        return samples.last
    }

    /// Attitude at `time`, interpolated between the bracketing samples; nil if outside the history.
    func rotation(at time: TimeInterval) -> Mat3? {
        lock.lock(); defer { lock.unlock() }
        guard let first = samples.first, let last = samples.last,
              time >= first.time - 0.02, time <= last.time + 0.05 else { return nil }
        guard let k = samples.firstIndex(where: { $0.time >= time }) else { return last.rotation }
        if k == 0 { return samples[0].rotation }
        let a = samples[k - 1], b = samples[k]
        let t = (time - a.time) / max(1e-6, b.time - a.time)
        let delta = (b.rotation * a.rotation.transposed).axisAngle
        return (Mat3.rotation(delta * t) * a.rotation).orthonormalized
    }

    private func record(_ m: CMDeviceMotion) {
        let q = m.attitude.quaternion
        let raw = Mat3.fromQuaternion(w: q.w, x: q.x, y: q.y, z: q.z)
        lock.lock(); defer { lock.unlock() }
        if transposed == nil {
            let g = Vec3(m.gravity.x, m.gravity.y, m.gravity.z)
            let down = Vec3(0, 0, -1)
            let errAsIs = (raw.transposed * down - g).length
            let errTransposed = (raw * down - g).length
            if abs(errAsIs - errTransposed) > 0.3 { transposed = errTransposed < errAsIs }
        }
        let r = m.rotationRate
        samples.append(Sample(time: m.timestamp,
                              rotation: transposed == true ? raw.transposed : raw,
                              rate: sqrt(r.x * r.x + r.y * r.y + r.z * r.z),
                              compassCalibrated: m.magneticField.accuracy.rawValue >= CMMagneticFieldCalibrationAccuracy.low.rawValue))
        if samples.count > 400 { samples.removeFirst(samples.count - 300) }
    }
}
