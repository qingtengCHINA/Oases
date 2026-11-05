import CoreText
import MetalKit
import UIKit

/// Mirrors `AsciiOceanUniforms` in AsciiOcean.metal.
struct AsciiOceanUniforms {
    var hueA: SIMD4<Float> = .zero
    var hueB: SIMD4<Float> = .zero
    var ink: SIMD4<Float> = .zero
    var snow: SIMD4<Float> = .zero
    var accent0: SIMD4<Float> = .zero
    var accent1: SIMD4<Float> = .zero
    var accent2: SIMD4<Float> = .zero
    var accent3: SIMD4<Float> = .zero
    var cellPx: SIMD2<Float> = .zero
    var grid: SIMD2<Float> = .zero
    var drawable: SIMD2<Float> = .zero
    var fade: SIMD2<Float> = .zero
    var time: Float = 0
    var tickRate: Float = 1.4
    var layerAlpha: Float = 1
    var glyphCap: Float = 1
    var tileScale: Float = 1
    var hot: Float = 1
    var light: Float = 0
    var gridAlpha: Float = 0.03
    var glyphCount: Float = 30
    var pad0: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0
}

/// How the ocean should look right now; set by the SwiftUI side, eased by the renderer.
struct AsciiOceanConfiguration: Equatable {
    var isLight = false
    /// Overall opacity: full on an empty session, faint behind a conversation.
    var layerAlpha: Float = 1
    var glyphCap: Float = 1
    var tileScale: Float = 1
    var allowsHotCells = true
    /// Points to fade in from the top edge and out at the bottom edge.
    var fadeTop: Float = 48
    var fadeBottom: Float = 0
    /// Where the composer's centre is, measured up from the bottom edge (points).
    var composerLift: Float = 60
    var framesPerSecond = 30
    /// Draws one still frame and stops (Reduce Motion, thermal pressure, background).
    var isStill = false
    var isPaused = false
}

/// Metal objects every ocean shares (iPad can show two Ogent windows).
final class AsciiOceanGPU: @unchecked Sendable {
    static let shared = AsciiOceanGPU()
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    let device: MTLDevice?
    let queue: MTLCommandQueue?
    let pipeline: MTLRenderPipelineState?
    let sampler: MTLSamplerState?

    private init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        queue = device?.makeCommandQueue()
        var pipeline: MTLRenderPipelineState?
        if let device, let library = device.makeDefaultLibrary() {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "asciiOceanVertex")
            d.fragmentFunction = library.makeFunction(name: "asciiOceanFragment")
            d.colorAttachments[0].pixelFormat = Self.pixelFormat
            pipeline = try? device.makeRenderPipelineState(descriptor: d)
        }
        self.pipeline = pipeline
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        s.sAddressMode = .clampToEdge
        s.tAddressMode = .clampToEdge
        sampler = device?.makeSamplerState(descriptor: s)
    }
}

/// The 12-step density ramp (two shapes per step) and the snow characters.
enum AsciiOceanGlyphs {
    static let ramp: [String] = [
        ".", "`", ",", "'", ":", "-", ";", "~", "=", "+", "i", "!",
        "c", "r", "o", "x", "a", "e", "%", "&", "$", "8", "#", "@",
    ]
    static let snow: [String] = [".", "-", "'", ",", "`", ":"]
    static var all: [String] { ramp + snow }
}

@MainActor
final class AsciiOceanRenderer: NSObject, MTKViewDelegate {
    private var sim = OceanSimulation()
    private var field = OceanField()
    private let signals: AgentLiveSignals?
    private var seen = AgentLiveSignals.Snapshot()
    private var hasSeenSignals = false

    var configuration = AsciiOceanConfiguration() {
        didSet { applyPolicy() }
    }
    var reduceMotion = false
    private weak var view: MTKView?

    // Eased display values.
    private var layerAlpha: Float = 0
    private var glyphCap: Float = 1
    private var tileScale: Float = 1
    private var hot: Float = 1
    private var lastFrame: CFTimeInterval = 0
    private var stillDrawn = false

    // Textures.
    private var cellTextures: [MTLTexture] = []
    private var cellIndex = 0
    private let inFlight = DispatchSemaphore(value: 3)
    private var atlas: MTLTexture?
    private var atlasKey = ""

    /// Off-screen views and a backgrounded app never draw (background GPU work is an error).
    var isInWindow = false {
        didSet { if isInWindow != oldValue { applyPolicy() } }
    }
    private var isAppActive = UIApplication.shared.applicationState == .active
    private let observers = NotificationTokens()

