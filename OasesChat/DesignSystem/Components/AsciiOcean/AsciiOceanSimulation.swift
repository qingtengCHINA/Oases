import Foundation
import simd

// The Ogent ASCII ocean: a few jellyfish (and, in turn, other sea and sky creatures, see
// AsciiOceanVisitors.swift) swim through a low-resolution light field, and the
// renderer turns every cell of that field into a tinted tile and a character whose density
// follows the light. Inspired by the Kurage dashboard's background; this is an independent
// native implementation (own simulation, field splatting, glyph ramp, palettes and shader).

/// Small, fast, reproducible random numbers (SplitMix64).
struct OceanRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// 0 ..< 1
    mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
    mutating func range(_ a: Float, _ b: Float) -> Float { a + (b - a) * unit() }
}

/// The ocean's colours and pace for one agent phase.
struct OceanPalette: Equatable {
    var a: SIMD3<Float>
    var b: SIMD3<Float>
    /// Pulse rate multiplier.
    var tempo: Float
    /// Body size multiplier.
    var size: Float

    static func rgb(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> { SIMD3(r, g, b) / 255 }

    /// Idle, answering: mint and sky.
    static let calm = OceanPalette(a: rgb(108, 232, 170), b: rgb(96, 196, 246), tempo: 1.0, size: 1.0)
    /// Waiting for the model or reasoning: violet and aqua, slower and larger.
    static let think = OceanPalette(a: rgb(160, 138, 255), b: rgb(112, 226, 214), tempo: 0.7, size: 1.12)
    /// Calling tools: amber and mint, quicker and smaller.
    static let tool = OceanPalette(a: rgb(255, 196, 108), b: rgb(108, 232, 170), tempo: 1.5, size: 0.88)

    static func forPhase(_ phase: AgentLiveSignals.Phase) -> OceanPalette {
        switch phase {
        case .awaiting, .thinking: return .think
        case .tool: return .tool
        case .idle, .text, .done, .failed: return .calm
        }
    }

    func lerp(to o: OceanPalette, _ t: Float) -> OceanPalette {
        OceanPalette(a: simd_mix(a, o.a, SIMD3(repeating: t)), b: simd_mix(b, o.b, SIMD3(repeating: t)),
                     tempo: tempo + (o.tempo - tempo) * t, size: size + (o.size - size) * t)
    }
}

/// The grid the characters sit on, in points.
struct OceanGrid: Equatable {
    var cellWidth: Float
    var cellHeight: Float
    var fontSize: Float
    var columns: Int
    var rows: Int

    init(width: Float, height: Float) {
        // Denser on phones, a little larger on wide iPad windows.
        cellWidth = width < 600 ? 8 : (width < 1100 ? 9 : 10)
        cellHeight = (cellWidth * 1.5).rounded()
        fontSize = (cellHeight * 0.74).rounded()
        columns = max(1, Int((width / cellWidth).rounded(.up)))
        rows = max(1, Int((height / cellHeight).rounded(.up)))
    }
}

struct OceanSimulation {
    // MARK: Model

    struct Strand {
        var points: [SIMD2<Float>]
        var previous: [SIMD2<Float>]
        /// Where it hangs from along the bell's rim, -1 (left) ... 1 (right).
        let anchor: Float
        /// Segment length as a fraction of the bell radius.
        let segment: Float
        /// Width at the root and at the tip, as fractions of the radius.
        let rootWidth: Float
        let tipWidth: Float
        let swayPhase: Float
        let isArm: Bool
    }

    struct Jelly {
        var position: SIMD2<Float>
        var velocity: SIMD2<Float> = .zero
        /// Swimming direction; 0 is straight up, positive turns clockwise.
        var heading: Float
        var radius: Float
        var baseRadius: Float
        /// 0 (far) ... 1 (near): brighter, larger and faster when near.
        var depth: Float
        /// 0 ..< 1 through one pulse.
        var phase: Float
        var rate: Float
        /// Share of colour B.
        var mix: Float
        var seed: Float
        var contraction: Float = 0
        var strands: [Strand] = []
    }

