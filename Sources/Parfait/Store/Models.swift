import Foundation

/// One utterance in a meeting transcript. Times are seconds from recording start.
struct TranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var speakerID: String
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

struct Speaker: Codable, Identifiable, Equatable, Sendable {
    /// Stable key referenced by TranscriptSegment.speakerID ("me", "s1", "s2", …).
    var id: String
    /// Display name, user-editable ("Me", "Speaker 1", "Alice").
    var name: String
    var isMe: Bool = false
}

enum MeetingState: String, Codable, Sendable {
    case recording
    case processing
    case ready
    case failed
}

struct Meeting: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date
    var duration: TimeInterval = 0
    /// App that triggered detection (e.g. "zoom.us"), if auto-detected.
    var sourceApp: String?
    var calendarEventTitle: String?
    /// Attendee names from the matched calendar event.
    var attendees: [String] = []
    var speakers: [Speaker] = []
    var state: MeetingState = .recording
    var templateName: String?
    /// Human-readable reason when state == .failed, or a non-fatal warning otherwise.
    var notice: String?
    var publishedURL: String?
    /// Which engine produced the summary: "apple" or "claude".
    var summaryProvider: String?
}

/// A commitment extracted from a meeting: an action item, open question, or
/// thing to chase. Written by Claude over MCP (save_followups); the app only
/// stores and displays them.
struct Followup: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case action
        case question
        case followup
    }

    enum Status: String, Codable, Sendable {
        case proposed
        case approved
        case inProgress = "in_progress"
        case done
        case dismissed
    }

    var id: UUID
    var kind: Kind
    var title: String
    /// Who's on the hook — an attendee/speaker name, or nil when unassigned.
    var owner: String?
    /// Verbatim transcript line the item was extracted from.
    var sourceQuote: String?
    var suggestedAction: String?
    var status: Status
    /// Link to whatever resolved the item (PR, doc, sent email…).
    var resultURL: String?
    var note: String?
    var createdAt: Date
    var updatedAt: Date
}

extension Meeting {
    static func placeholderTitle(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE h:mm a"
        return "Meeting · \(f.string(from: date))"
    }
}
