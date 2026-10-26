import MetalKit
import PanoCore
import SwiftUI
import simd

enum PanoViewMode {
    case look      // normal perspective view from the centre
    case planet    // stereographic view of the nadir
}

/// Interactive 360° viewer: drag to look around, pinch to zoom, double-tap for the little
/// planet, and optionally steer with the phone's motion.
struct PanoViewer: UIViewRepresentable {
    let url: URL
    /// Changes when the file is rewritten (re-stitch), forcing a reload.
    let version: Date?
    @Binding var mode: PanoViewMode
    var gyro: Bool

    func makeCoordinator() -> PanoRenderer { PanoRenderer() }

    func makeUIView(context: Context) -> MTKView {
        let renderer = context.coordinator
        let view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        (view.layer as? CAMetalLayer)?.colorspace = ImageCodec.colorSpace
        view.delegate = renderer
        renderer.attach(to: view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        let renderer = context.coordinator
        renderer.onToggleMode = { mode = (mode == .look) ? .planet : .look }
        renderer.load(url, version: version)
        renderer.setMode(mode)
        renderer.setGyro(gyro)
    }

    static func dismantleUIView(_ view: MTKView, coordinator: PanoRenderer) {
        coordinator.setGyro(false)
    }
}

final class PanoRenderer: NSObject, MTKViewDelegate {
    struct Uniforms {
        var viewToWorld: simd_float3x3
        var tanHalf: SIMD2<Float>
        var projection: Float
        var texHeight: Float
    }

    let device: MTLDevice = MTLCreateSystemDefaultDevice()!
    var onToggleMode: (() -> Void)?

    private lazy var commandQueue = device.makeCommandQueue()!
    private lazy var pipeline: MTLRenderPipelineState? = {
        guard let library = device.makeDefaultLibrary() else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "panoVertex")
        desc.fragmentFunction = library.makeFunction(name: "panoFragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: desc)
    }()
    private lazy var sampler: MTLSamplerState? = {
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear
        d.magFilter = .linear
        d.mipFilter = .linear
        d.sAddressMode = .repeat
        d.tAddressMode = .clampToEdge
        d.maxAnisotropy = 4
        return device.makeSamplerState(descriptor: d)
    }()

    private var texture: MTLTexture?
    private var loaded: (url: URL, version: Date?)?

    // View state. Yaw turns left (counter-clockwise from above), pitch looks up.
    private var yaw = 0.0
    private var pitch = 0.0
    private var lookExtent = tan(37.5 * Double.pi / 180)   // tan(vertical fov / 2)
    private var planetExtent = 2.4
    private var planet = 0.0, planetTarget = 0.0
    private var velocity = CGPoint.zero                     // radians/second from a fling
    private var dragging = false
    private var lastFrame = CACurrentMediaTime()

    private let motion = MotionTracker()
    private var gyro = false
    private var gyroYaw = 0.0
    private var gyroNeedsAlign = false
    /// Which way the screen is turned, for steering with the phone in landscape.
    private var orientation = UIInterfaceOrientation.portrait

