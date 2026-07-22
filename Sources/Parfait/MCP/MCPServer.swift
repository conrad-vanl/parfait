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
                "capabilities": [
                    "tools": [:] as [String: Any],
                    "resources": [:] as [String: Any],
                    // MCP Apps (ext-apps 2026-01-26): we serve ui:// HTML resources.
                    "extensions": [
                        "io.modelcontextprotocol/ui": ["mimeTypes": [FollowupCard.mimeType]],
                    ],
                ] as [String: Any],
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
                var result: [String: Any] = [
                    "content": [["type": "text", "text": text]],
                    "isError": false,
                ]
                // MCP Apps hosts hand structuredContent to the follow-up card
                // (see FollowupCard); the text envelope stays for text-only hosts.
                if name == "get_followups" || name == "get_all_followups",
                   let data = text.data(using: .utf8),
                   let envelope = try? JSONSerialization.jsonObject(with: data) {
                    result["structuredContent"] = envelope
                }
                return encode(resultID: id!, result: result)
            } catch {
                return encode(resultID: id!, result: [
                    "content": [["type": "text", "text": "Error: \(error.localizedDescription)"]],
                    "isError": true,
                ])
            }
        case "resources/list":
            return encode(resultID: id!, result: ["resources": [[
                "uri": FollowupCard.uri,
                "name": "followup-card",
                "title": "Follow-up card",
                "description": "Interactive card for the follow-up queue: renders get_followups and get_all_followups results with inline instruction editing, Done/Dismiss, and a hand-off to Claude.",
                "mimeType": FollowupCard.mimeType,
            ] as [String: Any]]])
        case "resources/read":
            let uri = params["uri"] as? String ?? ""
            guard uri == FollowupCard.uri else {
                // -32002: resource not found, per the MCP spec.
                return encode(errorID: id!, code: -32002, message: "Resource not found: \(uri)")
            }
            return encode(resultID: id!, result: ["contents": [[
                "uri": FollowupCard.uri,
                "mimeType": FollowupCard.mimeType,
                "text": FollowupCard.html,
            ] as [String: Any]]])
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
                    "since": ["type": "string", "description": "Only meetings created at or after this ISO8601 date or date-time (e.g. \"2026-07-01\" or \"2026-07-01T09:00:00Z\"). Use for \"what's new since the last digest\" queries."],
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
            "name": "get_followups",
            "description": "Get a meeting's follow-ups (action items, open questions, things to chase) as JSON, by meeting id. Returns {meeting_id, meeting_title, items}; items is [] if none have been saved yet.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "meeting_id": ["type": "string", "description": "Meeting UUID"],
                    "mine": ["type": "boolean", "description": "Only items for the local user — owned by them (owner \"me\" or their name) or unassigned"],
                ],
                "required": ["meeting_id"],
            ] as [String: Any],
            // MCP Apps: hosts that support ui:// render the follow-up card with
            // this tool's result instead of the raw JSON text.
            "_meta": ["ui": ["resourceUri": FollowupCard.uri]] as [String: Any],
        ],
        [
            "name": "get_all_followups",
            "description": "Get the cross-meeting follow-up queue: every meeting's follow-ups as JSON, newest meeting first, meetings with none omitted. Returns {meetings: [{meeting_id, meeting_title, items}]}. Pass status \"open\" for the working queue (proposed + approved + in_progress). The followups and digest skills should prefer one call to this over per-meeting get_followups calls.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "status": ["type": "string", "enum": ["open", "proposed", "approved", "in_progress", "done", "dismissed"], "description": "Only items with this status; \"open\" means proposed, approved, or in_progress. Omit for all."] as [String: Any],
                    "since": ["type": "string", "description": "Only meetings created at or after this ISO8601 date or date-time (e.g. \"2026-07-01\" or \"2026-07-01T09:00:00Z\")."],
                    "mine": ["type": "boolean", "description": "Only items for the local user — owned by them (owner \"me\" or their name) or unassigned"],
                ] as [String: Any],
            ] as [String: Any],
            // MCP Apps: the follow-up card renders this tool's result too
            // (cross-meeting envelope), not just get_followups.
            "_meta": ["ui": ["resourceUri": FollowupCard.uri]] as [String: Any],
        ],
        [
            "name": "save_followups",
            "description": "Replace a meeting's follow-up list in full. Each item needs a title; kind is action/question/followup (default followup) and status is proposed/approved/in_progress/done/dismissed (default proposed). Pass an item's existing id to keep its identity (and created_at) across saves; omit id for new items. To change one item, prefer update_followup.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "meeting_id": ["type": "string", "description": "Meeting UUID"],
                    "items": [
                        "type": "array",
                        "description": "The meeting's full follow-up list, replacing whatever was saved before",
                        "items": [
                            "type": "object",
                            "properties": [
                                "id": ["type": "string", "description": "Existing follow-up UUID to keep; omit for a new item"],
                                "kind": ["type": "string", "enum": ["action", "question", "followup"]] as [String: Any],
                                "title": ["type": "string", "description": "Short imperative description, e.g. \"Send Priya the Q3 deck\""],
                                "owner": ["type": "string", "description": "Who's on the hook (attendee/speaker name)"],
                                "source_quote": ["type": "string", "description": "Verbatim transcript line it came from"],
                                "suggested_action": ["type": "string", "description": "Concrete next step, e.g. a draft message"],
                                "status": ["type": "string", "enum": ["proposed", "approved", "in_progress", "done", "dismissed"]] as [String: Any],
                                "result_url": ["type": "string", "description": "Link to whatever resolved it"],
                                "note": ["type": "string"],
                            ] as [String: Any],
                            "required": ["title"],
                        ] as [String: Any],
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["meeting_id", "items"],
            ] as [String: Any],
        ],
        [
            "name": "update_followup",
            "description": "Edit one follow-up by meeting id + follow-up id: change its status and/or edit its title, suggested_action, owner, note, or result_url. Pass only the fields to change (at least one). Use this instead of save_followups when only one item changes.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "meeting_id": ["type": "string", "description": "Meeting UUID"],
                    "followup_id": ["type": "string", "description": "Follow-up UUID from get_followups/get_all_followups"],
                    "status": ["type": "string", "enum": ["proposed", "approved", "in_progress", "done", "dismissed"], "description": "New status"] as [String: Any],
                    "title": ["type": "string", "description": "New short imperative description"],
                    "suggested_action": ["type": "string", "description": "New instructions for executing the item"],
                    "owner": ["type": "string", "description": "Who's on the hook (attendee/speaker name)"],
                    "note": ["type": "string", "description": "Note about the change"],
                    "result_url": ["type": "string", "description": "Link to whatever resolved it"],
                ] as [String: Any],
                "required": ["meeting_id", "followup_id"],
            ] as [String: Any],
        ],
        [
            "name": "publish_meeting",
            "description": "Publish a meeting's notes — plus the transcript, unless the user turned that off in the app's share menu — as a styled web page (backed by a secret GitHub gist). Returns the shareable notes.parfait.to link — that's the URL to give the user — plus the underlying gist URL. Anyone with the link can read the page. Requires the GitHub CLI (gh) installed and authenticated.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "meeting_id": ["type": "string", "description": "Meeting UUID"],
                ],
                "required": ["meeting_id"],
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
            var meetings = archive.allMeetings()
            if let sinceString = arguments["since"] as? String, !sinceString.isEmpty {
                guard let since = Self.parseISODate(sinceString) else {
                    throw ToolError.badArgument(
                        "'since' must be an ISO8601 date or date-time, e.g. \"2026-07-01\" or \"2026-07-01T09:00:00Z\"")
                }
                meetings = meetings.filter { $0.createdAt >= since }
                if meetings.isEmpty { return "No meetings since \(sinceString)." }
            }
            let page = meetings.prefix(max(1, limit))
            if page.isEmpty { return "No meetings recorded yet." }
            return page.map(Self.describe).joined(separator: "\n")

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

        case "get_followups":
            let meeting = try meetingArg(arguments)
            var items = archive.followups(for: meeting.id)
            if arguments["mine"] as? Bool == true {
                let myName = meeting.localUserName()
                items = items.filter { $0.involvesMe(myName: myName) }
            }
            return Self.followupsJSON(meeting: meeting, items: items)

        case "get_all_followups":
            var statuses: Set<Followup.Status>?
            if let statusString = arguments["status"] as? String, !statusString.isEmpty {
                if statusString == "open" {
                    statuses = [.proposed, .approved, .inProgress]
                } else if let status = Followup.Status(rawValue: statusString) {
                    statuses = [status]
                } else {
                    throw ToolError.badArgument(
                        "'status' must be one of open, proposed, approved, in_progress, done, dismissed")
                }
            }
            var since: Date?
            if let sinceString = arguments["since"] as? String, !sinceString.isEmpty {
                guard let date = Self.parseISODate(sinceString) else {
                    throw ToolError.badArgument(
                        "'since' must be an ISO8601 date or date-time, e.g. \"2026-07-01\" or \"2026-07-01T09:00:00Z\"")
                }
                since = date
            }
            let mine = arguments["mine"] as? Bool == true
            let meetings: [[String: Any]] = archive.allFollowups().compactMap { entry in
                if let since, entry.meeting.createdAt < since { return nil }
                var items = statuses.map { wanted in entry.items.filter { wanted.contains($0.status) } }
                    ?? entry.items
                if mine {
                    let myName = entry.meeting.localUserName()
                    items = items.filter { $0.involvesMe(myName: myName) }
                }
                guard !items.isEmpty else { return nil }
                return [
                    "meeting_id": entry.meeting.id.uuidString,
                    "meeting_title": entry.meeting.title,
                    "items": Self.encodeFollowups(items),
                ]
            }
            return Self.prettyJSON(["meetings": meetings])

        case "save_followups":
            let meeting = try meetingArg(arguments)
            guard let rawItems = arguments["items"] as? [[String: Any]] else {
                throw ToolError.badArgument("'items' must be an array of follow-up objects")
            }
            let existing = Dictionary(
                uniqueKeysWithValues: archive.followups(for: meeting.id).map { ($0.id, $0) })
            let now = Date()
            let items = try rawItems.map { raw -> Followup in
                guard let title = raw["title"] as? String, !title.isEmpty else {
                    throw ToolError.badArgument("Every follow-up item needs a 'title'")
                }
                let kindString = raw["kind"] as? String ?? "followup"
                guard let kind = Followup.Kind(rawValue: kindString) else {
                    throw ToolError.badArgument(
                        "Invalid kind '\(kindString)' — use action, question, or followup")
                }
                let statusString = raw["status"] as? String ?? "proposed"
                guard let status = Followup.Status(rawValue: statusString) else {
                    throw ToolError.badArgument(
                        "Invalid status '\(statusString)' — use proposed, approved, in_progress, done, or dismissed")
                }
                let id = (raw["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
                return Followup(
                    id: id, kind: kind, title: title,
                    owner: raw["owner"] as? String,
                    sourceQuote: raw["source_quote"] as? String,
                    suggestedAction: raw["suggested_action"] as? String,
                    status: status,
                    resultURL: raw["result_url"] as? String,
                    note: raw["note"] as? String,
                    createdAt: existing[id]?.createdAt ?? now,
                    updatedAt: now)
            }
            try archive.saveFollowups(items, for: meeting.id)
            return "Saved \(items.count) follow-up\(items.count == 1 ? "" : "s") for \"\(meeting.title)\"."

        case "update_followup":
            let meeting = try meetingArg(arguments)
            guard let idString = arguments["followup_id"] as? String,
                  let followupID = UUID(uuidString: idString)
            else {
                throw ToolError.badArgument("'followup_id' must be a follow-up UUID")
            }
            var items = archive.followups(for: meeting.id)
            guard let i = items.firstIndex(where: { $0.id == followupID }) else {
                throw ToolError.badArgument("No follow-up with id \(idString) in \"\(meeting.title)\"")
            }
            var changed: [String] = []
            if let statusString = arguments["status"] as? String {
                guard let status = Followup.Status(rawValue: statusString) else {
                    throw ToolError.badArgument(
                        "'status' must be one of proposed, approved, in_progress, done, dismissed")
                }
                items[i].status = status
                changed.append("status → \(status.rawValue)")
            }
            if let title = arguments["title"] as? String {
                guard !title.isEmpty else { throw ToolError.badArgument("'title' can't be empty") }
                items[i].title = title
                changed.append("title")
            }
            if let action = arguments["suggested_action"] as? String {
                items[i].suggestedAction = action
                changed.append("suggested_action")
            }
            if let owner = arguments["owner"] as? String {
                items[i].owner = owner
                changed.append("owner")
            }
            if let note = arguments["note"] as? String {
                items[i].note = note
                changed.append("note")
            }
            if let url = arguments["result_url"] as? String {
                items[i].resultURL = url
                changed.append("result_url")
            }
            guard !changed.isEmpty else {
                throw ToolError.badArgument(
                    "Pass at least one field to change: status, title, suggested_action, owner, note, or result_url")
            }
            items[i].updatedAt = Date()
            try archive.saveFollowups(items, for: meeting.id)
            return "Updated \"\(items[i].title)\": \(changed.joined(separator: ", "))."

        case "publish_meeting":
            return try publishMeeting(meeting: try meetingArg(arguments))

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

    /// Newer tools take `meeting_id`; the original tools took `id`. Accept both everywhere.
    private func meetingArg(_ arguments: [String: Any]) throws -> Meeting {
        guard let idString = (arguments["meeting_id"] ?? arguments["id"]) as? String,
              let id = UUID(uuidString: idString)
        else {
            throw ToolError.badArgument("'meeting_id' must be a meeting UUID")
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

    /// Mirrors MeetingDetailView.publish(): render the page, upload as a secret
    /// gist via gh, persist the rendered URL. Same `blockingAwait` bridge as
    /// regenerateSummary — Claude expects the tool call to block until the link exists.
    private func publishMeeting(meeting: Meeting) throws -> String {
        let summary = archive.summary(for: meeting.id)
        guard !summary.isEmpty else {
            throw ToolError.badArgument("This meeting has no notes yet.")
        }
        guard GitHubGist.isAvailable else {
            throw ToolError.badArgument(
                "Publishing requires the GitHub CLI (gh). Install it (brew install gh), run gh auth login, and try again.")
        }
        let html = HTMLExporter.html(
            meeting: meeting, summaryMarkdown: summary,
            segments: AppSettings.publishTranscript ? archive.transcript(for: meeting.id) : [],
            followups: archive.followups(for: meeting.id))
        let title = meeting.title
        let outcome: Result<(gist: URL, rendered: URL), Error> = blockingAwait {
            do {
                return .success(try await GitHubGist.publish(
                    html: html, filename: "meeting.html",
                    description: "Parfait meeting notes — \(title)"))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success(let urls):
            // Re-fetch: the upload took a while and the meeting may have been
            // edited (or deleted — then don't resurrect it) meanwhile.
            if var fresh = archive.meeting(id: meeting.id) {
                fresh.publishedURL = urls.rendered.absoluteString
                try? archive.save(fresh)
            }
            return """
            Published "\(title)".
            Shareable link (give the user this one): \(urls.rendered.absoluteString)
            Underlying gist: \(urls.gist.absoluteString)
            """
        case .failure(let error):
            throw ToolError.badArgument(error.localizedDescription)
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

    // ISO8601 in the shapes Claude plausibly passes: fractional-second and plain
    // date-times, plus bare dates ("2026-07-01").
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
    private static let isoDateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    static func parseISODate(_ string: String) -> Date? {
        isoFractional.date(from: string)
            ?? isoPlain.date(from: string)
            ?? isoDateOnly.date(from: string)
    }

    /// The snake_case item shape shared by get_followups and get_all_followups
    /// (the tool contract, even though the on-disk Codable keys are camelCase);
    /// nil fields are omitted.
    private static func encodeFollowups(_ items: [Followup]) -> [[String: Any]] {
        items.map { f in
            var d: [String: Any] = [
                "id": f.id.uuidString,
                "kind": f.kind.rawValue,
                "title": f.title,
                "status": f.status.rawValue,
                "created_at": isoFractional.string(from: f.createdAt),
                "updated_at": isoFractional.string(from: f.updatedAt),
            ]
            if let v = f.owner { d["owner"] = v }
            if let v = f.sourceQuote { d["source_quote"] = v }
            if let v = f.suggestedAction { d["suggested_action"] = v }
            if let v = f.resultURL { d["result_url"] = v }
            if let v = f.note { d["note"] = v }
            return d
        }
    }

    /// Pretty-printed JSON envelope for get_followups.
    private static func followupsJSON(meeting: Meeting, items: [Followup]) -> String {
        prettyJSON([
            "meeting_id": meeting.id.uuidString,
            "meeting_title": meeting.title,
            "items": encodeFollowups(items),
        ])
    }

    private static func prettyJSON(_ envelope: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
        else { return "{}" }
        return String(data: data, encoding: .utf8)!
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
