import MetalKit
import SwiftUI

/// A small one-bit "mind" that gathers out of scattered pixels into a slowly turning 3D
/// object for the current kind of work (a magnifier while searching, a laptop while running
/// commands…), and morphs to the next one as the agent moves on. Driven by
/// `AgentLiveSignals` (streamed text speeds it up, finished tools spark it).
struct DitherMindView: UIViewRepresentable {
    /// The object to show; nil lets the mind pick one from the prompt and the reasoning.
    let shape: DitherMindShape?
    let signals: AgentLiveSignals?
    var isLive: Bool = true
    var ink: Color = OasesColor.foreground

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> DitherMindRenderer { DitherMindRenderer(signals: signals) }

    func makeUIView(context: Context) -> DitherMindMTKView {
        let view = DitherMindMTKView(frame: .zero, device: DitherMindGPU.shared.device)
        view.isUserInteractionEnabled = false
        view.renderer = context.coordinator
        let r = context.coordinator
        r.reduceMotion = reduceMotion
        r.isLive = isLive
        r.explicitShape = shape
        r.setShape(shape ?? r.guessedShape())
        r.attach(to: view)
        return view
    }

    func updateUIView(_ view: DitherMindMTKView, context: Context) {
        let r = context.coordinator
        r.reduceMotion = reduceMotion
        r.isLive = isLive
        r.ink = resolvedInk(for: view)
        r.lightInk = colorScheme == .dark
        r.explicitShape = shape
        if let shape { r.show(shape) }
    }

    static func dismantleUIView(_ view: DitherMindMTKView, coordinator: DitherMindRenderer) {
        coordinator.isInWindow = false
        view.delegate = nil
    }

    private func resolvedInk(for view: UIView) -> SIMD4<Float> {
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        let ui = UIColor(ink).resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4(Float(r), Float(g), Float(b), Float(a))
    }
}

final class DitherMindMTKView: MTKView {
    weak var renderer: DitherMindRenderer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        renderer?.isInWindow = window != nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        renderer?.layout(boundsSize: bounds.size, scale: traitCollection.displayScale)
    }
}
