import MetalKit
import UIKit

/// Mirrors `DitherMindUniforms` in DitherMind.metal.
struct DitherMindUniforms {
    var ink: SIMD4<Float> = SIMD4(1, 1, 1, 1)
    var res: SIMD2<Float> = .zero
    var time: Float = 0
    var form: Float = 1
    var morph: Float = 0
    var shapeA: Float = 0
    var shapeB: Float = 0
    var energy: Float = 0
    var shimmer: Float = 0
    var yaw: Float = 0
    var pitch: Float = 0.32
    var lightInk: Float = 0
}

final class DitherMindGPU: @unchecked Sendable {
    static let shared = DitherMindGPU()
    let device: MTLDevice?
    let queue: MTLCommandQueue?
    let pipeline: MTLRenderPipelineState?

    private init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        queue = device?.makeCommandQueue()
        var pipeline: MTLRenderPipelineState?
        if let device, let library = device.makeDefaultLibrary() {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "ditherMindVertex")
            d.fragmentFunction = library.makeFunction(name: "ditherMindFragment")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try? device.makeRenderPipelineState(descriptor: d)
        }
        self.pipeline = pipeline
    }
}

/// Drives the mind: which shape, how formed, how busy. Main-thread only (MTKView delegate).
@MainActor
final class DitherMindRenderer: NSObject, MTKViewDelegate {
    private let signals: AgentLiveSignals?
    private var seenCharacters = 0
    private var seenCompletions = 0
    private weak var view: MTKView?

    // Shape state.
    private var current = 0
    private var next: Int?
    private var queue: [Int] = []
    private var morphStart: CFTimeInterval = 0
    private var shownSince: CFTimeInterval = 0
    static let morphDuration: CFTimeInterval = 0.95
    static let minimumDwell: CFTimeInterval = 1.1

    // Motion state.
    private var form: Float = 0
    private var boost: Float = 0
    private var energy: Float = 0.25
    private var time: Float = 0
    private var lastFrame: CFTimeInterval = 0

    var ink = SIMD4<Float>(1, 1, 1, 1) { didSet { if oldValue != ink { view?.setNeedsDisplay() } } }
    /// The ink is lighter than the page (dark mode): lit faces get the ink, not the shade.
    var lightInk = false { didSet { if oldValue != lightInk { view?.setNeedsDisplay() } } }
    var reduceMotion = false { didSet { if oldValue != reduceMotion { applyPolicy() } } }
    /// Running: the mind moves and shimmers; otherwise it settles and stops.
    var isLive = true { didSet { if oldValue != isLive { applyPolicy() } } }
    var isInWindow = false { didSet { if oldValue != isInWindow { applyPolicy() } } }
    private var isAppActive = UIApplication.shared.applicationState == .active
    private let observers = NotificationTokens()

