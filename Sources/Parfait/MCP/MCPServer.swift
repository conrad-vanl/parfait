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
