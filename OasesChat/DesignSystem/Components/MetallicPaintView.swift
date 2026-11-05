import MetalKit
import SwiftUI

/// SwiftUI wrapper around MTKView that renders MetallicPaint.metal — the iOS
/// port of Web's WebGL2 `MetallicPaint` shader. Parameters intentionally mirror
/// the props on `MetallicPaint.tsx`; defaults match the empty-greeting preset.
struct MetallicPaintView: UIViewRepresentable {
    var imageName: String
    var seed: Float = 42
    var scale: Float = 4
    var refraction: Float = 0.01
    var blur: Float = 0.015
    var liquid: Float = 0.75
    var speed: Float = 0.3
    var brightness: Float = 2
    var contrast: Float = 0.5
    var angle: Float = 0
    var fresnel: Float = 1
    var patternSharpness: Float = 1
    var waveAmplitude: Float = 1
    var noiseScale: Float = 0.5
    var chromaticSpread: Float = 2
    var distortion: Float = 1
    var contour: Float = 0.2
    var lightColor: UIColor = .white
    var darkColor: UIColor = .black
    var tintColor: UIColor = UIColor(red: 0xfe / 255, green: 0xb3 / 255, blue: 0xff / 255, alpha: 1)
    var cropTransparent: Bool = false

    func makeCoordinator() -> MetallicPaintRenderer {
        MetallicPaintRenderer()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MetallicPaintGPU.shared.device
        view.colorPixelFormat = MetallicPaintGPU.colorPixelFormat
        view.framebufferOnly = true
        view.isOpaque = false
        view.backgroundColor = .clear
        view.layer.isOpaque = false
        // MTKView's default clearColor is opaque black; the icon shader writes
        // premultiplied RGBA so anything outside the silhouette must come
        // through transparent or the icon ends up sitting on a black card.
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        context.coordinator.attach(to: view)
        applyUniforms(to: context.coordinator)
        context.coordinator.loadImage(named: imageName, cropTransparent: cropTransparent)
        return view
    }

    /// Same shader, with an SF Symbol silhouette as the liquid-metal mask.
    static func symbol(
        _ systemName: String,
        tint: UIColor,
        liquid: Float = 0.92,
        chromaticSpread: Float = 3.2,
        speed: Float = 0.45
    ) -> some View {
        MetallicPaintSymbol(
            systemName: systemName,
            tint: tint,
            liquid: liquid,
            chromaticSpread: chromaticSpread,
            speed: speed
        )
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        applyUniforms(to: context.coordinator)
        if context.coordinator.currentImageKey != "\(imageName)::\(cropTransparent ? 1 : 0)" {
            context.coordinator.loadImage(named: imageName, cropTransparent: cropTransparent)
        }
    }

    private func applyUniforms(to renderer: MetallicPaintRenderer) {
        renderer.update(
            seed: seed, scale: scale, refraction: refraction, blur: blur, liquid: liquid,
            speed: speed, brightness: brightness, contrast: contrast, angle: angle,
            fresnel: fresnel, patternSharpness: patternSharpness, waveAmplitude: waveAmplitude,
            noiseScale: noiseScale, chromaticSpread: chromaticSpread, distortion: distortion,
            contour: contour,
            lightColor: lightColor.rgb, darkColor: darkColor.rgb, tintColor: tintColor.rgb
        )
    }
}

// MARK: - Renderer

/// The Metal device, compiled pipeline and sampler every liquid-metal view shares. Building
/// them (default library load + pipeline compile) used to happen per view, on the main thread,
/// while the welcome icon was being created; now `MetallicPaintPrewarm` builds them once at
/// launch, off the main thread (`static let` is initialised lazily and exactly once).
final class MetallicPaintGPU: @unchecked Sendable {
    static let shared = MetallicPaintGPU()
    /// The MTKViews' drawable format; the pipeline is compiled for it.
    static let colorPixelFormat: MTLPixelFormat = .bgra8Unorm

    let device: MTLDevice?
    let pipeline: MTLRenderPipelineState?
    let sampler: MTLSamplerState?

