import Foundation

/// Per-shot brightness gains from overlap means (Brown & Lowe 2007, section 6):
/// minimize sum n_ij (g_i I_ij - g_j I_ji)^2 / sigmaN^2 + sum (1 - g_i)^2 / sigmaG^2.
func gainCompensation(count n: Int, stats: [OverlapStats], sigmaN: Double = 10, sigmaG: Double = 0.1) -> [Double] {
    if stats.isEmpty { return [Double](repeating: 1, count: n) }
    var A = [Double](repeating: 0, count: n * n)
    var b = [Double](repeating: 0, count: n)
    let sn = 1 / (sigmaN * sigmaN), sg = 1 / (sigmaG * sigmaG)
    for s in stats {
        let w = Double(s.count) / 1000
        let (i, j, Ii, Ij) = (s.i, s.j, s.meanI, s.meanJ)
        A[i * n + i] += w * Ii * Ii * sn
        A[j * n + j] += w * Ij * Ij * sn
        A[i * n + j] -= w * Ii * Ij * sn
        A[j * n + i] -= w * Ii * Ij * sn
        // The prior is weighted by the overlap too, as in the paper (and OpenCV). Weighted once
        // per shot instead, it was ~1000x too weak, and since the brightness term alone is least
        // at g = 0, real overlaps that never agree exactly pulled every gain down (to ~0.25).
        A[i * n + i] += w * sg / 2; b[i] += w * sg / 2
        A[j * n + j] += w * sg / 2; b[j] += w * sg / 2
    }
    for k in 0..<n { A[k * n + k] += sg; b[k] += sg }  // keeps a shot without overlaps at 1
    return choleskySolve(A, b, n) ?? [Double](repeating: 1, count: n)
}

/// One shot prepared for rendering: float rotation rows and image.
private struct RenderShot {
    let r0: (Float, Float, Float), r1: (Float, Float, Float), r2: (Float, Float, Float)  // world -> camera
    let f: Float, cx: Float, cy: Float
    let w: Int, h: Int
    let gain: Float
    let latMin: Double, latMax: Double
}

/// Calls `body` with stable pointers to every array's storage.
private func withPointers<R>(_ arrays: [[UInt8]], _ acc: [UnsafePointer<UInt8>] = [],
                             _ body: ([UnsafePointer<UInt8>]) -> R) -> R {
    if acc.count == arrays.count { return body(acc) }
    return arrays[acc.count].withUnsafeBufferPointer { withPointers(arrays, acc + [$0.baseAddress!], body) }
}

