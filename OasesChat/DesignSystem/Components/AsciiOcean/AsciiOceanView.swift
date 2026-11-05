import MetalKit
import SwiftUI

/// Settings key for the Ogent background (on by default).
enum OgentOceanPreference {
    static let key = "ogent.asciiOceanBackground"
}

/// The ASCII ocean as a SwiftUI view. It never takes touches and is hidden from VoiceOver.
struct AsciiOceanView: UIViewRepresentable {
    let signals: AgentLiveSignals?
    var configuration: AsciiOceanConfiguration

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeCoordinator() -> AsciiOceanRenderer { AsciiOceanRenderer(signals: signals) }

    func makeUIView(context: Context) -> AsciiOceanMTKView {
        let view = AsciiOceanMTKView(frame: .zero, device: AsciiOceanGPU.shared.device)
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.renderer = context.coordinator
        context.coordinator.reduceMotion = reduceMotion
        context.coordinator.configuration = configuration
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: AsciiOceanMTKView, context: Context) {
        let renderer = context.coordinator
        if renderer.reduceMotion != reduceMotion {
            renderer.reduceMotion = reduceMotion
            renderer.applyPolicy()
        }
        if renderer.configuration != configuration {
            renderer.configuration = configuration
        }
    }

    static func dismantleUIView(_ view: AsciiOceanMTKView, coordinator: AsciiOceanRenderer) {
        coordinator.isInWindow = false
        view.delegate = nil
    }
}

final class AsciiOceanMTKView: MTKView {
    weak var renderer: AsciiOceanRenderer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        renderer?.isInWindow = window != nil
    }
}

/// The Ogent page background: the page colour with the ASCII ocean over it.
///
/// Full strength on an empty session (it is the welcome scene); faint behind a conversation so
/// text keeps its contrast, a little brighter while the agent works.
struct OgentOceanBackdrop: View, Equatable {
    let signals: AgentLiveSignals
    let hasMessages: Bool
    let isProcessing: Bool
    /// Height of the composer from the bottom edge, in points.
    let composerHeight: CGFloat

    @AppStorage(OgentOceanPreference.key) private var enabled = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    static func == (l: Self, r: Self) -> Bool {
        l.signals === r.signals && l.hasMessages == r.hasMessages && l.isProcessing == r.isProcessing
            && abs(l.composerHeight - r.composerHeight) < 1
    }

    var body: some View {
        if enabled, !(hasMessages && (reduceTransparency || contrast == .increased)) {
            AsciiOceanView(signals: signals, configuration: configuration)
                .ignoresSafeArea(.container, edges: .bottom)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
        }
    }

    private var configuration: AsciiOceanConfiguration {
        let light = colorScheme == .light
        var c = AsciiOceanConfiguration()
        c.isLight = light
        c.composerLift = Float(max(40, composerHeight * 0.5 + 8))
        c.fadeTop = 56
        c.fadeBottom = 0
        if !hasMessages {
            let lowered: Float = (reduceTransparency || contrast == .increased) ? 0.5 : 1
            c.layerAlpha = (light ? 0.85 : 1) * lowered
            c.glyphCap = 1
            c.tileScale = 1
            c.allowsHotCells = true
            c.framesPerSecond = 30
        } else {
            c.layerAlpha = isProcessing ? (light ? 0.18 : 0.26) : (light ? 0.12 : 0.18)
            c.glyphCap = 0.55
            c.tileScale = 0.5
            c.allowsHotCells = false
            c.framesPerSecond = isProcessing ? 30 : 20
        }
        c.isStill = reduceTransparency || contrast == .increased
        return c
    }
}
