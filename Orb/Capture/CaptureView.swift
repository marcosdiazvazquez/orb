import AVFoundation
import PanoCore
import SwiftUI

struct CaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CaptureStore.self) private var store
    @Environment(StitchService.self) private var stitcher
    @AppStorage(SettingsKey.lens) private var lens: Lens = .ultraWide
    @AppStorage(SettingsKey.density) private var density: ShotDensity = .standard
    @AppStorage(SettingsKey.output) private var output: OutputQuality = .high
    @AppStorage(SettingsKey.lockExposure) private var lockExposure = true
    @State private var model = CaptureModel()
    @State private var confirmDiscard = false
    @State private var flash = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: model.session, phase: model.phase).ignoresSafeArea()
            TimelineView(.animation) { _ in
                Canvas { ctx, size in CaptureOverlay.draw(model, &ctx, size) }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            Color.white.opacity(flash ? 0.35 : 0).ignoresSafeArea().allowsHitTesting(false)
            controls
        }
        .statusBarHidden()
        .task { await model.start(lens: lens, density: density, lockExposure: lockExposure) }
        .onDisappear { model.stop() }
        .onChange(of: model.shotCounter) {
            flash = true
            Task {
                try? await Task.sleep(for: .milliseconds(60))
                withAnimation(.easeOut(duration: 0.3)) { flash = false }
            }
        }
        .onChange(of: model.isComplete) { _, complete in
            if complete { finish() }
        }
        .confirmationDialog("Discard this capture?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard \(model.shots.count) shots", role: .destructive) {
                model.discard()
                dismiss()
            }
        }
    }

    @ViewBuilder private var controls: some View {
        VStack(spacing: 14) {
            HStack {
                Button {
                    if model.shots.isEmpty { model.discard(); dismiss() } else { confirmDiscard = true }
                } label: {
                    Image(systemName: "xmark").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                }
                .background(.ultraThinMaterial, in: Circle())
                Spacer()
                VStack(spacing: 6) {
                    if !model.targets.isEmpty {
                        Text("\(model.done.count) / \(model.targets.count)")
                            .font(.headline.monospacedDigit())
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    if model.phase == .aiming { gpsLabel }
                }
                Spacer()
                Button { model.undoLast() } label: {
                    Image(systemName: "arrow.uturn.backward").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                }
                .background(.ultraThinMaterial, in: Circle())
                .disabled(model.shots.isEmpty)
                .opacity(model.shots.isEmpty ? 0.4 : 1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)

            Spacer()

            if case .failed(let message) = model.phase {
                VStack(spacing: 12) {
                    Text(message).multilineTextAlignment(.center)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                .padding(24)
            } else {
                Text(hint)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 24)
            }

            if model.shots.count >= 2 {
                Button { finish() } label: {
                    Label("Stitch \(model.shots.count) shots", systemImage: "circle.hexagongrid")
                        .font(.headline)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .foregroundStyle(.black)
            }
        }
        .padding(.vertical, 12)
    }

    /// Live GPS accuracy, so the photographer can see whether the fix is good before leaving.
    private var gpsLabel: some View {
        let (text, symbol): (String, String) = switch model.gps {
        case .off: ("No location", "location.slash")
        case .searching: ("Finding GPS…", "location")
        case .fix(let accuracy): (String(format: "GPS ±%.0f m", accuracy), "location.fill")
        }
        return Label(text, systemImage: symbol)
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private var hint: String {
        switch model.phase {
        case .starting: return "Starting camera…"
        case .failed: return ""
        case .aiming:
            if model.isShooting || model.hold > 0 { return "Hold still…" }
            if model.shots.isEmpty {
                return "Put the circle on the yellow dot and hold still. Turn the phone around its lens, not around yourself."
            }
            return "Follow the arrow to the next dot."
        }
    }

    private func finish() {
        guard model.shots.count >= 2 else { return }
        model.stop()
        let record = model.makeRecord()
        store.save(record)
        stitcher.enqueue(record.id, outputWidth: output.rawValue)
        dismiss()
    }
}

/// Draws the guide over the live preview: outlines of the shots taken, the remaining target
/// dots, the reticle with its hold timer, and an arrow toward the next target when it's off screen.
enum CaptureOverlay {
    @MainActor
    static func draw(_ m: CaptureModel, _ ctx: inout GraphicsContext, _ size: CGSize) {
        guard let cam = m.cameraRotation, !m.targetDirections.isEmpty else { return }
        let toCamera = cam.transposed
        // The preview aspect-fills the view with a portrait 3:4 frame.
        let width = Double(size.width), height = Double(size.height)
        let frameAspect = 1 / m.aspect
        let shownHeight: Double = width / height < frameAspect ? height : width / frameAspect
        let f = shownHeight / 2 / tan(m.longFOV / 2)
        let cx = width / 2, cy = height / 2
        let center = CGPoint(x: cx, y: cy)

        func project(_ d: Vec3) -> CGPoint? {
            let c = toCamera * d
            guard c.z > 0.08 else { return nil }
            return CGPoint(x: cx + f * c.x / c.z, y: cy + f * c.y / c.z)
        }

        // Shots taken.
        let tx = tan(m.shortFOV / 2), ty = tan(m.longFOV / 2)
        let corners = [(-tx, -ty), (tx, -ty), (tx, ty), (-tx, ty), (-tx, -ty)]
        for r in m.shotRotations {
            var path = Path()
            var penDown = false, complete = true
            for k in 0..<4 {
                for s in 0...8 where !(s == 8 && k < 3) {
                    let t = Double(s) / 8
                    let (x0, y0) = corners[k], (x1, y1) = corners[k + 1]
                    let d = r * Vec3(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, 1).normalized
                    if let p = project(d) {
                        if penDown { path.addLine(to: p) } else { path.move(to: p) }
                        penDown = true
                    } else {
                        penDown = false
                        complete = false
                    }
                }
            }
            if complete { ctx.fill(path, with: .color(.white.opacity(0.08))) }
            ctx.stroke(path, with: .color(.white.opacity(0.45)), lineWidth: 1.5)
        }

        // Remaining targets.
        for (i, d) in m.targetDirections.enumerated() where !m.done.contains(i) {
            guard let p = project(d) else { continue }
            let isNext = i == m.nextTarget
            let r: CGFloat = isNext ? 17 : 11
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(isNext ? .yellow : .white.opacity(0.85)), lineWidth: isNext ? 3 : 2)
            let dot: CGFloat = isNext ? 6 : 4
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - dot, y: p.y - dot, width: 2 * dot, height: 2 * dot)),
                     with: .color(isNext ? .yellow : .white))
        }

        // Reticle and hold progress.
        let R: CGFloat = 28
        let ring = Path(ellipseIn: CGRect(x: center.x - R, y: center.y - R, width: 2 * R, height: 2 * R))
        ctx.stroke(ring, with: .color(.white), lineWidth: 2)
        if m.hold > 0 {
            let outer = Path(ellipseIn: CGRect(x: center.x - R - 7, y: center.y - R - 7, width: 2 * R + 14, height: 2 * R + 14))
            ctx.stroke(outer.trimmedPath(from: 0, to: CGFloat(m.hold)), with: .color(.yellow),
                       style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }

        // Arrow toward the next target.
        if let n = m.nextTarget {
            let inset = CGRect(x: 40, y: 110, width: size.width - 80, height: size.height - 280)
            let visible = project(m.targetDirections[n]).map { inset.contains($0) } ?? false
            if !visible {
                let c = toCamera * m.targetDirections[n]
                var v = CGVector(dx: c.x, dy: c.y)
                let len = hypot(v.dx, v.dy)
                v = len < 1e-6 ? CGVector(dx: 0, dy: -1) : CGVector(dx: v.dx / len, dy: v.dy / len)
                let reach = min(size.width, size.height) / 2 - 56
                let tip = CGPoint(x: center.x + v.dx * reach, y: center.y + v.dy * reach)
                let base = CGPoint(x: tip.x - v.dx * 24, y: tip.y - v.dy * 24)
                let perp = CGVector(dx: -v.dy * 13, dy: v.dx * 13)
                var arrow = Path()
                arrow.move(to: tip)
                arrow.addLine(to: CGPoint(x: base.x + perp.dx, y: base.y + perp.dy))
                arrow.addLine(to: CGPoint(x: base.x - perp.dx, y: base.y - perp.dy))
                arrow.closeSubpath()
                ctx.fill(arrow, with: .color(.yellow))
            }
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var phase: CaptureModel.Phase

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.setNeedsLayout()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let c = previewLayer.connection, c.isVideoRotationAngleSupported(90), c.videoRotationAngle != 90 {
                c.videoRotationAngle = 90
            }
        }
    }
}
