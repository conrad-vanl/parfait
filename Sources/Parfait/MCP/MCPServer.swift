import Foundation

/// A minimal MCP (Model Context Protocol) stdio server exposing the meeting archive
/// to Claude. JSON-RPC 2.0, one message per line on stdin/stdout, logs to stderr.
///
///     claude mcp add parfait -- /Applications/Parfait.app/Contents/MacOS/Parfait --mcp
final class MCPServer {
    /// Newest first. We echo the client's version when we support it (spec rule);
    /// otherwise we offer our latest and let the client decide.
    static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]

    private let archive: MeetingArchive
    private let templates: TemplateStore

    init(archive: MeetingArchive, templates: TemplateStore) {
        self.archive = archive
        self.templates = templates
    }

    func runBlocking() {
        FileHandle.standardError.write(Data("parfait mcp server ready (\(archive.root.path))\n".utf8))
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            if let response = handle(line: line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }

    /// Returns the JSON response string, or nil for notifications.
    func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return encode(errorID: NSNull(), code: -32700, message: "Parse error")
        }
        let method = message["method"] as? String ?? ""
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]

        // Notifications (no id) get no response.
        if id == nil {
            return nil
        }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let version = Self.supportedProtocolVersions.contains(requested)
                ? requested : Self.supportedProtocolVersions[0]
            return encode(resultID: id!, result: [
                "protocolVersion": version,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "parfait", "title": "Parfait", "version": Bootstrap.version],
            ])
        case "ping":
            return encode(resultID: id!, result: [:])
        case "tools/list":
            return encode(resultID: id!, result: ["tools": Self.toolDefinitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            guard Self.toolDefinitions.contains(where: { $0["name"] as? String == name }) else {
                // Unknown tool is a protocol error; execution failures below are soft
                // isError results so the model can self-correct.
                return encode(errorID: id!, code: -32602, message: "Unknown tool: \(name)")
            }
            do {
                let text = try call(tool: name, arguments: args)
                return encode(resultID: id!, result: [
                    "content": [["type": "text", "text": text]],
                    "isError": false,
                ])
            } catch {
                return encode(resultID: id!, result: [
                    "content": [["type": "text", "text": "Error: \(error.localizedDescription)"]],
                    "isError": true,
                ])
            }
        default:
            return encode(errorID: id!, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Tools

    static let toolDefinitions: [[String: Any]] = [
        [
            "name": "list_meetings",
            "description": "List recent meetings (id, title, date, duration, attendees). Newest first.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": ["type": "integer", "description": "Max meetings to return (default 20)"],
                ],
            ] as [String: Any],
        ],
        [
            "name": "search_meetings",
            "description": "Full-text search across meeting titles, summaries, transcripts, and attendees. Returns matching meetings with excerpt lines (speaker + timestamp).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Words to search for"],
                ],
                "required": ["query"],
            ] as [String: Any],
        ],
        [
            "name": "get_meeting",
            "description": "Get one meeting's metadata and full summary by id.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Meeting UUID from list_meetings/search_meetings"],
                ],
                "required": ["id"],
            ] as [String: Any],
        ],
        [
            "name": "get_transcript",
            "description": "Get one meeting's full transcript with speakers and timestamps, by id.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Meeting UUID"],
                ],
                "required": ["id"],
            ] as [String: Any],
        ],
        [
            "name": "get_live_transcript",
            "description": "Get the transcript of the meeting happening RIGHT NOW, to answer a question during a live, in-progress meeting. Returns only the most recent minutes by default (the user is mid-meeting and wants a fast answer); pass a larger \"minutes\", or minutes=0 for the whole meeting so far, when a question needs earlier context. The text is a real-time approximation — it may lag a few seconds behind and isn't final. Says so plainly if no meeting is being recorded.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "minutes": ["type": "integer", "description": "How many recent minutes of transcript to return. Omit for the last few minutes; use 0 for the entire meeting so far."],
                ] as [String: Any],
                "additionalProperties": false,
            ] as [String: Any],
        ],
        [
            "name": "update_summary",
            "description": "Replace a meeting's notes (its summary) with new Markdown text, by id. Use this to save edits to the notes; it overwrites the current notes in full.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Meeting UUID"],
                    "content": ["type": "string", "description": "New notes as Markdown, replacing the current notes in full"],
                ],
                "required": ["id", "content"],
            ] as [String: Any],
        ],
        [
            "name": "regenerate_summary",
            "description": "Re-summarize a meeting from its transcript, by id, using the on-device model (falling back to the user's Claude account for long meetings). Optionally switch the template first. Returns the new notes. Fails if the meeting has no transcript yet.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Meeting UUID"],
                    "template": ["type": "string", "description": "Optional template name to summarize with (see list_templates). Defaults to the meeting's current template."],
                ],
                "required": ["id"],
            ] as [String: Any],
        ],
        [
            "name": "list_templates",
            "description": "List the user's summary templates by name, with each one's heading outline (## sections). Templates are the markdown skeletons Parfait fills in to summarize a meeting.",
            "inputSchema": [
                "type": "object",
                "properties": [:] as [String: Any],
                "additionalProperties": false,
            ] as [String: Any],
        ],
        [
            "name": "get_template",
            "description": "Get the full markdown body of one summary template by name.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Template name, e.g. \"Meeting Notes\""],
                ],
                "required": ["name"],
            ] as [String: Any],
        ],
        [
            "name": "create_template",
            "description": "Create a new summary template. A template is a markdown skeleton: headings plus one line of guidance under each about what goes there -- not a filled-in example. Use placeholders {{title}}, {{date}}, {{attendees}}, {{duration}}, {{app}} anywhere in the body; they're substituted with meeting metadata before the transcript is handed to the model. Start with a level-1 heading (e.g. \"# {{title}}\") and use level-2 headings (##) for sections. Fails if a template with this name already exists (case-insensitive) -- use update_template to edit one instead.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "New template name. Can't contain \"/\" or \":\"."],
                    "content": ["type": "string", "description": "Markdown body, e.g. \"# {{title}}\\n\\n{{date}} - {{attendees}}\\n\\n## TL;DR\\nTwo or three sentences...\""],
                ],
                "required": ["name", "content"],
            ] as [String: Any],
        ],
        [
            "name": "update_template",
            "description": "Replace the full body of an existing summary template. Same placeholder and heading-skeleton conventions as create_template. Fails if no template with this name exists -- use create_template for a new one.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Existing template name"],
                    "content": ["type": "string", "description": "New markdown body, replacing the old one in full"],
                ],
                "required": ["name", "content"],
            ] as [String: Any],
        ],
        [
            "name": "delete_template",
            "description": "Delete a summary template by name. This cannot be undone.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Template name to delete"],
                ],
                "required": ["name"],
            ] as [String: Any],
        ],
        [
            "name": "rename_template",
            "description": "Rename a summary template, keeping its body unchanged. Case-only renames (e.g. \"notes\" -> \"Notes\") are supported.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "old_name": ["type": "string", "description": "Current template name"],
                    "new_name": ["type": "string", "description": "New template name. Can't contain \"/\" or \":\"."],
                ],
                "required": ["old_name", "new_name"],
            ] as [String: Any],
        ],
    ]

    enum ToolError: LocalizedError {
        case unknownTool(String)
        case badArgument(String)
        case notFound(String)
        case templateNotFound(String)
        var errorDescription: String? {
            switch self {
            case .unknownTool(let n): return "Unknown tool '\(n)'"
            case .badArgument(let m): return m
            case .notFound(let id): return "No meeting with id \(id)"
            case .templateNotFound(let name): return "No template named \"\(name)\""
            }
        }
    }

    func call(tool: String, arguments: [String: Any]) throws -> String {
        switch tool {
        case "list_meetings":
            let limit = arguments["limit"] as? Int ?? 20
            let meetings = archive.allMeetings().prefix(max(1, limit))
            if meetings.isEmpty { return "No meetings recorded yet." }
            return meetings.map(Self.describe).joined(separator: "\n")

        case "search_meetings":
            guard let query = arguments["query"] as? String, !query.isEmpty else {
                throw ToolError.badArgument("'query' is required")
            }
            let hits = archive.search(query)
            if hits.isEmpty { return "No meetings matched \"\(query)\"." }
            return hits.map { hit in
                Self.describe(hit.meeting) + hit.excerpts.map { "\n    · \($0)" }.joined()
            }
            .joined(separator: "\n")

        case "get_meeting":
            let meeting = try meetingArg(arguments)
            let summary = archive.summary(for: meeting.id)
            var out = Self.describe(meeting)
            if !meeting.attendees.isEmpty {
                out += "\nAttendees: \(meeting.attendees.joined(separator: ", "))"
            }
            out += "\nSpeakers: \(meeting.speakers.map(\.name).joined(separator: ", "))"
            out += "\n\n" + (summary.isEmpty ? "(no summary yet)" : summary)
            return out

        case "get_transcript":
            let meeting = try meetingArg(arguments)
            let segments = archive.transcript(for: meeting.id)
            if segments.isEmpty { return "(no transcript for \(meeting.title))" }
            return "# \(meeting.title)\n\n"
                + TranscriptFormatter.plainText(segments, speakers: meeting.speakers)

        case "get_live_transcript":
            return Self.liveTranscriptText(archive: archive, minutes: arguments["minutes"] as? Int)

        case "update_summary":
            let meeting = try meetingArg(arguments)
            guard let content = arguments["content"] as? String else {
                throw ToolError.badArgument("'content' is required")
            }
            try archive.saveSummary(content, for: meeting.id)
            return "Updated the notes for \"\(meeting.title)\"."

        case "regenerate_summary":
            return try regenerateSummary(meeting: try meetingArg(arguments), arguments: arguments)

        case "list_templates":
            let all = templates.list()
            if all.isEmpty { return "No templates yet." }
            return all.map(Self.describeTemplate).joined(separator: "\n")

        case "get_template":
            return try templateArg(arguments).body

        case "create_template":
            guard let name = arguments["name"] as? String, !name.isEmpty else {
                throw ToolError.badArgument("'name' is required")
            }
            guard let content = arguments["content"] as? String else {
                throw ToolError.badArgument("'content' is required")
            }
            try templates.create(name: name, body: content)
            return "Created template \"\(name)\"."

        case "update_template":
            guard let name = arguments["name"] as? String, !name.isEmpty else {
                throw ToolError.badArgument("'name' is required")
            }
            guard let content = arguments["content"] as? String else {
                throw ToolError.badArgument("'content' is required")
            }
            guard templates.template(named: name) != nil else { throw ToolError.templateNotFound(name) }
            try templates.save(SummaryTemplate(name: name, body: content))
            return "Updated template \"\(name)\"."

        case "delete_template":
            let template = try templateArg(arguments)
            try templates.delete(named: template.name)
            return "Deleted template \"\(template.name)\"."

        case "rename_template":
            guard let oldName = arguments["old_name"] as? String, !oldName.isEmpty else {
                throw ToolError.badArgument("'old_name' is required")
            }
            guard let newName = arguments["new_name"] as? String, !newName.isEmpty else {
                throw ToolError.badArgument("'new_name' is required")
            }
            guard let existing = templates.template(named: oldName) else {
                throw ToolError.templateNotFound(oldName)
            }
            try templates.rename(from: oldName, to: newName, body: existing.body)
            return "Renamed template \"\(oldName)\" to \"\(newName)\"."

        default:
            throw ToolError.unknownTool(tool)
        }
    }

    private func meetingArg(_ arguments: [String: Any]) throws -> Meeting {
        guard let idString = arguments["id"] as? String, let id = UUID(uuidString: idString) else {
            throw ToolError.badArgument("'id' must be a meeting UUID")
        }
        guard let meeting = archive.meeting(id: id) else { throw ToolError.notFound(idString) }
        return meeting
    }

    private func templateArg(_ arguments: [String: Any], key: String = "name") throws -> SummaryTemplate {
        guard let name = arguments[key] as? String, !name.isEmpty else {
            throw ToolError.badArgument("'\(key)' must be a template name")
        }
        guard let template = templates.template(named: name) else { throw ToolError.templateNotFound(name) }
        return template
    }

    /// Re-summarizes a meeting from its transcript, optionally switching template first.
    /// The MCP request loop is synchronous, so the async summarizer is bridged with
    /// `blockingAwait` — the tool call blocks until the notes are ready, which is the
    /// behavior Claude expects from a request/response tool.
    private func regenerateSummary(meeting: Meeting, arguments: [String: Any]) throws -> String {
        var m = meeting
        if let name = arguments["template"] as? String, !name.isEmpty {
            guard templates.template(named: name) != nil else { throw ToolError.templateNotFound(name) }
            m.templateName = name
        }
        let segments = archive.transcript(for: m.id)
        guard !segments.isEmpty else {
            throw ToolError.badArgument("\"\(m.title)\" has no transcript yet, so there's nothing to summarize.")
        }
        let transcript = TranscriptFormatter.plainText(segments, speakers: m.speakers)
        let snapshot = m // immutable capture for the @Sendable bridge closure
        let outcome = blockingAwait { await ProcessingPipeline.summarize(meeting: snapshot, transcript: transcript) }
        switch outcome {
        case .success(let summary, let provider):
            try archive.saveSummary(summary, for: m.id)
            if var fresh = archive.meeting(id: m.id) {
                fresh.summaryProvider = provider
                fresh.templateName = m.templateName
                try? archive.save(fresh)
            }
            return summary
        case .failure(let why):
            throw ToolError.badArgument(why)
        }
    }

    /// Runs an async operation to completion on a background task and blocks the
    /// calling (MCP request-loop) thread until it finishes.
    private func blockingAwait<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        // Detached so it can't inherit (and then block on) the calling context.
        Task.detached(priority: .userInitiated) {
            box.value = await operation()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }

    private static func describeTemplate(_ t: SummaryTemplate) -> String {
        let headings = t.body.split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("## ") }
            .map { String($0.dropFirst(3)) }
        return headings.isEmpty ? t.name : "\(t.name): \(headings.joined(separator: ", "))"
    }

    private static func describe(_ m: Meeting) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        var line = "[\(m.id.uuidString)] \(m.title) — \(df.string(from: m.createdAt))"
        if m.duration > 0 { line += " (\(TemplateRenderer.duration(m.duration)))" }
        return line
    }

    /// The in-progress meeting is the one still in `.recording` state. A crash-orphaned
    /// meeting (state stuck at `.recording` until the next launch's `finalizeOrphans`)
    /// is guarded out by requiring a recently-modified `live.json`. Static +
    /// archive-injected so it's unit-testable.
    /// Default recent window handed back when the caller doesn't ask for more —
    /// enough for "what should I add/ask right now" without making Claude read
    /// (and regurgitate) the whole meeting.
    static let liveDefaultWindowMinutes = 6

    static func liveTranscriptText(archive: MeetingArchive, now: Date = Date(), minutes: Int? = nil) -> String {
        guard let meeting = archive.allMeetings().first(where: { $0.state == .recording }),
              let modified = archive.liveTranscriptModified(for: meeting.id),
              now.timeIntervalSince(modified) < 60
        else { return "No meeting is being recorded right now." }
        let all = archive.liveTranscript(for: meeting.id)
        guard !all.isEmpty else {
            return "A meeting is being recorded (\"\(meeting.title)\"), but nothing has been transcribed yet."
        }

        // Default to the recent tail; minutes == 0 (or negative) means the whole meeting.
        let window = minutes ?? liveDefaultWindowMinutes
        var segments = all
        var trimmed = false
        if window > 0, let latest = all.map(\.end).max() {
            let cutoff = latest - TimeInterval(window) * 60
            let recent = all.filter { $0.end >= cutoff }
            if recent.count < all.count { segments = recent; trimmed = true }
        }
        let body = TranscriptFormatter.plainText(segments, speakers: LiveTranscriber.speakers)
        let scope = trimmed
            ? "the last \(window) minutes of the live transcript (call again with a larger \"minutes\", or minutes=0 for the whole meeting, if you need earlier context)"
            : "the live transcript so far"

        // The result text is the last thing in Claude's context before it answers, so
        // steer for a fast, short reply here (both before and after the body) rather
        // than in the pre-filled prompt.
        return """
        [The user is IN this meeting right now and needs a fast, glanceable answer. Reply in 1-2 sentences, no preamble, and don't summarize the transcript back — answer only what was asked.]

        Here is \(scope) of "\(meeting.title)". This is a real-time approximation (it may lag a few seconds behind and isn't final):

        \(body)

        [Reminder: the user is live in the meeting — answer now, in 1-2 sentences.]
        """
    }

    // MARK: - JSON-RPC plumbing

    private func encode(resultID id: Any, result: [String: Any]) -> String {
        json(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func encode(errorID id: Any, code: Int, message: String) -> String {
        json(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#
        }
        return String(data: data, encoding: .utf8)!
    }
}
