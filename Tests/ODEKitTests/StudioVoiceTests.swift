import XCTest
@testable import ODEKit

final class StudioVoiceTests: XCTestCase {
    private let fs: Float = 48_000

    private func sine(_ hz: Float, dbfs: Float, seconds: Float = 1) -> [Float] {
        let amp = pow(10, dbfs / 20)
        let n = Int(fs * seconds)
        return (0..<n).map { amp * sin(2 * .pi * hz * Float($0) / fs) }
    }

    /// Sum of equal-level sines — the chain's AGC normalizes overall
    /// loudness, so frequency response must be measured WITHIN one signal.
    private func composite(_ hzs: [Float], dbfsEach: Float, seconds: Float = 2) -> [Float] {
        let amp = pow(10, dbfsEach / 20)
        let n = Int(fs * seconds)
        return (0..<n).map { i in
            hzs.reduce(Float(0)) { $0 + amp * sin(2 * .pi * $1 * Float(i) / fs) }
        }
    }

    /// Goertzel power at one frequency over the steady-state tail.
    private func power(at hz: Float, in x: [Float]) -> Float {
        let tail = Array(x.suffix(x.count / 2))
        let w = 2 * Float.pi * hz / fs
        let coef = 2 * cos(w)
        var s0: Float = 0, s1: Float = 0, s2: Float = 0
        for v in tail {
            s0 = v + coef * s1 - s2
            s2 = s1
            s1 = s0
        }
        return s1 * s1 + s2 * s2 - coef * s1 * s2
    }

    private func ratioDB(_ a: Float, _ b: Float, in x: [Float]) -> Float {
        10 * log10(power(at: a, in: x) / power(at: b, in: x))
    }

