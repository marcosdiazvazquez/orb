import Foundation

/// Pinhole camera. Camera frame: x right, y down, z forward (optical axis), in image pixels.
public struct PinholeCamera: Sendable {
    public var width: Int
    public var height: Int
    public var focal: Double        // pixels
    /// Camera-to-world rotation: worldDirection = rotation * cameraDirection.
    public var rotation: Mat3

    public init(width: Int, height: Int, focal: Double, rotation: Mat3) {
        self.width = width; self.height = height; self.focal = focal; self.rotation = rotation
    }

    /// Focal length in pixels for an image whose longer side spans `longSideFOV` radians.
    public static func focal(longSide: Int, longSideFOV: Double) -> Double {
        Double(longSide) / 2 / tan(longSideFOV / 2)
    }

    public var cx: Double { Double(width) / 2 }
    public var cy: Double { Double(height) / 2 }
    public var opticalAxis: Vec3 { rotation.column(2) }

    /// Horizontal and vertical field of view, radians.
    public var fov: (h: Double, v: Double) {
        (2 * atan(Double(width) / 2 / focal), 2 * atan(Double(height) / 2 / focal))
    }

    /// World direction through pixel (x, y) (pixel centers at +0.5).
    @inline(__always)
    public func ray(_ x: Double, _ y: Double) -> Vec3 {
        rotation * Vec3((x - cx) / focal, (y - cy) / focal, 1).normalized
    }

    /// Pixel coordinates of a world direction, or nil when it is behind the camera.
    @inline(__always)
    public func project(_ world: Vec3) -> (x: Double, y: Double)? {
        let c = rotation.transposed * world
        if c.z <= 1e-9 { return nil }
        return (focal * c.x / c.z + cx, focal * c.y / c.z + cy)
    }

    @inline(__always)
    public func contains(_ p: (x: Double, y: Double), margin: Double = 0) -> Bool {
        p.x >= margin && p.y >= margin && p.x <= Double(width) - margin && p.y <= Double(height) - margin
    }
}

/// Fixed axis change between the phone body and its back camera, when the photo is decoded
/// upright for a portrait-held phone. Device frame: x right, y toward the top edge, z out of the
/// screen. Camera frame: x right, y down, z forward through the back lens.
public let deviceFromBackCamera = Mat3(rows: Vec3(1, 0, 0), Vec3(0, -1, 0), Vec3(0, 0, -1))

/// Same, for a photo left in the sensor's native landscape orientation (EXIF orientation not
/// applied): x toward the phone's bottom edge, y toward its left edge.
public let deviceFromNativeBackCamera = Mat3(rows: Vec3(0, -1, 0), Vec3(-1, 0, 0), Vec3(0, 0, -1))
