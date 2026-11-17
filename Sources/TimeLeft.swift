import Foundation

/// Estimates the time left in an import from bytes, not file counts (a clip can be 1,000× a JPEG).
/// The byte total covers the whole job: the copy, reading the copy back, and re-reading the card.
///
/// Two layers of smoothing keep the number steady:
///   1. The speed is an exponential moving average (time constant `smoothing`), seeded with the
///      plain average over the first few seconds. The three steps run at different speeds for each
///      file (writing vs. reading back), so the speed jumps around from second to second.
///   2. The time shown counts down by itself, second by second, and only drifts toward each new
///      estimate (time constant `damping`), so one slow or fast patch doesn't make it jump.
struct TimeLeftEstimator {
    /// Show "Estimating…" until this much time has passed, so the first guess has real data behind it.
    var warmup: TimeInterval = 5
    var smoothing: TimeInterval = 90
    var damping: TimeInterval = 40

    private var start: (time: Date, bytes: Int64)?
    private var last: (time: Date, bytes: Int64)?
    private var rate: Double?          // bytes per second
    private var shown: TimeInterval?   // the estimate last returned

    /// Feed the progress (about once a second). Returns the seconds left, or nil while still estimating.
    mutating func sample(done: Int64, total: Int64, at now: Date = Date()) -> TimeInterval? {
        guard let start, let last else {
            self.start = (now, done); self.last = (now, done)
            return nil
        }
        let elapsed = now.timeIntervalSince(start.time)
        let dt = now.timeIntervalSince(last.time)
        guard dt > 0 else { return shown }
        defer { self.last = (now, done) }

        if elapsed < warmup { return nil }
        if let r = rate {
            let recent = Double(done - last.bytes) / dt
            rate = r + (1 - exp(-dt / smoothing)) * (recent - r)
        } else {
            rate = Double(done - start.bytes) / elapsed
        }
        guard let r = rate, r > 0 else { return shown }
        let estimate = Double(max(0, total - done)) / r
        if let s = shown {
            let countedDown = max(0, s - dt)
            shown = countedDown + (1 - exp(-dt / damping)) * (estimate - countedDown)
        } else {
            shown = estimate
        }
        return shown
    }

    /// "About 4 min left", in plain words and rounded so it doesn't flicker.
    static func text(_ seconds: TimeInterval) -> String {
        if seconds < 50 { return "Less than a minute left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "About \(max(1, minutes)) min left" }
        let rounded = Int((seconds / 300).rounded()) * 5          // nearest 5 min once it's over an hour
        let h = rounded / 60, m = rounded % 60
        return m == 0 ? "About \(h) h left" : "About \(h) h \(m) min left"
    }
}