    private func steadyRMS(_ x: [Float]) -> Float {
        let tail = x.suffix(x.count / 2)
        let sum = tail.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(tail.count)).squareRoot()
    }

    // MARK: - Frequency shaping (measured within one composite signal)

    func testHighPassRejectsRumble() {
        let input = composite([50, 1_000], dbfsEach: -30)
        let output = StudioVoice().process(input)
        // 50 Hz must fall at least 6 dB relative to 1 kHz.
        XCTAssertLessThan(ratioDB(50, 1_000, in: output),
                          ratioDB(50, 1_000, in: input) - 6)
    }

    func testDCDies() {
        let step = [Float](repeating: 0.5, count: Int(fs))
        let out = StudioVoice().process(step)
        for v in out.suffix(4_800) {
            XCTAssertLessThan(abs(v), 1e-2)
        }
    }

    func testPresenceAndWarmthTilt() {
        let input = composite([140, 1_000, 3_200], dbfsEach: -30)
        let output = StudioVoice().process(input)
        // Presence: 3.2 kHz gains ≥ 2 dB on 1 kHz (both live in the mid
        // band, so its compressor scales them together and the EQ survives).
        XCTAssertGreaterThan(ratioDB(3_200, 1_000, in: output),
                             ratioDB(3_200, 1_000, in: input) + 2)
        // Warmth: 140 Hz must at least hold its own against 1 kHz despite
        // the HPF skirt (shelf + band balance keep the low end present).
        XCTAssertGreaterThan(ratioDB(140, 1_000, in: output),
                             ratioDB(140, 1_000, in: input) - 1)
    }

    func testDeEsserTamesSibilanceBand() {
        let input = composite([300, 7_000], dbfsEach: -20)
        let output = StudioVoice().process(input)
        // The high band's fast deep compression must pull 7 kHz down
        // relative to 300 Hz by a clearly audible amount.
        XCTAssertLessThan(ratioDB(7_000, 300, in: output),
                          ratioDB(7_000, 300, in: input) - 3)
    }

    // MARK: - Dynamics

    /// The marquee property: quiet and loud takes leave at nearly the same
    /// level. 22 dB of input spread must collapse to a few dB out.
    func testLoudnessConsistency() {
        let quiet = StudioVoice().process(sine(500, dbfs: -32, seconds: 3))
        let loud = StudioVoice().process(sine(500, dbfs: -10, seconds: 3))
        let spreadDB = 20 * log10(steadyRMS(loud) / steadyRMS(quiet))
        XCTAssertLessThan(abs(spreadDB), 6, "22 dB in → ≤6 dB out")
    }

    /// Room control: a speech burst followed by a reverb-style exponential
    /// tail (~500 ms decay, like an empty room). Without the expander, the
    /// AGC + compressors LIFT the tail; with it, the tail must decay
    /// meaningfully faster than it does in the input.
    func testExpanderTightensReverbTail() {
        let burstN = Int(fs * 1.5), tailN = Int(fs * 0.8)
        let tau: Float = 0.11 * fs  // ≈500 ms to fall 20 dB
        var input = sine(500, dbfs: -14, seconds: 1.5)
        input.append(contentsOf: (0..<tailN).map { i in
            0.2 * exp(-Float(i) / tau) * sin(2 * .pi * 500 * Float(burstN + i) / fs)
        })
        let output = StudioVoice().process(input)

        // Compare levels 350 ms into the tail, relative to each signal's own
        // steady speech level (AGC changes absolute levels by design).
        func relDB(_ x: [Float], _ from: Int, _ len: Int) -> Float {
            let seg = Array(x[from..<min(from + len, x.count)])
            let segRMS = (seg.reduce(Float(0)) { $0 + $1 * $1 } / Float(seg.count)).squareRoot()
            let speech = Array(x[(burstN - 24_000)..<burstN])
            let speechRMS = (speech.reduce(Float(0)) { $0 + $1 * $1 } / Float(speech.count)).squareRoot()
            return 20 * log10(max(segRMS, 1e-9) / max(speechRMS, 1e-9))
        }
        let probe = burstN + Int(fs * 0.35)
        let inputTail = relDB(input, probe, 4_800)
        let outputTail = relDB(output, probe, 4_800)
        XCTAssertLessThan(outputTail, inputTail - 6,
                          "the tail must sit ≥6 dB lower relative to speech")
    }

    func testCeilingIsAbsolute() {
        for input in [sine(200, dbfs: 0, seconds: 1),
                      [Float](repeating: 1.0, count: 9_600)] {
            let out = StudioVoice().process(input)
            for v in out {
                XCTAssertLessThanOrEqual(abs(v), 0.89125 + 1e-6)
            }
        }
    }

    // MARK: - Streaming/state contract

    func testSilenceInSilenceOut() {
        let out = StudioVoice().process([Float](repeating: 0, count: 4_800))
        XCTAssertTrue(out.allSatisfy { $0 == 0 })
    }

    func testResetReproducibility() {
        var seed: UInt32 = 12_345
        let input: [Float] = (0..<9_600).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return (Float(seed) / Float(UInt32.max) - 0.5) * 0.4
        }
        let voice = StudioVoice()
        let first = voice.process(input)
        voice.reset()
        let second = voice.process(input)
        XCTAssertEqual(first, second)
    }

    func testChunkSizeInvariance() {
        var seed: UInt32 = 99
        let input: [Float] = (0..<12_000).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return (Float(seed) / Float(UInt32.max) - 0.5) * 0.6
        }
        let whole = StudioVoice().process(input)

        let chopped = StudioVoice()
        var pieced: [Float] = []
        var i = 0
        for size in [1, 7, 480, 3, 1_023, 0, 2_048, 5_000, 10_000] {
            let end = min(i + size, input.count)
            pieced.append(contentsOf: chopped.process(Array(input[i..<end])))
            i = end
            if i == input.count { break }
        }
        if i < input.count {
            pieced.append(contentsOf: chopped.process(Array(input[i...])))
        }
        XCTAssertEqual(whole, pieced)
    }

    func testNaNSelfHeals() {
        let voice = StudioVoice()
        var poisoned = sine(440, dbfs: -20, seconds: 0.1)
        poisoned[100] = .nan
        _ = voice.process(poisoned)
        let after = voice.process(sine(440, dbfs: -20, seconds: 0.1))
        XCTAssertTrue(after.allSatisfy { $0.isFinite })
    }
}
