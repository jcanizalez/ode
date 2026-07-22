import Foundation
import os

/// Detects speaker bleed the way real echo cancellers find their delay:
/// by correlating the microphone signal against the far-end REFERENCE — the
/// audio ODE itself is playing to the speakers. When what the mic hears IS
/// the reference (delayed by buffers and the room, filtered by both), the
/// mic is capturing the other side of the call, and feeding it to the "You"
/// transcription stream would attribute their words to the user.
///
/// This is detection, not cancellation: it compares 10 ms loudness
/// envelopes (robust against the room's spectral filtering) with a Pearson
/// correlation searched across −50…+600 ms of lag, and raises `echoActive`
/// with hysteresis. During double-talk the user's own voice dominates the
/// mic envelope, correlation collapses, and the gate stays open — their
/// speech is never muted, at the cost of letting overlap bleed through.
/// Full removal during overlap needs a reference-based AEC model (planned).
///
/// Thread-safe: the speaker path pushes the reference and the mic path
/// pushes capture from different serial queues; `echoActive` is read from
/// the capture thread.
public final class EchoGate {
    /// Envelope frame: 10 ms at 48 kHz.
    static let frameSamples = 480
    /// Reference history: 2 s of frames (covers buffer + room delays).
    static let refFrames = 200
    /// Mic window correlated per decision: 500 ms (~4 syllable events —
    /// short windows over smooth envelopes correlate by chance).
    static let micWindow = 50
    /// Lag search: −5…+60 frames (−50 ms scheduling skew … +600 ms delay).
    static let lagRange = -5...60

    static let closeThreshold: Float = 0.75  // correlation to declare echo
    static let openThreshold: Float = 0.5    // correlation to release
    /// True echo correlates AT ONE LAG and nowhere else; two unrelated
    /// smooth envelopes correlate moderately at many lags. The peak must
    /// stand this far above the across-lags average to count.
    static let prominence: Float = 0.25
    static let closeAfter = 8                // consecutive STABLE-LAG frames
    static let openAfter = 5                 // consecutive frames (50 ms)
    static let refFloorDB: Float = -60       // no reference energy → no echo

    private var lock = os_unfair_lock()

    // dB envelopes as ring buffers indexed by monotonically increasing
    // frame counters (mic and reference tick at the same 10 ms rate).
    private var refEnv = [Float](repeating: -80, count: refFrames)
    private var refCount = 0
    private var micEnv = [Float](repeating: -80, count: micWindow)
    private var micCount = 0

    // Partial-frame accumulators (chunks are variable-length).
    private var refAcc: Float = 0; private var refAccN = 0
    private var micAcc: Float = 0; private var micAccN = 0

    private var closeStreak = 0
    private var openStreak = 0
    private var lastBestLag: Int?
    private var _echoActive = false
    /// Last evaluation's (peak r, mean r across lags, peak lag) — tests only.
    var debugStats: (best: Float, meanR: Float, lag: Int) = (0, 0, 0)

    /// True while the microphone is judged to be hearing the speakers.
    public var echoActive: Bool {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return _echoActive
    }

    public init() {}

