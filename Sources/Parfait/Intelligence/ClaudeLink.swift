import Foundation

/// The single deep-link builder for every Claude handoff surface. Prompts open
/// via ClaudeDesktop.openNewChat and name the plugin's skills on the first line
/// (`/parfait:dig-in`, `/parfait:scoop`) so they route into the skill when the
/// parfait plugin is installed; the parenthesized sentence after describes the
/// task naturally so the prompt still works without it.
enum ClaudeLink {
    static func digInPrompt(meetingID: UUID, title: String) -> String {
        """
        /parfait:dig-in \(meetingID.uuidString)

        (Dig into my Parfait meeting "\(title)" — id \(meetingID.uuidString): review the notes, \
        extract commitments and follow-ups, and help me act on them.)
        """
    }

    /// Generic "open this meeting in Claude" — no skill, just steers Claude to
    /// the parfait tools by naming the meeting and its id.
    static func meetingPrompt(meetingID: UUID, title: String) -> String {
        """
        Give me a quick overview of my Parfait meeting "\(title)" (id: \(meetingID.uuidString)) \
        — key decisions and action items.
        """
    }

    static func libraryPrompt() -> String {
        """
        Answer using my Parfait meetings:

        What have I been talking about across my recent meetings?
        """
    }

    /// For the "Ask Claude live" button during a recording. Claude has the live
    /// transcript tool available and uses it on its own.
    static func livePrompt() -> String {
        "I'm in a Parfait meeting happening right now — What's being discussed, and is there anything I should add or ask?"
    }

    static func scoopPrompt(eventTitle: String?) -> String {
        let title = eventTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let skill = title.isEmpty ? "/parfait:scoop" : "/parfait:scoop \(title)"
        let subject = title.isEmpty ? "my upcoming meeting" : "my upcoming meeting \"\(title)\""
        return """
        \(skill)

        (Get me the scoop before \(subject) — pull my past Parfait meetings with the same people, \
        open commitments, and anything I should know going in.)
        """
    }

    @discardableResult
    static func open(prompt: String) -> Bool {
        ClaudeDesktop.openNewChat(prompt: prompt)
    }

    @discardableResult
    static func openDigIn(meetingID: UUID, title: String) -> Bool {
        open(prompt: digInPrompt(meetingID: meetingID, title: title))
    }

    @discardableResult
    static func openScoop(eventTitle: String?) -> Bool {
        open(prompt: scoopPrompt(eventTitle: eventTitle))
    }
}
