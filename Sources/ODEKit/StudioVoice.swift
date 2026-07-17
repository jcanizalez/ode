import Foundation

/// One RBJ-cookbook biquad section, transposed direct form II. Coefficients
/// are pre-normalized (a0 == 1) at construction; runtime is five multiplies
/// per sample and two delay slots.
struct Biquad {
    var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    private var z1: Float = 0, z2: Float = 0

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func reset() { z1 = 0; z2 = 0 }

    var stateIsFinite: Bool { z1.isFinite && z2.isFinite }

    /// Flush delay state to zero once it decays below audibility — keeps
    /// Intel/Rosetta out of the subnormal slow path (Apple Silicon doesn't
    /// care, but the check is two compares per chunk).
    mutating func flushDenormals() {
        if abs(z1) < 1e-20 { z1 = 0 }
        if abs(z2) < 1e-20 { z2 = 0 }
    }

    static func highpass(fs: Float, f0: Float, q: Float) -> Biquad {
        let w0 = 2 * Float.pi * f0 / fs
        let cosw = cos(w0), alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        return Biquad(b0: (1 + cosw) / 2 / a0,
                      b1: -(1 + cosw) / a0,
                      b2: (1 + cosw) / 2 / a0,
                      a1: -2 * cosw / a0,
                      a2: (1 - alpha) / a0)
    }

    static func lowpass(fs: Float, f0: Float, q: Float) -> Biquad {
        let w0 = 2 * Float.pi * f0 / fs
        let cosw = cos(w0), alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        return Biquad(b0: (1 - cosw) / 2 / a0,
                      b1: (1 - cosw) / a0,
                      b2: (1 - cosw) / 2 / a0,
                      a1: -2 * cosw / a0,
                      a2: (1 - alpha) / a0)
    }

    static func lowShelf(fs: Float, f0: Float, gainDB: Float, slope: Float) -> Biquad {
        let A = pow(10, gainDB / 40)
        let w0 = 2 * Float.pi * f0 / fs
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / 2 * ((A + 1 / A) * (1 / slope - 1) + 2).squareRoot()
        let k = 2 * A.squareRoot() * alpha
        let a0 = (A + 1) + (A - 1) * cosw + k
        return Biquad(b0: A * ((A + 1) - (A - 1) * cosw + k) / a0,
                      b1: 2 * A * ((A - 1) - (A + 1) * cosw) / a0,
                      b2: A * ((A + 1) - (A - 1) * cosw - k) / a0,
                      a1: -2 * ((A - 1) + (A + 1) * cosw) / a0,
                      a2: ((A + 1) + (A - 1) * cosw - k) / a0)
    }

    static func highShelf(fs: Float, f0: Float, gainDB: Float, slope: Float) -> Biquad {
        let A = pow(10, gainDB / 40)
        let w0 = 2 * Float.pi * f0 / fs
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / 2 * ((A + 1 / A) * (1 / slope - 1) + 2).squareRoot()
        let k = 2 * A.squareRoot() * alpha
        let a0 = (A + 1) - (A - 1) * cosw + k
        return Biquad(b0: A * ((A + 1) + (A - 1) * cosw + k) / a0,
                      b1: -2 * A * ((A - 1) + (A + 1) * cosw) / a0,
                      b2: A * ((A + 1) + (A - 1) * cosw - k) / a0,
                      a1: 2 * ((A - 1) - (A + 1) * cosw) / a0,
                      a2: ((A + 1) - (A - 1) * cosw - k) / a0)
    }

    static func peaking(fs: Float, f0: Float, gainDB: Float, q: Float) -> Biquad {
        let A = pow(10, gainDB / 40)
        let w0 = 2 * Float.pi * f0 / fs
        let cosw = cos(w0), alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha / A
        return Biquad(b0: (1 + alpha * A) / a0,
                      b1: -2 * cosw / a0,
                      b2: (1 - alpha * A) / a0,
                      a1: -2 * cosw / a0,
                      a2: (1 - alpha / A) / a0)
    }
}

