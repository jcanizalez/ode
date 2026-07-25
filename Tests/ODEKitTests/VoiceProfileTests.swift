import XCTest
@testable import ODEKit

/// Remembering a voice across meetings. Sortformer has no persistent speaker
/// database — enrollment is priming with audio you kept yourself — so these
/// cover the keeping: what is worth saving, what replaces what, and what
/// happens when a sample goes missing.
final class VoiceProfileStoreTests: XCTestCase {
    private var dir: URL!
    private var store: VoiceProfileStore!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ode-voices-\(UUID().uuidString)")
        store = VoiceProfileStore(directory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// Audible tone rather than silence: WAV round-trips through 16-bit PCM,
    /// and silence would round-trip perfectly even if the writer were broken.
    private func speech(seconds: Double) -> [Float] {
        let n = Int(seconds * VoiceProfileStore.sampleRate)
        return (0..<n).map { i in
            0.5 * sin(2 * .pi * 220 * Float(i) / Float(VoiceProfileStore.sampleRate))
        }
    }

    func testStartsEmpty() {
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertTrue(store.enrollable().isEmpty)
    }

    func testSavesAndReloadsAVoice() {
        let profile = store.save(name: "Igor", samples: speech(seconds: 4))
        XCTAssertNotNil(profile)
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.all().first?.name, "Igor")
        XCTAssertEqual(profile?.seconds ?? 0, 4, accuracy: 0.05)

        // A second store over the same directory sees it — profiles must
        // survive relaunch, that is the entire point.
        let reopened = VoiceProfileStore(directory: dir)
        XCTAssertEqual(reopened.all().first?.name, "Igor")
    }

    func testAudioRoundTripsAtTheEnrollmentRate() {
        guard let profile = store.save(name: "Igor", samples: speech(seconds: 3)) else {
            return XCTFail("save must succeed for a 3 s sample")
        }
        guard let samples = store.samples(for: profile.id) else {
            return XCTFail("audio must be readable back")
        }
        XCTAssertEqual(Double(samples.count) / VoiceProfileStore.sampleRate, 3, accuracy: 0.05)
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.1)  // not silence
    }

    /// A too-short sample enrolls badly, and a confidently wrong name is
    /// worse than "Speaker 2".
    func testRejectsSamplesShorterThanTheMinimum() {
        let tooShort = VoiceProfileStore.minimumSeconds / 2
        XCTAssertNil(store.save(name: "Igor", samples: speech(seconds: tooShort)))
        XCTAssertTrue(store.all().isEmpty)
    }

    func testRejectsEmptyNames() {
        XCTAssertNil(store.save(name: "   ", samples: speech(seconds: 4)))
        XCTAssertTrue(store.all().isEmpty)
    }

    func testTrimsWhitespaceFromNames() {
        _ = store.save(name: "  Igor  ", samples: speech(seconds: 4))
        XCTAssertEqual(store.all().first?.name, "Igor")
    }

    /// Long samples are clipped: enrollment quality plateaus, and every
    /// profile is replayed at the start of every meeting.
    func testClipsOverlyLongSamples() {
        let profile = store.save(name: "Igor",
                                 samples: speech(seconds: VoiceProfileStore.maximumSeconds * 3))
        XCTAssertEqual(profile?.seconds ?? 0, VoiceProfileStore.maximumSeconds, accuracy: 0.05)
    }

    /// Naming the same person in a later meeting refreshes their sample
    /// instead of leaving two "Igor"s that both claim a slot at enrollment.
    func testSavingTheSameNameReplacesInPlace() {
        let first = store.save(name: "Igor", samples: speech(seconds: 2))
        let second = store.save(name: "igor", samples: speech(seconds: 5))
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(first?.id, second?.id)
        XCTAssertEqual(store.all().first?.name, "igor")
        XCTAssertEqual(store.all().first?.seconds ?? 0, 5, accuracy: 0.05)
    }

    func testDistinctNamesCoexist() {
        _ = store.save(name: "Igor", samples: speech(seconds: 3))
        _ = store.save(name: "Ana", samples: speech(seconds: 3))
        XCTAssertEqual(Set(store.all().map(\.name)), ["Igor", "Ana"])
        XCTAssertEqual(store.enrollable().count, 2)
    }

    func testRenameKeepsTheAudio() {
        guard let profile = store.save(name: "Speaker 2", samples: speech(seconds: 3)) else {
            return XCTFail("save must succeed")
        }
        store.rename(profile.id, to: "Igor")
        XCTAssertEqual(store.all().first?.name, "Igor")
        XCTAssertNotNil(store.samples(for: profile.id))
    }

    func testDeleteRemovesProfileAndAudio() {
        guard let profile = store.save(name: "Igor", samples: speech(seconds: 3)) else {
            return XCTFail("save must succeed")
        }
        store.delete(profile.id)
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertNil(store.samples(for: profile.id))
        XCTAssertTrue(store.enrollable().isEmpty)
    }

    /// An empty enrollment still claims a speaker slot, so a profile whose
    /// audio has gone missing must be skipped rather than enrolled blank.
    func testEnrollableSkipsProfilesWithMissingAudio() {
        guard let profile = store.save(name: "Igor", samples: speech(seconds: 3)) else {
            return XCTFail("save must succeed")
        }
        try? FileManager.default.removeItem(
            at: dir.appendingPathComponent("\(profile.id.uuidString).wav"))
        XCTAssertEqual(store.all().count, 1)      // still listed in Settings
        XCTAssertTrue(store.enrollable().isEmpty) // but never enrolled blank
    }

    func testEnrollablePairsNamesWithAudio() {
        _ = store.save(name: "Igor", samples: speech(seconds: 3))
        let enrollable = store.enrollable()
        XCTAssertEqual(enrollable.count, 1)
        XCTAssertEqual(enrollable.first?.name, "Igor")
        XCTAssertFalse(enrollable.first?.samples.isEmpty ?? true)
    }
}