    struct Flake {
        var x: Float
        var y: Float
        var speed: Float
        var sway: Float
        var swayPhase: Float
        /// 1 ... 6 (the snow glyphs).
        var glyph: UInt8
        var alpha: Float
        /// > 1 draws a short dashed run.
        var run: Int
    }

    struct Ripple {
        var age: Float
        let delay: Float
        let maxRadius: Float
    }

    private(set) var width: Float = 0
    private(set) var height: Float = 0
    private(set) var grid = OceanGrid(width: 1, height: 1)
    private(set) var jellies: [Jelly] = []
    private(set) var flakes: [Flake] = []
    private(set) var ripples: [Ripple] = []
    /// Creatures crossing the screen (see AsciiOceanVisitors.swift).
    private(set) var visitors: [OceanVisitor] = []
    private var visitorQueue: [OceanVisitor.Kind] = []
    private var lastVisitorKind: OceanVisitor.Kind?
    private var nextVisitorAt: Float = 2.5
    private var random: OceanRandom
    private(set) var time: Float = 0

    // Inputs and smoothed state.
    var palette = OceanPalette.calm
    private var paletteFrom = OceanPalette.calm
    private var paletteTo = OceanPalette.calm
    private var paletteT: Float = 1
    /// Where the composer is (points); typing steers the jellyfish toward it.
    var target = SIMD2<Float>(0, 0)
    private var typingUntil: Float = -1
    private var boostUntil: Float = -1
    private var dimUntil: Float = -1
    private(set) var flickerUntil: Float = -1
    private(set) var gain: Float = 1
    /// Extra brightness from text streaming in (decays quickly).
    private var feedGlow: Float = 0
    var isLive = false

    init(seed: UInt64 = 0x0A5E_5C0D) {
        random = OceanRandom(seed: seed)
    }

    // MARK: Layout

    /// Sets the area in points; keeps the swimmers where they were, proportionally.
    mutating func resize(width w: Float, height h: Float) {
        guard w > 0, h > 0 else { return }
        let first = jellies.isEmpty
        if !first, abs(w - width) < 0.5, abs(h - height) < 0.5 { return }
        let sx = width > 0 ? w / width : 1, sy = height > 0 ? h / height : 1
        width = w
        height = h
        grid = OceanGrid(width: w, height: h)
        target = SIMD2(w / 2, h - 60)
        let count = w < 600 ? 2 : (w < 1100 ? 3 : 4)
        if first {
            spawnInitial(count: count)
            // Start mid-swim rather than from a standstill.
            for _ in 0..<200 { step(1.0 / 60) }
        } else {
            for i in jellies.indices {
                jellies[i].position *= SIMD2(sx, sy)
                for s in jellies[i].strands.indices {
                    for p in jellies[i].strands[s].points.indices {
                        jellies[i].strands[s].points[p] *= SIMD2(sx, sy)
                        jellies[i].strands[s].previous[p] *= SIMD2(sx, sy)
                    }
                }
                jellies[i].baseRadius = baseRadius(depth: jellies[i].depth)
            }
            for i in visitors.indices {
                visitors[i].x *= sx
            }
            while jellies.count < count { jellies.append(makeJelly(slot: jellies.count, of: count, y: nil)) }
            if jellies.count > count { jellies.removeLast(jellies.count - count) }
            jellies.sort { $0.depth < $1.depth }
        }
        seedSnow()
    }

    private func baseRadius(depth: Float) -> Float {
        let base = min(max(min(width, height * 1.2) * 0.08, 44), 96)
        return base * (0.64 + 0.52 * depth)
    }

    private mutating func spawnInitial(count: Int) {
        jellies = (0..<count).map { makeJelly(slot: $0, of: count, y: nil) }
        // Both colours on screen from the first frame.
        for i in jellies.indices { jellies[i].mix = count > 1 ? Float(i) / Float(count - 1) : 0.5 }
        jellies.sort { $0.depth < $1.depth }
    }

    private mutating func makeJelly(slot: Int, of count: Int, y: Float?) -> Jelly {
        let depth = random.range(0.15, 1)
        let lane = (Float(slot) + 0.5) / Float(count)
        let r = baseRadius(depth: depth) * random.range(0.9, 1.1)
        var jelly = Jelly(
            position: SIMD2(width * (lane + random.range(-0.12, 0.12)), y ?? height * random.range(0.2, 0.95)),
            heading: random.range(-0.4, 0.4),
            radius: r,
            baseRadius: r,
            depth: depth,
            phase: random.unit(),
            rate: random.range(0.86, 1.14),
            mix: random.unit(),
            seed: random.range(0, 100)
        )
        jelly.strands = makeStrands(for: jelly)
        return jelly
    }