/// One band of the multiband compressor: peak detector + Giannoulis
/// soft-knee static curve, no makeup (applied globally after the band sum).
private struct BandCompressor {
    let threshold: Float, ratio: Float, knee: Float
    let attackCoef: Float, releaseCoef: Float
    var env: Float = 0

    init(threshold: Float, ratio: Float, knee: Float,
         attackMs: Float, releaseMs: Float) {
        self.threshold = threshold
        self.ratio = ratio
        self.knee = knee
        attackCoef = exp(-1 / (attackMs / 1_000 * 48_000))
        releaseCoef = exp(-1 / (releaseMs / 1_000 * 48_000))
    }

    mutating func process(_ x: Float) -> Float {
        let r = abs(x)
        env = r > env ? attackCoef * env + (1 - attackCoef) * r
                      : releaseCoef * env + (1 - releaseCoef) * r
        let level = 20 * log10(max(env, 1e-9))
        let over = level - threshold
        let compressed: Float
        if 2 * over < -knee {
            compressed = level
        } else if 2 * abs(over) <= knee {
            compressed = level + (1 / ratio - 1) * (over + knee / 2) * (over + knee / 2) / (2 * knee)
        } else {
            compressed = threshold + over / ratio
        }
        return x * pow(10, (compressed - level) / 20)
    }

    mutating func reset() { env = 0 }
}

/// Downward expander — the inverse of a compressor: everything below the
/// threshold is pushed further down. After the AGC normalizes speech to a
/// known level, this is what tightens the ROOM: reverb tails and bleed
/// between words sit 15-25 dB under speech, and the expander steepens their
/// decay instead of letting the compressors lift them back up.
private struct DownwardExpander {
    let threshold: Float   // dBFS, below which expansion starts
    let ratio: Float       // 2 = every dB below becomes two
    let maxCutDB: Float    // attenuation floor — expander, not a hard gate
    let attackCoef: Float  // fast: speech onsets must open instantly
    let releaseCoef: Float // how quickly the tail is chased down
    var env: Float = 0

    init(threshold: Float, ratio: Float, maxCutDB: Float,
         attackMs: Float, releaseMs: Float) {
        self.threshold = threshold
        self.ratio = ratio
        self.maxCutDB = maxCutDB
        attackCoef = exp(-1 / (attackMs / 1_000 * 48_000))
        releaseCoef = exp(-1 / (releaseMs / 1_000 * 48_000))
    }

    mutating func process(_ x: Float) -> Float {
        let r = abs(x)
        env = r > env ? attackCoef * env + (1 - attackCoef) * r
                      : releaseCoef * env + (1 - releaseCoef) * r
        let level = 20 * log10(max(env, 1e-9))
        guard level < threshold else { return x }
        let cut = max((level - threshold) * (ratio - 1), maxCutDB)
        return x * pow(10, cut / 20)
    }

    mutating func reset() { env = 0 }
}

/// "Studio Voice" — a real broadcast processing chain, the kind radio
/// processors and podcast chains run, not just polish EQ:
///
///   HPF → EQ (mud cut, warmth, presence, air) → slow AGC (constant loudness)
///   → downward expander (tightens room reverb between words) → 3-band
///   compressor (LR4 crossovers 220 Hz / 5 kHz; the high band doubles as a
///   de-esser) → subtle tape-style saturation → peak limiter.
///
/// It runs AFTER the ML denoiser, so the floor is already clean and the AGC
/// can safely ride gain without pumping noise up (it also freezes on
/// silence). What listeners register as "studio" is loudness consistency and
/// multiband density — this chain provides both. Zero lookahead, no latency.
///
/// Not thread-safe by design: LiveEngine touches it only on its serial
/// processing queue, exactly like the denoiser and the DryWetMixer.
public final class StudioVoice {
    private static let fs: Float = 48_000

