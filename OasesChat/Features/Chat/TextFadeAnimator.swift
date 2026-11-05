//  TextFadeAnimator.swift
//
//  Streaming reveal for text appended to a live NSTextStorage: each new word (and the gap after
//  it) fades in, and on its way in passes through a short colour trail — it appears in a soft
//  violet, holds it briefly, cools to grey and settles on its own colour. While a reply streams,
//  the last couple of seconds of words therefore form a gradient tail behind the reveal edge.
//
//  Timing comes from `RevealScheduler`, which releases words evenly at the measured arrival
//  pace instead of flashing each refresh's batch at once.
//
//  Display-layer only: we change `.foregroundColor` on the storage (TextKit 1 redraws without
//  relayout) and never touch the Markdown parser or renderer. Work per frame is proportional to
//  the words still animating, never to the length of the text, and attribute writes only happen
//  when a word's quantised colour/opacity step changes.
//
//  Trail colours and timings follow rit3zh/expo-animated-streaming-text (MIT).

import UIKit

@MainActor
final class TextFadeAnimator {

    // MARK: - Tunables

    /// Opacity 0 → 1.
    private static let fadeDuration: CFTimeInterval = 1.1
    /// Violet → grey → own colour.
    private static let trailDuration: CFTimeInterval = 2.0
    /// Share of the trail spent holding the first colour.
    private static let trailHold: Double = 0.45
    /// Opacity only, when Reduce Motion is on.
    private static let reducedFadeDuration: CFTimeInterval = 0.2
    /// Above this many units in one batch, neighbours are merged so the batch still animates
    /// (it used to be skipped and appear at once).
    private static let maxUnitsPerBatch = 160
    private static let colorSteps = 32
    private static let alphaSteps = 16

