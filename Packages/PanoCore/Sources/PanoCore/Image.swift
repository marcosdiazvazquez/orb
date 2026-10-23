import Foundation

/// 8-bit RGBA, row-major, alpha 255 for opaque pixels. Alpha 0 marks "no data" in panoramas.
public struct RGBAImage: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4)
        self.width = width; self.height = height; self.pixels = pixels
    }

    public init(width: Int, height: Int) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: 0, count: width * height * 4))
    }

    /// Rec. 601 luma in 0...255.
    public func gray() -> GrayImage {
        var out = [Float](repeating: 0, count: width * height)
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for i in 0..<(width * height) {
                    let r = Float(src[i * 4]), g = Float(src[i * 4 + 1]), b = Float(src[i * 4 + 2])
                    dst[i] = 0.299 * r + 0.587 * g + 0.114 * b
                }
            }
        }
        return GrayImage(width: width, height: height, pixels: out)
    }

    /// Box-filter downscale to fit `maxSide` on the longer side (no-op if already smaller).
    public func resized(maxSide: Int) -> RGBAImage {
        let scale = Double(maxSide) / Double(max(width, height))
        if scale >= 1 { return self }
        return resized(width: max(1, Int((Double(width) * scale).rounded())),
                       height: max(1, Int((Double(height) * scale).rounded())))
    }

    /// Area-average resample (good for downscaling; bilinear-ish when upscaling).
    public func resized(width w: Int, height h: Int) -> RGBAImage {
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let sx = Double(width) / Double(w), sy = Double(height) / Double(h)
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let y0 = Double(y) * sy, y1 = y0 + sy
                    for x in 0..<w {
                        let x0 = Double(x) * sx, x1 = x0 + sx
                        var acc = (0.0, 0.0, 0.0, 0.0), wsum = 0.0
                        var yy = Int(y0)
                        while Double(yy) < y1 && yy < height {
                            let wy = min(Double(yy + 1), y1) - max(Double(yy), y0)
                            var xx = Int(x0)
                            while Double(xx) < x1 && xx < width {
                                let wx = min(Double(xx + 1), x1) - max(Double(xx), x0)
                                let wgt = wx * wy
                                let i = (yy * width + xx) * 4
                                acc.0 += Double(src[i]) * wgt
                                acc.1 += Double(src[i + 1]) * wgt
                                acc.2 += Double(src[i + 2]) * wgt
                                acc.3 += Double(src[i + 3]) * wgt
                                wsum += wgt
                                xx += 1
                            }
                            yy += 1
                        }
                        let o = (y * w + x) * 4
                        if wsum > 0 {
                            dst[o] = UInt8(min(255, acc.0 / wsum + 0.5))
                            dst[o + 1] = UInt8(min(255, acc.1 / wsum + 0.5))
                            dst[o + 2] = UInt8(min(255, acc.2 / wsum + 0.5))
                            dst[o + 3] = UInt8(min(255, acc.3 / wsum + 0.5))
                        }
                    }
                }
            }
        }
        return RGBAImage(width: w, height: h, pixels: out)
    }
}

/// Single-channel float image, values in 0...255.
public struct GrayImage: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height)
        self.width = width; self.height = height; self.pixels = pixels
    }

    /// 2x2 box downsample.
    public func half() -> GrayImage {
        let w = max(1, width / 2), h = max(1, height / 2)
        var out = [Float](repeating: 0, count: w * h)
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let a = min(2 * y, height - 1) * width, b = min(2 * y + 1, height - 1) * width
                    for x in 0..<w {
                        let x0 = min(2 * x, width - 1), x1 = min(2 * x + 1, width - 1)
                        dst[y * w + x] = 0.25 * (src[a + x0] + src[a + x1] + src[b + x0] + src[b + x1])
                    }
                }
            }
        }
        return GrayImage(width: w, height: h, pixels: out)
    }

    public func resized(maxSide: Int) -> GrayImage {
        var img = self
        while max(img.width, img.height) > maxSide * 2 { img = img.half() }
        if max(img.width, img.height) <= maxSide { return img }
        // Final non-power-of-two step: bilinear.
        let s = Double(maxSide) / Double(max(img.width, img.height))
        let w = max(1, Int(Double(img.width) * s)), h = max(1, Int(Double(img.height) * s))
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                out[y * w + x] = img.sample((Double(x) + 0.5) / s - 0.5, (Double(y) + 0.5) / s - 0.5)
            }
        }
        return GrayImage(width: w, height: h, pixels: out)
    }

    /// Bilinear sample with edge clamping.
    @inline(__always)
    public func sample(_ x: Double, _ y: Double) -> Float {
        let xc = max(0, min(Double(width - 1), x)), yc = max(0, min(Double(height - 1), y))
        let x0 = Int(xc), y0 = Int(yc)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = Float(xc - Double(x0)), fy = Float(yc - Double(y0))
        return pixels.withUnsafeBufferPointer { p in
            let a = p[y0 * width + x0], b = p[y0 * width + x1]
            let c = p[y1 * width + x0], d = p[y1 * width + x1]
            return (a + (b - a) * fx) + ((c + (d - c) * fx) - (a + (b - a) * fx)) * fy
        }
    }
}
