import Foundation

/// Decides when each newly streamed reveal unit (a word, or the gap after it) appears.
///
/// Tokens arrive in bursts, and the UI only refreshes every 0.04–2 s depending on the reply's
/// length. Revealing each burst all at once (or within a fixed 0.1 s window) makes long replies
/// stutter: a flash of words, then nothing until the next refresh. Instead the scheduler
/// measures how fast units are arriving and lets them out evenly at that pace with a little
/// headroom, queued behind the previous batch, never falling more than about one refresh
/// interval behind the data.
///
/// Inspired by the adaptive reveal schedule of rit3zh/expo-animated-streaming-text (MIT).
struct RevealScheduler: Sendable {
    struct Tunables: Sendable {
        /// Pace before anything has been measured (seconds per unit).
        var initialPace: CFTimeInterval = 0.03
        /// The fastest a backlog may be released, per unit.
        var minimumInterval: CFTimeInterval = 0.004
        /// Smallest interval while not catching up.
        var unit: CFTimeInterval = 0.016
        /// A pause longer than this does not count toward the measured pace.
        var stall: CFTimeInterval = 0.25
        /// Smoothing time constant of the pace estimate.
        var smoothing: CFTimeInterval = 0.4
        /// Release slightly faster than units arrive, so the queue drains.
        var slack: CFTimeInterval = 1.25
        /// Never more than this far behind the data (raised up to `maxLagCeiling` when the
        /// view itself only refreshes that rarely).
        var maxLagFloor: CFTimeInterval = 0.5
        var maxLagCeiling: CFTimeInterval = 2.0
    }

    var tunables = Tunables()
    private(set) var end: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var pace: CFTimeInterval = 0
    private var refreshGap: CFTimeInterval = 0

    init(tunables: Tunables = Tunables()) {
        self.tunables = tunables
    }

    /// Plans `count` new units arriving at `now`. Returns the start time of the first unit and
    /// the spacing between consecutive units.
    mutating func schedule(count: Int, now: CFTimeInterval) -> (start: CFTimeInterval, interval: CFTimeInterval) {
        guard count > 0 else { return (now, 0) }
        let t = tunables
        let n = CFTimeInterval(count)
        if last == 0 {
            pace = t.initialPace
        } else {
            let gap = max(0, now - last)
            if gap <= t.stall {
                let sample = gap / n
                pace += (sample - pace) * (1 - exp(-gap / t.smoothing))
            }
            // How often the view refreshes: the longest believable lag.
            refreshGap = refreshGap == 0 ? gap : refreshGap + (gap - refreshGap) * 0.3
        }
        last = now
        let maxLag = min(t.maxLagCeiling, max(t.maxLagFloor, refreshGap))
        let start = max(now, end)
        let backlog = start - now
        let interval = max(t.unit, pace * t.slack * max(0, 1 - backlog / maxLag))
        let finish = max(start + n * t.minimumInterval, min(start + n * interval, now + maxLag))
        end = finish
        return (start, (finish - start) / n)
    }

    mutating func reset() {
        end = 0
        last = 0
        pace = 0
        refreshGap = 0
    }
}