    /// The trail's first and second colours.
    static let trailLead = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0xBA / 255, green: 0xA7 / 255, blue: 0xFF / 255, alpha: 1)
        : UIColor(red: 0x8E / 255, green: 0x7F / 255, blue: 0xD6 / 255, alpha: 1) }
    static let trailMid = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0xB4 / 255, green: 0xB4 / 255, blue: 0xB4 / 255, alpha: 1)
        : UIColor(red: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255, alpha: 1) }

    // MARK: - State

    private struct RGBA { var r, g, b, a: CGFloat }

    private struct Unit {
        let range: NSRange
        let start: CFTimeInterval
        /// The word's own colour (restored exactly at the end).
        let original: UIColor
        let base: RGBA
        let reduced: Bool
        var lastStep = -1
    }

    private weak var storage: NSTextStorage?
    private let requestRedraw: () -> Void
    private let traits: () -> UITraitCollection?
    private var units: [Unit] = []
    /// Only touched on the main thread; `nonisolated(unsafe)` lets deinit invalidate it.
    private nonisolated(unsafe) var displayLink: CADisplayLink?
    private var scheduler = RevealScheduler()
    private var lead = RGBA(r: 0, g: 0, b: 0, a: 1)
    private var mid = RGBA(r: 0, g: 0, b: 0, a: 1)

    // MARK: - Init

    /// - Parameters:
    ///   - traits: the text view's trait collection, to resolve dynamic colours.
    ///   - requestRedraw: repaints the text view after a frame's attribute writes.
    init(traits: @escaping () -> UITraitCollection? = { nil }, requestRedraw: @escaping () -> Void) {
        self.traits = traits
        self.requestRedraw = requestRedraw
    }

    deinit {
        displayLink?.invalidate()
    }

    // MARK: - Scheduling

    /// Reveal the text inside `range` of `targetStorage` (call after appending it).
    func scheduleAnimation(for range: NSRange, in targetStorage: NSTextStorage) {
        guard range.length > 0 else { return }
        let storageLen = targetStorage.length
        guard range.location >= 0, range.location < storageLen else { return }
        let safeRange = NSRange(location: range.location, length: min(range.length, storageLen - range.location))
        guard safeRange.length > 0 else { return }
        if storage !== targetStorage {
            // A different text view's storage: nothing in flight belongs to it.
            units.removeAll(keepingCapacity: true)
            scheduler.reset()
        } else {
            // A full re-render may have reset the colours of words still in flight; repaint
            // them on the next frame.
            for i in units.indices { units[i].lastStep = -1 }
        }
        storage = targetStorage

        let nsString = targetStorage.string as NSString
        var ranges = Self.revealUnits(in: nsString, within: safeRange)
        guard !ranges.isEmpty else { return }
        if ranges.count > Self.maxUnitsPerBatch {
            ranges = Self.merge(ranges, into: Self.maxUnitsPerBatch)
        }

        let reduced = UIAccessibility.isReduceMotionEnabled
        let resolved = traits() ?? UITraitCollection.current
        lead = Self.rgba(Self.trailLead.resolvedColor(with: resolved))
        mid = Self.rgba(Self.trailMid.resolvedColor(with: resolved))

        let now = CACurrentMediaTime()
        let plan = reduced ? (start: now, interval: 0.0) : scheduler.schedule(count: ranges.count, now: now)

        targetStorage.beginEditing()
        for (i, r) in ranges.enumerated() {
            let original = currentForegroundColor(at: r.location, in: targetStorage)
            let base = Self.rgba(original.resolvedColor(with: resolved))
            units.append(Unit(range: r, start: plan.start + CFTimeInterval(i) * plan.interval,
                              original: original, base: base, reduced: reduced))
            // Hidden until its turn (in the trail's first colour).
            targetStorage.addAttribute(.foregroundColor, value: Self.color(reduced ? base : lead, alpha: 0), range: r)
        }
        targetStorage.endEditing()

        requestRedraw()
        startDisplayLinkIfNeeded()
    }

    /// Finish everything now: every word gets its own colour back. Called on a new message,
    /// a width or appearance change, or any update that is not an append.
    func cancelAll() {
        stopDisplayLink()
        scheduler.reset()
        if let storage, !units.isEmpty {
            let len = storage.length
            storage.beginEditing()
            for u in units where NSMaxRange(u.range) <= len {
                storage.addAttribute(.foregroundColor, value: u.original, range: u.range)
            }
            storage.endEditing()
            requestRedraw()
        }
        units.removeAll(keepingCapacity: true)
    }

    /// Whether any word is still on its way in.
    var isAnimating: Bool { !units.isEmpty }

    // MARK: - Frame loop

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil, !units.isEmpty else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        // The trail moves slowly; 60 Hz is plenty and 30 on Low Power.
        link.preferredFrameRateRange = lowPower
            ? CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
            : CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        guard let storage else {
            stopDisplayLink()
            units.removeAll(keepingCapacity: true)
            return
        }
        let now = CACurrentMediaTime()
        let len = storage.length
        var wrote = false
        var finished: [Int] = []
        storage.beginEditing()
        for i in units.indices {
            let u = units[i]
            guard NSMaxRange(u.range) <= len else {
                finished.append(i)
                continue
            }
            let elapsed = now - u.start
            if elapsed <= 0 { continue }
            let fade = u.reduced ? Self.reducedFadeDuration : Self.fadeDuration
            let total = u.reduced ? fade : max(fade, Self.trailDuration)
            if elapsed >= total {
                storage.addAttribute(.foregroundColor, value: u.original, range: u.range)
                finished.append(i)
                wrote = true
                continue
            }
            let alpha = Self.easeInOut(min(1, elapsed / fade))
            let p = u.reduced ? 1 : min(1, elapsed / Self.trailDuration)
            let colorStep = Int(p * Double(Self.colorSteps))
            let alphaStep = Int(alpha * Double(Self.alphaSteps))
            let step = colorStep * (Self.alphaSteps + 1) + alphaStep
            guard step != u.lastStep else { continue }
            units[i].lastStep = step
            let qp = Double(colorStep) / Double(Self.colorSteps)
            let qa = CGFloat(alphaStep) / CGFloat(Self.alphaSteps)
            let rgb = u.reduced ? u.base : trailColor(at: qp, base: u.base)
            storage.addAttribute(.foregroundColor, value: Self.color(rgb, alpha: qa), range: u.range)
            wrote = true
        }
        storage.endEditing()
        for i in finished.reversed() { units.remove(at: i) }
        if wrote { requestRedraw() }
        if units.isEmpty { stopDisplayLink() }
    }

    // MARK: - Colour

    private func trailColor(at p: Double, base: RGBA) -> RGBA {
        let hold = Self.trailHold
        let mid1 = hold + (1 - hold) / 2
        if p < hold { return lead }
        if p < mid1 { return Self.mix(lead, mid, Self.easeInOut((p - hold) / (mid1 - hold))) }
        return Self.mix(mid, base, Self.easeInOut((p - mid1) / (1 - mid1)))
    }

    private static func mix(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA {
        let k = CGFloat(t)
        return RGBA(r: a.r + (b.r - a.r) * k, g: a.g + (b.g - a.g) * k, b: a.b + (b.b - a.b) * k, a: a.a + (b.a - a.a) * k)
    }

    private static func color(_ c: RGBA, alpha: CGFloat) -> UIColor {
        UIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a * alpha)
    }

    private static func rgba(_ c: UIColor) -> RGBA {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if !c.getRed(&r, green: &g, blue: &b, alpha: &a) {
            var w: CGFloat = 0
            c.getWhite(&w, alpha: &a)
            r = w; g = w; b = w
        }
        return RGBA(r: r, g: g, b: b, a: a)
    }

    private static func easeInOut(_ t: Double) -> Double {
        // cubic-bezier(0.42, 0, 0.58, 1) is close to smoothstep.
        let x = max(0, min(1, t))
        return x * x * (3 - 2 * x)
    }

    // MARK: - Units

    /// Words plus the gaps between them, covering every character of `range`, so punctuation
    /// and spaces fade too. Uses the localized word breaker (dictionary-based for Chinese and
    /// Japanese), so a CJK sentence reveals in words rather than as one block.
    private static func revealUnits(in string: NSString, within range: NSRange) -> [NSRange] {
        var units: [NSRange] = []
        string.enumerateSubstrings(in: range, options: [.byWords, .localized, .substringNotRequired]) { _, word, _, _ in
            let gapStart = units.last.map { NSMaxRange($0) } ?? range.location
            if word.location > gapStart { units.append(NSRange(location: gapStart, length: word.location - gapStart)) }
            units.append(word)
        }
        let tailStart = units.last.map { NSMaxRange($0) } ?? range.location
        if NSMaxRange(range) > tailStart { units.append(NSRange(location: tailStart, length: NSMaxRange(range) - tailStart)) }
        return units
    }

    /// Joins neighbouring units so there are at most `limit`.
    private static func merge(_ ranges: [NSRange], into limit: Int) -> [NSRange] {
        let size = Int((Double(ranges.count) / Double(limit)).rounded(.up))
        var merged: [NSRange] = []
        merged.reserveCapacity(limit)
        var i = 0
        while i < ranges.count {
            let first = ranges[i]
            let last = ranges[min(ranges.count - 1, i + size - 1)]
            merged.append(NSRange(location: first.location, length: NSMaxRange(last) - first.location))
            i += size
        }
        return merged
    }

    /// The colour a glyph carries now (links and code keep their own), defaulting to label.
    private func currentForegroundColor(at location: Int, in storage: NSTextStorage) -> UIColor {
        guard location >= 0, location < storage.length else { return .label }
        return storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? UIColor ?? .label
    }
}
