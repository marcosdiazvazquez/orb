import Foundation
import PanoCore
import simd

extension Mat3 {
    init(rowMajor v: [Double]) {
        precondition(v.count == 9)
        self.init(rows: Vec3(v[0], v[1], v[2]), Vec3(v[3], v[4], v[5]), Vec3(v[6], v[7], v[8]))
    }

    var rowMajor: [Double] { [r0.x, r0.y, r0.z, r1.x, r1.y, r1.z, r2.x, r2.y, r2.z] }

    var simd: simd_float3x3 {
        simd_float3x3(columns: (
            SIMD3<Float>(Float(r0.x), Float(r1.x), Float(r2.x)),
            SIMD3<Float>(Float(r0.y), Float(r1.y), Float(r2.y)),
            SIMD3<Float>(Float(r0.z), Float(r1.z), Float(r2.z))))
    }

    /// Rotation about world Z (up), counter-clockwise seen from above.
    static func yaw(_ angle: Double) -> Mat3 { rotation(axis: Vec3(0, 0, 1), angle: angle) }
}

extension Vec3 {
    /// Panorama longitude of a direction (0 at the centre, positive to the right).
    var longitude: Double { atan2(-y, x) }
    var latitude: Double { asin(max(-1, min(1, normalized.z))) }
}
