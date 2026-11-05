import Foundation
import simd

// Visitors to the Ogent ASCII ocean: creatures that cross the screen one or two at a time,
// in a shuffled carousel (a school of fish, a shark, a whale, a porpoising dolphin, a manta
// ray, a sea turtle, a flock of gulls up in the sky). Each is drawn into the same light field
// as the jellyfish, out of soft strokes along a swimming spine.

struct OceanVisitor {
    enum Kind: Int, CaseIterable {
        case school, shark, whale, dolphin, manta, turtle, gulls
    }

    let kind: Kind
    /// The leader's head, in points.
    var x: Float
    var y: Float
    let baseY: Float
    /// +1 swims right, -1 left.
    let direction: Float
    /// Points per second.
    let speed: Float
    /// Body length (wingspan for the ray and the gulls), in points.
    let length: Float
    /// Animation clock.
    var phase: Float = 0
    /// Nose up (+) or down (-), radians.
    var pitch: Float = 0
    /// 0 (far, dim) ... 1 (near).
    let depth: Float
    /// Share of colour B.
    let mix: Float
    /// Followers for the school and the flock: offset (in lengths) and a phase offset.
    let members: [SIMD3<Float>]

    /// How far the group reaches behind or ahead of the leader, in points.
    var spread: Float {
        var reach: Float = 0
        for m in members { reach = max(reach, abs(m.x)) }
        return reach * length + length * 1.4
    }

    func isGone(width: Float) -> Bool {
        direction > 0 ? x - spread > width + 20 : x + spread < -20
    }

    mutating func step(_ dt: Float) {
        phase += dt
        x += direction * speed * dt
        switch kind {
        case .dolphin:
            // Porpoising: a long, slow wave with the body following its slope.
            let w: Float = 1.25
            let a = length * 0.22
            y = baseY + a * sin(phase * w)
            pitch = atan2(-a * w * cos(phase * w), speed)
        case .manta:
            y = baseY + length * 0.05 * sin(phase * 0.6)
        case .whale:
            y = baseY + length * 0.015 * sin(phase * 0.3)
            pitch = 0.04 * sin(phase * 0.3 + 1)
        case .gulls:
            y = baseY + length * 0.25 * sin(phase * 0.8)
        case .school, .shark, .turtle:
            y = baseY + length * 0.04 * sin(phase * 0.9)
        }
    }
}

extension OceanSimulation {
    /// A visitor of `kind`, placed just off one side of the screen.
    static func makeVisitor(_ kind: OceanVisitor.Kind, width: Float, height: Float,
                            random: inout OceanRandom) -> OceanVisitor {
        let direction: Float = random.unit() < 0.5 ? 1 : -1
        let scale = max(0.8, min(1.6, width / 400))
        var length: Float
        var speed: Float
        var y: Float
        var depth = random.range(0.3, 0.62)
        var members: [SIMD3<Float>] = []
        switch kind {
        case .school:
            length = min(max(width * 0.15, 50), 72)
            speed = 58 * scale
            y = height * random.range(0.3, 0.7)
            for _ in 0..<7 {
                members.append(SIMD3(random.range(-3.2, -0.7), random.range(-1.0, 1.0), random.range(0, 6.28)))
            }
        case .shark:
            length = min(max(width * 0.66, 220), 420)
            speed = 46 * scale
            y = height * random.range(0.3, 0.62)
        case .whale:
            length = min(max(width * 1.05, 380), 720)
            speed = 24 * scale
            y = height * random.range(0.45, 0.66)
            depth = random.range(0.2, 0.36)
        case .dolphin:
            length = min(max(width * 0.5, 170), 320)
            speed = 74 * scale
            y = height * random.range(0.3, 0.6)
            if random.unit() < 0.6 { members = [SIMD3(-1.3, 0.55, 1.4)] }
        case .manta:
            length = min(max(width * 0.62, 220), 400)
            speed = 30 * scale
            y = height * random.range(0.3, 0.6)
        case .turtle:
            length = min(max(width * 0.42, 150), 260)
            speed = 26 * scale
            y = height * random.range(0.3, 0.65)
        case .gulls:
            length = min(max(width * 0.2, 72), 104)
            speed = 62 * scale
            y = height * random.range(0.07, 0.16)
            members = [SIMD3(-1.3, 0.55, 0.7), SIMD3(-1.3, -0.55, 1.6),
                       SIMD3(-2.6, 1.1, 2.4), SIMD3(-2.6, -1.1, 0.3)]
            depth = random.range(0.55, 0.8)
        }
        var v = OceanVisitor(kind: kind, x: 0, y: y, baseY: y, direction: direction,
                             speed: speed, length: length, depth: depth, mix: random.unit(),
                             members: members)
        let offset = v.spread * 0.6 + length * 0.2
        v.x = direction > 0 ? -offset : width + offset
        v.phase = random.range(0, 6.28)
        return v
    }
}