    private mutating func makeStrands(for jelly: Jelly) -> [Strand] {
        var strands: [Strand] = []
        let anchorPoint = rimPoint(of: jelly, anchor: 0)
        // Fine tentacles around the rim.
        for i in 0..<8 {
            let anchor = -0.92 + 1.84 * Float(i) / 7
            strands.append(Strand(points: Array(repeating: anchorPoint, count: 13),
                                  previous: Array(repeating: anchorPoint, count: 13),
                                  anchor: anchor, segment: 0.26, rootWidth: 0.07, tipWidth: 0.02,
                                  swayPhase: random.range(0, 6.28), isArm: false))
        }
        // Thicker oral arms under the centre.
        for i in 0..<3 {
            let anchor = -0.3 + 0.3 * Float(i)
            strands.append(Strand(points: Array(repeating: anchorPoint, count: 9),
                                  previous: Array(repeating: anchorPoint, count: 9),
                                  anchor: anchor, segment: 0.22, rootWidth: 0.16, tipWidth: 0.05,
                                  swayPhase: random.range(0, 6.28), isArm: true))
        }
        return strands
    }

    private mutating func seedSnow() {
        let count = max(8, grid.columns * grid.rows / 80)
        flakes = (0..<count).map { _ in
            Flake(x: random.range(0, width), y: random.range(0, height),
                  speed: random.range(3, 11), sway: random.range(2, 9), swayPhase: random.range(0, 6.28),
                  glyph: UInt8(1 + Int(random.unit() * 6) % 6), alpha: random.range(0.14, 0.44),
                  run: random.unit() < 0.16 ? 2 + Int(random.unit() * 3) : 1)
        }
    }

    // MARK: Events

    mutating func setPalette(_ p: OceanPalette) {
        guard p != paletteTo else { return }
        paletteFrom = palette
        paletteTo = p
        paletteT = 0
    }

    mutating func typing() { typingUntil = time + 1.8 }

    /// A send: every jellyfish strokes at once, rings spread from the composer and the
    /// characters shimmer for a moment.
    mutating func pulse(reduceMotion: Bool) {
        boostUntil = time + 1.8
        guard !reduceMotion else { return }
        flickerUntil = time + 1.2
        for i in jellies.indices {
            let dir = Self.direction(jellies[i].heading)
            jellies[i].velocity += dir * 46 * (0.6 + 0.4 * jellies[i].depth)
            jellies[i].phase = 0.02
        }
        let reach = max(width, height)
        ripples = [Ripple(age: 0, delay: 0, maxRadius: reach * 0.62),
                   Ripple(age: 0, delay: 0.26, maxRadius: reach * 0.5)]
    }

    /// An error or a stop: the light drops for half a second.
    mutating func dim() { dimUntil = time + 0.5 }

    mutating func feed(characters: Int) {
        guard characters > 0 else { return }
        feedGlow = min(0.12, feedGlow + Float(min(characters, 40)) * 0.003)
    }

    // MARK: Simulation

    static func direction(_ heading: Float) -> SIMD2<Float> { SIMD2(sin(heading), -cos(heading)) }

    /// Pulse curve: a quick contraction then a long relaxation.
    static func contraction(_ phase: Float) -> Float {
        if phase < 0.3 { return sin(phase / 0.3 * .pi / 2) }
        return 0.5 + 0.5 * cos((phase - 0.3) / 0.7 * .pi)
    }

    /// Advances by `dt` seconds in fixed 60 Hz steps (at most six per call).
    mutating func advance(_ dt: Float) {
        let steps = max(1, min(6, Int((dt * 60).rounded())))
        for _ in 0..<steps { step(1.0 / 60) }
    }