    // EQ, applied in order: steep rumble HPF (24 dB/oct — the low band's
    // compressor would otherwise lift back what a gentle slope removes),
    // 300 Hz mud cut (clarity), warmth shelf, presence peak, air shelf.
    // Hotter than a mastering EQ on purpose — the source is a laptop or
    // headset mic, not a condenser.
    private var eq: [Biquad] = [
        .highpass(fs: fs, f0: 80, q: 0.7071),
        .highpass(fs: fs, f0: 80, q: 0.7071),
        .peaking(fs: fs, f0: 300, gainDB: -2.5, q: 1.2),
        .lowShelf(fs: fs, f0: 160, gainDB: 3.5, slope: 1),
        .peaking(fs: fs, f0: 3_200, gainDB: 4, q: 0.9),
        .highShelf(fs: fs, f0: 10_500, gainDB: 2.5, slope: 1),
    ]

    // AGC: slow RMS rider toward a constant speech level. Lean back from the
    // mic and it brings you up; lean in and it backs off — the single most
    // audible "produced" property. Freezes below the silence floor so pauses
    // aren't pumped up.
    private let agcTargetRMS: Float = 0.1          // −20 dBFS
    private let agcSilenceRMS: Float = 0.003       // −50 dBFS: freeze below
    private let agcMinGain: Float = 0.25           // −12 dB
    private let agcMaxGain: Float = 10             // +20 dB
    private let agcEnvUp = Float(exp(-1.0 / (0.200 * 48_000)))
    private let agcEnvDown = Float(exp(-1.0 / (0.600 * 48_000)))
    private let agcGainSlew = Float(1 - exp(-1.0 / (0.500 * 48_000)))
    private var agcMeanSq: Float = 0
    private var agcGain: Float = 1

    // Room control: post-AGC, speech peaks sit near −8 dBFS and reverb tails
    // 15-25 dB lower, so a −30 dB knee catches the tail without clipping
    // word endings. 3:1 with a −20 dB floor and a fast 60 ms release chases
    // a ~500 ms room tail down hard; the 1 ms attack reopens instantly on
    // the next word so speech onsets are untouched.
    private var expander = DownwardExpander(threshold: -30, ratio: 3,
                                            maxCutDB: -20,
                                            attackMs: 1, releaseMs: 60)

    // Linkwitz-Riley 4th-order crossovers (two cascaded Butterworth halves)
    // at 220 Hz and 5 kHz. The bands sum back allpass-flat; the low band's
    // missing 5 kHz allpass is ~96 dB down there and inaudible.
    private var lowLP: [Biquad] = [.lowpass(fs: fs, f0: 220, q: 0.7071),
                                   .lowpass(fs: fs, f0: 220, q: 0.7071)]
    private var restHP: [Biquad] = [.highpass(fs: fs, f0: 220, q: 0.7071),
                                    .highpass(fs: fs, f0: 220, q: 0.7071)]
    private var midLP: [Biquad] = [.lowpass(fs: fs, f0: 5_000, q: 0.7071),
                                   .lowpass(fs: fs, f0: 5_000, q: 0.7071)]
    private var highHP: [Biquad] = [.highpass(fs: fs, f0: 5_000, q: 0.7071),
                                    .highpass(fs: fs, f0: 5_000, q: 0.7071)]

    // Per-band dynamics. The high band's fast, deep compression IS the
    // de-esser: steady highs pass nearly untouched, sibilant bursts get
    // clamped hard.
    private var bands: [BandCompressor] = [
        BandCompressor(threshold: -28, ratio: 2.5, knee: 8, attackMs: 20, releaseMs: 250),
        BandCompressor(threshold: -26, ratio: 3, knee: 8, attackMs: 8, releaseMs: 150),
        BandCompressor(threshold: -38, ratio: 4, knee: 6, attackMs: 1.5, releaseMs: 80),
    ]

    /// Post-sum makeup: the multiband stage costs ~4-6 dB of density.
    private let makeup = Float(pow(10.0, 6.0 / 20.0))

    // Subtle tape-style saturation: 20% of a normalized tanh adds low-order
    // harmonics — perceived warmth and loudness without measurable level.
    private let satDrive: Float = 1.6
    private let satMix: Float = 0.2