    private init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        var pipeline: MTLRenderPipelineState?
        if let device, let library = device.makeDefaultLibrary() {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "metallicPaintVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "metallicPaintFragment")
            descriptor.colorAttachments[0].pixelFormat = Self.colorPixelFormat
            // Pre-multiplied source-over blending — the shader emits col * vs.
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        self.pipeline = pipeline
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        sampler = device?.makeSamplerState(descriptor: samplerDescriptor)
    }
}

/// Everything the welcome icon needs, started from `application(_:didFinishLaunchingWithOptions:)`
/// so it runs while the launch splash plays instead of after the first screen appears.
enum MetallicPaintPrewarm {
    static func start() {
        DispatchQueue.global(qos: .userInitiated).async {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = MetallicPaintGPU.shared
            _ = MetallicPaintImage.processed(imageName: "OasesIcon")
            NSLog("[OasesLaunch] metallic_prewarm_ms=%.0f", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            // The sidebar brand mark (cropped variant); not needed for the first screen.
            _ = MetallicPaintImage.processed(imageName: "OasesIcon", cropTransparent: true)
        }
    }
}

@MainActor
final class MetallicPaintRenderer: NSObject, MTKViewDelegate {
    fileprivate struct Uniforms {
        var u_time: Float = 0
        var u_ratio: Float = 1
        var u_imgRatio: Float = 1
        var u_seed: Float = 42
        var u_scale: Float = 4
        var u_refract: Float = 0.01
        var u_blur: Float = 0.015
        var u_liquid: Float = 0.75
        var u_bright: Float = 2
        var u_contrast: Float = 0.5
        var u_angle: Float = 0
        var u_fresnel: Float = 1
        var u_sharp: Float = 1
        var u_wave: Float = 1
        var u_noise: Float = 0.5
        var u_chroma: Float = 2
        var u_distort: Float = 1
        var u_contour: Float = 0.2
        // SIMD3<Float> already carries 16-byte alignment + 4 bytes internal
        // padding, matching MSL's `float3` layout exactly. Do not add explicit
        // pad floats here — that overshoots the shader's stride by 16 bytes
        // per colour and the GPU reads garbage for u_darkColor / u_tint.
        var u_lightColor: SIMD3<Float> = SIMD3(1, 1, 1)
        var u_darkColor: SIMD3<Float> = SIMD3(0, 0, 0)
        var u_tint: SIMD3<Float> = SIMD3(1, 1, 1)
    }

    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?
    private var texture: MTLTexture?
    private var uniforms = Uniforms()
    private var speed: Float = 0.3
    private var animationTime: Float = 0
    private var lastFrameTime: CFTimeInterval = 0
    private(set) var currentImageKey: String = ""

    private weak var view: MTKView?

    func attach(to view: MTKView) {
        let gpu = MetallicPaintGPU.shared
        guard let device = gpu.device else { return }
        self.view = view
        self.device = device
        self.commandQueue = device.makeCommandQueue()
        pipeline = gpu.pipeline
        sampler = gpu.sampler
    }

    func loadImage(named imageName: String, cropTransparent: Bool) {
        let key = "\(imageName)::\(cropTransparent ? 1 : 0)"
        currentImageKey = key
        if MetallicPaintImage.isReady(imageName: imageName, cropTransparent: cropTransparent),
           let processed = MetallicPaintImage.processed(imageName: imageName, cropTransparent: cropTransparent) {
            uploadTexture(processed)
            return
        }
        // Not ready yet: start transparent and fade in on upload (it used to pop in).
        if texture == nil { view?.alpha = 0 }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let processed = MetallicPaintImage.processed(imageName: imageName, cropTransparent: cropTransparent) else { return }
            Task { @MainActor [weak self] in
                // A newer image may have been asked for while this one was computing.
                guard let self, self.currentImageKey == key else { return }
                self.uploadTexture(processed)
            }
        }
    }