    private mutating func step(_ dt: Float) {
        time += dt
        if paletteT < 1 {
            paletteT = min(1, paletteT + dt / 0.9)
            let e = paletteT * paletteT * (3 - 2 * paletteT)
            palette = paletteFrom.lerp(to: paletteTo, e)
        }
        let typingNow = time < typingUntil
        var gainTarget: Float = 1
        if typingNow { gainTarget = 1.1 }
        if time < boostUntil { gainTarget = 1.25 }
        if isLive { gainTarget *= 1.06 }
        if time < dimUntil { gainTarget = 0.3 }
        gain += (gainTarget - gain) * (gainTarget < gain ? min(1, 9 * dt) : min(1, 2.4 * dt))
        feedGlow *= exp(-2.2 * dt)

        let tempo = palette.tempo * (typingNow ? 1.28 : 1)
        for i in jellies.indices {
            var jelly = jellies[i]
            stepJelly(&jelly, dt: dt, tempo: tempo, typing: typingNow)
            jellies[i] = jelly
        }
        stepSnow(dt)
        stepVisitors(dt)
        if !ripples.isEmpty {
            for i in ripples.indices { ripples[i].age += dt }
            ripples.removeAll { $0.age - $0.delay > 1.7 }
        }
    }

    private mutating func stepJelly(_ j: inout Jelly, dt: Float, tempo: Float, typing: Bool) {
        j.phase += dt * tempo * j.rate / 2.6
        if j.phase >= 1 { j.phase -= 1 }
        let c = Self.contraction(j.phase)
        let dc = c - j.contraction
        j.contraction = c

        // Heading: a slow wander, or toward the composer while the user types.
        var desired = 0.45 * sin(0.11 * time + j.seed)
        var turn: Float = 0.32
        if typing {
            let to = target - j.position
            desired = max(-1.1, min(1.1, atan2(to.x, -to.y)))
            turn = 0.9
        }
        var delta = desired - j.heading
        delta = atan2(sin(delta), cos(delta))
        j.heading += max(-turn * dt, min(turn * dt, delta))

        let dir = Self.direction(j.heading)
        if dc > 0 {
            j.velocity += dir * dc * 70 * (0.5 + 0.5 * j.depth) * tempo.squareRoot()
        }
        j.velocity *= exp(-1.15 * dt)
        j.position += j.velocity * dt
        j.position.x += sin(0.07 * time + j.seed) * 1.6 * dt

        let targetRadius = j.baseRadius * palette.size
        j.radius += (targetRadius - j.radius) * min(1, 1.4 * dt)

        // Off the top: come back from below with a new colour. Wrap sideways.
        let r = j.radius
        if j.position.y < -4.4 * r {
            j.position.y = height + 1.2 * r
            j.position.x = random.range(0.1, 0.9) * width
            j.mix = random.unit()
            j.velocity = .zero
            resetStrands(&j)
        } else if j.position.y > height + 5 * r {
            j.position.y = -3 * r
            resetStrands(&j)
        }
        if j.position.x < -2 * r {
            j.position.x += width + 4 * r
            resetStrands(&j)
        } else if j.position.x > width + 2 * r {
            j.position.x -= width + 4 * r
            resetStrands(&j)
        }

        stepStrands(&j, dir: dir, contraction: c, tempo: tempo)
    }

    private func rimPoint(of j: Jelly, anchor: Float) -> SIMD2<Float> {
        let rx = j.radius * (1 - 0.17 * j.contraction)
        let ry = j.radius * 0.8 * (1 + 0.1 * j.contraction)
        let local = SIMD2<Float>(anchor * rx * 0.86, ry * 0.32)
        return j.position + Self.rotate(local, j.heading)
    }

    static func rotate(_ v: SIMD2<Float>, _ angle: Float) -> SIMD2<Float> {
        let c = cos(angle), s = sin(angle)
        return SIMD2(v.x * c - v.y * s, v.x * s + v.y * c)
    }

    private func resetStrands(_ j: inout Jelly) {
        for s in j.strands.indices {
            let p = rimPoint(of: j, anchor: j.strands[s].anchor)
            for k in j.strands[s].points.indices {
                j.strands[s].points[k] = p
                j.strands[s].previous[k] = p
            }
        }
    }