/// Draws one creature in its own frame: `along` runs from the head (0) toward the tail
/// (negative), `upward` toward its back, both in body lengths.
private struct VisitorPen {
    let head: SIMD2<Float>
    let forward: SIMD2<Float>
    let up: SIMD2<Float>
    let length: Float
    let phase: Float
    let ka: Float
    let kb: Float
    let k: Float
    let px: SIMD2<Float>

    func at(_ along: Float, _ upward: Float) -> SIMD2<Float> {
        head + forward * (along * length) + up * (upward * length)
    }

    func stroke(_ field: inout OceanField, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ radius: Float,
                glow: Float = 1, white: Float = 0) {
        field.addSoftCapsule(a, b, radius: radius * length, ka: ka * glow, kw: white * k, kb: kb * glow, px: px)
    }

    /// A filled triangle: strokes fanned from the edge a→b to the point c.
    func fan(_ field: inout OceanField, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>,
             _ radius: Float, glow: Float = 1, steps: Int = 5) {
        for i in 0...steps {
            let t = Float(i) / Float(steps)
            stroke(&field, a + (b - a) * t, c, radius, glow: glow)
        }
    }

    func wave(_ s: Float, amp: Float, freq: Float) -> Float {
        amp * s * s * sin(phase * freq - s * 5)
    }

    /// A body from the head (s = 0) to `end`, with a radius profile and a tail-heavy wave.
    func spine(_ field: inout OceanField, end: Float, segments: Int, amp: Float, freq: Float,
               glow: Float = 1, radius: (Float) -> Float) {
        var previous = at(0, 0)
        for i in 1...segments {
            let s0 = end * Float(i - 1) / Float(segments)
            let s = end * Float(i) / Float(segments)
            let p = at(-s, wave(s, amp: amp, freq: freq))
            stroke(&field, previous, p, (radius(s0) + radius(s)) * 0.5, glow: glow)
            previous = p
        }
    }

    static func bell(_ s: Float, start: Float = 0, end: Float, power: Float) -> Float {
        let t = max(0, min(1, (s - start) / (end - start)))
        return pow(sin(Float.pi * t), power)
    }
}

extension OceanField {
    /// Draws one visitor (and its school or flock) into the light field.
    mutating func splatVisitor(_ v: OceanVisitor, sim: OceanSimulation, px: SIMD2<Float>) {
        let k = sim.gain * (0.4 + 0.5 * v.depth)
        drawVisitor(v, head: SIMD2(v.x, v.y), phase: v.phase, k: k, px: px)
        for m in v.members {
            let head = SIMD2(v.x + v.direction * m.x * v.length, v.y + m.y * v.length)
            drawVisitor(v, head: head, phase: v.phase + m.z, k: k * 0.9, px: px)
        }
    }

    private mutating func drawVisitor(_ v: OceanVisitor, head: SIMD2<Float>, phase: Float, k: Float,
                                      px: SIMD2<Float>) {
        let forward = SIMD2<Float>(v.direction * cos(v.pitch), -sin(v.pitch))
        let up = v.direction > 0 ? SIMD2<Float>(forward.y, -forward.x) : SIMD2<Float>(-forward.y, forward.x)
        let pen = VisitorPen(head: head, forward: forward, up: up, length: v.length, phase: phase,
                             ka: (1 - v.mix) * k, kb: v.mix * k, k: k, px: px)
        switch v.kind {
        case .school: Self.drawFish(&self, pen)
        case .shark: Self.drawShark(&self, pen)
        case .whale: Self.drawWhale(&self, pen)
        case .dolphin: Self.drawDolphin(&self, pen)
        case .manta: Self.drawManta(&self, pen)
        case .turtle: Self.drawTurtle(&self, pen)
        case .gulls: Self.drawGull(&self, pen)
        }
    }

    private static func drawFish(_ f: inout OceanField, _ p: VisitorPen) {
        let amp: Float = 0.08, fr: Float = 9
        p.spine(&f, end: 0.78, segments: 8, amp: amp, freq: fr) { 0.27 * VisitorPen.bell($0, end: 0.8, power: 0.65) }
        let root = p.at(-0.74, p.wave(0.74, amp: amp, freq: fr))
        let flick = 0.08 * sin(p.phase * fr - 4.5)
        p.fan(&f, p.at(-1.06, 0.3 + flick), p.at(-1.06, -0.3 + flick), root, 0.06, glow: 0.85, steps: 5)
        p.fan(&f, p.at(-0.3, 0.17), p.at(-0.5, 0.15), p.at(-0.45, 0.3), 0.03, glow: 0.7, steps: 2)
        p.stroke(&f, p.at(-0.12, 0.04), p.at(-0.12, 0.04), 0.035, glow: 0.3, white: 0.7)
    }

