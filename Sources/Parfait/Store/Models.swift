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
/// thing to chase. Extracted by the pipeline at summary time; curated in the
/// app's Follow-ups tab; worked and updated by Claude over MCP.
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

extension Followup {
    /// Still on the queue: anything not yet done or dismissed.
    var isOpen: Bool { status != .done && status != .dismissed }

    /// Owned by the local user: the extractor writes "me" (casing not
    /// guaranteed), while MCP writers may use the user's real name.
    func isMine(myName: String?) -> Bool {
        let owner = (owner ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty else { return false }
        if owner.caseInsensitiveCompare("me") == .orderedSame { return true }
        guard let myName, !myName.isEmpty else { return false }
        return owner.caseInsensitiveCompare(myName) == .orderedSame
    }

    /// Mine, or unassigned — unassigned items still need the user's triage,
    /// so they count as involving the user.
    func involvesMe(myName: String?) -> Bool {
        let owner = (owner ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return owner.isEmpty || isMine(myName: myName)
    }
}

extension Meeting {
    /// The local user's name as this meeting knows it: the isMe speaker's
    /// name (set from the account name at processing time, possibly edited
    /// since), falling back to the account name when absent.
    func localUserName(fallback: String = NSFullUserName()) -> String {
        if let name = speakers.first(where: { $0.isMe })?.name, !name.isEmpty {
            return name
        }
        return fallback
    }

    static func placeholderTitle(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE h:mm a"
        return "Meeting · \(f.string(from: date))"
    }
}