    private func stepStrands(_ j: inout Jelly, dir: SIMD2<Float>, contraction c: Float, tempo: Float) {
        let back = -dir
        let side = SIMD2<Float>(-dir.y, dir.x)
        for s in j.strands.indices {
            let segLen = j.strands[s].segment * j.radius
            let n = j.strands[s].points.count
            let anchor = j.strands[s].anchor
            j.strands[s].points[0] = rimPoint(of: j, anchor: anchor)
            j.strands[s].previous[0] = j.strands[s].points[0]
            for k in 1..<n {
                let p = j.strands[s].points[k]
                let v = (p - j.strands[s].previous[k]) * 0.88
                j.strands[s].previous[k] = p
                let along = Float(k) / Float(n - 1)
                var push = back * segLen * (0.042 + 0.025 * (1 - c))
                let wave = sin(time * 2.1 * tempo - Float(k) * 0.55 + j.strands[s].swayPhase)
                push += side * wave * segLen * 0.05 * (0.3 + along)
                // Fan out while the bell contracts.
                push += side * anchor * c * segLen * 0.035 * (1 - along)
                j.strands[s].points[k] = p + v + push
            }
            // Keep the segment lengths (from the root outward).
            for k in 1..<n {
                let a = j.strands[s].points[k - 1]
                var d = j.strands[s].points[k] - a
                let len = simd_length(d)
                if len > 0.0001 {
                    d *= segLen / len
                    j.strands[s].points[k] = a + d
                }
            }
        }
    }

    /// One or two visitors at a time, taken from a shuffled carousel of every kind, with a
    /// short pause between them.
    private mutating func stepVisitors(_ dt: Float) {
        guard width > 0, height > 0 else { return }
        let tempo: Float = isLive ? 1.15 : 1
        for i in visitors.indices { visitors[i].step(dt * tempo) }
        visitors.removeAll { $0.isGone(width: width) }
        let limit = width < 600 ? 1 : 2
        // A flock in the sky may share the screen with one creature in the sea.
        let seaCount = visitors.filter { $0.kind != .gulls }.count
        guard time >= nextVisitorAt else { return }
        if visitorQueue.isEmpty {
            var kinds = OceanVisitor.Kind.allCases
            for i in stride(from: kinds.count - 1, to: 0, by: -1) {
                let j = Int(random.unit() * Float(i + 1)) % (i + 1)
                kinds.swapAt(i, j)
            }
            if kinds.first == lastVisitorKind, kinds.count > 1 { kinds.swapAt(0, kinds.count - 1) }
            visitorQueue = kinds
        }
        guard let kind = visitorQueue.first else { return }
        let fits = kind == .gulls
            ? !visitors.contains { $0.kind == .gulls }
            : seaCount < limit
        guard fits else { return }
        visitorQueue.removeFirst()
        lastVisitorKind = kind
        visitors.append(Self.makeVisitor(kind, width: width, height: height, random: &random))
        nextVisitorAt = time + random.range(5, 9)
    }

    private mutating func stepSnow(_ dt: Float) {
        for i in flakes.indices {
            flakes[i].y += flakes[i].speed * dt
            flakes[i].x += sin(time * 0.6 + flakes[i].swayPhase) * flakes[i].sway * dt
            if flakes[i].y > height + 10 {
                flakes[i].y = -10
                flakes[i].x = random.range(0, width)
            }
        }
    }
}

// MARK: - Light field

/// The light field at two samples per cell in each direction, reduced to one RGBA byte quad per
/// cell: R = colour A, G = white core, B = colour B, A = a snow glyph (index in the top three
/// bits, opacity in the low five).
struct OceanField {
    private(set) var columns = 0
    private(set) var rows = 0
    private var fw = 0
    private var fh = 0
    private var a: [Float] = []
    private var w: [Float] = []
    private var b: [Float] = []
    private(set) var cells: [UInt8] = []

    mutating func render(_ sim: OceanSimulation) {
        let grid = sim.grid
        if grid.columns != columns || grid.rows != rows {
            columns = grid.columns
            rows = grid.rows
            fw = columns * 2
            fh = rows * 2
            a = Array(repeating: 0, count: fw * fh)
            w = a
            b = a
            cells = Array(repeating: 0, count: columns * rows * 4)
        } else {
            for i in a.indices { a[i] = 0; w[i] = 0; b[i] = 0 }
        }
        // Field pixel size in points.
        let px = SIMD2<Float>(grid.cellWidth / 2, grid.cellHeight / 2)
        for v in sim.visitors { splatVisitor(v, sim: sim, px: px) }
        for j in sim.jellies { splat(j, sim: sim, px: px) }
        for r in sim.ripples { splatRipple(r, sim: sim, px: px) }
        reduce()
        for f in sim.flakes { markSnow(f, grid: grid) }
    }