    private static func drawShark(_ f: inout OceanField, _ p: VisitorPen) {
        let amp: Float = 0.035, fr: Float = 3.2
        p.spine(&f, end: 0.84, segments: 20, amp: amp, freq: fr) { s in
            // A pointed snout, a deep chest, a long slim tail stock.
            0.12 * VisitorPen.bell(s, start: -0.04, end: 0.9, power: 0.6) * (s < 0.12 ? 0.55 + 3.75 * s : 1)
        }
        let root = p.at(-0.84, p.wave(0.84, amp: amp, freq: fr))
        let sway = 0.05 * sin(p.phase * fr - 4.3)
        // A crescent tail: the upper lobe long, the lower one short.
        p.fan(&f, root, p.at(-0.9, 0.02 + sway), p.at(-1.08, 0.3 + sway), 0.022, steps: 4)
        p.fan(&f, root, p.at(-0.9, sway), p.at(-1.0, -0.17 + sway), 0.022, steps: 3)
        // Tall dorsal fin, swept back.
        p.fan(&f, p.at(-0.28, 0.09), p.at(-0.46, 0.08), p.at(-0.5, 0.33), 0.024, steps: 6)
        // Pectoral fin.
        p.fan(&f, p.at(-0.24, -0.08), p.at(-0.36, -0.08), p.at(-0.44, -0.27), 0.022, steps: 4)
        // Second dorsal and anal fins.
        p.fan(&f, p.at(-0.7, 0.04), p.at(-0.75, 0.035), p.at(-0.77, 0.1), 0.012, steps: 2)
        p.fan(&f, p.at(-0.68, -0.04), p.at(-0.73, -0.035), p.at(-0.75, -0.1), 0.012, steps: 2)
        // Gill slits and the eye.
        for g in 0..<4 {
            let s = -0.17 - Float(g) * 0.024
            p.stroke(&f, p.at(s, 0.035), p.at(s - 0.008, -0.045), 0.004, glow: 0.15, white: 0.4)
        }
        p.stroke(&f, p.at(-0.08, 0.035), p.at(-0.08, 0.035), 0.013, glow: 0.3, white: 0.9)
    }

    private static func drawWhale(_ f: inout OceanField, _ p: VisitorPen) {
        let amp: Float = 0.02, fr: Float = 1.2
        p.spine(&f, end: 0.88, segments: 26, amp: amp, freq: fr, glow: 0.9) { s in
            // A blunt head, a deep body, a slim tail stock.
            let body = 0.13 * VisitorPen.bell(s, start: -0.2, end: 0.94, power: 0.75)
            return s < 0.06 ? body * (0.75 + 4 * s) : body
        }
        let root = p.at(-0.88, p.wave(0.88, amp: amp, freq: fr))
        let lift = 0.04 * sin(p.phase * fr - 4.5)
        // Flukes, seen from the side as a wide fork.
        p.fan(&f, root, p.at(-0.92, lift), p.at(-1.06, 0.13 + lift), 0.018, steps: 4)
        p.fan(&f, root, p.at(-0.92, lift), p.at(-1.06, -0.1 + lift), 0.018, steps: 4)
        // Long pectoral flipper (a humpback's), slowly stroking.
        let fl = 0.035 * sin(p.phase * 0.9)
        p.fan(&f, p.at(-0.24, -0.08), p.at(-0.32, -0.09), p.at(-0.52, -0.3 + fl), 0.022, steps: 5)
        // Small dorsal fin.
        p.fan(&f, p.at(-0.6, 0.07), p.at(-0.66, 0.065), p.at(-0.68, 0.12), 0.012, steps: 2)
        // Throat grooves and the eye.
        for g in 0..<5 {
            let off = -0.045 - Float(g) * 0.02
            p.stroke(&f, p.at(-0.03, off), p.at(-0.38, off + 0.012), 0.004, glow: 0.2, white: 0.3)
        }
        p.stroke(&f, p.at(-0.16, -0.005), p.at(-0.16, -0.005), 0.011, glow: 0.3, white: 0.9)
    }

