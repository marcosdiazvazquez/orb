import Foundation
#if canImport(Dispatch)
import Dispatch
#endif

/// A point seen in two shots, in level-0 pixel coordinates of each.
public struct Correspondence: Sendable {
    public let i: Int, j: Int
    public let xi: Double, yi: Double
    public let xj: Double, yj: Double
    public let score: Float
}

/// Mean luminance of shots i and j over the pixels both see.
struct OverlapStats: Sendable {
    let i: Int, j: Int
    let meanI: Double, meanJ: Double
    let count: Int
}

/// Gray pyramid of one shot, used for matching.
struct ShotPyramid {
    let levels: [GrayImage]

    init(_ gray: GrayImage, levels n: Int) {
        var l = [gray]
        for _ in 1..<max(1, n) { l.append(l.last!.half()) }
        levels = l
    }
}

/// Local gnomonic (tangent-plane) frame on the sphere: pixel (a, b) looks along
/// normalize(center + (a - size/2) * step * right + (b - size/2) * step * down).
struct TangentPatch {
    let center: Vec3, right: Vec3, down: Vec3
    let size: Int
    let step: Double

    init(center c: Vec3, size: Int, pixelAngle: Double) {
        let n = c.normalized
        let up = abs(n.z) > 0.9 ? Vec3(1, 0, 0) : Vec3(0, 0, 1)
        right = n.cross(up).normalized
        down = n.cross(right).normalized
        center = n
        self.size = size
        step = tan(pixelAngle)
    }

    @inline(__always)
    func ray(_ a: Double, _ b: Double) -> Vec3 {
        let h = Double(size) / 2
        return (center + right * ((a - h) * step) + down * ((b - h) * step)).normalized
    }
}

/// Renders the patch from one shot's pyramid level. Pixels the shot doesn't see are NaN.
func renderPatch(_ patch: TangentPatch, camera: PinholeCamera, image: GrayImage) -> [Float] {
    let s = Double(image.width) / Double(camera.width)
    let f = camera.focal * s, cx = Double(image.width) / 2, cy = Double(image.height) / 2
    let rt = camera.rotation.transposed
    let n = patch.size
    var out = [Float](repeating: .nan, count: n * n)
    let w = image.width, h = image.height
    let maxX = Double(w) - 1.001, maxY = Double(h) - 1.001
    image.pixels.withUnsafeBufferPointer { src in
        out.withUnsafeMutableBufferPointer { dst in
            for b in 0..<n {
                for a in 0..<n {
                    let d = rt * patch.ray(Double(a) + 0.5, Double(b) + 0.5)
                    if d.z <= 1e-6 { continue }
                    let x = f * d.x / d.z + cx - 0.5, y = f * d.y / d.z + cy - 0.5
                    if x < 0 || y < 0 || x > maxX || y > maxY { continue }
                    let x0 = Int(x), y0 = Int(y)
                    let fx = Float(x - Double(x0)), fy = Float(y - Double(y0))
                    let i = y0 * w + x0
                    let top = src[i] + (src[i + 1] - src[i]) * fx
                    let bot = src[i + w] + (src[i + w + 1] - src[i + w]) * fx
                    dst[b * n + a] = top + (bot - top) * fy
                }
            }
        }
    }
    return out
}

struct MatchRound {
    var pixelAngle: Double   // radians per patch pixel
    var searchRadius: Int    // patch pixels
    var blockRadius: Int = 8
}

