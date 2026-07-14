import XCTest
import AVFoundation
@testable import ODEKit

final class AudioIOTests: XCTestCase {
    func testMonoFormatProperties() {
        let fmt = AudioIO.monoFormat
        XCTAssertEqual(fmt.sampleRate, 48_000)
        XCTAssertEqual(fmt.channelCount, 1)
        XCTAssertEqual(fmt.commonFormat, .pcmFormatFloat32)
    }

    private func makeBuffer(format: AVAudioFormat, frames: Int,
                            fill: (Int) -> Float) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<Int(format.channelCount) {
            let ptr = buf.floatChannelData![ch]
            for i in 0..<frames { ptr[i] = fill(i) }
        }
        return buf
    }

    func testBufferToArray() {
        let buf = makeBuffer(format: AudioIO.monoFormat, frames: 100) { Float($0) / 100 }
        let arr = AudioIO.bufferToArray(buf)
        XCTAssertEqual(arr.count, 100)
        XCTAssertEqual(arr[50], 0.5, accuracy: 0.0001)
    }

    func testResamplePassthroughWhenAlready48kMono() {
        let buf = makeBuffer(format: AudioIO.monoFormat, frames: 480) { _ in 0.25 }
        let out = AudioIO.resampleToMono48k(buf)
        XCTAssertEqual(out.count, 480)
        XCTAssertEqual(out[0], 0.25, accuracy: 0.0001)
    }

    func testResampleUpsamples24kStereoTo48kMono() {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                channels: 2, interleaved: false)!
        let buf = makeBuffer(format: fmt, frames: 2_400) { _ in 0.5 }
        let out = AudioIO.resampleToMono48k(buf)
        // 0.1 s of audio should stay ~0.1 s at 48 kHz (converter may trim edges).
        XCTAssertGreaterThan(out.count, 4_000)
        XCTAssertLessThanOrEqual(out.count, 4_900)
    }

    func testWavWriteReadRoundtrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ode-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        // 0.1 s 440 Hz sine.
        let n = 4_800
        let samples = (0..<n).map { Float(sin(2 * .pi * 440 * Double($0) / 48_000)) * 0.5 }
        try AudioIO.writeWav(samples: samples, url: url)

        let back = try AudioIO.readSamples(url: url)
        XCTAssertEqual(back.count, n)
        // 16-bit quantization: values should match closely.
        for i in stride(from: 0, to: n, by: 97) {
            XCTAssertEqual(back[i], samples[i], accuracy: 0.001)
        }
    }

    func testReadSamplesMissingFileThrows() {
        XCTAssertThrowsError(try AudioIO.readSamples(
            url: URL(fileURLWithPath: "/nonexistent/nope.wav")))
    }
}

