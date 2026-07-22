import XCTest
@testable import ODEKit

final class EchoGateTests: XCTestCase {
    private let fs = 48_000

    /// Counter-based hash (SplitMix64): unlike an LCG — whose different
    /// seeds yield time-SHIFTED copies of one orbit, which a lag-searching
    /// correlator rightly detects as echo! — this gives genuinely
    /// independent streams per seed.
    private func rnd(_ seed: UInt64, _ i: UInt64) -> Float {
        var z = (seed &* 0x9E3779B97F4A7C15) &+ (i &* 0xBF58476D1CE4E5B9)
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Float(z >> 40) / Float(1 << 24)
    }

    /// Speech-like signal: noise carrier amplitude-modulated by a slow
    /// random envelope (syllable-rate bursts and gaps).
    private func speechLike(seconds: Float, seed: UInt64, level: Float) -> [Float] {
        let n = Int(Float(fs) * seconds)
        // Envelope changes every 120 ms; ~40% silence, bursts of varied level.
        let hop = fs * 12 / 100
        let blocks = n / hop + 1
        let envelope: [Float] = (0..<blocks).map { b in
            rnd(seed, UInt64(b)) < 0.4 ? 0 : 0.3 + 0.7 * rnd(seed &+ 1, UInt64(b))
        }
        return (0..<n).map { i in
            level * envelope[i / hop] * (rnd(seed &+ 2, UInt64(i)) * 2 - 1)
        }
    }

    /// Simulate the speaker→room→mic path: delay + one-pole lowpass + gain.
    private func roomEcho(_ x: [Float], delaySamples: Int, gain: Float) -> [Float] {
        var out = [Float](repeating: 0, count: x.count)
        var lp: Float = 0
        for i in x.indices {
            let src = i >= delaySamples ? x[i - delaySamples] : 0
            lp = 0.7 * lp + 0.3 * src
            out[i] = gain * lp
        }
        return out
    }

    /// Feed both streams in interleaved 10 ms chunks, like the live paths.
    private func run(_ gate: EchoGate, reference: [Float], mic: [Float]) {
        let chunk = 480
        var i = 0
        while i < min(reference.count, mic.count) {
            let end = min(i + chunk, reference.count, mic.count)
            gate.pushReference(Array(reference[i..<end]))
            gate.pushMic(Array(mic[i..<end]))
            i = end
        }
    }

    func testPureBleedIsDetected() {
        let gate = EchoGate()
        let farEnd = speechLike(seconds: 3, seed: 7, level: 0.5)
        // Mic hears ONLY the speakers: 180 ms behind, room-filtered, quieter.
        let mic = roomEcho(farEnd, delaySamples: Int(0.18 * 48_000), gain: 0.4)
        run(gate, reference: farEnd, mic: mic)
        XCTAssertTrue(gate.echoActive, "mic playing back the reference must gate")
    }

    func testIndependentSpeechStaysOpen() {
        let gate = EchoGate()
        let farEnd = speechLike(seconds: 3, seed: 7, level: 0.5)
        let ownVoice = speechLike(seconds: 3, seed: 991, level: 0.5)
        run(gate, reference: farEnd, mic: ownVoice)
        XCTAssertFalse(gate.echoActive, "the user's own speech must never gate")
    }

    func testDoubleTalkStaysOpen() {
        let gate = EchoGate()
        let farEnd = speechLike(seconds: 3, seed: 7, level: 0.5)
        let echo = roomEcho(farEnd, delaySamples: Int(0.15 * 48_000), gain: 0.25)
        let ownVoice = speechLike(seconds: 3, seed: 991, level: 0.6)
        let mic = zip(ownVoice, echo).map(+)
        run(gate, reference: farEnd, mic: mic)
        XCTAssertFalse(gate.echoActive,
                       "own voice over background echo must not be muted")
    }

    func testSilentReferenceNeverGates() {
        let gate = EchoGate()
        let silence = [Float](repeating: 0, count: 3 * fs)
        let ownVoice = speechLike(seconds: 3, seed: 42, level: 0.5)
        run(gate, reference: silence, mic: ownVoice)
        XCTAssertFalse(gate.echoActive)
    }

    func testGateReleasesWhenBleedStops() {
        let gate = EchoGate()
        let farEnd = speechLike(seconds: 3, seed: 7, level: 0.5)
        let bleed = roomEcho(farEnd, delaySamples: Int(0.18 * 48_000), gain: 0.4)
        run(gate, reference: farEnd, mic: bleed)
        XCTAssertTrue(gate.echoActive)
        // The far end goes quiet; the user starts talking.
        let quiet = [Float](repeating: 0, count: 2 * fs)
        let ownVoice = speechLike(seconds: 2, seed: 555, level: 0.5)
        run(gate, reference: quiet, mic: ownVoice)
        XCTAssertFalse(gate.echoActive, "gate must reopen when bleed ends")
    }

    func testResetClearsState() {
        let gate = EchoGate()
        let farEnd = speechLike(seconds: 3, seed: 7, level: 0.5)
        let bleed = roomEcho(farEnd, delaySamples: Int(0.18 * 48_000), gain: 0.4)
        run(gate, reference: farEnd, mic: bleed)
        XCTAssertTrue(gate.echoActive)
        gate.reset()
        XCTAssertFalse(gate.echoActive)
    }
}