/// Renders shots into an equirectangular panorama with feathered blending.
/// Weights fall off toward each frame's edges (`(wx * wy)^sharpness`), which hides exposure
/// steps while keeping overlaps from ghosting. Pixels no shot covers get alpha 0.
func blendEquirect(width: Int, cameras: [PinholeCamera], images: [RGBAImage], gains: [Double],
                   world: Mat3, sharpness: Float = 3, progress: ((Double) -> Void)? = nil) -> RGBAImage {
    let height = width / 2
    let shots: [RenderShot] = cameras.indices.map { k in
        let cam = cameras[k]
        let rot = world * cam.rotation              // camera -> output world
        let rt = rot.transposed
        // Latitude span: sample the frame border; poles inside the frame widen it to +-90.
        var latMin = Double.pi / 2, latMax = -Double.pi / 2
        let samples = 32
        for s in 0...samples {
            let t = Double(s) / Double(samples)
            for (x, y) in [(t * Double(cam.width), 0.0), (t * Double(cam.width), Double(cam.height)),
                           (0.0, t * Double(cam.height)), (Double(cam.width), t * Double(cam.height))] {
                let d = rot * Vec3((x - cam.cx) / cam.focal, (y - cam.cy) / cam.focal, 1).normalized
                let lat = asin(max(-1, min(1, d.z)))
                latMin = min(latMin, lat); latMax = max(latMax, lat)
            }
        }
        let cNorth = rt * Vec3(0, 0, 1), cSouth = rt * Vec3(0, 0, -1)
        func inFrame(_ c: Vec3) -> Bool {
            guard c.z > 0 else { return false }
            let x = cam.focal * c.x / c.z + cam.cx, y = cam.focal * c.y / c.z + cam.cy
            return x >= 0 && y >= 0 && x <= Double(cam.width) && y <= Double(cam.height)
        }
        if inFrame(cNorth) { latMax = Double.pi / 2 }
        if inFrame(cSouth) { latMin = -Double.pi / 2 }
        let img = images[k]
        let scale = Double(img.width) / Double(cam.width)
        return RenderShot(
            r0: (Float(rt.r0.x), Float(rt.r0.y), Float(rt.r0.z)),
            r1: (Float(rt.r1.x), Float(rt.r1.y), Float(rt.r1.z)),
            r2: (Float(rt.r2.x), Float(rt.r2.y), Float(rt.r2.z)),
            f: Float(cam.focal * scale), cx: Float(Double(img.width) / 2), cy: Float(Double(img.height) / 2),
            w: img.width, h: img.height, gain: Float(gains[k]),
            latMin: latMin - 0.01, latMax: latMax + 0.01)
    }

    // Per-column direction terms.
    var cosLon = [Float](repeating: 0, count: width), sinLon = [Float](repeating: 0, count: width)
    for x in 0..<width {
        let lon = ((Double(x) + 0.5) / Double(width) - 0.5) * 2 * Double.pi
        cosLon[x] = Float(cos(lon)); sinLon[x] = Float(sin(lon))
    }

    var out = [UInt8](repeating: 0, count: width * height * 4)
    let band = 16
    let bands = (height + band - 1) / band
    let done = LockedCounter()
    withPointers(images.map(\.pixels)) { src in
    out.withUnsafeMutableBufferPointer { dstBuf in
        let dst = dstBuf.baseAddress!
        parallelFor(bands) { bi in
            let y0 = bi * band, y1 = min(height, y0 + band)
            for y in y0..<y1 {
                let lat = (0.5 - (Double(y) + 0.5) / Double(height)) * Double.pi
                let cl = Float(cos(lat)), sl = Float(sin(lat))
                let active = shots.indices.filter { lat >= shots[$0].latMin && lat <= shots[$0].latMax }
                for x in 0..<width {
                    let dx = cl * cosLon[x], dy = -cl * sinLon[x], dz = sl
                    var accR: Float = 0, accG: Float = 0, accB: Float = 0, accW: Float = 0
                    for k in active {
                        let s = shots[k]
                        let cz = s.r2.0 * dx + s.r2.1 * dy + s.r2.2 * dz
                        if cz <= 1e-4 { continue }
                        let inv = 1 / cz
                        let u = s.f * (s.r0.0 * dx + s.r0.1 * dy + s.r0.2 * dz) * inv + s.cx - 0.5
                        let v = s.f * (s.r1.0 * dx + s.r1.1 * dy + s.r1.2 * dz) * inv + s.cy - 0.5
                        let maxU = Float(s.w) - 1.001, maxV = Float(s.h) - 1.001
                        if u < 0 || v < 0 || u > maxU || v > maxV { continue }
                        let wu = 1 - abs(2 * u / maxU - 1), wv = 1 - abs(2 * v / maxV - 1)
                        var wt = wu * wv
                        wt = sharpness == 3 ? wt * wt * wt : powf(wt, sharpness)
                        wt += 1e-6
                        let x0 = Int(u), y0i = Int(v)
                        let fx = u - Float(x0), fy = v - Float(y0i)
                        let p = src[k]
                        let i00 = (y0i * s.w + x0) * 4, i10 = i00 + 4, i01 = i00 + s.w * 4, i11 = i01 + 4
                        let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy), w01 = (1 - fx) * fy, w11 = fx * fy
                        let r = Float(p[i00]) * w00 + Float(p[i10]) * w10 + Float(p[i01]) * w01 + Float(p[i11]) * w11
                        let g = Float(p[i00 + 1]) * w00 + Float(p[i10 + 1]) * w10 + Float(p[i01 + 1]) * w01 + Float(p[i11 + 1]) * w11
                        let b = Float(p[i00 + 2]) * w00 + Float(p[i10 + 2]) * w10 + Float(p[i01 + 2]) * w01 + Float(p[i11 + 2]) * w11
                        let wg = wt * s.gain
                        accR += r * wg; accG += g * wg; accB += b * wg; accW += wt
                    }
                    let o = (y * width + x) * 4
                    if accW > 0 {
                        let inv = 1 / accW
                        dst[o] = UInt8(max(0, min(255, accR * inv + 0.5)))
                        dst[o + 1] = UInt8(max(0, min(255, accG * inv + 0.5)))
                        dst[o + 2] = UInt8(max(0, min(255, accB * inv + 0.5)))
                        dst[o + 3] = 255
                    }
                }
            }
            if let progress { progress(Double(done.increment()) / Double(bands)) }
        }
    }
    }
    return RGBAImage(width: width, height: height, pixels: out)
}

