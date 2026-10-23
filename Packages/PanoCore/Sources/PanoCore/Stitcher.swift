import Foundation

/// One captured frame, decoded upright for a portrait-held phone.
public struct StitchShot: Sendable {
    public var image: RGBAImage
    /// Camera-to-world rotation from the motion sensors (world Z up).
    public var rotation: Mat3
    /// Focal length in pixels of `image`.
    public var focal: Double

    public init(image: RGBAImage, rotation: Mat3, focal: Double) {
        self.image = image; self.rotation = rotation; self.focal = focal
    }
}

public struct StitchOptions: Sendable {
    /// Equirectangular width; height is half of it.
    public var outputWidth = 6144
    /// Refine the sensor rotations by matching overlaps (bundle adjustment).
    public var refine = true
    public var gainCompensation = true
    public var fillHoles = true
    /// Higher keeps seams narrower (less ghosting), lower hides exposure steps better.
    public var blendSharpness: Float = 3

    public init(outputWidth: Int = 6144) { self.outputWidth = outputWidth }
}

public struct StitchReport: Sendable {
    public struct Round: Sendable {
        public var pixelAngleDegrees: Double
        public var pairs: Int
        public var matches: Int
        public var rmsBeforeDegrees: Double
        public var rmsAfterDegrees: Double
        public var inlierFraction: Double
    }
    public var rounds: [Round] = []
    public var focalScale = 1.0
    public var gains: [Double] = []
    /// Refined camera-to-world rotations, in the output panorama's frame.
    public var rotations: [Mat3] = []
    public var seconds = 0.0
}

public enum Stitcher {
    /// Stitches shots into an equirectangular panorama. `progress` gets (fraction, stage).
    public static func stitch(_ shots: [StitchShot], options: StitchOptions = StitchOptions(),
                              progress: @escaping @Sendable (Double, String) -> Void = { _, _ in })
        -> (RGBAImage, StitchReport) {
        let start = Date()
        var report = StitchReport()
        var cameras = shots.map {
            PinholeCamera(width: $0.image.width, height: $0.image.height, focal: $0.focal, rotation: $0.rotation)
        }
        let priors = cameras.map(\.rotation)
        let baseFocals = cameras.map(\.focal)
        var stats: [OverlapStats] = []

        if options.refine && shots.count >= 2 {
            progress(0, "Preparing")
            // Matching resolution: enough for the finest round, no more.
            let fine = radians(0.07)
            let pyramids: [ShotPyramid] = {
                let out = LockedArray<(Int, ShotPyramid)>()
                parallelFor(shots.count) { k in
                    let cam = cameras[k]
                    let longFOV = max(cam.fov.h, cam.fov.v)
                    let side = min(max(cam.width, cam.height), Int(longFOV / fine * 1.1))
                    let gray = shots[k].image.resized(maxSide: side).gray()
                    out.append((k, ShotPyramid(gray, levels: 4)))
                }
                return out.all.sorted { $0.0 < $1.0 }.map(\.1)
            }()

            // Coarse to fine; never finer than the source images resolve.
            let sourcePixel = cameras.map { 1 / $0.focal }.max() ?? fine
            var rounds = [MatchRound(pixelAngle: radians(0.35), searchRadius: 14),
                          MatchRound(pixelAngle: radians(0.15), searchRadius: 6),
                          MatchRound(pixelAngle: radians(0.07), searchRadius: 4)]
            for k in rounds.indices { rounds[k].pixelAngle = max(rounds[k].pixelAngle, sourcePixel * 1.2) }
            let maxFOV = cameras.map { max($0.fov.h, $0.fov.v) }.max() ?? radians(60)
            let halfExtent = min(radians(38), maxFOV / 2)

            for (ri, round) in rounds.enumerated() {
                progress(0.5 * Double(ri) / Double(rounds.count), "Aligning")
                let pairs = overlappingPairs(cameras)
                let found = LockedArray<Correspondence>()
                let roundStats = LockedArray<OverlapStats>()
                let snapshot = cameras
                parallelFor(pairs.count) { p in
                    let (i, j) = pairs[p]
                    let (m, s) = matchPair(i: i, j: j, cameras: snapshot, pyramids: pyramids,
                                           round: round, maxHalfExtent: halfExtent)
                    found.append(contentsOf: m)
                    if let s { roundStats.append(s) }
                }
                let matches = found.all
                stats = roundStats.all
                let ba = BundleAdjuster(sigmaMatch: round.pixelAngle)
                let r = ba.run(cameras: &cameras, priors: priors, baseFocals: baseFocals, matches: matches)
                report.rounds.append(.init(pixelAngleDegrees: degrees(round.pixelAngle), pairs: pairs.count,
                                           matches: matches.count, rmsBeforeDegrees: degrees(r.initialRMS),
                                           rmsAfterDegrees: degrees(r.finalRMS), inlierFraction: r.inlierFraction))
            }
            report.focalScale = cameras[0].focal / baseFocals[0]
        } else if options.gainCompensation && shots.count >= 2 {
            let pyramids = shots.map { ShotPyramid($0.image.resized(maxSide: 512).gray(), levels: 1) }
            let round = MatchRound(pixelAngle: radians(0.5), searchRadius: 2)
            for (i, j) in overlappingPairs(cameras) {
                if let s = matchPair(i: i, j: j, cameras: cameras, pyramids: pyramids, round: round,
                                     maxHalfExtent: radians(30)).1 { stats.append(s) }
            }
        }

        let gains = options.gainCompensation ? gainCompensation(count: shots.count, stats: stats)
                                             : [Double](repeating: 1, count: shots.count)
        report.gains = gains

        // Center the panorama on the first shot's heading.
        let axis0 = cameras.first?.opticalAxis ?? Vec3(1, 0, 0)
        let lon0 = atan2(-axis0.y, axis0.x)
        let world = Mat3.rotation(axis: Vec3(0, 0, 1), angle: lon0)
        report.rotations = cameras.map { world * $0.rotation }

        progress(0.5, "Blending")
        var pano = blendEquirect(width: options.outputWidth, cameras: cameras, images: shots.map(\.image),
                                 gains: gains, world: world, sharpness: options.blendSharpness) { f in
            progress(0.5 + 0.45 * f, "Blending")
        }
        if options.fillHoles {
            progress(0.95, "Filling")
            fillHoles(&pano)
        }
        progress(1, "Done")
        report.seconds = Date().timeIntervalSince(start)
        return (pano, report)
    }
}

