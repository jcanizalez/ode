import Foundation

/// How a speaker is identified at a glance: which colour slot they get, and
/// the letters on their avatar.
///
/// Lives here rather than in the view so the two properties that matter can
/// be tested: the colour must be the *same every launch* (it is how you
/// recognise someone across the window), and two different speakers in one
/// meeting should not end up with the same badge.
public enum SpeakerBadge {
    /// Number of colour slots the app maps `paletteIndex` onto.
    ///
    /// Discrete slots rather than a continuous hue: hashing straight to a
    /// hue let two speakers land a few degrees apart and read as the same
    /// colour. Ten well-separated hues can collide, but never *nearly*
    /// collide — and a collision is obvious rather than subtly misleading.
    public static let paletteSize = 10

    /// Stable colour slot for a speaker label.
    ///
    /// Uses FNV-1a rather than `String.hashValue`: Swift seeds its hasher
    /// per process, so `hashValue` gave every speaker a different colour on
    /// every launch of the app.
    public static func paletteIndex(for speaker: String) -> Int {
        Int(fnv1a(speaker.lowercased()) % UInt64(paletteSize))
    }

    /// Colour slots for everyone in one meeting.
    ///
    /// `paletteIndex` alone is not enough: with ten slots and five speakers,
    /// two of them share a colour about half the time. Each speaker takes
    /// their preferred slot, and a speaker who wants a taken one steps to
    /// the next free slot — so nobody in a meeting shares a colour until
    /// there are more than ten of them.
    ///
    /// Deterministic for a given ordered speaker list, and the transcript's
    /// order is first-appearance, so the earlier speaker keeps their
    /// preferred colour and later ones move. "You" and "Others" are styled
    /// separately and deliberately consume no slot.
    public static func paletteIndices(for speakers: [String]) -> [String: Int] {
        var taken = Set<Int>()
        var assigned: [String: Int] = [:]
        for speaker in speakers {
            let key = speaker.lowercased()
            guard key != "you", key != "others", assigned[speaker] == nil else { continue }
            var index = paletteIndex(for: speaker)
            // Once every slot is taken, collisions are unavoidable — stop
            // probing rather than spinning.
            if taken.count < paletteSize {
                while taken.contains(index) { index = (index + 1) % paletteSize }
            }
            taken.insert(index)
            assigned[speaker] = index
        }
        return assigned
    }

    /// Letters for the avatar.
    ///
    /// Diarized labels all begin with "Speaker", so their first letter
    /// identifies nothing — the number is the whole identity. Single names
    /// get two letters, because one initial made "Andres" and "Abel" the
    /// same badge.
    public static func initials(for speaker: String) -> String {
        let trimmed = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("you") == .orderedSame { return "Y" }
        if trimmed.caseInsensitiveCompare("others") == .orderedSame { return "O" }
        if let number = speakerNumber(trimmed) { return number }

        let words = trimmed.split(separator: " ")
        if words.count >= 2 {
            return words.prefix(2).map { $0.prefix(1).uppercased() }.joined()
        }
        guard let first = trimmed.first else { return "?" }
        guard trimmed.count > 1 else { return String(first).uppercased() }
        let second = trimmed[trimmed.index(after: trimmed.startIndex)]
        return String(first).uppercased() + String(second).lowercased()
    }

    /// "Speaker 4" → "4". Nil for anything else, including a real name that
    /// happens to start with the word.
    private static func speakerNumber(_ speaker: String) -> String? {
        let parts = speaker.split(separator: " ")
        guard parts.count == 2,
              parts[0].caseInsensitiveCompare("speaker") == .orderedSame,
              Int(parts[1]) != nil else { return nil }
        return String(parts[1])
    }

    /// FNV-1a over UTF-8. Small, dependency-free, and — unlike Swift's
    /// built-in hashing — identical on every run and every machine.
    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }
}
