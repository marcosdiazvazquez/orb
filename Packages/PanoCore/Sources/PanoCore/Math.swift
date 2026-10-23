import Foundation

public struct Vec3: Equatable, Sendable {
    public var x, y, z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x; self.y = y; self.z = z
    }

    public static let zero = Vec3(0, 0, 0)

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public static func * (s: Double, a: Vec3) -> Vec3 { a * s }
    public static prefix func - (a: Vec3) -> Vec3 { Vec3(-a.x, -a.y, -a.z) }

    public func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }
    public func cross(_ b: Vec3) -> Vec3 {
        Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x)
    }
    public var length: Double { sqrt(dot(self)) }
    public var normalized: Vec3 {
        let l = length
        return l > 0 ? self * (1 / l) : self
    }

    /// Angle between two vectors, in radians.
    public func angle(to b: Vec3) -> Double {
        atan2(cross(b).length, dot(b))
    }
}

/// 3x3 matrix stored as rows. Rotations here map camera coordinates to world coordinates.
public struct Mat3: Equatable, Sendable {
    public var r0, r1, r2: Vec3

    public init(rows r0: Vec3, _ r1: Vec3, _ r2: Vec3) {
        self.r0 = r0; self.r1 = r1; self.r2 = r2
    }

    public init(columns c0: Vec3, _ c1: Vec3, _ c2: Vec3) {
        r0 = Vec3(c0.x, c1.x, c2.x)
        r1 = Vec3(c0.y, c1.y, c2.y)
        r2 = Vec3(c0.z, c1.z, c2.z)
    }

    public static let identity = Mat3(rows: Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1))

    public func row(_ r: Int) -> Vec3 { r == 0 ? r0 : (r == 1 ? r1 : r2) }
    public func column(_ c: Int) -> Vec3 {
        switch c {
        case 0: return Vec3(r0.x, r1.x, r2.x)
        case 1: return Vec3(r0.y, r1.y, r2.y)
        default: return Vec3(r0.z, r1.z, r2.z)
        }
    }

    public var transposed: Mat3 { Mat3(columns: r0, r1, r2) }

    @inline(__always)
    public static func * (a: Mat3, v: Vec3) -> Vec3 {
        Vec3(a.r0.dot(v), a.r1.dot(v), a.r2.dot(v))
    }

    public static func * (a: Mat3, b: Mat3) -> Mat3 {
        let c0 = b.column(0), c1 = b.column(1), c2 = b.column(2)
        return Mat3(rows:
            Vec3(a.r0.dot(c0), a.r0.dot(c1), a.r0.dot(c2)),
            Vec3(a.r1.dot(c0), a.r1.dot(c1), a.r1.dot(c2)),
            Vec3(a.r2.dot(c0), a.r2.dot(c1), a.r2.dot(c2)))
    }

    /// Rodrigues: rotation by |w| radians about w.
    public static func rotation(_ w: Vec3) -> Mat3 {
        let theta = w.length
        if theta < 1e-12 { return .identity }
        let k = w * (1 / theta)
        let c = cos(theta), s = sin(theta), t = 1 - c
        return Mat3(rows:
            Vec3(t * k.x * k.x + c, t * k.x * k.y - s * k.z, t * k.x * k.z + s * k.y),
            Vec3(t * k.x * k.y + s * k.z, t * k.y * k.y + c, t * k.y * k.z - s * k.x),
            Vec3(t * k.x * k.z - s * k.y, t * k.y * k.z + s * k.x, t * k.z * k.z + c))
    }

    public static func rotation(axis: Vec3, angle: Double) -> Mat3 {
        rotation(axis.normalized * angle)
    }

    /// Inverse of `rotation(_:)`: the axis-angle vector of a rotation matrix.
    public var axisAngle: Vec3 {
        let tr = r0.x + r1.y + r2.z
        let c = max(-1, min(1, (tr - 1) / 2))
        let theta = acos(c)
        let v = Vec3(r2.y - r1.z, r0.z - r2.x, r1.x - r0.y)
        if theta < 1e-9 { return v * 0.5 }
        if Double.pi - theta < 1e-6 {
            // Near 180 degrees: take the axis from the diagonal.
            let xx = sqrt(max(0, (r0.x + 1) / 2)), yy = sqrt(max(0, (r1.y + 1) / 2)), zz = sqrt(max(0, (r2.z + 1) / 2))
            var axis = Vec3(xx, r0.y >= 0 ? yy : -yy, r0.z >= 0 ? zz : -zz)
            if xx < 1e-6 { axis = Vec3(0, yy, r1.z >= 0 ? zz : -zz) }
            return axis.normalized * theta
        }
        return v * (theta / (2 * sin(theta)))
    }

    /// Rotation angle of this matrix, in radians.
    public var rotationAngle: Double { axisAngle.length }

    /// Rotation from a unit quaternion (w, x, y, z) that maps body vectors to reference vectors.
    public static func fromQuaternion(w: Double, x: Double, y: Double, z: Double) -> Mat3 {
        let n = sqrt(w * w + x * x + y * y + z * z)
        let (w, x, y, z) = (w / n, x / n, y / n, z / n)
        return Mat3(rows:
            Vec3(1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)),
            Vec3(2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)),
            Vec3(2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)))
    }

    /// Re-orthonormalize (Gram-Schmidt on the columns) to stop drift after many updates.
    public var orthonormalized: Mat3 {
        let c0 = column(0).normalized
        var c1 = column(1)
        c1 = (c1 - c0 * c0.dot(c1)).normalized
        let c2 = c0.cross(c1)
        return Mat3(columns: c0, c1, c2)
    }
}

/// World frame: Z up (against gravity), X toward the panorama's center, right-handed.
/// Equirectangular images have u (column) increasing to the viewer's right and v (row) increasing downward.
public enum Equirect {
    /// u, v in [0, 1].
    @inline(__always)
    public static func direction(u: Double, v: Double) -> Vec3 {
        let lon = (u - 0.5) * 2 * Double.pi
        let lat = (0.5 - v) * Double.pi
        return Vec3(cos(lat) * cos(lon), -cos(lat) * sin(lon), sin(lat))
    }

    @inline(__always)
    public static func uv(_ d: Vec3) -> (u: Double, v: Double) {
        let n = d.normalized
        let lat = asin(max(-1, min(1, n.z)))
        let lon = atan2(-n.y, n.x)
        return (lon / (2 * Double.pi) + 0.5, 0.5 - lat / Double.pi)
    }

    public static func direction(latitude: Double, longitude: Double) -> Vec3 {
        Vec3(cos(latitude) * cos(longitude), -cos(latitude) * sin(longitude), sin(latitude))
    }
}

@inline(__always)
func degrees(_ r: Double) -> Double { r * 180 / Double.pi }
@inline(__always)
func radians(_ d: Double) -> Double { d * Double.pi / 180 }