    /// Feed what the speaker path just played (48 kHz mono).
    public func pushReference(_ samples: [Float]) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        for v in samples {
            refAcc += v * v
            refAccN += 1
            if refAccN == Self.frameSamples {
                refEnv[refCount % Self.refFrames] = Self.dB(refAcc / Float(refAccN))
                refCount += 1
                refAcc = 0; refAccN = 0
            }
        }
    }

    /// Called (outside the lock) whenever `echoActive` flips, with the new
    /// state — for field diagnostics. Set before feeding.
    public var onTransition: ((Bool) -> Void)?

    /// Feed what the mic path captured (48 kHz mono). Completing a frame
    /// re-evaluates the gate.
    public func pushMic(_ samples: [Float]) {
        os_unfair_lock_lock(&lock)
        let before = _echoActive
        for v in samples {
            micAcc += v * v
            micAccN += 1
            if micAccN == Self.frameSamples {
                micEnv[micCount % Self.micWindow] = Self.dB(micAcc / Float(micAccN))
                micCount += 1
                micAcc = 0; micAccN = 0
                evaluateLocked()
            }
        }
        let after = _echoActive
        os_unfair_lock_unlock(&lock)
        if before != after { onTransition?(after) }
    }

    /// Forget everything (call at meeting start).
    public func reset() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        refEnv = [Float](repeating: -80, count: Self.refFrames)
        micEnv = [Float](repeating: -80, count: Self.micWindow)
        refCount = 0; micCount = 0
        refAcc = 0; refAccN = 0; micAcc = 0; micAccN = 0
        closeStreak = 0; openStreak = 0
        lastBestLag = nil
        _echoActive = false
    }

    // MARK: - Internals (lock held)

    private static func dB(_ meanSquare: Float) -> Float {
        10 * log10(max(meanSquare, 1e-8))  // floor −80 dB
    }

    private func evaluateLocked() {
        guard micCount >= Self.micWindow, refCount >= Self.micWindow else { return }

        // Mic window, oldest→newest.
        var mic = [Float](repeating: 0, count: Self.micWindow)
        for i in 0..<Self.micWindow {
            mic[i] = micEnv[(micCount - Self.micWindow + i) % Self.micWindow]
        }

        var best: Float = 0
        var bestRefMean: Float = -80
        var bestLag = 0
        var rSum: Float = 0
        var rCount = 0
        for lag in Self.lagRange {
            // Reference window `lag` frames further in the past, aligned by
            // the two streams' frame counters.
            let newest = refCount - 1 - lag
            let oldest = newest - Self.micWindow + 1
            guard oldest >= max(0, refCount - Self.refFrames), newest < refCount else { continue }
            var ref = [Float](repeating: 0, count: Self.micWindow)
            for i in 0..<Self.micWindow {
                ref[i] = refEnv[(oldest + i) % Self.refFrames]
            }
            let (r, refMean) = Self.pearson(mic, ref)
            rSum += r
            rCount += 1
            if r > best { best = r; bestRefMean = refMean; bestLag = lag }
        }

        // Real echo has a CONSISTENT lag (the buffers and the room don't
        // move) and a PROMINENT peak (it matches at that lag and nowhere
        // else); chance correlations between unrelated envelopes wander and
        // sit on an elevated baseline across all lags. Closing requires
        // repeated prominent correlation AT THE SAME LAG — the same
        // principle as an echo canceller's delay estimator.
        let meanR = rCount > 0 ? rSum / Float(rCount) : 0
        debugStats = (best, meanR, bestLag)
        let echoNow = best > Self.closeThreshold
            && best - meanR > Self.prominence
            && bestRefMean > Self.refFloorDB
        if echoNow {
            closeStreak = lastBestLag.map { abs(bestLag - $0) <= 1 } == true ? closeStreak + 1 : 1
            lastBestLag = bestLag
            openStreak = 0
            if closeStreak >= Self.closeAfter { _echoActive = true }
        } else if best < Self.openThreshold || bestRefMean <= Self.refFloorDB {
            openStreak += 1
            closeStreak = 0
            if openStreak >= Self.openAfter { _echoActive = false }
        }
        // Between thresholds: hold the current state (hysteresis).
    }

    /// Pearson correlation of two equal-length envelopes; also returns the
    /// reference mean so callers can ignore silent-reference matches.
    private static func pearson(_ a: [Float], _ b: [Float]) -> (r: Float, bMean: Float) {
        let n = Float(a.count)
        let ma = a.reduce(0, +) / n
        let mb = b.reduce(0, +) / n
        var cov: Float = 0, va: Float = 0, vb: Float = 0
        for i in a.indices {
            let da = a[i] - ma, db = b[i] - mb
            cov += da * db
            va += da * da
            vb += db * db
        }
        guard va > 1e-6, vb > 1e-6 else { return (0, mb) }
        return (cov / (va.squareRoot() * vb.squareRoot()), mb)
    }
}
