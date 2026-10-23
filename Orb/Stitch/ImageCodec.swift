import CoreGraphics
import Foundation
import ImageIO
import PanoCore
import UniformTypeIdentifiers

enum ImageCodecError: LocalizedError {
    case unreadable(String)
    case unwritable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let f): "Could not read \(f)."
        case .unwritable(let f): "Could not write \(f)."
        }
    }
}

/// ImageIO bridge for PanoCore's RGBA buffers. Everything stays in Display P3, the iPhone
/// camera's colour space, so stitching doesn't clip its gamut.
enum ImageCodec {
    static let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    /// Decodes with the EXIF orientation applied, downscaled so the long side is at most `maxPixelSize`.
    static func decode(_ url: URL, maxPixelSize: Int) throws -> RGBAImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageCodecError.unreadable(url.lastPathComponent)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw ImageCodecError.unreadable(url.lastPathComponent)
        }
        return rgba(image)
    }

    static func rgba(_ image: CGImage) -> RGBAImage {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return RGBAImage(width: w, height: h, pixels: pixels)
    }

    static func cgImage(_ image: RGBAImage) -> CGImage {
        let provider = CGDataProvider(data: Data(image.pixels) as CFData)!
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: image.width * 4, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    /// Writes a JPEG. With `equirectangular`, adds Google's GPano XMP so Google Photos,
    /// Facebook and other 360° viewers open it as a sphere.
    static func writeJPEG(_ image: RGBAImage, to url: URL, quality: Double, equirectangular: Bool = false) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImageCodecError.unwritable(url.lastPathComponent)
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        let cg = cgImage(image)
        if equirectangular {
            CGImageDestinationAddImageAndMetadata(dest, cg, panoramaMetadata(width: image.width, height: image.height),
                                                  props as CFDictionary)
        } else {
            CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw ImageCodecError.unwritable(url.lastPathComponent) }
    }

    /// Photo Sphere XMP (https://developers.google.com/streetview/spherical-metadata).
    static func panoramaMetadata(width: Int, height: Int) -> CGImageMetadata {
        let meta = CGImageMetadataCreateMutable()
        let ns = "http://ns.google.com/photos/1.0/panorama/" as CFString
        CGImageMetadataRegisterNamespaceForPrefix(meta, ns, "GPano" as CFString, nil)
        let fields: [(String, String)] = [
            ("ProjectionType", "equirectangular"),
            ("UsePanoramaViewer", "True"),
            ("CaptureSoftware", "Orb"),
            ("StitchingSoftware", "Orb"),
            ("FullPanoWidthPixels", "\(width)"),
            ("FullPanoHeightPixels", "\(height)"),
            ("CroppedAreaImageWidthPixels", "\(width)"),
            ("CroppedAreaImageHeightPixels", "\(height)"),
            ("CroppedAreaLeftPixels", "0"),
            ("CroppedAreaTopPixels", "0"),
        ]
        for (key, value) in fields {
            CGImageMetadataSetValueWithPath(meta, nil, "GPano:\(key)" as CFString, value as CFString)
        }
        return meta
    }
}
