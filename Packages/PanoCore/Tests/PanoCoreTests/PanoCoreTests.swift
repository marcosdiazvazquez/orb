import Foundation
import XCTest
@testable import PanoCore

final class MathTests: XCTestCase {
    func testRotationRoundTrip() {
        var rng = LCG(state: 1)
        for _ in 0..<200 {
            let w = rng.unitVector() * (rng.next() * 3.1)
            let back = Mat3.rotation(w).axisAngle
            XCTAssertLessThan((back - w).length, 1e-9)
        }
    }

    func testQuaternionMatchesRodrigues() {
        let axis = Vec3(1, 2, -0.5).normalized, angle = 0.8
        let q = (w: cos(angle / 2), x: axis.x * sin(angle / 2), y: axis.y * sin(angle / 2), z: axis.z * sin(angle / 2))
        let a = Mat3.fromQuaternion(w: q.w, x: q.x, y: q.y, z: q.z)
        let b = Mat3.rotation(axis: axis, angle: angle)
        XCTAssertLessThan((a * b.transposed).rotationAngle, 1e-9)
    }

    func testEquirectRoundTripAndHandedness() {
        for (u, v) in [(0.1, 0.2), (0.5, 0.5), (0.9, 0.7), (0.33, 0.95)] {
            let back = Equirect.uv(Equirect.direction(u: u, v: v))
            XCTAssertEqual(back.u, u, accuracy: 1e-9)
            XCTAssertEqual(back.v, v, accuracy: 1e-9)
        }
        XCTAssertLessThan((Equirect.direction(u: 0.5, v: 0.5) - Vec3(1, 0, 0)).length, 1e-12)
        XCTAssertLessThan((Equirect.direction(u: 0.5, v: 0) - Vec3(0, 0, 1)).length, 1e-12)
        // Standing at the centre facing +X with Z up, your right hand points to -Y.
        XCTAssertGreaterThan(Equirect.uv(Vec3(1, -0.1, 0)).u, 0.5)
    }

    /// A phone held upright in portrait, back camera facing world +X: pixels right of the
    /// image centre must land right of the panorama centre, pixels above it above the horizon.
    func testBackCameraAxes() {
        // Device frame in world: back of the phone (-z) faces +X, top edge (+y) points up.
        let deviceToWorld = Mat3(columns: Vec3(0, -1, 0), Vec3(0, 0, 1), Vec3(-1, 0, 0))
        let cam = PinholeCamera(width: 300, height: 400, focal: 300,
                                rotation: deviceToWorld * deviceFromBackCamera)
        XCTAssertLessThan((cam.opticalAxis - Vec3(1, 0, 0)).length, 1e-12)
        let right = Equirect.uv(cam.ray(250, 200)), up = Equirect.uv(cam.ray(150, 50))
        XCTAssertGreaterThan(right.u, 0.5)
        XCTAssertLessThan(up.v, 0.5)

        // The native landscape buffer is the portrait image before a 90° clockwise turn
        // (EXIF orientation 6): native (xn, yn) shows what portrait (H - yn, xn) shows.
        let native = PinholeCamera(width: 400, height: 300, focal: 300,
                                   rotation: deviceToWorld * deviceFromNativeBackCamera)
        for (xn, yn) in [(10.0, 20.0), (390.0, 150.0), (200.0, 299.0)] {
            let a = native.ray(xn, yn), b = cam.ray(300 - yn, xn)
            XCTAssertLessThan((a - b).length, 1e-12)
        }
    }
}

final class ShotPlanTests: XCTestCase {
    /// Every direction must be inside at least one frame, for portrait, landscape and upside down.
    private func assertCovers(_ plan: ShotPlan, longFOV: Double, aspect: Double, file: StaticString = #filePath, line: UInt = #line) {
        let longSide = 400
        let shortSide = Int(Double(longSide) / aspect)
        let f = PinholeCamera.focal(longSide: longSide, longSideFOV: longFOV)
        var rng = LCG(state: 3)
        let dirs = (0..<4000).map { _ in rng.unitVector() }
        for roll in [0.0, Double.pi / 2, Double.pi] {
            let cams = plan.targets.map {
                PinholeCamera(width: shortSide, height: longSide, focal: f, rotation: lookRotation($0.direction, roll: roll))
            }
            var worst = Double.infinity
            for d in dirs {
                var best = -Double.infinity
                for c in cams {
                    guard let p = c.project(d) else { continue }
                    let m = min(p.x, p.y, Double(c.width) - p.x, Double(c.height) - p.y) / Double(c.width)
                    best = max(best, m)
                }
                worst = min(worst, best)
            }
            XCTAssertGreaterThan(worst, 0.02, "roll \(roll): a direction is uncovered", file: file, line: line)
        }
    }

