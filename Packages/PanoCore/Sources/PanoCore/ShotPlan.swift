import Foundation

public struct ShotTarget: Sendable, Identifiable, Equatable {
    public let id: Int
    public let ring: Int            // 0 = horizon, +k above, -k below; ±100 = pole
    public let latitude: Double     // radians
    public let longitude: Double    // radians, relative to the heading at the start of capture

    public var direction: Vec3 { Equirect.direction(latitude: latitude, longitude: longitude) }
}

/// Where to point the camera to cover the full sphere.
///
/// Each shot is treated as a cone of half-angle `shortFOV / 2` (the inscribed circle of the
/// frame), so coverage holds however the phone is rolled, including upside down. Neighbouring
/// shots, within a ring and between rings, are at most `2a(1 - overlap)` apart.
public struct ShotPlan: Sendable {
    public let targets: [ShotTarget]
    public let shortFOV: Double
    public let overlap: Double

    public var count: Int { targets.count }

    public init(shortFOV: Double, overlap: Double = 0.4) {
        self.shortFOV = shortFOV
        self.overlap = overlap
        let a = shortFOV / 2
        let step = 2 * a * (1 - overlap)
        let margin = radians(3)

        // Option A: k evenly spaced rings, the last one also covering the pole.
        let k = max(1, Int(ceil((Double.pi / 2 + margin - a) / step - 1e-9)))
        let ringsA = (1...k).map { Double($0) * (Double.pi / 2 + margin - a) / Double(k) }
        // Option B: rings every `step`, then a single shot straight at the pole.
        var ringsB: [Double] = []
        var last = 0.0
        while Double.pi / 2 - last > step { last += step; ringsB.append(last) }
        if last >= Double.pi / 2 - 1e-3 { ringsB = [] }

        func count(atLatitude l: Double) -> Int {
            if l == 0 { return max(3, Int(ceil(2 * Double.pi / step - 0.25))) }
            let s2 = sin(l) * sin(l), c2 = cos(l) * cos(l)
            let c = max(-1, min(1, (cos(step) - s2) / c2))
            return max(3, Int(ceil(2 * Double.pi / acos(c) - 0.25)))
        }
        let costA = ringsA.reduce(0) { $0 + count(atLatitude: $1) }
        let costB = ringsB.isEmpty ? Int.max : ringsB.reduce(1) { $0 + count(atLatitude: $1) }
        let usePole = costB < costA
        let rings = usePole ? ringsB : ringsA

        var out: [ShotTarget] = []
        func addRing(_ index: Int, _ l: Double) {
            let n = count(atLatitude: l)
            // Stagger alternate rings by half a spacing so their seams don't line up.
            let offset = index % 2 == 0 ? 0 : Double.pi / Double(n)
            for i in 0..<n {
                var lon = offset + 2 * Double.pi * Double(i) / Double(n)
                if lon > Double.pi { lon -= 2 * Double.pi }
                out.append(ShotTarget(id: out.count, ring: index, latitude: l, longitude: lon))
            }
        }
        addRing(0, 0)
        for (i, l) in rings.enumerated() { addRing(i + 1, l) }
        for (i, l) in rings.enumerated() { addRing(-(i + 1), -l) }
        if usePole {
            out.append(ShotTarget(id: out.count, ring: 100, latitude: Double.pi / 2, longitude: 0))
            out.append(ShotTarget(id: out.count, ring: -100, latitude: -Double.pi / 2, longitude: 0))
        }
        targets = out
    }
}