    func attach(to view: MTKView) {
        view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(onPan(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:))))
        let tap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap(_:)))
        tap.numberOfTapsRequired = 2
        view.addGestureRecognizer(tap)
    }

    func load(_ url: URL, version: Date?) {
        if let loaded, loaded.url == url, loaded.version == version { return }
        loaded = (url, version)
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .generateMipmaps: true,
            .SRGB: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
        ]
        loader.newTexture(URL: url, options: options) { [weak self] texture, _ in
            DispatchQueue.main.async { self?.texture = texture }
        }
    }

    func setMode(_ mode: PanoViewMode) {
        planetTarget = mode == .planet ? 1 : 0
    }

    func setGyro(_ on: Bool) {
        guard on != gyro else { return }
        if on {
            motion.start(hz: 60)
            gyroNeedsAlign = true
        } else {
            // Keep looking where the phone was pointing.
            if let forward = gyroForward() {
                yaw = -forward.longitude
                pitch = forward.latitude
            }
            motion.stop()
        }
        gyro = on
    }

    // MARK: - Rendering

    /// View frame (x right, y up, -z forward) to world, for the drag-controlled camera.
    private func dragViewToWorld(pitch p: Double) -> Mat3 {
        // Looking at +X with Z up puts the view's right on -Y.
        let base = Mat3(columns: Vec3(0, -1, 0), Vec3(0, 0, 1), Vec3(-1, 0, 0))
        return Mat3.yaw(yaw) * base * Mat3.rotation(axis: Vec3(1, 0, 0), angle: p)
    }

    /// In portrait the view frame is the device frame, so the attitude is the view rotation. In
    /// landscape the view frame is the device frame turned a quarter about the screen normal.
    private func gyroViewToWorld() -> Mat3? {
        guard let attitude = motion.latest?.rotation else { return nil }
        let quarterTurns: Double = switch orientation {
        case .landscapeRight: -1    // top edge to the left: view up is device +x
        case .landscapeLeft: 1      // top edge to the right: view up is device -x
        default: 0
        }
        return Mat3.yaw(gyroYaw) * attitude * Mat3.rotation(axis: Vec3(0, 0, 1), angle: quarterTurns * .pi / 2)
    }

    private func gyroForward() -> Vec3? { gyroViewToWorld().map { $0 * Vec3(0, 0, -1) } }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = min(0.05, now - lastFrame)
        lastFrame = now
        orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait

        planet += (planetTarget - planet) * min(1, dt * 7)
        if abs(planetTarget - planet) < 0.001 { planet = planetTarget }
        if !dragging, velocity != .zero {
            applyDrag(dx: Double(velocity.x) * dt, dy: Double(velocity.y) * dt)
            let decay = pow(0.04, dt)
            velocity = CGPoint(x: velocity.x * decay, y: velocity.y * decay)
            if hypot(velocity.x, velocity.y) < 0.01 { velocity = .zero }
        }

        if gyro && gyroNeedsAlign, let attitude = motion.latest?.rotation {
            // Turn the world so the phone's current heading shows what is on screen now.
            let viewForward = dragViewToWorld(pitch: pitch) * Vec3(0, 0, -1)
            let phoneForward = attitude * Vec3(0, 0, -1)
            gyroYaw = phoneForward.longitude - viewForward.longitude
            gyroNeedsAlign = false
        }

        let t = planet * planet * (3 - 2 * planet)
        let viewToWorld: Mat3
        if gyro && planetTarget == 0 && t < 0.01, let g = gyroViewToWorld() {
            viewToWorld = g
        } else {
            viewToWorld = dragViewToWorld(pitch: pitch + (-Double.pi / 2 - pitch) * t)
        }
        let extent = lookExtent + (planetExtent - lookExtent) * t
        let size = view.drawableSize
        let aspect = size.height > 0 ? Double(size.width / size.height) : 1

        guard let pipeline, let texture, let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable, let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        // `extent` spans the longer side, so turning the phone sideways keeps the scale.
        let tanHalf = aspect > 1 ? SIMD2(Float(extent), Float(extent / aspect)) : SIMD2(Float(extent * aspect), Float(extent))
        var uniforms = Uniforms(viewToWorld: viewToWorld.simd,
                                tanHalf: tanHalf,
                                projection: Float(t),
                                texHeight: Float(texture.height))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    // MARK: - Gestures

    private var currentExtent: Double { planetTarget > 0.5 ? planetExtent : lookExtent }

    private func applyDrag(dx: Double, dy: Double) {
        if gyro && planetTarget == 0 {
            gyroYaw += dx
        } else if planetTarget > 0.5 {
            yaw -= dx                       // spin the planet with the finger
        } else {
            yaw += dx
            pitch = max(-1.55, min(1.55, pitch + dy))
        }
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        guard let view = g.view, view.bounds.height > 0 else { return }
        // Radians per point at the centre of the view, so content tracks the finger. The extent
        // spans the longer side.
        let long = Double(max(view.bounds.width, view.bounds.height))
        let k = 2 * currentExtent / long / (planetTarget > 0.5 ? 2 : 1)
        switch g.state {
        case .began:
            dragging = true
            velocity = .zero
        case .changed:
            let p = g.translation(in: view)
            g.setTranslation(.zero, in: view)
            applyDrag(dx: Double(p.x) * k, dy: Double(p.y) * k)
        default:
            dragging = false
            let v = g.velocity(in: view)
            velocity = CGPoint(x: Double(v.x) * k, y: Double(v.y) * k)
        }
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        let s = Double(g.scale)
        g.scale = 1
        guard s > 0 else { return }
        if planetTarget > 0.5 {
            planetExtent = max(1.2, min(8, planetExtent / s))
        } else {
            lookExtent = max(tan(10 * Double.pi / 180), min(tan(60 * Double.pi / 180), lookExtent / s))
        }
    }

    @objc private func onDoubleTap(_ g: UITapGestureRecognizer) {
        onToggleMode?()
    }
}