    func loadSymbol(_ systemName: String) {
        if texture == nil { view?.alpha = 0 }
        let key = "symbol-fill::\(systemName)"
        currentImageKey = key
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let processed = MetallicPaintImage.processedSymbol(systemName) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.currentImageKey == key else { return }
                self.uploadTexture(processed)
            }
        }
    }

    private func uploadTexture(_ processed: MetallicPaintImage.Processed) {
        guard let device else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: processed.width,
            height: processed.height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return }
        processed.pixels.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, processed.width, processed.height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: processed.width * 4
            )
        }
        self.texture = texture
        uniforms.u_imgRatio = Float(processed.width) / Float(processed.height)
        if let view, view.alpha < 1 {
            UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                view.alpha = 1
            }
        }
    }

    func update(
        seed: Float, scale: Float, refraction: Float, blur: Float, liquid: Float,
        speed: Float, brightness: Float, contrast: Float, angle: Float,
        fresnel: Float, patternSharpness: Float, waveAmplitude: Float,
        noiseScale: Float, chromaticSpread: Float, distortion: Float,
        contour: Float,
        lightColor: SIMD3<Float>, darkColor: SIMD3<Float>, tintColor: SIMD3<Float>
    ) {
        self.speed = speed
        uniforms.u_seed = seed
        uniforms.u_scale = scale
        uniforms.u_refract = refraction
        uniforms.u_blur = blur
        uniforms.u_liquid = liquid
        uniforms.u_bright = brightness
        uniforms.u_contrast = contrast
        uniforms.u_angle = angle
        uniforms.u_fresnel = fresnel
        uniforms.u_sharp = patternSharpness
        uniforms.u_wave = waveAmplitude
        uniforms.u_noise = noiseScale
        uniforms.u_chroma = chromaticSpread
        uniforms.u_distort = distortion
        uniforms.u_contour = contour
        uniforms.u_lightColor = lightColor
        uniforms.u_darkColor = darkColor
        uniforms.u_tint = tintColor
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        uniforms.u_ratio = size.height > 0 ? Float(size.width / size.height) : 1
    }

    func draw(in view: MTKView) {
        guard let pipeline, let sampler, let texture,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let queue = commandQueue,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            view.currentDrawable?.present()
            return
        }

        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        descriptor.colorAttachments[0].loadAction = .clear

        let now = CACurrentMediaTime()
        if lastFrameTime > 0 {
            animationTime += Float((now - lastFrameTime) * 1000) * speed
        }
        lastFrameTime = now
        uniforms.u_time = animationTime

        encoder.setRenderPipelineState(pipeline)
        var u = uniforms
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.size, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

/// SF Symbol rendered through the liquid-metal shader. Used for the four
/// mode glyphs (text / audio / image / Ogent) so they flow instead of sitting
/// as flat template icons.
private struct MetallicPaintSymbol: UIViewRepresentable {
    var systemName: String
    var tint: UIColor
    var liquid: Float
    var chromaticSpread: Float
    var speed: Float

    func makeCoordinator() -> MetallicPaintRenderer { MetallicPaintRenderer() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MetallicPaintGPU.shared.device
        view.colorPixelFormat = MetallicPaintGPU.colorPixelFormat
        view.framebufferOnly = true
        view.isOpaque = false
        view.backgroundColor = .clear
        view.layer.isOpaque = false
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        context.coordinator.attach(to: view)
        apply(to: context.coordinator)
        context.coordinator.loadSymbol(systemName)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        apply(to: context.coordinator)
        if context.coordinator.currentImageKey != "symbol-fill::\(systemName)" {
            context.coordinator.loadSymbol(systemName)
        }
    }

    private func apply(to renderer: MetallicPaintRenderer) {
        renderer.update(
            seed: 18, scale: 2.4, refraction: 0.03, blur: 0.012, liquid: liquid,
            speed: speed,             brightness: 1.55, contrast: 1.08, angle: 0.4,
            fresnel: 1.15, patternSharpness: 1.2, waveAmplitude: 1.05,
            noiseScale: 0.55, chromaticSpread: chromaticSpread, distortion: 1.15,
            contour: 0.22,
            lightColor: UIColor.white.rgb,
            darkColor: UIColor(white: 0.08, alpha: 1).rgb,
            tintColor: tint.rgb
        )
    }
}

private extension UIColor {
    var rgb: SIMD3<Float> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD3(Float(r), Float(g), Float(b))
    }
}