/// Block matching between the two renderings of one overlap. Returns correspondences in
/// level-0 shot pixels and the overlap's mean brightness in each shot.
func matchPair(i: Int, j: Int, cameras: [PinholeCamera], pyramids: [ShotPyramid],
               round: MatchRound, maxHalfExtent: Double) -> ([Correspondence], OverlapStats?) {
    let ci = cameras[i], cj = cameras[j]
    let center = (ci.opticalAxis + cj.opticalAxis).normalized
    let size = max(48, Int(2 * maxHalfExtent / round.pixelAngle))
    let patch = TangentPatch(center: center, size: size, pixelAngle: round.pixelAngle)

    // Coarsest pyramid level that still has at least one source pixel per patch pixel.
    func level(for p: ShotPyramid, camera: PinholeCamera) -> GrayImage {
        var chosen = p.levels[0]
        for img in p.levels {
            let pixelAngleHere = 1 / (camera.focal * Double(img.width) / Double(camera.width))
            if pixelAngleHere <= round.pixelAngle * 1.05 { chosen = img } else { break }
        }
        return chosen
    }
    let a = renderPatch(patch, camera: ci, image: level(for: pyramids[i], camera: ci))
    let b = renderPatch(patch, camera: cj, image: level(for: pyramids[j], camera: cj))

    // Overlap brightness, for gain compensation.
    var sumA = 0.0, sumB = 0.0, both = 0
    for k in 0..<(size * size) where !a[k].isNaN && !b[k].isNaN {
        sumA += Double(a[k]); sumB += Double(b[k]); both += 1
    }
    if both < 64 { return ([], nil) }
    let stats = OverlapStats(i: i, j: j, meanI: sumA / Double(both), meanJ: sumB / Double(both), count: both)

    // Integral images of b, b^2 and validity, for O(1) block sums in the search.
    let n1 = size + 1
    var sb = [Double](repeating: 0, count: n1 * n1)
    var sbb = [Double](repeating: 0, count: n1 * n1)
    var sv = [Int32](repeating: 0, count: n1 * n1)
    for y in 0..<size {
        var rb = 0.0, rbb = 0.0
        var rv: Int32 = 0
        for x in 0..<size {
            let v = b[y * size + x]
            if !v.isNaN { rb += Double(v); rbb += Double(v) * Double(v); rv += 1 }
            let o = (y + 1) * n1 + x + 1
            sb[o] = sb[o - n1] + rb
            sbb[o] = sbb[o - n1] + rbb
            sv[o] = sv[o - n1] + rv
        }
    }

    let hb = round.blockRadius, r = round.searchRadius
    let bw = 2 * hb + 1, area = bw * bw
    let margin = hb + r + 1
    let grid = max(bw, (size - 2 * margin) / 22)
    let side = 2 * r + 1
    var scores = [Float](repeating: -2, count: side * side)
    var blockA = [Float](repeating: 0, count: area)
    var results: [Correspondence] = []

    var by = margin
    while by < size - margin {
        var bx = margin
        while bx < size - margin {
            defer { bx += grid }
            // Block in A: must be fully valid and textured.
            var mean: Float = 0, valid = true
            for dy in -hb...hb {
                for dx in -hb...hb {
                    let v = a[(by + dy) * size + bx + dx]
                    if v.isNaN { valid = false; break }
                    blockA[(dy + hb) * bw + dx + hb] = v
                    mean += v
                }
                if !valid { break }
            }
            if !valid { continue }
            mean /= Float(area)
            var varA: Float = 0
            for k in 0..<area { blockA[k] -= mean; varA += blockA[k] * blockA[k] }
            if varA / Float(area) < 9 { continue }  // std < 3 gray levels: flat
            let normA = sqrt(varA)

            // NCC over the search window.
            var best: Float = -2, bestK = -1
            for oy in -r...r {
                for ox in -r...r {
                    let k = (oy + r) * side + ox + r
                    scores[k] = -2
                    let x0 = bx + ox - hb, y0 = by + oy - hb, x1 = x0 + bw, y1 = y0 + bw
                    let cnt = sv[y1 * n1 + x1] - sv[y0 * n1 + x1] - sv[y1 * n1 + x0] + sv[y0 * n1 + x0]
                    if Int(cnt) != area { continue }
                    let s1 = sb[y1 * n1 + x1] - sb[y0 * n1 + x1] - sb[y1 * n1 + x0] + sb[y0 * n1 + x0]
                    let s2 = sbb[y1 * n1 + x1] - sbb[y0 * n1 + x1] - sbb[y1 * n1 + x0] + sbb[y0 * n1 + x0]
                    let varB = s2 - s1 * s1 / Double(area)
                    if varB <= 1e-6 { continue }
                    var cross: Float = 0
                    b.withUnsafeBufferPointer { bp in
                        blockA.withUnsafeBufferPointer { ap in
                            for dy in 0..<bw {
                                let rowB = (y0 + dy) * size + x0
                                let rowA = dy * bw
                                for dx in 0..<bw { cross += ap[rowA + dx] * bp[rowB + dx] }
                            }
                        }
                    }
                    let ncc = cross / (normA * Float(sqrt(varB)))
                    scores[k] = ncc
                    if ncc > best { best = ncc; bestK = k }
                }
            }
            if bestK < 0 || best < 0.75 { continue }
            let px = bestK % side - r, py = bestK / side - r
            if abs(px) == r || abs(py) == r { continue }  // peak on the window edge: may lie outside

            // Distinctiveness: the best score away from the peak must be clearly lower.
            var second: Float = -2
            for oy in -r...r {
                for ox in -r...r where abs(ox - px) > 2 || abs(oy - py) > 2 {
                    second = max(second, scores[(oy + r) * side + ox + r])
                }
            }
            if second > best - 0.04 { continue }

            // Subpixel peak (parabola per axis).
            func sub(_ m: Float, _ c: Float, _ p: Float) -> Double {
                let den = m - 2 * c + p
                if m < -1.5 || p < -1.5 || abs(den) < 1e-6 { return 0 }
                return Double(max(-0.5, min(0.5, 0.5 * (m - p) / den)))
            }
            let kc = (py + r) * side + px + r
            let ddx = sub(scores[kc - 1], best, scores[kc + 1])
            let ddy = sub(scores[kc - side], best, scores[kc + side])

            let rayA = patch.ray(Double(bx) + 0.5, Double(by) + 0.5)
            let rayB = patch.ray(Double(bx) + 0.5 + Double(px) + ddx, Double(by) + 0.5 + Double(py) + ddy)
            guard let pi = ci.project(rayA), let pj = cj.project(rayB),
                  ci.contains(pi), cj.contains(pj) else { continue }
            results.append(Correspondence(i: i, j: j, xi: pi.x, yi: pi.y, xj: pj.x, yj: pj.y, score: best))
        }
        by += grid
    }
    return (results, stats)
}

/// Pairs of shots whose fields of view overlap by a useful amount.
func overlappingPairs(_ cameras: [PinholeCamera]) -> [(Int, Int)] {
    var pairs: [(Int, Int)] = []
    for i in 0..<cameras.count {
        for j in (i + 1)..<cameras.count {
            let fi = cameras[i].fov, fj = cameras[j].fov
            let reach = (min(fi.h, fi.v) + min(fj.h, fj.v)) / 2 * 0.5 + (max(fi.h, fi.v) + max(fj.h, fj.v)) / 2 * 0.5
            let angle = cameras[i].opticalAxis.angle(to: cameras[j].opticalAxis)
            if angle < reach - radians(8) { pairs.append((i, j)) }
        }
    }
    return pairs
}

/// Runs `body` for 0..<count across all cores.
func parallelFor(_ count: Int, _ body: (Int) -> Void) {
    if count <= 1 { if count == 1 { body(0) }; return }
    DispatchQueue.concurrentPerform(iterations: count, execute: body)
}

final class LockedArray<T>: @unchecked Sendable {
    private var items: [T] = []
    private let lock = NSLock()
    func append(contentsOf more: [T]) { lock.lock(); items.append(contentsOf: more); lock.unlock() }
    func append(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}