    /// `addCapsule` for the visitors.
    mutating func addSoftCapsule(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>, radius: Float,
                                 ka: Float, kw: Float, kb: Float, px: SIMD2<Float>) {
        addCapsule(p0, p1, radius: radius, ka: ka, kw: kw, kb: kb, px: px)
    }

    // A soft disc / capsule add, in points.
    private mutating func addCapsule(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>, radius: Float,
                                     ka: Float, kw: Float, kb: Float, px: SIMD2<Float>) {
        let r = max(radius, px.x * 0.45)
        let lo = simd_min(p0, p1) - r - px
        let hi = simd_max(p0, p1) + r + px
        let x0 = max(0, Int(lo.x / px.x)), x1 = min(fw - 1, Int(hi.x / px.x))
        let y0 = max(0, Int(lo.y / px.y)), y1 = min(fh - 1, Int(hi.y / px.y))
        guard x0 <= x1, y0 <= y1 else { return }
        let seg = p1 - p0
        let segLen2 = max(simd_length_squared(seg), 1e-6)
        let soft = px.x * 0.9
        for y in y0...y1 {
            let cy = (Float(y) + 0.5) * px.y
            for x in x0...x1 {
                let q = SIMD2<Float>((Float(x) + 0.5) * px.x, cy)
                let t = max(0, min(1, simd_dot(q - p0, seg) / segLen2))
                let d = simd_length(q - (p0 + seg * t))
                let cover = max(0, min(1, (r + soft * 0.5 - d) / soft))
                if cover <= 0 { continue }
                let i = y * fw + x
                a[i] += ka * cover
                w[i] += kw * cover
                b[i] += kb * cover
            }
        }
    }

    private mutating func splat(_ j: OceanSimulation.Jelly, sim: OceanSimulation, px: SIMD2<Float>) {
        let c = j.contraction
        let boost: Float = sim.time < sim.flickerUntil ? 0.4 : 0
        let k = sim.gain * (0.54 + 0.56 * j.depth) * (1 + boost * 0.9 * c)
        let ka = (1 - j.mix) * k
        let kb = j.mix * k

        // Tentacles first (dimmer, behind the bell).
        for strand in j.strands {
            let n = strand.points.count
            for s in 1..<n {
                let along = Float(s) / Float(n - 1)
                let width = j.radius * (strand.rootWidth + (strand.tipWidth - strand.rootWidth) * along)
                let fade = (strand.isArm ? 0.55 : 0.42) * (1 - 0.65 * along)
                addCapsule(strand.points[s - 1], strand.points[s], radius: width * 0.5,
                           ka: ka * fade, kw: strand.isArm ? 0.06 * fade : 0, kb: kb * fade, px: px)
            }
        }

        // The bell: a dome, brighter toward the crown and along the rim.
        let rx = j.radius * (1 - 0.17 * c)
        let ry = j.radius * 0.8 * (1 + 0.1 * c)
        let reach = max(rx, ry) + px.x * 2
        let x0 = max(0, Int((j.position.x - reach) / px.x)), x1 = min(fw - 1, Int((j.position.x + reach) / px.x))
        let y0 = max(0, Int((j.position.y - reach) / px.y)), y1 = min(fh - 1, Int((j.position.y + reach) / px.y))
        if x0 <= x1, y0 <= y1 {
            let cosH = cos(-j.heading), sinH = sin(-j.heading)
            for y in y0...y1 {
                let wy = (Float(y) + 0.5) * px.y - j.position.y
                for x in x0...x1 {
                    let wx = (Float(x) + 0.5) * px.x - j.position.x
                    // Into the bell's own frame (y down = toward the rim).
                    let lx = wx * cosH - wy * sinH
                    let ly = wx * sinH + wy * cosH
                    let nx = lx / rx, ny = ly / ry
                    let d = (nx * nx + ny * ny).squareRoot()
                    // A scalloped hem cuts the bottom of the ellipse.
                    let hem = 0.3 + 0.05 * cos(nx * 9)
                    if ny > hem { continue }
                    let edge = max(0, min(1, (1 - d) * rx / (px.x * 1.2)))
                    if edge <= 0 { continue }
                    let crown = 0.35 + 0.45 * max(0, -ny)
                    let rim = exp(-pow((1 - d) * 5, 2)) * 0.55
                    let hemGlow = exp(-pow((hem - ny) * 9, 2)) * 0.35
                    let light = edge * (crown + rim + hemGlow)
                    // Four pale gonads around the centre.
                    var core: Float = 0
                    let gx = abs(nx) - 0.26, gy = ny + 0.08
                    let g = (gx * gx) / 0.018 + (gy * gy) / 0.03
                    if g < 1 { core = (1 - g) * 0.75 }
                    let i = y * fw + x
                    a[i] += ka * light
                    b[i] += kb * light
                    w[i] += core * edge * k * 0.9 + rim * 0.12 * k
                }
            }
        }
        // Dots along the hem.
        for i in 0..<9 {
            let t = -0.85 + 1.7 * Float(i) / 8
            let local = SIMD2<Float>(t * rx * 0.92, ry * (0.3 + 0.05 * cos(t * 9)))
            let p = j.position + OceanSimulation.rotate(local, j.heading)
            addCapsule(p, p, radius: j.radius * 0.035, ka: ka * 0.4, kw: 0.25 * k, kb: kb * 0.4, px: px)
        }
    }

