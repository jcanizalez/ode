import Foundation

/// Blends the original (dry) signal with the denoised (wet) signal so users
/// can trade noise removal for naturalness: `out = wet·s + dry·(1−s)`.
///
/// The streaming denoiser buffers internally to frame boundaries, so a single
/// call's output count rarely matches its input count — but cumulative
/// alignment holds (wet sample k corresponds to dry sample k). A FIFO of
/// pending dry samples pairs each wet sample with its original.
///
/// Not thread-safe by design: LiveEngine touches it only on its serial
/// processing queue, exactly like the denoiser itself.
public final class DryWetMixer {
    private var dryPending: [Float] = []

    /// Safety cap — the denoiser can never lag the input by anywhere near
    /// this much; if the FIFO grows past it something is wrong upstream, and
    /// dropping the oldest dry samples beats unbounded memory growth.
    static let maxPending = 48_000  // 1 s at 48 kHz

    public init() {}

    /// Queue original samples, in the same order they are fed to the denoiser.
    public func feed(dry: [Float]) {
        dryPending.append(contentsOf: dry)
        if dryPending.count > Self.maxPending {
            dryPending.removeFirst(dryPending.count - Self.maxPending)
        }
    }

    /// Blend denoised samples with their queued originals. Strength 1 returns
    /// wet unchanged, 0 returns the originals. If the FIFO runs short (it
    /// shouldn't — cumulative wet never exceeds cumulative dry) the missing
    /// dry samples degrade to the wet ones, never crashing or clicking.
    public func mix(wet: [Float], strength: Float) -> [Float] {
        let s = min(max(strength, 0), 1)
        if s >= 0.999 || wet.isEmpty {
            if !dryPending.isEmpty { dryPending.removeFirst(min(wet.count, dryPending.count)) }
            return wet
        }
        let paired = min(wet.count, dryPending.count)
        var out = wet
        for i in 0..<paired {
            out[i] = wet[i] * s + dryPending[i] * (1 - s)
        }
        dryPending.removeFirst(paired)
        return out
    }

    /// Forget queued dry audio (call wherever the denoiser stream is reset).
    public func reset() {
        dryPending.removeAll()
    }
}