    // Limiter: instant attack (|out| ≤ ceiling by construction), 50 ms
    // release. Bit-transparent below the ceiling.
    private let ceiling: Float = 0.89125           // −1 dBFS
    private let limiterRelease = Float(exp(-1.0 / (0.050 * 48_000)))
    private var limEnv: Float = 0

    public init() {}

    /// Process one chunk, stateful across chunks (output is identical no
    /// matter how the stream is sliced). Empty in, empty out, no state change.
    public func process(_ samples: [Float]) -> [Float] {
        if samples.isEmpty { return samples }
        var out = samples
        for i in out.indices {
            var v = out[i]
            for e in eq.indices { v = eq[e].process(v) }

            // AGC — slow loudness rider, frozen during silence.
            let sq = v * v
            agcMeanSq = sq > agcMeanSq ? agcEnvUp * agcMeanSq + (1 - agcEnvUp) * sq
                                       : agcEnvDown * agcMeanSq + (1 - agcEnvDown) * sq
            let rms = agcMeanSq.squareRoot()
            if rms > agcSilenceRMS {
                let desired = min(max(agcTargetRMS / rms, agcMinGain), agcMaxGain)
                agcGain += (desired - agcGain) * agcGainSlew
            }
            v *= agcGain
            v = expander.process(v)

            // Three-way split, per-band dynamics, flat sum.
            var low = v, rest = v
            for e in lowLP.indices { low = lowLP[e].process(low) }
            for e in restHP.indices { rest = restHP[e].process(rest) }
            var mid = rest, high = rest
            for e in midLP.indices { mid = midLP[e].process(mid) }
            for e in highHP.indices { high = highHP[e].process(high) }
            v = (bands[0].process(low) + bands[1].process(mid)
                 + bands[2].process(high)) * makeup

            // Saturation (unity small-signal gain), then the safety ceiling.
            v += satMix * (tanh(satDrive * v) / satDrive - v)
            limEnv = max(abs(v), limiterRelease * limEnv)
            out[i] = v * (ceiling / max(limEnv, ceiling))
        }
        sanitizeStateIfNeeded()
        return out
    }

    /// Back to the exact post-init state (coefficients are immutable, so only
    /// delays, envelopes and the AGC clear). Call wherever the denoiser
    /// stream resets.
    public func reset() {
        for i in eq.indices { eq[i].reset() }
        for i in lowLP.indices { lowLP[i].reset() }
        for i in restHP.indices { restHP[i].reset() }
        for i in midLP.indices { midLP[i].reset() }
        for i in highHP.indices { highHP[i].reset() }
        for i in bands.indices { bands[i].reset() }
        agcMeanSq = 0
        agcGain = 1
        expander.reset()
        limEnv = 0
    }

    /// A NaN in feedback state is sticky and would poison every future
    /// sample. Checked once per chunk: any non-finite state → full reset, so
    /// one bad chunk self-heals on the next call instead of silencing the mic.
    private func sanitizeStateIfNeeded() {
        let filtersFinite = eq.allSatisfy(\.stateIsFinite)
            && lowLP.allSatisfy(\.stateIsFinite) && restHP.allSatisfy(\.stateIsFinite)
            && midLP.allSatisfy(\.stateIsFinite) && highHP.allSatisfy(\.stateIsFinite)
        let scalarsFinite = agcMeanSq.isFinite && agcGain.isFinite && limEnv.isFinite
            && expander.env.isFinite && bands.allSatisfy { $0.env.isFinite }
        guard filtersFinite && scalarsFinite else {
            reset()
            return
        }
        for i in eq.indices { eq[i].flushDenormals() }
        for i in lowLP.indices { lowLP[i].flushDenormals() }
        for i in restHP.indices { restHP[i].flushDenormals() }
        for i in midLP.indices { midLP[i].flushDenormals() }
        for i in highHP.indices { highHP[i].flushDenormals() }
        if agcMeanSq < 1e-20 { agcMeanSq = 0 }
        if expander.env < 1e-20 { expander.env = 0 }
        for i in bands.indices where bands[i].env < 1e-20 { bands[i].env = 0 }
        if limEnv < 1e-20 { limEnv = 0 }
    }
}
