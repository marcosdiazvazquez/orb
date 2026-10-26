import CoreMotion
import Foundation
import PanoCore
import SwiftUI

/// Finds which way north is in `MotionTracker`'s gyroscope-only frame, whose X axis points
/// wherever the phone happened to when tracking began. A second tracker, steered by the compass,
/// reads the same attitudes against north, and each pair of readings gives the bearing of that X
/// axis. The compass swings near steel and wiring, which is why the shots don't use it directly,
/// but a capture turns the phone all the way round, and averaging over it evens the swings out.
@MainActor
final class Compass {
    private var tracker = MotionTracker()
    private var trueNorth = true
    private var all = BearingMean()
    private var calibrated = BearingMean()
    private var first: TimeInterval?
    private var last: TimeInterval?

    /// True north needs location access, for the magnetic declination; without it, the
    /// bearings are from magnetic north.
    func start(trueNorth: Bool) {
        self.trueNorth = trueNorth
        tracker = MotionTracker(frame: trueNorth ? .xTrueNorthZVertical : .xMagneticNorthZVertical)
        all = BearingMean()
        calibrated = BearingMean()
        first = nil
        last = nil
        tracker.start(hz: 30)
    }

    func stop() {
        tracker.stop()
    }

    /// Pairs the newest compass reading with `motion`'s attitude at the same instant. Call
    /// often while capturing.
    func update(against motion: MotionTracker) {
        guard let north = tracker.latest, north.time != last else { return }
        last = north.time
        if first == nil { first = north.time }
        // The compass frame takes a moment to settle after it starts.
        guard let first, north.time - first > 1, let gyro = motion.rotation(at: north.time) else { return }
        // The gyroscope frame's X axis, in the north frame (X north, Y west, so longitude is the
        // bearing).
        let x = (north.rotation * gyro.transposed).column(0)
        all.add(x.longitude)
        if north.compassCalibrated { calibrated.add(x.longitude) }
    }

    /// Readings from while Core Motion counted the compass as calibrated, if there are enough;
    /// nil until there are enough of any.
    var heading: CaptureHeading? {
        let readings = calibrated.count >= 30 ? calibrated : all
        guard readings.count >= 30, let mean = readings.mean else { return nil }
        return CaptureHeading(worldX: Bearing.normalized(mean * 180 / .pi), spread: readings.spread * 180 / .pi,
                              trueNorth: trueNorth)
    }
}

/// Running circular mean of angles, in radians.
private struct BearingMean {
    private var x = 0.0, y = 0.0
    private(set) var count = 0

    mutating func add(_ angle: Double) {
        x += cos(angle)
        y += sin(angle)
        count += 1
    }

    /// Length of the mean of the angles' unit vectors: 1 when they all agree.
    private var resultant: Double { count > 0 ? hypot(x, y) / Double(count) : 0 }
    var mean: Double? { resultant > 1e-6 ? atan2(y, x) : nil }
    /// Circular standard deviation.
    var spread: Double { sqrt(-2 * log(max(1e-12, resultant))) }
}

enum Bearing {
    /// In 0..<360 degrees.
    static func normalized(_ degrees: Double) -> Double {
        // Twice, since adding 360 to a tiny negative remainder rounds to 360.
        (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    /// "47° NE": whole degrees from north, and the nearest of the eight compass points.
    static func label(_ degrees: Double) -> String {
        let d = normalized(degrees.rounded())
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return "\(Int(d))° \(points[Int((d / 45).rounded()) % 8])"
    }
}

/// The bearing the camera or the view faces, with an arrow that points north.
struct BearingLabel: View {
    let degrees: Double

    var body: some View {
        Label {
            Text(Bearing.label(degrees))
        } icon: {
            Image(systemName: "location.north.fill").rotationEffect(.degrees(-degrees))
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityLabel("Facing \(Bearing.label(degrees))")
    }
}