    private mutating func splatRipple(_ r: OceanSimulation.Ripple, sim: OceanSimulation, px: SIMD2<Float>) {
        let t = (r.age - r.delay) / 1.7
        guard t > 0, t < 1 else { return }
        let e = 1 - pow(1 - t, 3)
        let radius = r.maxRadius * e
        let band = 10 + 26 * t
        let strength = (1 - t) * 0.5
        let centre = sim.target
        for y in 0..<fh {
            let dy = ((Float(y) + 0.5) * px.y - centre.y) / 0.62
            for x in 0..<fw {
                let dx = (Float(x) + 0.5) * px.x - centre.x
                let d = abs((dx * dx + dy * dy).squareRoot() - radius)
                if d > band { continue }
                let v = (1 - d / band) * strength
                let i = y * fw + x
                a[i] += v * 0.5
                b[i] += v * 0.5
                w[i] += v * 0.35
            }
        }
    }

    private mutating func reduce() {
        for cy in 0..<rows {
            let r0 = cy * 2 * fw, r1 = r0 + fw
            for cx in 0..<columns {
                let x = cx * 2
                let sa = (a[r0 + x] + a[r0 + x + 1] + a[r1 + x] + a[r1 + x + 1]) * 0.25
                let sw = (w[r0 + x] + w[r0 + x + 1] + w[r1 + x] + w[r1 + x + 1]) * 0.25
                let sb = (b[r0 + x] + b[r0 + x + 1] + b[r1 + x] + b[r1 + x + 1]) * 0.25
                let o = (cy * columns + cx) * 4
                cells[o] = UInt8(min(255, sa * 255))
                cells[o + 1] = UInt8(min(255, sw * 255))
                cells[o + 2] = UInt8(min(255, sb * 255))
                cells[o + 3] = 0
            }
        }
    }

    private mutating func markSnow(_ f: OceanSimulation.Flake, grid: OceanGrid) {
        let cy = Int(f.y / grid.cellHeight)
        guard cy >= 0, cy < rows else { return }
        let alpha = UInt8(max(1, min(31, Int(f.alpha * 31))))
        for k in 0..<f.run {
            let cx = Int(f.x / grid.cellWidth) + k * 2
            guard cx >= 0, cx < columns else { continue }
            let o = (cy * columns + cx) * 4
            // Never over a lit cell: the jellyfish win.
            if cells[o] > 14 || cells[o + 2] > 14 { continue }
            let glyph = f.run > 1 ? UInt8(2) : f.glyph
            cells[o + 3] = (glyph << 5) | alpha
        }
    }
}