    func testUltraWidePlan() {
        let longFOV = radians(106), shortFOV = 2 * atan(tan(longFOV / 2) * 0.75)
        let plan = ShotPlan(shortFOV: shortFOV)
        print("ultra-wide plan: \(plan.count) shots, rings \(Dictionary(grouping: plan.targets, by: \.ring).mapValues(\.count))")
        XCTAssertLessThanOrEqual(plan.count, 18)
        assertCovers(plan, longFOV: longFOV, aspect: 4.0 / 3)
    }

    func testWidePlan() {
        let longFOV = radians(67), shortFOV = 2 * atan(tan(longFOV / 2) * 0.75)
        let plan = ShotPlan(shortFOV: shortFOV)
        print("wide plan: \(plan.count) shots, rings \(Dictionary(grouping: plan.targets, by: \.ring).mapValues(\.count))")
        XCTAssertLessThanOrEqual(plan.count, 48)
        assertCovers(plan, longFOV: longFOV, aspect: 4.0 / 3)
    }
}

struct SyntheticCapture {
    var truth: [Mat3]
    var shots: [StitchShot]
    var trueFocal: Double
}

/// Renders a full ultra-wide capture of the synthetic scene, then corrupts the "sensor"
/// rotations and focal length the way a phone's motion data would be wrong.
func makeCapture(rotationError: Double, focalError: Double, brightShot: Int? = nil) -> SyntheticCapture {
    let longFOV = radians(106), shortFOV = 2 * atan(tan(longFOV / 2) * 0.75)
    let plan = ShotPlan(shortFOV: shortFOV)
    let (w, h) = (480, 640)
    let f = PinholeCamera.focal(longSide: h, longSideFOV: longFOV)
    let scene = SyntheticScene()
    var rng = LCG(state: 11)
    var truth: [Mat3] = [], shots: [StitchShot] = []
    for t in plan.targets {
        let roll = (rng.next() - 0.5) * radians(10)
        let r = lookRotation(t.direction, roll: roll)
        truth.append(r)
        let cam = PinholeCamera(width: w, height: h, focal: f, rotation: r)
        let img = scene.render(cam, gain: t.id == brightShot ? 1.15 : 1)
        let noise = Mat3.rotation(rng.unitVector() * (rotationError * (0.5 + rng.next() * 0.5)))
        shots.append(StitchShot(image: img, rotation: noise * r, focal: f * (1 + focalError)))
    }
    return SyntheticCapture(truth: truth, shots: shots, trueFocal: f)
}

final class StitchTests: XCTestCase {
    /// Rotation error of each refined shot after removing the gauge (shot 0 is held fixed).
    func rotationErrors(_ report: StitchReport, _ truth: [Mat3]) -> [Double] {
        let m = report.rotations[0] * truth[0].transposed
        return truth.indices.map { degrees((report.rotations[$0] * truth[$0].transposed * m.transposed).rotationAngle) }
    }

    func psnr(_ pano: RGBAImage, against report: StitchReport, truth: [Mat3]) -> Double {
        let m = report.rotations[0] * truth[0].transposed
        let scene = SyntheticScene()
        var se = 0.0, n = 0
        // Skip the polar caps, where equirect pixels are tiny and sampling dominates.
        for y in stride(from: pano.height / 8, to: pano.height * 7 / 8, by: 2) {
            for x in stride(from: 0, to: pano.width, by: 2) {
                let d = Equirect.direction(u: (Double(x) + 0.5) / Double(pano.width), v: (Double(y) + 0.5) / Double(pano.height))
                let c = scene.color(m.transposed * d)
                let o = (y * pano.width + x) * 4
                let g0 = 0.299 * c.0 + 0.587 * c.1 + 0.114 * c.2
                let g1 = 0.299 * Double(pano.pixels[o]) + 0.587 * Double(pano.pixels[o + 1]) + 0.114 * Double(pano.pixels[o + 2])
                se += (g0 - g1) * (g0 - g1); n += 1
            }
        }
        return 10 * log10(255 * 255 / (se / Double(n)))
    }

