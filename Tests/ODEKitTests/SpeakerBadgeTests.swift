import XCTest
@testable import ODEKit

/// Telling speakers apart at a glance. Colour used to come from
/// `String.hashValue`, which Swift seeds per process — so everyone changed
/// colour on every launch — and every diarized speaker showed the same "S".
final class SpeakerBadgeTests: XCTestCase {

    // MARK: - Colour is stable

    /// The property that broke: these are literals, not computed from the
    /// implementation, so a change to the hash fails here rather than
    /// silently reshuffling everyone's colour in the next release.
    func testPaletteIndexIsPinnedAcrossLaunchesAndBuilds() {
        XCTAssertEqual(SpeakerBadge.paletteIndex(for: "Andres"), 0)
        XCTAssertEqual(SpeakerBadge.paletteIndex(for: "Abel"), 7)
        XCTAssertEqual(SpeakerBadge.paletteIndex(for: "Speaker 1"), 7)
        XCTAssertEqual(SpeakerBadge.paletteIndex(for: "Speaker 4"), 2)
    }

    func testSameNameAlwaysGetsTheSameSlot() {
        for name in ["Igor", "Ana Ruiz", "Speaker 2", "José"] {
            let first = SpeakerBadge.paletteIndex(for: name)
            XCTAssertEqual(SpeakerBadge.paletteIndex(for: name), first)
        }
    }

    /// Renaming "Speaker 2" to "Igor" is meant to change their colour — the
    /// badge tracks the name, not a slot number.
    func testDifferentNamesGetDifferentSlots() {
        XCTAssertNotEqual(SpeakerBadge.paletteIndex(for: "Andres"),
                          SpeakerBadge.paletteIndex(for: "Abel"))
    }

    func testCaseDoesNotChangeTheSlot() {
        XCTAssertEqual(SpeakerBadge.paletteIndex(for: "Igor"),
                       SpeakerBadge.paletteIndex(for: "IGOR"))
    }

    func testIndexIsAlwaysInsideThePalette() {
        let names = ["", "A", "Speaker 1", "Ana Ruiz", "José", "日本語",
                     String(repeating: "x", count: 500)]
        for name in names {
            let index = SpeakerBadge.paletteIndex(for: name)
            XCTAssertTrue((0..<SpeakerBadge.paletteSize).contains(index),
                          "\(name) produced out-of-range slot \(index)")
        }
    }

    /// Four speakers is the diarizer's ceiling, so the common case must not
    /// collide even though ten slots can in principle.
    func testTheFourDiarizedLabelsAllGetDistinctSlots() {
        let slots = (1...4).map { SpeakerBadge.paletteIndex(for: "Speaker \($0)") }
        XCTAssertEqual(Set(slots).count, 4, "diarized speakers share a colour: \(slots)")
    }

    // MARK: - Collisions inside one meeting

    /// The reported case. "Abel" and "Speaker 1" both prefer slot 7, so a
    /// pure hash gives them the same colour in the same meeting.
    func testCollidingSpeakersGetDifferentSlotsInTheSameMeeting() {
        XCTAssertEqual(SpeakerBadge.paletteIndex(for: "Abel"),
                       SpeakerBadge.paletteIndex(for: "Speaker 1"),
                       "precondition: these two collide on preference")

        let assigned = SpeakerBadge.paletteIndices(
            for: ["Andres", "Abel", "Speaker 4", "You", "Speaker 1"])
        XCTAssertNotEqual(assigned["Abel"], assigned["Speaker 1"])
    }

    func testEveryoneInAMeetingGetsADistinctSlot() {
        let speakers = ["Andres", "Abel", "Speaker 4", "You", "Speaker 1"]
        let assigned = SpeakerBadge.paletteIndices(for: speakers)
        XCTAssertEqual(Set(assigned.values).count, assigned.count)
    }

    /// First-appearance order decides who keeps their preferred colour, so
    /// the same meeting always renders the same way.
    func testAssignmentIsStableForTheSameSpeakerList() {
        let speakers = ["Abel", "Speaker 1", "Igor", "Ana Ruiz"]
        XCTAssertEqual(SpeakerBadge.paletteIndices(for: speakers),
                       SpeakerBadge.paletteIndices(for: speakers))
    }