/// Voice samples ride along with the transcript, so naming a speaker later
/// can still reach their audio.
final class TranscriptVoiceSampleTests: XCTestCase {
    private var dir: URL!
    private var store: TranscriptStore!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ode-transcripts-\(UUID().uuidString)")
        store = TranscriptStore(directory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func transcript(speakers: [String]) -> Transcript {
        Transcript(title: "Standup", startedAt: Date(), endedAt: Date().addingTimeInterval(600),
                   segments: speakers.enumerated().map { i, s in
                       TranscriptSegment(speaker: s, start: Double(i) * 5,
                                         end: Double(i) * 5 + 4, text: "hello")
                   })
    }

    func testWritesAndResolvesVoiceSamples() {
        var t = transcript(speakers: ["You", "Speaker 1"])
        let audio = [Float](repeating: 0.2, count: 32_000)
        t.voiceSamples = store.writeVoiceSamples(["Speaker 1": audio], for: t)

        XCTAssertEqual(t.voiceSamples?.count, 1)
        XCTAssertNotNil(store.voiceSampleURL(for: t, speaker: "Speaker 1"))
        XCTAssertNil(store.voiceSampleURL(for: t, speaker: "You"))
    }

    /// The sample becomes worth keeping exactly when the speaker is named, so
    /// the rename must carry it rather than orphan it.
    func testRenameCarriesTheVoiceSampleToTheNewLabel() {
        var t = transcript(speakers: ["You", "Speaker 1"])
        t.voiceSamples = store.writeVoiceSamples(
            ["Speaker 1": [Float](repeating: 0.2, count: 32_000)], for: t)

        XCTAssertTrue(t.renameSpeaker("Speaker 1", to: "Igor"))
        XCTAssertNil(t.voiceSamples?["Speaker 1"])
        XCTAssertNotNil(t.voiceSamples?["Igor"])
        XCTAssertNotNil(store.voiceSampleURL(for: t, speaker: "Igor"))
    }

    func testRenameWithoutASampleIsHarmless() {
        var t = transcript(speakers: ["You", "Speaker 1"])
        XCTAssertTrue(t.renameSpeaker("Speaker 1", to: "Igor"))
        XCTAssertNil(t.voiceSamples)
    }

    func testDeletingATranscriptRemovesItsVoiceSamples() {
        var t = transcript(speakers: ["You", "Speaker 1"])
        t.voiceSamples = store.writeVoiceSamples(
            ["Speaker 1": [Float](repeating: 0.2, count: 32_000)], for: t)
        store.save(t)
        let url = store.voiceSampleURL(for: t, speaker: "Speaker 1")
        XCTAssertNotNil(url)

        store.delete(t)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url!.path))
    }

    /// Deleting one Q&A entry identifies it by id, so those ids must survive
    /// a save/load round trip — otherwise the wrong answer gets deleted.
    func testChatMessageIdsSurviveSaveAndLoad() {
        var t = transcript(speakers: ["You"])
        t.chat = [ChatMessage(question: "what did Abel mention?", answer: "permissions"),
                  ChatMessage(question: "typo qustion", answer: "unclear"),
                  ChatMessage(question: "who owns the PR?", answer: "Andres")]
        let ids = t.chat.map(\.id)
        store.save(t)

        guard let loaded = store.load().first(where: { $0.id == t.id }) else {
            return XCTFail("transcript must reload")
        }
        XCTAssertEqual(loaded.chat.map(\.id), ids)

        // Delete the middle one the way the UI does.
        var edited = loaded
        edited.chat.removeAll { $0.id == ids[1] }
        store.save(edited)

        guard let reloaded = store.load().first(where: { $0.id == t.id }) else {
            return XCTFail("transcript must reload after deleting a Q&A")
        }
        XCTAssertEqual(reloaded.chat.map(\.question),
                       ["what did Abel mention?", "who owns the PR?"])
    }

    /// Transcripts written before voice samples existed must still load.
    func testTranscriptsWithoutVoiceSamplesStillDecode() {
        let json = """
        {"title":"Old","startedAt":"2026-01-01T10:00:00Z","endedAt":"2026-01-01T10:30:00Z",
         "segments":[{"id":"\(UUID().uuidString)","speaker":"You","start":0,"end":2,"text":"hi"}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try? decoder.decode(Transcript.self, from: Data(json.utf8))
        XCTAssertEqual(decoded?.title, "Old")
        XCTAssertNil(decoded?.voiceSamples)
    }
}