final class RingBufferTests: XCTestCase {
    private func read(_ ring: RingBuffer, _ count: Int) -> [Float] {
        var out = [Float](repeating: -99, count: count)
        out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: count) }
        return out
    }

    func testWriteThenReadPreservesOrder() {
        let ring = RingBuffer(capacity: 16)
        ring.write([1, 2, 3, 4])
        XCTAssertEqual(read(ring, 4), [1, 2, 3, 4])
    }

    func testUnderrunPadsWithSilence() {
        let ring = RingBuffer(capacity: 16)
        ring.write([1, 2])
        XCTAssertEqual(read(ring, 4), [1, 2, 0, 0])
    }

    func testOverflowOverwritesOldest() {
        let ring = RingBuffer(capacity: 4)
        ring.write([1, 2, 3, 4, 5, 6])   // capacity 4 → keeps 3,4,5,6
        XCTAssertEqual(read(ring, 4), [3, 4, 5, 6])
    }

    func testResetDropsBufferedAudio() {
        let ring = RingBuffer(capacity: 16)
        ring.write([1, 2, 3])
        ring.reset()
        XCTAssertEqual(read(ring, 2), [0, 0])
    }

    func testInterleavedWriteRead() {
        let ring = RingBuffer(capacity: 8)
        ring.write([1, 2])
        XCTAssertEqual(read(ring, 1), [1])
        ring.write([3])
        XCTAssertEqual(read(ring, 2), [2, 3])
    }

    func testWrapAroundPreservesData() {
        let ring = RingBuffer(capacity: 4)
        ring.write([1, 2, 3])
        XCTAssertEqual(read(ring, 3), [1, 2, 3])
        ring.write([4, 5, 6])          // wraps the internal indices
        XCTAssertEqual(read(ring, 3), [4, 5, 6])
    }

    func testPrefillGatesReadsUntilCushionFills() {
        let ring = RingBuffer(capacity: 16, prefill: 4)
        ring.write([1, 2])
        XCTAssertEqual(read(ring, 2), [0, 0])   // not primed yet → silence
        ring.write([3, 4])
        XCTAssertEqual(read(ring, 4), [1, 2, 3, 4])  // cushion reached
    }

    func testUnderrunReArmsThePrefillCushion() {
        let ring = RingBuffer(capacity: 16, prefill: 3)
        ring.write([1, 2, 3])
        XCTAssertEqual(read(ring, 4), [1, 2, 3, 0])  // underrun → re-arm
        ring.write([4, 5])
        XCTAssertEqual(read(ring, 2), [0, 0])        // rebuffering
        ring.write([6])
        XCTAssertEqual(read(ring, 3), [4, 5, 6])     // primed again
    }

    func testMaxFillDropsBacklogKeepingNewest() {
        let ring = RingBuffer(capacity: 16, prefill: 2, maxFill: 6)
        ring.write([1, 2, 3, 4, 5, 6, 7, 8])   // 8 > maxFill 6 → drop to prefill 2
        var out = [Float](repeating: -1, count: 2)
        out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 2) }
        XCTAssertEqual(out, [7, 8])            // only the newest cushion remains
    }
}

final class DenoiserTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        // The test executable lives deep inside .build; point the locator at
        // the repo's bundled model explicitly.
        let repoRoot = URL(fileURLWithPath: #filePath)          // …/Tests/ODEKitTests/AudioTests.swift
            .deletingLastPathComponent()                        // …/Tests/ODEKitTests
            .deletingLastPathComponent()                        // …/Tests
            .deletingLastPathComponent()                        // repo root
        let model = repoRoot.appendingPathComponent("Resources/dpdfnet2_48khz_hr.onnx")
        setenv("ODE_MODEL_PATH", model.path, 1)
    }

    func testOfflineDenoisePreservesLengthAndIsFinite() {
        let denoiser = Denoiser()
        // 0.5 s of white-ish noise.
        var seed: UInt64 = 42
        let noise = (0..<24_000).map { _ -> Float in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: seed) % 1000) / 5000
        }
        let out = denoiser.process(noise)
        XCTAssertEqual(out.count, noise.count)
        XCTAssertTrue(out.allSatisfy { $0.isFinite })
    }

    func testStreamingDenoiseProducesOutputAcrossChunks() {
        let denoiser = Denoiser()
        denoiser.resetStreaming()
        var produced = 0
        for chunk in 0..<10 {
            let samples = (0..<4_800).map {
                Float(sin(2 * .pi * 220 * Double(chunk * 4_800 + $0) / 48_000)) * 0.3
            }
            produced += denoiser.processStreaming(samples).count
        }
        produced += denoiser.flushStreaming().count
        // Streaming output should roughly track the 48 000 samples fed.
        XCTAssertGreaterThan(produced, 24_000)
        denoiser.resetStreaming()
    }

    func testProcessEmptyInputReturnsEmpty() {
        let denoiser = Denoiser()
        XCTAssertTrue(denoiser.process([]).isEmpty)
        XCTAssertTrue(denoiser.processStreaming([]).isEmpty)
    }
}