    func testRefinementRecoversRotations() {
        let setup = makeCapture(rotationError: radians(2), focalError: 0.03, brightShot: 5)
        var opts = StitchOptions(outputWidth: 1536)

        opts.refine = false
        let (rawPano, rawReport) = Stitcher.stitch(setup.shots, options: opts)
        let rawErr = rotationErrors(rawReport, setup.truth)
        let rawPSNR = psnr(rawPano, against: rawReport, truth: setup.truth)

        opts.refine = true
        let (pano, report) = Stitcher.stitch(setup.shots, options: opts)
        let err = rotationErrors(report, setup.truth)
        let refinedPSNR = psnr(pano, against: report, truth: setup.truth)

        for r in report.rounds {
            print(String(format: "round %.2f°/px: %d pairs, %d matches, rms %.3f° -> %.3f°, inliers %.0f%%",
                         r.pixelAngleDegrees, r.pairs, r.matches, r.rmsBeforeDegrees, r.rmsAfterDegrees, r.inlierFraction * 100))
        }
        print(String(format: "sensor error max %.3f°, refined max %.3f°, focal scale %.4f (truth %.4f)",
                     rawErr.max()!, err.max()!, report.focalScale, 1 / 1.03))
        print(String(format: "PSNR raw %.1f dB, refined %.1f dB, %.1fs; gains %@", rawPSNR, refinedPSNR, report.seconds,
                     report.gains.map { String(format: "%.3f", $0) }.joined(separator: " ")))

        XCTAssertLessThan(err.max()!, 0.15)
        XCTAssertEqual(report.focalScale, 1 / 1.03, accuracy: 0.005)
        // Shot 0 is held fixed, so the centre is its input heading.
        let axis0 = setup.shots[0].rotation.column(2)
        XCTAssertEqual(report.centerLongitude, atan2(-axis0.y, axis0.x), accuracy: 1e-9)
        XCTAssertGreaterThan(refinedPSNR, rawPSNR + 3)
        // The brightened shot should be turned down relative to the rest.
        let others = report.gains.enumerated().filter { $0.offset != 5 }.map(\.element)
        let ratio = report.gains[5] / (others.reduce(0, +) / Double(others.count))
        XCTAssertEqual(ratio, 1 / 1.15, accuracy: 0.04)
    }

    func testHoleFillAndLittlePlanet() {
        var setup = makeCapture(rotationError: 0, focalError: 0)
        // Drop the bottom ring: the nadir becomes a hole that must be filled.
        let plan = ShotPlan(shortFOV: 2 * atan(tan(radians(53)) * 0.75))
        let keep = plan.targets.filter { $0.ring >= 0 }.map(\.id)
        setup.shots = keep.map { setup.shots[$0] }
        var opts = StitchOptions(outputWidth: 512)
        opts.refine = false
        let (pano, _) = Stitcher.stitch(setup.shots, options: opts)
        XCTAssertFalse(stride(from: 3, to: pano.pixels.count, by: 4).contains { pano.pixels[$0] == 0 })
        let planet = PanoRender.littlePlanet(pano, size: 128)
        XCTAssertEqual(planet.width, 128)
    }

    /// Real overlaps never agree exactly (noise, vignetting, slight misalignment). Gains should
    /// even them out without changing the overall brightness; they once came out near 0.25.
    func testGainsKeepBrightnessWhenOverlapsDisagree() {
        // A ring of four shots, each overlap 4% brighter in one shot than in the next, so no
        // gains can match them all. Counts are the size of real overlaps.
        let stats = (0..<4).map { OverlapStats(i: $0, j: ($0 + 1) % 4, meanI: 104, meanJ: 100, count: 500_000) }
        let gains = gainCompensation(count: 4, stats: stats)
        XCTAssertEqual(gains.reduce(0, +) / Double(gains.count), 1, accuracy: 0.03)
    }
}

