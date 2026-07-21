import Foundation

/// The single deep-link builder for every Claude handoff surface. Prompts open
/// via ClaudeDesktop.openNewChat and name the plugin's skills on the first line
/// (`/parfait:followups`, `/parfait:scoop`) so they route into the skill when
/// the parfait plugin is installed; the parenthesized sentence after describes
/// the task naturally so the prompt still works without it.
enum ClaudeLink {
    /// What a follow-ups handoff covers: the whole queue, one meeting's items,
    /// or a single item. The skill parses the first prompt line, so the arg
    /// formats here are a contract with `skills/followups`.
    enum FollowupScope {
        case all
        case meeting(id: UUID, title: String)
        case item(meetingID: UUID, itemID: UUID, title: String)
    }

    /// Titles are transcript/LLM-derived and headed into a chat prompt inside
    /// quotes — strip quotes and newlines and cap length so a hostile title
    /// can't break out of the sentence (same guard as the follow-up card's
    /// promptTitle in FollowupCard.html).
    static func promptTitle(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "\"", with: "'")
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(120))
    }

    static func followupsPrompt(scope: FollowupScope) -> String {
        switch scope {
        case .all:
            return """
            /parfait:followups

            (Work through my open Parfait follow-ups: read them with get_all_followups, \
            do each item's instructions, and record results.)
            """
        case .meeting(let id, let title):
            return """
            /parfait:followups meeting \(id.uuidString)

            (Work through the open follow-ups from my Parfait meeting "\(promptTitle(title))": \
            read them with get_all_followups, do each item's instructions, and record results.)
            """
        case .item(let meetingID, let itemID, let title):
            return """
            /parfait:followups item \(meetingID.uuidString) \(itemID.uuidString)

            (Work on my Parfait follow-up "\(promptTitle(title))": read it with get_all_followups, \
            do its instructions, and record the result.)
            """
        }
    }

    /// Generic "open this meeting in Claude" — no skill, just steers Claude to
    /// the parfait tools by naming the meeting and its id.
    static func meetingPrompt(meetingID: UUID, title: String) -> String {
        """
        Give me a quick overview of my Parfait meeting "\(promptTitle(title))" (id: \(meetingID.uuidString)) \
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
        let title = eventTitle.map(promptTitle) ?? ""
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
    static func openFollowups(scope: FollowupScope) -> Bool {
        open(prompt: followupsPrompt(scope: scope))
    }

    @discardableResult
    static func openScoop(eventTitle: String?) -> Bool {
        open(prompt: scoopPrompt(eventTitle: eventTitle))
    }
}
