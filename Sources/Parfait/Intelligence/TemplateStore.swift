import Foundation

/// Summary templates are plain markdown files the user can edit in-app (or in any editor).
/// A template is the *skeleton* of the summary: headings plus guidance for what goes under
/// each. Placeholders {{title}}, {{date}}, {{attendees}}, {{duration}}, {{app}} are filled
/// in before the transcript and template are handed to the model.
struct SummaryTemplate: Identifiable, Equatable, Sendable {
    var name: String        // filename without .md
    var body: String
    var id: String { name }
}

final class TemplateStore: @unchecked Sendable {
    let dir: URL

    init(root: URL = MeetingArchive.defaultRoot) {
        dir = root.appendingPathComponent("Templates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        seedIfEmpty()
    }

    func list() -> [SummaryTemplate] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "md" }
            .compactMap { url in
                guard let body = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return SummaryTemplate(name: url.deletingPathExtension().lastPathComponent, body: body)
            }
            .sorted { $0.name < $1.name }
    }

    func template(named name: String) -> SummaryTemplate? {
        // Case-insensitive to match create()/rename() collision semantics (and APFS) —
        // names are unique case-insensitively, so this can't be ambiguous.
        list().first { $0.name.lowercased() == name.lowercased() }
    }

    enum TemplateError: LocalizedError {
        case invalidName
        case nameTaken(String)

        var errorDescription: String? {
            switch self {
            case .invalidName:
                return "A template name can't contain “/” or “:”."
            case .nameTaken(let name):
                return "A template named “\(name)” already exists."
            }
        }
    }

    static func isValid(name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.contains("/") && !trimmed.contains(":")
    }

    func save(_ template: SummaryTemplate) throws {
        guard Self.isValid(name: template.name) else { throw TemplateError.invalidName }
        let url = dir.appendingPathComponent(template.name + ".md")
        try template.body.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    /// Rename with safety: reject invalid names, refuse to overwrite a different
    /// template, and write-before-delete so a crash can't lose the body. A
    /// case-only rename on case-insensitive APFS is the same file, so the delete
    /// is skipped.
    func rename(from oldName: String, to newName: String, body: String) throws {
        guard Self.isValid(name: newName) else { throw TemplateError.invalidName }
        if newName == oldName {
            try save(SummaryTemplate(name: newName, body: body))
            return
        }
        let oldURL = dir.appendingPathComponent(oldName + ".md")
        let newURL = dir.appendingPathComponent(newName + ".md")

        // Case-only rename ("notes" → "Notes"): on case-insensitive APFS a plain
        // write onto the case-variant keeps the old directory-entry case, so the
        // rename appears to do nothing. moveItem performs the actual case change.
        if oldName.lowercased() == newName.lowercased() {
            try body.data(using: .utf8)!.write(to: oldURL, options: .atomic)
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            return
        }
        if list().contains(where: { $0.name.lowercased() == newName.lowercased() }) {
            throw TemplateError.nameTaken(newName)
        }
        // Write-before-delete so a crash can't lose the body.
        try save(SummaryTemplate(name: newName, body: body))
        try? FileManager.default.removeItem(at: oldURL)
    }

    func delete(named name: String) throws {
        try FileManager.default.removeItem(at: dir.appendingPathComponent(name + ".md"))
    }

    /// Create-only variant of save(): fails if a template with this name already
    /// exists (case-insensitively), so MCP callers can't silently clobber one.
    func create(name: String, body: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard Self.isValid(name: trimmed) else { throw TemplateError.invalidName }
        if list().contains(where: { $0.name.lowercased() == trimmed.lowercased() }) {
            throw TemplateError.nameTaken(trimmed)
        }
        try save(SummaryTemplate(name: trimmed, body: body))
    }

    private func seedIfEmpty() {
        guard list().isEmpty else { return }
        for t in Self.builtins { try? save(t) }
    }

    static let builtins: [SummaryTemplate] = [
        SummaryTemplate(name: "Meeting Notes", body: """
        # {{title}}

        {{date}} · {{attendees}}

        ## TL;DR
        Two or three sentences capturing what this meeting was about and where it landed.

        ## Key Points
        The main topics discussed, as short bullets grouped by theme.

        ## Decisions
        Anything that was decided. If nothing was decided, omit this section.

        ## Action Items
        - [ ] Task — owner (use names from the transcript when clear)

        ## Open Questions
        Unresolved threads worth following up on. Omit if none.
        """),
        SummaryTemplate(name: "1-on-1", body: """
        # {{title}}

        {{date}} · {{attendees}}

        ## How they're doing
        Mood, energy, anything personal that came up.

        ## Updates
        What they're working on and how it's going.

        ## Feedback & Coaching
        Feedback given or received, in either direction.

        ## Commitments
        - [ ] What each person agreed to do before next time.
        """),
        SummaryTemplate(name: "Interview", body: """
        # {{title}}

        {{date}} · {{attendees}}

        ## Candidate Snapshot
        Role, background, and overall impression in two sentences.

        ## Strengths
        Concrete evidence from the conversation.

        ## Concerns
        Gaps, risks, or things to probe in later rounds.

        ## Notable Answers
        Question → what they said, for the strongest moments.

        ## Recommendation
        Hire signal and suggested next step.
        """),
    ]
}

enum TemplateRenderer {
    /// Substitute {{placeholders}} with meeting metadata. The transcript is NOT substituted
    /// here — it travels separately in the model prompt.
    static func fill(_ template: String, meeting: Meeting) -> String {
        let df = DateFormatter()
        df.dateStyle = .full
        df.timeStyle = .short
        var out = template
        let attendees = meeting.attendees.isEmpty
            ? meeting.speakers.map(\.name).joined(separator: ", ")
            : meeting.attendees.joined(separator: ", ")
        let subs: [String: String] = [
            "{{title}}": meeting.title,
            "{{date}}": df.string(from: meeting.createdAt),
            "{{attendees}}": attendees,
            "{{duration}}": Self.duration(meeting.duration),
            "{{app}}": meeting.sourceApp ?? "",
        ]
        for (k, v) in subs { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }

    static func duration(_ t: TimeInterval) -> String {
        let mins = Int((t / 60).rounded())
        if mins < 60 { return "\(mins) min" }
        return "\(mins / 60) hr \(mins % 60) min"
    }
}