public enum PanoRender {
    /// Bilinear sample of an equirectangular image at (u, v) in [0, 1], wrapping in u.
    @inline(__always)
    static func sample(_ pano: RGBAImage, _ u: Double, _ v: Double) -> (Float, Float, Float) {
        let w = pano.width, h = pano.height
        let x = u * Double(w) - 0.5, y = max(0, min(Double(h - 1), v * Double(h) - 0.5))
        let xf = floor(x), y0 = Int(y), y1 = min(h - 1, y0 + 1)
        let x0 = ((Int(xf) % w) + w) % w, x1 = (x0 + 1) % w
        let fx = Float(x - xf), fy = Float(y - Double(y0))
        return pano.pixels.withUnsafeBufferPointer { p in
            func px(_ xx: Int, _ yy: Int, _ c: Int) -> Float { Float(p[(yy * w + xx) * 4 + c]) }
            func ch(_ c: Int) -> Float {
                let top = px(x0, y0, c) * (1 - fx) + px(x1, y0, c) * fx
                let bot = px(x0, y1, c) * (1 - fx) + px(x1, y1, c) * fx
                return top * (1 - fy) + bot * fy
            }
            return (ch(0), ch(1), ch(2))
        }
    }

    /// "Little planet": stereographic projection centred on the nadir, front of the scene at the top.
    /// `fov` is the angle across the square's width.
    public static func littlePlanet(_ pano: RGBAImage, size: Int, fov: Double = 250 * Double.pi / 180) -> RGBAImage {
        var out = RGBAImage(width: size, height: size)
        let forward = Vec3(0, 0, -1), right = Vec3(0, -1, 0), down = Vec3(-1, 0, 0)
        let edge = 2 * tan(fov / 4)
        for y in 0..<size {
            for x in 0..<size {
                let px = ((Double(x) + 0.5) / Double(size) * 2 - 1) * edge
                let py = ((Double(y) + 0.5) / Double(size) * 2 - 1) * edge
                let r = sqrt(px * px + py * py)
                let theta = 2 * atan(r / 2)
                let dir: Vec3
                if r < 1e-12 { dir = forward } else {
                    dir = forward * cos(theta) + (right * (px / r) + down * (py / r)) * sin(theta)
                }
                let (u, v) = Equirect.uv(dir)
                let c = sample(pano, u, v)
                let o = (y * size + x) * 4
                out.pixels[o] = UInt8(min(255, c.0 + 0.5))
                out.pixels[o + 1] = UInt8(min(255, c.1 + 0.5))
                out.pixels[o + 2] = UInt8(min(255, c.2 + 0.5))
                out.pixels[o + 3] = 255
            }
        }
        return out
    }
}