    init(signals: AgentLiveSignals?) {
        self.signals = signals
        super.init()
        if let s = signals?.snapshot() {
            seenCharacters = s.streamedCharacters
            seenCompletions = s.toolCompletionCount
        }
        observers.add(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setAppActive(false) }
        })
        observers.add(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setAppActive(true) }
        })
    }

    private func setAppActive(_ active: Bool) {
        isAppActive = active
        applyPolicy()
    }

    func attach(to view: MTKView) {
        self.view = view
        view.device = DitherMindGPU.shared.device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.isOpaque = false
        view.layer.isOpaque = false
        view.framebufferOnly = true
        // A few device pixels per mind pixel, scaled up without smoothing.
        view.autoResizeDrawable = false
        view.layer.magnificationFilter = .nearest
        view.delegate = self
        applyPolicy()
    }

    /// Set by the view: the running step's object. Nil means "guess from the conversation".
    var explicitShape: DitherMindShape?
    private var lastGuess: CFTimeInterval = 0

    /// An object for what the model is thinking about, or for what the user asked.
    func guessedShape() -> DitherMindShape {
        guard let s = signals?.snapshot() else { return .orb }
        return DitherMindShape.guess(String(s.reasoningTail.suffix(AgentLiveSignals.reasoningTailLimit)))
            ?? DitherMindShape.guess(s.prompt)
            ?? .orb
    }

    /// Starts on `shape` without a morph.
    func setShape(_ shape: DitherMindShape) {
        current = shape.rawValue
        next = nil
        queue.removeAll()
        shownSince = CACurrentMediaTime()
    }

    /// Shows `shape` next (after the current one has had its moment).
    func show(_ shape: DitherMindShape) {
        let slice = shape.rawValue
        if reduceMotion {
            current = slice
            next = nil
            queue.removeAll()
            view?.setNeedsDisplay()
            return
        }
        if next == nil && slice == current { return }
        if queue.last == slice || (queue.isEmpty && next == slice) { return }
        queue.append(slice)
        if queue.count > 3 { queue.removeFirst(queue.count - 3) }
        applyPolicy()
    }

    func applyPolicy() {
        guard let view else { return }
        let ready = DitherMindGPU.shared.pipeline != nil
        guard ready, isInWindow, isAppActive else {
            view.isPaused = true
            view.enableSetNeedsDisplay = false
            return
        }
        let settling = form < 1 || next != nil || !queue.isEmpty
        if reduceMotion || (!isLive && !settling) {
            // Draw a still frame.
            if reduceMotion { form = 1 }
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            view.setNeedsDisplay()
        } else {
            view.enableSetNeedsDisplay = false
            view.preferredFramesPerSecond = settling ? 60 : 30
            if view.isPaused {
                lastFrame = 0
                view.isPaused = false
            }
        }
    }

    func layout(boundsSize: CGSize, scale: CGFloat) {
        guard let view else { return }
        // Whole device pixels per mind pixel: 4 on 3× screens, 3 on 2×.
        let devicePixels: CGFloat = scale >= 3 ? 4 : 3
        let factor = scale / devicePixels
        let size = CGSize(width: max(1, (boundsSize.width * factor).rounded()), height: max(1, (boundsSize.height * factor).rounded()))
        if view.drawableSize != size {
            view.drawableSize = size
            view.setNeedsDisplay()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let gpu = DitherMindGPU.shared
        guard let queueGPU = gpu.queue, let pipeline = gpu.pipeline, isInWindow, isAppActive else { return }

        let now = CACurrentMediaTime()
        let dt: Float = view.isPaused ? 0 : (lastFrame == 0 ? 1.0 / 60 : Float(min(0.1, now - lastFrame)))
        lastFrame = now
        if dt > 0 { step(dt, now: now) }

        var u = DitherMindUniforms()
        u.ink = ink
        u.res = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
        u.time = time
        u.form = reduceMotion ? 1 : form
        u.shapeA = Float(current)
        if let next {
            let t = Float(min(1, (now - morphStart) / Self.morphDuration))
            u.shapeB = Float(next)
            u.morph = t * t * (3 - 2 * t)
        }
        u.energy = energy
        u.shimmer = isLive && !reduceMotion ? floor(time * 9) : 0
        u.yaw = reduceMotion ? -0.3 : -0.3 + 0.45 * sin(time * 0.33)
        u.pitch = reduceMotion ? 0.32 : 0.32 + 0.04 * sin(time * 0.5)
        u.lightInk = lightInk ? 1 : 0

        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = queueGPU.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<DitherMindUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()

        // Settled and idle: stop the clock.
        if !view.isPaused, !isLive, form >= 1, next == nil, queue.isEmpty { applyPolicy() }
    }

    private func step(_ dt: Float, now: CFTimeInterval) {
        time += dt
        if let s = signals?.snapshot() {
            let fed = s.streamedCharacters - seenCharacters
            if fed > 0 { boost = min(5, boost + 0.03 * Float(fed)) }
            if s.toolCompletionCount != seenCompletions { energy = 1.4 }
            seenCharacters = s.streamedCharacters
            seenCompletions = s.toolCompletionCount
        }
        if explicitShape == nil, isLive, now - lastGuess > 0.6 {
            lastGuess = now
            show(guessedShape())
        }
        form = min(1, form + dt * (0.45 + boost))
        boost *= pow(0.92, dt / 0.0167)
        let target: Float = isLive ? 1 : 0.25
        energy += (target - energy) * min(1, dt * 3.6)

        // Shape sequence: finish the morph, then start the next one once the current shape
        // has been on screen long enough.
        if let next, now - morphStart >= Self.morphDuration {
            current = next
            self.next = nil
            shownSince = now
        }
        if next == nil, let first = queue.first {
            let dwell = Self.minimumDwell * (boost > 1 ? 0.5 : 1)
            if now - shownSince >= dwell {
                queue.removeFirst()
                if first != current {
                    next = first
                    morphStart = now
                }
            }
        }
    }
}