/// Full-size timing run (ORB_PERF=1 swift test -c release --filter Perf): phone-sized shots, 6K output.
final class PerfTests: XCTestCase {
    func testPhoneSizedStitch() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ORB_PERF"] == "1")
        let longFOV = radians(106), shortFOV = 2 * atan(tan(longFOV / 2) * 0.75)
        let plan = ShotPlan(shortFOV: shortFOV)
        let (w, h) = (1500, 2000)
        let f = PinholeCamera.focal(longSide: h, longSideFOV: longFOV)
        var rng = LCG(state: 5)
        let scene = SyntheticScene()
        let renderStart = Date()
        let truthAndShots: [(Mat3, StitchShot)] = plan.targets.map { t in
            let r = lookRotation(t.direction, roll: (rng.next() - 0.5) * 0.2)
            let cam = PinholeCamera(width: w, height: h, focal: f, rotation: r)
            var img = RGBAImage(width: w, height: h)
            let rows = LockedArray<(Int, [UInt8])>()
            parallelFor(h) { y in
                var row = [UInt8](repeating: 255, count: w * 4)
                for x in 0..<w {
                    let c = scene.color(cam.ray(Double(x) + 0.5, Double(y) + 0.5))
                    row[x * 4] = UInt8(c.0); row[x * 4 + 1] = UInt8(c.1); row[x * 4 + 2] = UInt8(c.2)
                }
                rows.append((y, row))
            }
            for (y, row) in rows.all { img.pixels.replaceSubrange((y * w * 4)..<((y + 1) * w * 4), with: row) }
            let noise = Mat3.rotation(rng.unitVector() * radians(1.5))
            return (r, StitchShot(image: img, rotation: noise * r, focal: f * 1.02))
        }
        print(String(format: "rendered %d shots in %.1fs", plan.count, Date().timeIntervalSince(renderStart)))
        let (_, report) = Stitcher.stitch(truthAndShots.map(\.1), options: StitchOptions(outputWidth: 6144)) { p, stage in
            if Int(p * 100) % 25 == 0 { print(String(format: "  %3.0f%% %@", p * 100, stage)) }
        }
        for r in report.rounds {
            print(String(format: "round %.2f°/px: %d matches, rms %.3f° -> %.3f°", r.pixelAngleDegrees, r.matches,
                         r.rmsBeforeDegrees, r.rmsAfterDegrees))
        }
        let m = report.rotations[0] * truthAndShots[0].0.transposed
        let err = truthAndShots.indices.map {
            degrees((report.rotations[$0] * truthAndShots[$0].0.transposed * m.transposed).rotationAngle)
        }
        print(String(format: "stitched in %.1fs, max rotation error %.4f°", report.seconds, err.max()!))
    }
}

/// Writes a synthetic stitch and its little planet as PPM files for eyeballing
/// (ORB_DUMP=/dir swift test -c release --filter Dump).
final class DumpTests: XCTestCase {
    func testDumpImages() throws {
        guard let dir = ProcessInfo.processInfo.environment["ORB_DUMP"] else { throw XCTSkip("set ORB_DUMP") }
        let setup = makeCapture(rotationError: radians(2), focalError: 0.03, brightShot: 5)
        // Leave out the bottom ring so the hole fill shows.
        let plan = ShotPlan(shortFOV: 2 * atan(tan(radians(53)) * 0.75))
        let shots = plan.targets.filter { $0.ring >= 0 }.map { setup.shots[$0.id] }
        let (pano, _) = Stitcher.stitch(shots, options: StitchOptions(outputWidth: 2048))
        func ppm(_ img: RGBAImage, _ name: String) throws {
            var data = Data("P6\n\(img.width) \(img.height)\n255\n".utf8)
            for i in 0..<(img.width * img.height) { data.append(contentsOf: img.pixels[(i * 4)..<(i * 4 + 3)]) }
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        try ppm(pano, "pano.ppm")
        try ppm(PanoRender.littlePlanet(pano, size: 768), "planet.ppm")
        try ppm(setup.shots[0].image, "shot0.ppm")
    }
}