    private static func drawDolphin(_ f: inout OceanField, _ p: VisitorPen) {
        let amp: Float = 0.03, fr: Float = 4
        p.spine(&f, end: 0.88, segments: 18, amp: amp, freq: fr) { s in
            s < 0.09 ? 0.03 + 0.14 * s : 0.12 * VisitorPen.bell(s, start: 0.02, end: 0.9, power: 0.6)
        }
        let root = p.at(-0.88, p.wave(0.88, amp: amp, freq: fr))
        let beat = 0.06 * sin(p.phase * fr - 4.5)
        p.fan(&f, root, p.at(-0.92, beat), p.at(-1.04, 0.11 + beat), 0.016, steps: 3)
        p.fan(&f, root, p.at(-0.92, beat), p.at(-1.04, -0.11 + beat), 0.016, steps: 3)
        // Curved, hooked dorsal fin.
        p.fan(&f, p.at(-0.36, 0.1), p.at(-0.54, 0.08), p.at(-0.58, 0.28), 0.024, steps: 6)
        // Flipper and eye.
        p.fan(&f, p.at(-0.22, -0.08), p.at(-0.31, -0.09), p.at(-0.4, -0.22), 0.02, steps: 4)
        p.stroke(&f, p.at(-0.12, 0.015), p.at(-0.12, 0.015), 0.012, glow: 0.3, white: 0.9)
    }

    private static func drawManta(_ f: inout OceanField, _ p: VisitorPen) {
        // Seen from above: wide wings flapping, horns in front, a thin whip of a tail.
        let flap = 0.8 + 0.2 * sin(p.phase * 2.1)
        let curl = 0.07 * sin(p.phase * 2.1 + 0.8)
        for side in [Float(1), -1] {
            let tip = p.at(-0.2 - curl, side * 0.5 * flap)
            p.fan(&f, p.at(0, side * 0.06), p.at(-0.36, side * 0.06), tip, 0.04, glow: 0.85, steps: 7)
            p.stroke(&f, p.at(0.02, side * 0.05), p.at(0.11, side * 0.08), 0.024)
            p.stroke(&f, p.at(-0.1, side * 0.09), p.at(-0.1, side * 0.09), 0.014, glow: 0.2, white: 0.6)
        }
        p.stroke(&f, p.at(0, 0), p.at(-0.34, 0), 0.09)
        p.stroke(&f, p.at(-0.34, 0), p.at(-0.84, 0.03 * sin(p.phase * 1.5)), 0.012, glow: 0.7)
    }

    private static func drawTurtle(_ f: inout OceanField, _ p: VisitorPen) {
        // Seen from above: shell, head, four flippers rowing.
        p.stroke(&f, p.at(-0.25, 0), p.at(-0.5, 0), 0.22)
        let plates: [(Float, Float)] = [(-0.29, 0.09), (-0.29, -0.09), (-0.44, 0), (-0.18, 0), (-0.4, 0.13), (-0.4, -0.13)]
        for (along, side) in plates {
            p.stroke(&f, p.at(along, side), p.at(along, side), 0.045, glow: 0.2, white: 0.4)
        }
        p.stroke(&f, p.at(-0.01, 0), p.at(-0.1, 0), 0.075)
        p.stroke(&f, p.at(0, 0.03), p.at(0, 0.03), 0.014, glow: 0.2, white: 0.8)
        p.stroke(&f, p.at(0, -0.03), p.at(0, -0.03), 0.014, glow: 0.2, white: 0.8)
        let row = sin(p.phase * 1.7)
        for side in [Float(1), -1] {
            let tip = p.at(-0.34 + 0.13 * row, side * 0.5)
            p.fan(&f, p.at(-0.17, side * 0.17), p.at(-0.27, side * 0.18), tip, 0.03, steps: 4)
            p.fan(&f, p.at(-0.52, side * 0.13), p.at(-0.58, side * 0.1), p.at(-0.66 - 0.03 * row, side * 0.26), 0.024, steps: 3)
        }
        p.stroke(&f, p.at(-0.6, 0), p.at(-0.7, 0), 0.022)
    }

    private static func drawGull(_ f: inout OceanField, _ p: VisitorPen) {
        // An "M" in the sky, the wings beating.
        let beat = sin(p.phase * 6.5)
        let elbowY = 0.1 + 0.14 * beat
        let tipY = 0.32 * beat
        p.stroke(&f, p.at(0.03, 0), p.at(-0.15, 0), 0.07, glow: 1.3)
        for side in [Float(1), -1] {
            let shoulder = p.at(-0.05 + side * 0.04, 0.01)
            let elbow = p.at(-0.05 + side * 0.24, elbowY)
            let tip = p.at(-0.05 + side * 0.5, tipY - 0.06)
            p.stroke(&f, shoulder, elbow, 0.065, glow: 1.3)
            p.stroke(&f, elbow, tip, 0.045, glow: 1.3)
        }
    }
}
