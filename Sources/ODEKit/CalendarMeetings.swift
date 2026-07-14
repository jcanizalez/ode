import Foundation
import EventKit

/// Looks up the calendar event happening right now, so meeting transcripts
/// get real titles ("Sprint Planning") and attendee names instead of
/// "11:09 AM Meeting". Works with any account macOS Calendar syncs
/// (iCloud, Google, Exchange/Outlook). Degrades silently: no access or no
/// event → callers fall back to AI/time-based titles.
public enum CalendarMeetings {
    private static let store = EKEventStore()

    /// Request full calendar access once; never re-prompt after a denial.
    /// (macOS 14+ API — the older requestAccess(to:) silently reports denied
    /// for full access on modern systems.)
    public static func ensureAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return true
        case .notDetermined:
            return (try? await store.requestFullAccessToEvents()) ?? false
        default:
            return false  // denied / restricted / write-only
        }
    }

    public struct CurrentMeeting {
        public let title: String
        public let attendeeFirstNames: [String]
    }

    /// The non-all-day event overlapping `date`, preferring the one whose
    /// start is closest to now (handles back-to-back meetings).
    public static func currentEvent(at date: Date = Date()) -> CurrentMeeting? {
        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-60),
            end: date.addingTimeInterval(60),
            calendars: nil)
        let candidates = store.events(matching: predicate).filter { !$0.isAllDay }
        guard let event = candidates.min(by: {
            abs($0.startDate.timeIntervalSince(date)) <
            abs($1.startDate.timeIntervalSince(date))
        }), let title = event.title,
              !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        let names = (event.attendees ?? [])
            .filter { $0.participantType == .person && !$0.isCurrentUser }
            .compactMap { $0.name?.split(separator: " ").first.map(String.init) }
        return CurrentMeeting(title: title, attendeeFirstNames: names)
    }
}
