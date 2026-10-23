import Foundation
@testable import PanoCore

/// A procedurally textured sphere: multi-octave value noise on the unit sphere, so every
/// direction has detail at the scales block matching uses.
struct SyntheticScene {
    var seed: UInt64 = 7

    private func hash(_ x: Int, _ y: Int, _ z: Int, _ c: Int) -> Double {
        var h = UInt64(bitPattern: Int64(x)) &* 0x9E37_79B9_7F4A_7C15
        h ^= UInt64(bitPattern: Int64(y)) &* 0xC2B2_AE3D_27D4_EB4F
        h ^= UInt64(bitPattern: Int64(z)) &* 0x1656_67B1_9E37_79F9
        h ^= UInt64(c) &* 0x27D4_EB2F_1656_67C5 ^ seed
        h ^= h >> 31; h &*= 0x7FB5_D329_728E_A185; h ^= h >> 27
        return Double(h >> 11) / Double(1 << 53)
    }

    private func noise(_ p: Vec3, _ c: Int) -> Double {
        let xf = floor(p.x), yf = floor(p.y), zf = floor(p.z)
        let (x0, y0, z0) = (Int(xf), Int(yf), Int(zf))
        func s(_ t: Double) -> Double { t * t * (3 - 2 * t) }
        let fx = s(p.x - xf), fy = s(p.y - yf), fz = s(p.z - zf)
        func l(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
        let c00 = l(hash(x0, y0, z0, c), hash(x0 + 1, y0, z0, c), fx)
        let c10 = l(hash(x0, y0 + 1, z0, c), hash(x0 + 1, y0 + 1, z0, c), fx)
        let c01 = l(hash(x0, y0, z0 + 1, c), hash(x0 + 1, y0, z0 + 1, c), fx)
        let c11 = l(hash(x0, y0 + 1, z0 + 1, c), hash(x0 + 1, y0 + 1, z0 + 1, c), fx)
        return l(l(c00, c10, fy), l(c01, c11, fy), fz)
    }

    func color(_ d: Vec3) -> (Double, Double, Double) {
        var rgb = (0.0, 0.0, 0.0)
        var amp = 0.5, freq = 6.0, total = 0.0
        for _ in 0..<6 {
            let p = d * freq
            rgb.0 += amp * noise(p, 0); rgb.1 += amp * noise(p, 1); rgb.2 += amp * noise(p, 2)
            total += amp; amp *= 0.6; freq *= 2.3
        }
        return (rgb.0 / total * 255, rgb.1 / total * 255, rgb.2 / total * 255)
    }

    /// Renders what `camera` sees, with 2x2 supersampling, scaled by `gain`.
    func render(_ camera: PinholeCamera, gain: Double = 1) -> RGBAImage {
        var img = RGBAImage(width: camera.width, height: camera.height)
        for y in 0..<camera.height {
            for x in 0..<camera.width {
                var acc = (0.0, 0.0, 0.0)
                for (sx, sy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
                    let c = color(camera.ray(Double(x) + sx, Double(y) + sy))
                    acc.0 += c.0; acc.1 += c.1; acc.2 += c.2
                }
                let o = (y * camera.width + x) * 4
                img.pixels[o] = UInt8(max(0, min(255, acc.0 / 4 * gain)))
                img.pixels[o + 1] = UInt8(max(0, min(255, acc.1 / 4 * gain)))
                img.pixels[o + 2] = UInt8(max(0, min(255, acc.2 / 4 * gain)))
                img.pixels[o + 3] = 255
            }
        }
        return img
    }
}

/// Camera-to-world rotation looking along `axis`, image "down" toward world down, then rolled.
func lookRotation(_ axis: Vec3, roll: Double = 0) -> Mat3 {
    let z = axis.normalized
    let worldDown = Vec3(0, 0, -1)
    var y = worldDown - z * z.dot(worldDown)
    if y.length < 1e-6 { y = Vec3(-1, 0, 0) - z * z.dot(Vec3(-1, 0, 0)) }  // at the poles: top of frame toward +X
    y = y.normalized
    let x = y.cross(z)
    return Mat3(columns: x, y, z) * Mat3.rotation(axis: Vec3(0, 0, 1), angle: roll)
}

/// Deterministic pseudo-random numbers for perturbations.
struct LCG {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func unitVector() -> Vec3 {
        while true {
            let v = Vec3(next() * 2 - 1, next() * 2 - 1, next() * 2 - 1)
            if v.length > 0.1 && v.length <= 1 { return v.normalized }
        }
    }
}
