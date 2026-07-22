import EventKit
import Foundation

/// A not-yet-started calendar event worth pre-meeting attention: it has other
/// attendees or a join link. Drives the floating card's upcoming state.
struct UpcomingEvent: Equatable, Sendable {
    var title: String
    var attendees: [String]
    var startDate: Date
    /// Lets the card's linger stop at the event's end — a 5-minute event must
    /// not keep offering "Join & record" for the full 10-minute linger.
    var endDate: Date
    /// Video-call join URL, when one was found on the event.
    var link: URL?
    /// eventIdentifier alone is shared by every instance of a recurring event,
    /// so "already shown" tracking keys on identifier + occurrence start.
    var occurrenceKey: String
}

/// Matches calendar events so meetings can inherit titles and attendees — the
/// in-progress one at record time, plus the next upcoming one for the
/// pre-meeting card.
enum CalendarMatcher {
    static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    static var isDenied: Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        // .writeOnly counts as denied: read APIs return zero events under it,
        // and re-requesting full access won't re-prompt.
        case .denied, .restricted, .writeOnly: return true
        default: return false
        }
    }

    static func requestAccess() async -> Bool {
        (try? await EKEventStore().requestFullAccessToEvents()) ?? false
    }

    static func currentEvent() async -> (title: String, attendees: [String])? {
        guard isAuthorized else { return nil }
        // events(matching:) is synchronous/blocking — keep it off the main actor.
        // Fresh store per call: stores created before access was granted keep returning nothing.
        return await Task.detached { () -> (title: String, attendees: [String])? in
            let store = EKEventStore()
            let now = Date()
            // Predicate matches events OVERLAPPING the window; the wide start catches
            // long-running meetings, then we filter to truly in-progress ones.
            let predicate = store.predicateForEvents(
                withStart: now.addingTimeInterval(-4 * 3600),
                end: now.addingTimeInterval(60),
                calendars: nil)

            let event = store.events(matching: predicate)
                .filter { !$0.isAllDay && $0.startDate <= now && now < $0.endDate }
                .max { $0.startDate < $1.startDate }
            guard let event else { return nil }
            return (event.title ?? "Untitled event", attendeeNames(of: event))
        }.value
    }

    /// Every event starting within `window` that deserves a pre-meeting card,
    /// earliest first: not all-day, not already started (that's currentEvent's
    /// job), and not declined by the user. Solo blocks with neither other
    /// attendees nor a join link (focus time, reminders-as-events) are skipped —
    /// there's nothing to join and no one to get a scoop on. The full list (not
    /// just the first) lets the poll tell "deleted" from "superseded by an
    /// earlier event", and lets a lingering card yield to the next meeting.
    static func upcomingEvents(within window: TimeInterval) async -> [UpcomingEvent] {
        guard isAuthorized else { return [] }
        return await Task.detached { () -> [UpcomingEvent] in
            let store = EKEventStore()
            let now = Date()
            let predicate = store.predicateForEvents(
                withStart: now, end: now.addingTimeInterval(window), calendars: nil)

            return store.events(matching: predicate)
                .filter { !$0.isAllDay && $0.startDate > now && !isDeclined($0) }
                .sorted { $0.startDate < $1.startDate }
                .compactMap { event in
                    let attendees = attendeeNames(of: event)
                    let link = meetingLink(url: event.url, location: event.location, notes: event.notes)
                    guard !attendees.isEmpty || link != nil else { return nil }
                    return UpcomingEvent(
                        title: event.title ?? "Untitled event",
                        attendees: attendees,
                        startDate: event.startDate,
                        endDate: event.endDate,
                        link: link,
                        occurrenceKey: "\(event.eventIdentifier ?? "unknown")@\(Int(event.startDate.timeIntervalSince1970))")
                }
        }.value
    }

    /// Display names of the other participants.
    private static func attendeeNames(of event: EKEvent) -> [String] {
        (event.attendees ?? [])
            .filter { !$0.isCurrentUser }
            .compactMap { participant -> String? in
                if let name = participant.name, !name.isEmpty { return name }
                // EKParticipant has no email property; it lives in the mailto: url.
                let s = participant.url.absoluteString
                return s.hasPrefix("mailto:") ? String(s.dropFirst(7)) : s
            }
    }

    /// The user declined — don't nag them to join a meeting they're skipping.
    private static func isDeclined(_ event: EKEvent) -> Bool {
        (event.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined }
    }

    // MARK: - Join links

    /// Hosts that unambiguously mean "video call". Subdomains count
    /// (us02web.zoom.us, company.webex.com).
    private static let meetingHosts = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "webex.com", "whereby.com", "meet.jit.si", "gotomeeting.com",
    ]

    /// The event's join link: the URL field when it's a known provider, else
    /// the first provider https link found scanning location then notes
    /// (Google and Outlook invites bury the link in HTML-ish notes).
    static func meetingLink(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, isMeetingHost(url.host) { return url }
        for text in [location, notes] {
            guard let text, let link = firstMeetingLink(in: text) else { continue }
            return link
        }
        return nil
    }

    private static func isMeetingHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return meetingHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    private static func firstMeetingLink(in text: String) -> URL? {
        // NSDataDetector over a hand-rolled regex: it already handles links
        // embedded in HTML attributes, trailing punctuation, and parentheses.
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector
            .matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap(\.url)
            .first { $0.scheme == "https" && isMeetingHost($0.host) }
    }
}
