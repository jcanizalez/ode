import XCTest
import AVFoundation
@testable import ODEKit

final class RecordingTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ode-recording-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func sample(recording: String? = nil) -> Transcript {
        Transcript(title: "Standup", startedAt: Date(timeIntervalSince1970: 1_000),
                   endedAt: Date(timeIntervalSince1970: 1_600),
                   segments: [TranscriptSegment(speaker: "You", start: 0, end: 10,
                                                text: "Buenos días")],
                   recordingFile: recording)
    }

    // MARK: - Schema round-trip

    func testRecordingFileSurvivesSaveLoad() {
        let store = TranscriptStore(directory: tempDir)
        store.save(sample(recording: "call.m4a"))
        XCTAssertEqual(store.load().first?.recordingFile, "call.m4a")
    }

    func testOldTranscriptsDecodeWithoutRecordingField() throws {
        let store = TranscriptStore(directory: tempDir)
        store.save(sample())
        XCTAssertNil(store.load().first?.recordingFile)
    }

    func testDeleteRemovesRecordingSidecar() throws {
        let store = TranscriptStore(directory: tempDir)
        let t = sample(recording: "call.m4a")
        store.save(t)
        let recording = tempDir.appendingPathComponent("call.m4a")
        try Data([1, 2, 3]).write(to: recording)
        XCTAssertNotNil(store.recordingURL(for: t))
        store.delete(t)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.path))
    }

    func testRecordingURLNilWhenFileMissing() {
        let store = TranscriptStore(directory: tempDir)
        XCTAssertNil(store.recordingURL(for: sample(recording: "gone.m4a")))
        XCTAssertNil(store.recordingURL(for: sample()))
    }

    // MARK: - CallRecorder

    private func sine(_ hz: Float, amp: Float, count: Int) -> [Float] {
        (0..<count).map { amp * sin(2 * .pi * hz * Float($0) / 48_000) }
    }

    /// One-sided call: only the mic feeds. The recorder must pad the silent
    /// side and still produce the sine.
    func testRecorderCapturesOneSidedAudio() throws {
        let url = tempDir.appendingPathComponent("one-sided.m4a")
        let rec = try CallRecorder(url: url)
        let tone = sine(440, amp: 0.5, count: 96_000)  // 2 s
        for chunk in stride(from: 0, to: tone.count, by: 480).map({
            Array(tone[$0..<min($0 + 480, tone.count)])
        }) {
            rec.feedMic(chunk)
        }
        guard let saved = rec.finish() else {
            return XCTFail("finish() returned nil for a fed recorder")
        }

        let file = try AVAudioFile(forReading: saved)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                   frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        let decoded = AudioIO.bufferToArray(buf)
        XCTAssertGreaterThan(decoded.count, 48_000)  // ~2 s survived encoding
        // AAC is lossy; assert the energy, not the samples. RMS of a 0.5-amp
        // sine is 0.354 — allow generous codec tolerance.
        let mid = Array(decoded.dropFirst(9_600).prefix(48_000))
        let rms = (mid.reduce(Float(0)) { $0 + $1 * $1 } / Float(mid.count)).squareRoot()
        XCTAssertEqual(rms, 0.354, accuracy: 0.08)
    }

    /// Both sides feed: the file must contain their sum.
    func testRecorderMixesBothSides() throws {
        let url = tempDir.appendingPathComponent("mixed.m4a")
        let rec = try CallRecorder(url: url)
        // Interleaved 10 ms chunks, the way the two live paths actually feed.
        let tone = sine(440, amp: 0.25, count: 48_000)
        for start in stride(from: 0, to: tone.count, by: 480) {
            let chunk = Array(tone[start..<min(start + 480, tone.count)])
            rec.feedMic(chunk)
            rec.feedOthers(chunk)
        }
        guard let saved = rec.finish() else {
            return XCTFail("finish() returned nil for a fed recorder")
        }
        let file = try AVAudioFile(forReading: saved)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                   frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        let decoded = AudioIO.bufferToArray(buf)
        // In-phase 0.25 + 0.25 sums to a 0.5-amp sine → RMS 0.354.
        let mid = Array(decoded.dropFirst(9_600).prefix(24_000))
        let rms = (mid.reduce(Float(0)) { $0 + $1 * $1 } / Float(mid.count)).squareRoot()
        XCTAssertEqual(rms, 0.354, accuracy: 0.08)
    }

    func testFinishWithNoAudioRemovesEmptyFile() throws {
        let url = tempDir.appendingPathComponent("empty.m4a")
        let rec = try CallRecorder(url: url)
        XCTAssertNil(rec.finish())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// Wildly unequal feed rates must neither deadlock nor grow unbounded.
    func testRecorderSurvivesUnequalFeeds() throws {
        let url = tempDir.appendingPathComponent("unequal.m4a")
        let rec = try CallRecorder(url: url)
        for _ in 0..<200 { rec.feedMic(sine(200, amp: 0.3, count: 4_800)) }  // 20 s
        rec.feedOthers(sine(300, amp: 0.3, count: 480))                      // 10 ms
        XCTAssertNotNil(rec.finish())
    }
}