    init(signals: AgentLiveSignals?) {
        self.signals = signals
        super.init()
        let center = NotificationCenter.default
        observers.add(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setAppActive(false) }
        })
        observers.add(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setAppActive(true) }
        })
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.add(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyPolicy() }
            })
        }
    }

    private func setAppActive(_ active: Bool) {
        guard active != isAppActive else { return }
        isAppActive = active
        applyPolicy()
    }

    /// Frame rate after the system's own pressure: 30 normally, 20 on Low Power, still when hot.
    private var systemAllowsMotion: Bool { ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue }
    private var systemFrameRate: Int {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? min(20, configuration.framesPerSecond) : configuration.framesPerSecond
    }

    func attach(to view: MTKView) {
        self.view = view
        view.device = AsciiOceanGPU.shared.device
        view.colorPixelFormat = AsciiOceanGPU.pixelFormat
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.isOpaque = false
        view.layer.isOpaque = false
        view.framebufferOnly = true
        view.autoResizeDrawable = true
        view.delegate = self
        applyPolicy()
    }

    // MARK: Policy

    func applyPolicy() {
        guard let view else { return }
        guard isInWindow, isAppActive, !configuration.isPaused else {
            // Keep the last frame on screen; draw nothing until we are back.
            view.isPaused = true
            view.enableSetNeedsDisplay = false
            return
        }
        if isStill {
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            if !stillDrawn { view.setNeedsDisplay() }
        } else {
            stillDrawn = false
            view.enableSetNeedsDisplay = false
            view.preferredFramesPerSecond = systemFrameRate
            if view.isPaused {
                lastFrame = 0
                view.isPaused = false
            }
        }
    }

    /// One still frame instead of motion.
    private var isStill: Bool { configuration.isStill || reduceMotion || !systemAllowsMotion }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        stillDrawn = false
        if view.isPaused { view.setNeedsDisplay() }
    }

    func draw(in view: MTKView) {
        let gpu = AsciiOceanGPU.shared
        guard let device = gpu.device, let queue = gpu.queue, let pipeline = gpu.pipeline,
              let sampler = gpu.sampler else { return }
        let bounds = view.bounds.size
        guard bounds.width > 1, bounds.height > 1 else { return }
        let scale = Float(view.contentScaleFactor)

        // Time step.
        let now = CACurrentMediaTime()
        var dt: Float = lastFrame == 0 ? 1.0 / 30 : Float(min(0.1, now - lastFrame))
        lastFrame = now
        guard isInWindow, isAppActive else { return }
        let moving = !(configuration.isPaused || isStill)
        if !moving { dt = 0 }

        sim.resize(width: Float(bounds.width), height: Float(bounds.height))
        sim.target = SIMD2(Float(bounds.width) / 2, Float(bounds.height) - configuration.composerLift)
        readSignals()
        if dt > 0 { sim.advance(dt) }

        // Ease the presentation toward the configuration (≈0.35 s).
        let k: Float = dt > 0 ? min(1, dt / 0.35 * 2.2) : 1
        layerAlpha += (configuration.layerAlpha - layerAlpha) * k
        glyphCap += (configuration.glyphCap - glyphCap) * k
        tileScale += (configuration.tileScale - tileScale) * k
        hot += ((configuration.allowsHotCells ? 1 : 0) - hot) * k

        field.render(sim)
        let grid = sim.grid
        guard let atlas = glyphAtlas(device: device, grid: grid, scale: scale),
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return }
        // Wait for a free slot before touching a cell texture the GPU may still be reading.
        inFlight.wait()
        guard let cells = cellTexture(device: device, columns: grid.columns, rows: grid.rows) else {
            inFlight.signal()
            return
        }
        field.cells.withUnsafeBytes { raw in
            cells.replace(region: MTLRegionMake2D(0, 0, grid.columns, grid.rows), mipmapLevel: 0,
                          withBytes: raw.baseAddress!, bytesPerRow: grid.columns * 4)
        }

        var u = AsciiOceanUniforms()
        let p = sim.palette
        u.hueA = SIMD4(p.a, 1)
        u.hueB = SIMD4(p.b, 1)
        u.ink = SIMD4(SIMD3<Float>(20, 22, 28) / 255, 1)
        let light = configuration.isLight
        u.snow = light ? SIMD4(SIMD3<Float>(90, 105, 130) / 255, 0.65) : SIMD4(SIMD3<Float>(150, 172, 205) / 255, 1)
        u.accent0 = SIMD4(SIMD3<Float>(143, 245, 184) / 255, 1)
        u.accent1 = SIMD4(SIMD3<Float>(255, 200, 120) / 255, 1)
        u.accent2 = SIMD4(SIMD3<Float>(240, 150, 190) / 255, 1)
        u.accent3 = SIMD4(SIMD3<Float>(190, 170, 255) / 255, 1)
        u.cellPx = SIMD2(grid.cellWidth * scale, grid.cellHeight * scale)
        u.grid = SIMD2(Float(grid.columns), Float(grid.rows))
        u.drawable = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
        u.fade = SIMD2(configuration.fadeTop * scale, configuration.fadeBottom * scale)
        u.time = sim.time
        u.tickRate = sim.time < sim.flickerUntil ? 10 : 1.4
        u.layerAlpha = layerAlpha
        u.glyphCap = glyphCap
        u.tileScale = tileScale
        u.hot = hot
        u.light = light ? 1 : 0
        u.gridAlpha = light ? 0.035 : 0.03
        u.glyphCount = Float(AsciiOceanGlyphs.all.count)

        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
            inFlight.signal()
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<AsciiOceanUniforms>.stride, index: 0)
        encoder.setFragmentTexture(cells, index: 0)
        encoder.setFragmentTexture(atlas, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        let semaphore = inFlight
        buffer.addCompletedHandler { _ in semaphore.signal() }
        buffer.present(drawable)
        buffer.commit()
        if !moving { stillDrawn = true }
    }

    // MARK: Signals

    private func readSignals() {
        guard let signals else { return }
        let s = signals.snapshot()
        defer { seen = s; hasSeenSignals = true }
        sim.setPalette(OceanPalette.forPhase(s.phase))
        sim.isLive = s.phase.isLive
        guard hasSeenSignals else { return }
        if s.sendCount != seen.sendCount { sim.pulse(reduceMotion: reduceMotion) }
        if s.failureCount != seen.failureCount { sim.dim() }
        if s.typedAt != seen.typedAt { sim.typing() }
        if s.streamedCharacters != seen.streamedCharacters {
            sim.feed(characters: s.streamedCharacters - seen.streamedCharacters)
        }
    }

    // MARK: Textures

    private func cellTexture(device: MTLDevice, columns: Int, rows: Int) -> MTLTexture? {
        if cellTextures.first.map({ $0.width != columns || $0.height != rows }) ?? true {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: columns,
                                                             height: rows, mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .shared
            cellTextures = (0..<3).compactMap { _ in device.makeTexture(descriptor: d) }
        }
        guard cellTextures.count == 3 else { return nil }
        cellIndex = (cellIndex + 1) % 3
        return cellTextures[cellIndex]
    }

    /// The characters, white on black, one cell each, at the screen's pixel scale.
    private func glyphAtlas(device: MTLDevice, grid: OceanGrid, scale: Float) -> MTLTexture? {
        let key = "\(grid.cellWidth)x\(grid.cellHeight)@\(scale)"
        if key == atlasKey, let atlas { return atlas }
        let glyphs = AsciiOceanGlyphs.all
        let gw = Int((grid.cellWidth * scale).rounded())
        let gh = Int((grid.cellHeight * scale).rounded())
        let width = gw * glyphs.count
        guard width > 0, gh > 0,
              let ctx = CGContext(data: nil, width: width, height: gh, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: gh))
        let font = UIFont.monospacedSystemFont(ofSize: CGFloat(grid.fontSize * scale), weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): UIColor.white.cgColor,
        ]
        let ascent = font.ascender, descent = -font.descender
        for (i, g) in glyphs.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: g, attributes: attrs))
            let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let x = CGFloat(i * gw) + (CGFloat(gw) - advance) / 2
            // Centre the line box vertically, half a pixel low like a baseline nudge.
            let y = (CGFloat(gh) - (ascent + descent)) / 2 + descent - CGFloat(scale) * 0.5
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, ctx)
        }
        guard let data = ctx.data else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: gh, mipmapped: false)
        d.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, gh), mipmapLevel: 0, withBytes: data, bytesPerRow: width)
        atlas = texture
        atlasKey = key
        return texture
    }
}

/// Notification observers removed when their owner goes away.
final class NotificationTokens: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []
    private let lock = NSLock()

    func add(_ token: NSObjectProtocol) {
        lock.lock()
        tokens.append(token)
        lock.unlock()
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