/// Fills alpha-0 pixels smoothly from their surroundings (push-pull on a coarse grid), then
/// marks them opaque. Used for the patch under the tripod or anything left uncaptured.
func fillHoles(_ img: inout RGBAImage) {
    let w = img.width, h = img.height
    var holes = 0
    for i in 0..<(w * h) where img.pixels[i * 4 + 3] == 0 { holes += 1 }
    if holes == 0 { return }

    // Coarse premultiplied grid with weights.
    let gw = min(512, w), gh = max(1, gw / 2)
    var grid = [Float](repeating: 0, count: gw * gh * 4)
    for y in 0..<h {
        let gy = y * gh / h
        for x in 0..<w {
            let i = (y * w + x) * 4
            if img.pixels[i + 3] == 0 { continue }
            let g = (gy * gw + x * gw / w) * 4
            grid[g] += Float(img.pixels[i]); grid[g + 1] += Float(img.pixels[i + 1])
            grid[g + 2] += Float(img.pixels[i + 2]); grid[g + 3] += 1
        }
    }
    // Push: build a pyramid of the weighted grid.
    var levels: [(w: Int, h: Int, d: [Float])] = [(gw, gh, grid)]
    while levels.last!.w > 2 {
        let p = levels.last!
        let nw = max(1, p.w / 2), nh = max(1, p.h / 2)
        var d = [Float](repeating: 0, count: nw * nh * 4)
        for y in 0..<nh {
            for x in 0..<nw {
                for (sx, sy) in [(2 * x, 2 * y), (2 * x + 1, 2 * y), (2 * x, 2 * y + 1), (2 * x + 1, 2 * y + 1)] {
                    let xx = sx % p.w, yy = min(sy, p.h - 1)
                    let s = (yy * p.w + xx) * 4
                    for c in 0..<4 { d[(y * nw + x) * 4 + c] += p.d[s + c] }
                }
            }
        }
        levels.append((nw, nh, d))
    }
    // Pull: fill sparse cells from the coarser level, upsampled bilinearly (wrapping in
    // longitude) so the fill has no block edges.
    for li in stride(from: levels.count - 2, through: 0, by: -1) {
        let coarse = levels[li + 1]
        var fine = levels[li]
        for y in 0..<fine.h {
            let cyf = max(0, min(Double(coarse.h - 1), (Double(y) + 0.5) / 2 - 0.5))
            let y0 = Int(cyf), y1 = min(coarse.h - 1, y0 + 1), fy = Float(cyf - Double(y0))
            for x in 0..<fine.w {
                let f = (y * fine.w + x) * 4
                let fw = fine.d[f + 3]
                if fw >= 1 {
                    for k in 0..<3 { fine.d[f + k] /= fw }
                    fine.d[f + 3] = 1
                    continue
                }
                let cxf = (Double(x) + 0.5) / 2 - 0.5
                let x0 = Int(floor(cxf)), fx = Float(cxf - floor(cxf))
                var acc: (Float, Float, Float) = (0, 0, 0), wsum: Float = 0
                for (xx, yy, w) in [(x0, y0, (1 - fx) * (1 - fy)), (x0 + 1, y0, fx * (1 - fy)),
                                    (x0, y1, (1 - fx) * fy), (x0 + 1, y1, fx * fy)] {
                    let c = (yy * coarse.w + ((xx % coarse.w) + coarse.w) % coarse.w) * 4
                    let cw = coarse.d[c + 3]
                    if cw <= 0 || w <= 0 { continue }
                    acc.0 += w * coarse.d[c] / cw; acc.1 += w * coarse.d[c + 1] / cw; acc.2 += w * coarse.d[c + 2] / cw
                    wsum += w
                }
                if wsum <= 0 { continue }
                // Cells with a little data of their own keep it in proportion.
                for (k, v) in [acc.0, acc.1, acc.2].enumerated() {
                    let own = fw > 0 ? fine.d[f + k] / fw : 0
                    fine.d[f + k] = own * fw + (v / wsum) * (1 - fw)
                }
                fine.d[f + 3] = 1
            }
        }
        levels[li] = fine
    }
    let filled = levels[0]
    for y in 0..<h {
        let gyf = (Double(y) + 0.5) * Double(gh) / Double(h) - 0.5
        for x in 0..<w {
            let i = (y * w + x) * 4
            if img.pixels[i + 3] != 0 { continue }
            let gxf = (Double(x) + 0.5) * Double(gw) / Double(w) - 0.5
            // Bilinear on the filled grid (wrapping in longitude).
            let x0 = Int(floor(gxf)), y0 = max(0, min(gh - 1, Int(floor(gyf))))
            let y1 = min(gh - 1, y0 + 1)
            let fx = Float(gxf - floor(gxf)), fy = Float(max(0, min(1, gyf - Double(y0))))
            for c in 0..<3 {
                func at(_ xx: Int, _ yy: Int) -> Float {
                    let xw = ((xx % gw) + gw) % gw
                    return filled.d[(yy * gw + xw) * 4 + c]
                }
                let top = at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx
                let bot = at(x0, y1) * (1 - fx) + at(x0 + 1, y1) * fx
                img.pixels[i + c] = UInt8(max(0, min(255, top * (1 - fy) + bot * fy + 0.5)))
            }
            img.pixels[i + 3] = 255
        }
    }
}

final class LockedCounter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
