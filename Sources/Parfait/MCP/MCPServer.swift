import Foundation

/// A minimal MCP (Model Context Protocol) stdio server exposing the meeting archive
/// to Claude. JSON-RPC 2.0, one message per line on stdin/stdout, logs to stderr.
///
///     claude mcp add parfait -- /Applications/Parfait.app/Contents/MacOS/Parfait --mcp
final class MCPServer {
    static let protocolVersion = "2025-06-18"

    private let archive: MeetingArchive

    init(archive: MeetingArchive) {
        self.archive = archive
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
            return encode(resultID: id!, result: [
                "protocolVersion": Self.protocolVersion,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "parfait", "version": Bootstrap.version],
            ])
        case "ping":
            return encode(resultID: id!, result: [:])
        case "tools/list":
            return encode(resultID: id!, result: ["tools": Self.toolDefinitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
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
    ]

    enum ToolError: LocalizedError {
        case unknownTool(String)
        case badArgument(String)
        case notFound(String)
        var errorDescription: String? {
            switch self {
            case .unknownTool(let n): return "Unknown tool '\(n)'"
            case .badArgument(let m): return m
            case .notFound(let id): return "No meeting with id \(id)"
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