    func testTheEarlierSpeakerKeepsThePreferredSlot() {
        let assigned = SpeakerBadge.paletteIndices(for: ["Abel", "Speaker 1"])
        XCTAssertEqual(assigned["Abel"], SpeakerBadge.paletteIndex(for: "Abel"))
        XCTAssertNotEqual(assigned["Speaker 1"], SpeakerBadge.paletteIndex(for: "Speaker 1"))
    }

    /// "You" and "Others" are styled separately, so they must not eat a slot
    /// that a real speaker could have used.
    func testReservedLabelsAreNotAssignedASlot() {
        let assigned = SpeakerBadge.paletteIndices(for: ["You", "Others", "Igor"])
        XCTAssertNil(assigned["You"])
        XCTAssertNil(assigned["Others"])
        XCTAssertEqual(assigned.count, 1)
    }

    func testDuplicateNamesResolveToOneSlot() {
        let assigned = SpeakerBadge.paletteIndices(for: ["Igor", "Igor", "Ana"])
        XCTAssertEqual(assigned.count, 2)
    }

    /// More speakers than colours must still terminate and assign everyone.
    func testMoreSpeakersThanColoursStillAssignsEveryone() {
        let speakers = (1...25).map { "Person \($0)" }
        let assigned = SpeakerBadge.paletteIndices(for: speakers)
        XCTAssertEqual(assigned.count, 25)
        for index in assigned.values {
            XCTAssertTrue((0..<SpeakerBadge.paletteSize).contains(index))
        }
    }

    func testEmptyMeetingAssignsNothing() {
        XCTAssertTrue(SpeakerBadge.paletteIndices(for: []).isEmpty)
    }

    // MARK: - Initials distinguish

    /// Every diarized label starts with "Speaker", so the first letter
    /// identifies nothing — all four used to show "S".
    func testDiarizedSpeakersAreLabelledByTheirNumber() {
        XCTAssertEqual(SpeakerBadge.initials(for: "Speaker 1"), "1")
        XCTAssertEqual(SpeakerBadge.initials(for: "Speaker 4"), "4")
        XCTAssertEqual(SpeakerBadge.initials(for: "Speaker 12"), "12")
    }

    /// The reported bug: one initial made these the same badge.
    func testSingleNamesUseTwoLettersSoSimilarNamesDiffer() {
        XCTAssertEqual(SpeakerBadge.initials(for: "Andres"), "An")
        XCTAssertEqual(SpeakerBadge.initials(for: "Abel"), "Ab")
        XCTAssertNotEqual(SpeakerBadge.initials(for: "Andres"),
                          SpeakerBadge.initials(for: "Abel"))
    }

    func testFullNamesUseOneLetterPerWord() {
        XCTAssertEqual(SpeakerBadge.initials(for: "Ana Ruiz"), "AR")
        XCTAssertEqual(SpeakerBadge.initials(for: "igor petrov sanchez"), "IP")
    }

    func testYouAndOthersKeepTheirLetters() {
        XCTAssertEqual(SpeakerBadge.initials(for: "You"), "Y")
        XCTAssertEqual(SpeakerBadge.initials(for: "you"), "Y")
        XCTAssertEqual(SpeakerBadge.initials(for: "Others"), "O")
    }

    /// A real person called "Speaker" is not a diarizer label.
    func testAWordThatMerelyStartsWithSpeakerIsNotANumber() {
        XCTAssertEqual(SpeakerBadge.initials(for: "Speaker"), "Sp")
        XCTAssertEqual(SpeakerBadge.initials(for: "Speakerphone Bob"), "SB")
        XCTAssertEqual(SpeakerBadge.initials(for: "Speaker Bob"), "SB")
    }

    func testHandlesShortAndEmptyNames() {
        XCTAssertEqual(SpeakerBadge.initials(for: "A"), "A")
        XCTAssertEqual(SpeakerBadge.initials(for: ""), "?")
        XCTAssertEqual(SpeakerBadge.initials(for: "   "), "?")
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(SpeakerBadge.initials(for: "  Igor  "), "Ig")
        XCTAssertEqual(SpeakerBadge.initials(for: " Speaker 3 "), "3")
    }

    func testAccentedNamesKeepTheirLetters() {
        XCTAssertEqual(SpeakerBadge.initials(for: "José"), "Jo")
        XCTAssertEqual(SpeakerBadge.initials(for: "Ángela Ruiz"), "ÁR")
    }
}
