import Foundation

/// A remembered voice: a person's name plus a few seconds of their speech.
///
/// Sortformer has no persistent speaker database — `enrollSpeaker` is
/// *priming*: you hand it audio and a name before the meeting starts, and it
/// carries that name on the matching slot for the rest of the session. So
/// "remembering" a voice across meetings means keeping the audio ourselves
/// and replaying it at every session start.
///
/// The sample lives beside the metadata as `<id>.wav`, 16 kHz mono — a few
/// seconds each, and playable if you ever want to hear what ODE kept.
public struct VoiceProfile: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    /// Duration of the stored sample. Surfaced in Settings so a too-thin
    /// sample — which enrolls badly — is visible rather than mysterious.
    public var seconds: Double

    public init(id: UUID = UUID(), name: String,
                createdAt: Date = Date(), seconds: Double) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.seconds = seconds
    }
}

public extension Notification.Name {
    /// Posted after a voice profile is added, renamed, or deleted.
    static let odeVoiceProfilesChanged = Notification.Name("odeVoiceProfilesChanged")
}

/// Stores voice profiles under Application Support/ODE/Voices.
public final class VoiceProfileStore {
    public static let shared = VoiceProfileStore()

    /// Enrollment audio is fed straight to Sortformer, which consumes
    /// 16 kHz mono.
    public static let sampleRate: Double = 16_000

    /// Shortest sample worth keeping. Below this, enrollment reliably
    /// mislabels — better to keep "Speaker 2" than to confidently print the
    /// wrong person's name.
    public static let minimumSeconds: Double = 1.5

    /// Longest sample kept. Enrollment quality plateaus quickly and every
    /// profile is replayed at the start of every meeting.
    public static let maximumSeconds: Double = 8

    public let directory: URL
    private let lock = NSLock()

    public convenience init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        self.init(directory: base.appendingPathComponent("ODE/Voices", isDirectory: true))
    }

    /// Store rooted at a custom directory (tests use a temp dir).
    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
    }

    private var indexURL: URL { directory.appendingPathComponent("profiles.json") }
    private func audioURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).wav")
    }

    // MARK: - Reading

    /// All saved profiles, newest first.
    public func all() -> [VoiceProfile] {
        lock.lock(); defer { lock.unlock() }
        return loadIndexLocked().sorted { $0.createdAt > $1.createdAt }
    }

    /// The enrollment audio for a profile, at 16 kHz mono.
    public func samples(for id: UUID) -> [Float]? {
        let url = audioURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? AudioIO.readSamples(url: url, sampleRate: Self.sampleRate)
    }

    /// Every profile paired with its audio, ready to prime a diarizer.
    /// Profiles whose audio has gone missing are skipped rather than
    /// enrolled empty — an empty enrollment silently claims a speaker slot.
    public func enrollable() -> [(name: String, samples: [Float])] {
        all().compactMap { profile in
            guard let s = samples(for: profile.id), !s.isEmpty else { return nil }
            return (profile.name, s)
        }
    }

    // MARK: - Writing

    /// Remember `samples` as `name`, replacing any existing profile with the
    /// same name (case-insensitively) so naming the same person in a later
    /// meeting refreshes their sample instead of accumulating duplicates.
    ///
    /// Returns nil when the sample is too short to enroll usefully.
    @discardableResult
    public func save(name: String, samples: [Float]) -> VoiceProfile? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let seconds = Double(samples.count) / Self.sampleRate
        guard !trimmed.isEmpty, seconds >= Self.minimumSeconds else { return nil }

        // Keep the tail: the most recent speech is likeliest to be clean
        // continuous talking rather than the crosstalk that often opens a call.
        let cap = Int(Self.maximumSeconds * Self.sampleRate)
        let clipped = samples.count > cap ? Array(samples.suffix(cap)) : samples

        lock.lock()
        var index = loadIndexLocked()
        let existing = index.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        let profile = VoiceProfile(id: existing?.id ?? UUID(), name: trimmed,
                                   seconds: Double(clipped.count) / Self.sampleRate)
        index.removeAll { $0.id == profile.id }
        index.append(profile)
        do {
            try AudioIO.writeWav(samples: clipped, url: audioURL(profile.id),
                                 sampleRate: Self.sampleRate)
            try writeIndexLocked(index)
        } catch {
            lock.unlock()
            NSLog("ODE: failed to save voice profile: \(error.localizedDescription)")
            return nil
        }
        lock.unlock()
        NotificationCenter.default.post(name: .odeVoiceProfilesChanged, object: nil)
        return profile
    }

    public func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        var index = loadIndexLocked()
        guard let i = index.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }
        index[i].name = trimmed
        try? writeIndexLocked(index)
        lock.unlock()
        NotificationCenter.default.post(name: .odeVoiceProfilesChanged, object: nil)
    }

    public func delete(_ id: UUID) {
        lock.lock()
        var index = loadIndexLocked()
        index.removeAll { $0.id == id }
        try? writeIndexLocked(index)
        try? FileManager.default.removeItem(at: audioURL(id))
        lock.unlock()
        NotificationCenter.default.post(name: .odeVoiceProfilesChanged, object: nil)
    }

    // MARK: - private

    private func loadIndexLocked() -> [VoiceProfile] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([VoiceProfile].self, from: data)) ?? []
    }

    private func writeIndexLocked(_ profiles: [VoiceProfile]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(profiles).write(to: indexURL)
    }
}
