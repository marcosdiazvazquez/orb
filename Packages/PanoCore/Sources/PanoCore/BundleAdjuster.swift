import Foundation

/// Rotation-only bundle adjustment (Brown & Lowe's "ray" residual): for every correspondence,
/// the world rays through the two observations should coincide. Unknowns are a rotation update
/// per shot (shot 0 fixed) and one focal-length scale shared by all shots. Priors pull each
/// shot toward its motion-sensor attitude: tightly in tilt (gravity is accurate), loosely in yaw.
struct BundleAdjuster {
    var sigmaMatch: Double          // radians; expected match noise
    var huber: Double = 2           // in units of sigmaMatch
    var sigmaTilt: Double = radians(0.6)
    var sigmaYaw: Double = radians(4)
    var sigmaFocal: Double = 0.08   // log-scale
    var maxIterations = 30

    struct Report {
        var initialRMS: Double      // radians, matches only
        var finalRMS: Double
        var inlierFraction: Double
        var iterations: Int
    }

    /// `cameras` are updated in place; `priors` are the sensor rotations.
    func run(cameras: inout [PinholeCamera], priors: [Mat3], baseFocals: [Double],
             matches: [Correspondence]) -> Report {
        let n = cameras.count
        let nParams = 3 * (n - 1) + 1
        @inline(__always) func paramIndex(_ cam: Int) -> Int { cam == 0 ? -1 : 3 * (cam - 1) }
        let focalIndex = nParams - 1

        var logFocal = log(cameras[0].focal / baseFocals[0])

        // Normalized camera-frame rays of the observations at the current focal.
        func cameraRay(_ cam: PinholeCamera, _ x: Double, _ y: Double) -> (n: Vec3, q: Vec3) {
            let q = Vec3((x - cam.cx) / cam.focal, (y - cam.cy) / cam.focal, 1)
            return (q.normalized, q)
        }

        func matchResidual(_ m: Correspondence, _ cams: [PinholeCamera]) -> Vec3 {
            let ri = cams[m.i].rotation * cameraRay(cams[m.i], m.xi, m.yi).n
            let rj = cams[m.j].rotation * cameraRay(cams[m.j], m.xj, m.yj).n
            return (ri - rj) * (1 / sigmaMatch)
        }

        func robust(_ s: Double) -> Double { s <= huber ? s * s : 2 * huber * s - huber * huber }

        func priorResidual(_ k: Int, _ cams: [PinholeCamera]) -> Vec3 {
            let d = (cams[k].rotation * priors[k].transposed).axisAngle
            return Vec3(d.x / sigmaTilt, d.y / sigmaTilt, d.z / sigmaYaw)
        }

        func cost(_ cams: [PinholeCamera], _ lf: Double) -> Double {
            var c = 0.0
            for m in matches { c += robust(matchResidual(m, cams).length) }
            for k in 1..<n { c += priorResidual(k, cams).dot(priorResidual(k, cams)) }
            c += (lf / sigmaFocal) * (lf / sigmaFocal)
            return c
        }

        func rms(_ cams: [PinholeCamera]) -> (Double, Double) {
            if matches.isEmpty { return (0, 1) }
            var s = 0.0, inl = 0
            for m in matches {
                let r = matchResidual(m, cams).length
                s += r * r
                if r <= huber { inl += 1 }
            }
            return (sqrt(s / Double(matches.count)) * sigmaMatch, Double(inl) / Double(matches.count))
        }

        let initial = rms(cameras).0
        var lambda = 1e-3
        var iterations = 0
        var current = cost(cameras, logFocal)

        for _ in 0..<maxIterations {
            iterations += 1
            var H = [Double](repeating: 0, count: nParams * nParams)
            var g = [Double](repeating: 0, count: nParams)

            // Accumulate J^T W J and J^T W r. Jacobian blocks, per shot k with world ray u:
            // d(R u)/d(omega) = -[u]x, so column c is e_c x u.
            for m in matches {
                let ci = cameras[m.i], cj = cameras[m.j]
                let (ni, qi) = cameraRay(ci, m.xi, m.yi)
                let (nj, qj) = cameraRay(cj, m.xj, m.yj)
                let ui = ci.rotation * ni, uj = cj.rotation * nj
                let r = (ui - uj) * (1 / sigmaMatch)
                let s = r.length
                let w = s <= huber ? 1.0 : huber / s

                // Focal: f = f0 e^sigma, dq/dsigma = (-qx, -qy, 0), dn/dq = (I - n n^T) / |q|.
                func dnds(_ n: Vec3, _ q: Vec3) -> Vec3 {
                    let dq = Vec3(-q.x, -q.y, 0)
                    return (dq - n * n.dot(dq)) * (1 / q.length)
                }
                let df = (ci.rotation * dnds(ni, qi) - cj.rotation * dnds(nj, qj)) * (1 / sigmaMatch)

                var cols: [(Int, Vec3)] = []
                cols.reserveCapacity(7)
                let pi = paramIndex(m.i), pj = paramIndex(m.j)
                let axes = [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)]
                if pi >= 0 { for c in 0..<3 { cols.append((pi + c, axes[c].cross(ui) * (1 / sigmaMatch))) } }
                if pj >= 0 { for c in 0..<3 { cols.append((pj + c, axes[c].cross(uj) * (-1 / sigmaMatch))) } }
                cols.append((focalIndex, df))

                for (a, ja) in cols {
                    g[a] += w * ja.dot(r)
                    for (b, jb) in cols { H[a * nParams + b] += w * ja.dot(jb) }
                }
            }
            // Priors: residual d = log(R P^T) in world axes, Jacobian ~ identity (scaled).
            for k in 1..<n {
                let r = priorResidual(k, cameras)
                let p = paramIndex(k)
                let sc = [1 / sigmaTilt, 1 / sigmaTilt, 1 / sigmaYaw]
                let rr = [r.x, r.y, r.z]
                for c in 0..<3 {
                    g[p + c] += sc[c] * rr[c]
                    H[(p + c) * nParams + p + c] += sc[c] * sc[c]
                }
            }
            g[focalIndex] += logFocal / (sigmaFocal * sigmaFocal)
            H[focalIndex * nParams + focalIndex] += 1 / (sigmaFocal * sigmaFocal)

            var accepted = false
            var stepNorm = 0.0
            while lambda < 1e10 {
                var A = H
                for d in 0..<nParams { A[d * nParams + d] += lambda * (H[d * nParams + d] + 1e-9) }
                guard let delta = choleskySolve(A, g.map { -$0 }, nParams) else { lambda *= 10; continue }
                var trial = cameras
                for k in 1..<n {
                    let p = paramIndex(k)
                    let w = Vec3(delta[p], delta[p + 1], delta[p + 2])
                    trial[k].rotation = (Mat3.rotation(w) * cameras[k].rotation).orthonormalized
                }
                let lf = logFocal + delta[focalIndex]
                for k in 0..<n { trial[k].focal = baseFocals[k] * exp(lf) }
                let c = cost(trial, lf)
                if c < current {
                    cameras = trial
                    logFocal = lf
                    stepNorm = delta.reduce(0) { $0 + $1 * $1 }.squareRoot()
                    current = c
                    lambda = max(1e-7, lambda / 3)
                    accepted = true
                    break
                }
                lambda *= 4
            }
            if !accepted || stepNorm < 1e-7 { break }
        }
        let (finalRMS, inliers) = rms(cameras)
        return Report(initialRMS: initial, finalRMS: finalRMS, inlierFraction: inliers, iterations: iterations)
    }
}

/// Solves A x = b for symmetric positive-definite A (row-major, n x n).
func choleskySolve(_ a: [Double], _ b: [Double], _ n: Int) -> [Double]? {
    var L = [Double](repeating: 0, count: n * n)
    for i in 0..<n {
        for j in 0...i {
            var s = a[i * n + j]
            for k in 0..<j { s -= L[i * n + k] * L[j * n + k] }
            if i == j {
                if s <= 0 { return nil }
                L[i * n + i] = sqrt(s)
            } else {
                L[i * n + j] = s / L[j * n + j]
            }
        }
    }
    var y = [Double](repeating: 0, count: n)
    for i in 0..<n {
        var s = b[i]
        for k in 0..<i { s -= L[i * n + k] * y[k] }
        y[i] = s / L[i * n + i]
    }
    var x = [Double](repeating: 0, count: n)
    for i in stride(from: n - 1, through: 0, by: -1) {
        var s = y[i]
        for k in (i + 1)..<n { s -= L[k * n + i] * x[k] }
        x[i] = s / L[i * n + i]
    }
    return x
}
