import XCTest
@testable import Parfait

final class MCPServerTests: XCTestCase {
    var tmp: URL!
    var archive: MeetingArchive!
    var templates: TemplateStore!
    var server: MCPServer!
    var meeting: Meeting!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parfait-mcp-\(UUID().uuidString)")
        archive = MeetingArchive(root: tmp)
        templates = TemplateStore(root: tmp)
        server = MCPServer(archive: archive, templates: templates)

        var m = Meeting(title: "Roadmap sync", createdAt: Date())
        m.speakers = [Speaker(id: "me", name: "Me", isMe: true), Speaker(id: "s1", name: "Priya")]
        m.duration = 1800
        m.state = .ready
        try archive.createFolder(for: m.id)
        try archive.save(m)
        try archive.saveTranscript(
            [TranscriptSegment(speakerID: "s1", start: 12, end: 15, text: "Let's move launch to March.")],
            for: m.id
        )
        try archive.saveSummary("## TL;DR\nLaunch moved to March.", for: m.id)
        meeting = m
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func roundTrip(_ request: [String: Any]) throws -> [String: Any] {
        let line = String(
            data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8)!
        guard let response = server.handle(line: line) else { return [:] }
        return try JSONSerialization.jsonObject(with: Data(response.utf8)) as! [String: Any]
    }

    func testInitializeEchoesSupportedVersion() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [:]],
        ])
        let result = resp["result"] as! [String: Any]
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        let serverInfo = result["serverInfo"] as! [String: Any]
        XCTAssertEqual(serverInfo["name"] as? String, "parfait")
        XCTAssertNotNil((result["capabilities"] as! [String: Any])["tools"])
    }

    func testInitializeOffersLatestForUnknownVersion() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "1999-01-01", "capabilities": [:]],
        ])
        let result = resp["result"] as! [String: Any]
        XCTAssertEqual(result["protocolVersion"] as? String, MCPServer.supportedProtocolVersions[0])
    }

    func testUnknownToolIsProtocolError() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 10, "method": "tools/call",
            "params": ["name": "explode", "arguments": [:]],
        ])
        let error = resp["error"] as! [String: Any]
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    func testInitializedNotificationGetsNoResponse() {
        let response = server.handle(
            line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(response)
    }

    func testToolsList() throws {
        let resp = try roundTrip(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = (resp["result"] as! [String: Any])["tools"] as! [[String: Any]]
        let names = tools.map { $0["name"] as! String }.sorted()
        XCTAssertEqual(names, [
            "create_template", "delete_template", "get_followups", "get_live_transcript",
            "get_meeting", "get_template", "get_transcript", "list_meetings",
            "list_templates", "publish_meeting", "regenerate_summary", "rename_template",
            "save_followups", "search_meetings", "update_followup_status", "update_summary",
            "update_template",
        ])
        for tool in tools {
            XCTAssertNotNil(tool["description"])
            XCTAssertNotNil(tool["inputSchema"])
        }
    }

    func testListMeetingsCall() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "list_meetings", "arguments": [:]],
        ])
        let result = resp["result"] as! [String: Any]
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = result["content"] as! [[String: Any]]
        let text = content[0]["text"] as! String
        XCTAssertTrue(text.contains("Roadmap sync"))
        XCTAssertTrue(text.contains(meeting.id.uuidString))
    }

    func testSearchAndGetTranscript() throws {
        let search = try roundTrip([
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "search_meetings", "arguments": ["query": "march launch"]],
        ])
        let searchText = (((search["result"] as! [String: Any])["content"]
            as! [[String: Any]])[0]["text"] as! String)
        XCTAssertTrue(searchText.contains("Roadmap sync"))

        let transcript = try roundTrip([
            "jsonrpc": "2.0", "id": 5, "method": "tools/call",
            "params": ["name": "get_transcript", "arguments": ["id": meeting.id.uuidString]],
        ])
        let text = (((transcript["result"] as! [String: Any])["content"]
            as! [[String: Any]])[0]["text"] as! String)
        XCTAssertTrue(text.contains("Priya @ 0:12: Let's move launch to March."))
    }

    func testGetMeetingIncludesSummary() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 6, "method": "tools/call",
            "params": ["name": "get_meeting", "arguments": ["id": meeting.id.uuidString]],
        ])
        let text = (((resp["result"] as! [String: Any])["content"]
            as! [[String: Any]])[0]["text"] as! String)
        XCTAssertTrue(text.contains("Launch moved to March."))
        XCTAssertTrue(text.contains("Priya"))
    }

    func testToolErrorsAreSoft() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 7, "method": "tools/call",
            "params": ["name": "get_meeting", "arguments": ["id": UUID().uuidString]],
        ])
        let result = resp["result"] as! [String: Any]
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    func testUnknownMethodIsJSONRPCError() throws {
        let resp = try roundTrip(["jsonrpc": "2.0", "id": 8, "method": "nonexistent/method"])
        let error = resp["error"] as! [String: Any]
        XCTAssertEqual(error["code"] as? Int, -32601)
    }

    func testParseError() {
        let resp = server.handle(line: "not json")
        XCTAssertTrue(resp!.contains("-32700"))
    }

    func testPing() throws {
        let resp = try roundTrip(["jsonrpc": "2.0", "id": 9, "method": "ping"])
        XCTAssertNotNil(resp["result"])
    }

    func testListTemplatesReflectsSeededBuiltins() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 20, "method": "tools/call",
            "params": ["name": "list_templates", "arguments": [:]],
        ])
        let result = resp["result"] as! [String: Any]
        XCTAssertEqual(result["isError"] as? Bool, false)
        let text = (((result)["content"] as! [[String: Any]])[0]["text"] as! String)
        XCTAssertTrue(text.contains("Meeting Notes"))
        XCTAssertTrue(text.contains("1-on-1"))
        XCTAssertTrue(text.contains("Interview"))
    }

    func testCreateTemplateHappyPath() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 21, "method": "tools/call",
            "params": [
                "name": "create_template",
                "arguments": ["name": "Standup", "content": "# {{title}}\n\n## Blockers\nWhat's stuck."],
            ],
        ])
        let result = resp["result"] as! [String: Any]
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertNotNil(templates.template(named: "Standup"))
    }

    func testCreateTemplateCollisionIsError() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 22, "method": "tools/call",
            "params": [
                "name": "create_template",
                "arguments": ["name": "meeting notes", "content": "# {{title}}"],
            ],
        ])
        let result = resp["result"] as! [String: Any]
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    func testUpdateTemplateOnMissingNameIsError() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 23, "method": "tools/call",
            "params": [
                "name": "update_template",
                "arguments": ["name": "Does Not Exist", "content": "# {{title}}"],
            ],
        ])
        let result = resp["result"] as! [String: Any]
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    func testGetTemplateRoundTrip() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 24, "method": "tools/call",
            "params": ["name": "get_template", "arguments": ["name": "Interview"]],
        ])
        let result = resp["result"] as! [String: Any]
        XCTAssertEqual(result["isError"] as? Bool, false)
        let text = (((result)["content"] as! [[String: Any]])[0]["text"] as! String)
        XCTAssertTrue(text.contains("## Candidate Snapshot"))
    }

    func testDeleteTemplateReflectedInList() throws {
        let delete = try roundTrip([
            "jsonrpc": "2.0", "id": 25, "method": "tools/call",
            "params": ["name": "delete_template", "arguments": ["name": "1-on-1"]],
        ])
        XCTAssertEqual((delete["result"] as! [String: Any])["isError"] as? Bool, false)

        let list = try roundTrip([
            "jsonrpc": "2.0", "id": 26, "method": "tools/call",
            "params": ["name": "list_templates", "arguments": [:]],
        ])
        let text = (((list["result"] as! [String: Any])["content"] as! [[String: Any]])[0]["text"] as! String)
        XCTAssertFalse(text.contains("1-on-1"))
    }

    func testRenameTemplateCaseOnly() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 27, "method": "tools/call",
            "params": [
                "name": "rename_template",
                "arguments": ["old_name": "Interview", "new_name": "interview"],
            ],
        ])
        let result = resp["result"] as! [String: Any]
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual(templates.template(named: "interview")?.name, "interview")
    }

    // MARK: - get_live_transcript

    private func startRecordingMeeting(
        title: String, live segments: [TranscriptSegment]
    ) throws -> Meeting {
        var m = Meeting(title: title, createdAt: Date())
        m.state = .recording
        try archive.createFolder(for: m.id)
        try archive.save(m)
        archive.saveLiveTranscript(segments, for: m.id)
        return m
    }

    func testLiveTranscriptWhenNothingRecording() {
        // setUp's fixture meeting is .ready, not .recording.
        XCTAssertEqual(
            MCPServer.liveTranscriptText(archive: archive),
            "No meeting is being recorded right now.")
    }

    func testLiveTranscriptReturnsInProgressMeeting() throws {
        _ = try startRecordingMeeting(title: "Standup", live: [
            TranscriptSegment(speakerID: LiveTranscriber.youSpeakerID, start: 1, end: 1, text: "Morning everyone."),
            TranscriptSegment(speakerID: LiveTranscriber.othersSpeakerID, start: 3, end: 3, text: "Hi, ready to start."),
        ])
        let text = MCPServer.liveTranscriptText(archive: archive)
        XCTAssertTrue(text.contains("Standup"))
        XCTAssertTrue(text.contains("You @"))
        XCTAssertTrue(text.contains("Morning everyone."))
        XCTAssertTrue(text.contains("Others @"))
        XCTAssertTrue(text.contains("real-time approximation"))
    }

    func testLiveTranscriptRecordingButEmpty() throws {
        _ = try startRecordingMeeting(title: "Quiet", live: [])
        XCTAssertTrue(
            MCPServer.liveTranscriptText(archive: archive).contains("nothing has been transcribed yet"))
    }

    func testLiveTranscriptStaleFileIgnored() throws {
        _ = try startRecordingMeeting(title: "Orphan", live: [
            TranscriptSegment(speakerID: LiveTranscriber.youSpeakerID, start: 0, end: 0, text: "hello"),
        ])
        // A crash-orphaned .recording meeting: live.json older than 60s isn't "live".
        XCTAssertEqual(
            MCPServer.liveTranscriptText(archive: archive, now: Date().addingTimeInterval(120)),
            "No meeting is being recorded right now.")
    }

    func testLiveTranscriptWindowsToRecentByDefault() throws {
        _ = try startRecordingMeeting(title: "Long call", live: [
            TranscriptSegment(speakerID: LiveTranscriber.youSpeakerID, start: 0, end: 0, text: "Ancient history."),
            TranscriptSegment(speakerID: LiveTranscriber.othersSpeakerID, start: 600, end: 600, text: "Recent point."),
        ])
        let text = MCPServer.liveTranscriptText(archive: archive)
        XCTAssertTrue(text.contains("Recent point."))
        XCTAssertFalse(text.contains("Ancient history."))
        XCTAssertTrue(text.contains("last \(MCPServer.liveDefaultWindowMinutes) minutes"))
        XCTAssertTrue(text.contains("1-2 sentences")) // brevity steering present
    }

    func testLiveTranscriptMinutesZeroReturnsWholeMeeting() throws {
        _ = try startRecordingMeeting(title: "Long call", live: [
            TranscriptSegment(speakerID: LiveTranscriber.youSpeakerID, start: 0, end: 0, text: "Ancient history."),
            TranscriptSegment(speakerID: LiveTranscriber.othersSpeakerID, start: 600, end: 600, text: "Recent point."),
        ])
        let text = MCPServer.liveTranscriptText(archive: archive, minutes: 0)
        XCTAssertTrue(text.contains("Ancient history."))
        XCTAssertTrue(text.contains("Recent point."))
    }

    // MARK: - update_summary / regenerate_summary

    func testUpdateSummaryWritesNotes() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 30, "method": "tools/call",
            "params": ["name": "update_summary", "arguments": [
                "id": meeting.id.uuidString, "content": "## New\nRewritten notes.",
            ]],
        ])
        XCTAssertEqual((resp["result"] as! [String: Any])["isError"] as? Bool, false)
        XCTAssertEqual(archive.summary(for: meeting.id), "## New\nRewritten notes.")
    }

    func testUpdateSummaryRequiresContent() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 31, "method": "tools/call",
            "params": ["name": "update_summary", "arguments": ["id": meeting.id.uuidString]],
        ])
        XCTAssertEqual((resp["result"] as! [String: Any])["isError"] as? Bool, true)
    }

    func testRegenerateSummaryWithoutTranscriptErrors() throws {
        var m = Meeting(title: "Empty", createdAt: Date())
        m.state = .ready
        try archive.createFolder(for: m.id)
        try archive.save(m)
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 32, "method": "tools/call",
            "params": ["name": "regenerate_summary", "arguments": ["id": m.id.uuidString]],
        ])
        let result = resp["result"] as! [String: Any]
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = ((result["content"] as! [[String: Any]])[0]["text"] as! String)
        XCTAssertTrue(text.contains("no transcript"))
    }

    func testRegenerateSummaryUnknownTemplateErrors() throws {
        // The fixture meeting HAS a transcript, but an unknown template is rejected
        // before summarization is ever attempted (so this stays deterministic).
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 33, "method": "tools/call",
            "params": ["name": "regenerate_summary", "arguments": [
                "id": meeting.id.uuidString, "template": "Nonexistent Template",
            ]],
        ])
        XCTAssertEqual((resp["result"] as! [String: Any])["isError"] as? Bool, true)
    }

    // MARK: - Followups

    private func callTool(_ name: String, _ arguments: [String: Any], id: Int) throws -> [String: Any] {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": id, "method": "tools/call",
            "params": ["name": name, "arguments": arguments],
        ])
        return resp["result"] as! [String: Any]
    }

    private func text(_ result: [String: Any]) -> String {
        (result["content"] as! [[String: Any]])[0]["text"] as! String
    }

    func testGetFollowupsEmptyEnvelope() throws {
        let result = try callTool("get_followups", ["meeting_id": meeting.id.uuidString], id: 40)
        XCTAssertEqual(result["isError"] as? Bool, false)
        let json = try JSONSerialization.jsonObject(with: Data(text(result).utf8)) as! [String: Any]
        XCTAssertEqual(json["meeting_id"] as? String, meeting.id.uuidString)
        XCTAssertEqual(json["meeting_title"] as? String, "Roadmap sync")
        XCTAssertEqual((json["items"] as! [Any]).count, 0)
    }

    func testSaveFollowupsRoundTrips() throws {
        let save = try callTool("save_followups", [
            "meeting_id": meeting.id.uuidString,
            "items": [[
                "title": "Send Priya the launch plan",
                "kind": "action",
                "owner": "Me",
                "source_quote": "Let's move launch to March.",
                "suggested_action": "Email the March plan",
            ]],
        ], id: 41)
        XCTAssertEqual(save["isError"] as? Bool, false)
        XCTAssertTrue(text(save).contains("1 follow-up"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: archive.folder(for: meeting.id).appendingPathComponent("followups.json").path))

        // Read back through the legacy "id" spelling to cover the meeting_id/id fallback.
        let get = try callTool("get_followups", ["id": meeting.id.uuidString], id: 42)
        let json = try JSONSerialization.jsonObject(with: Data(text(get).utf8)) as! [String: Any]
        let items = json["items"] as! [[String: Any]]
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["title"] as? String, "Send Priya the launch plan")
        XCTAssertEqual(items[0]["kind"] as? String, "action")
        XCTAssertEqual(items[0]["owner"] as? String, "Me")
        XCTAssertEqual(items[0]["source_quote"] as? String, "Let's move launch to March.")
        XCTAssertEqual(items[0]["suggested_action"] as? String, "Email the March plan")
        XCTAssertEqual(items[0]["status"] as? String, "proposed")
        XCTAssertNotNil(UUID(uuidString: items[0]["id"] as! String))
        XCTAssertNotNil(items[0]["created_at"])
        XCTAssertNotNil(items[0]["updated_at"])
    }

    func testSaveFollowupsInvalidStatusIsError() throws {
        let result = try callTool("save_followups", [
            "meeting_id": meeting.id.uuidString,
            "items": [["title": "x", "status": "someday"]],
        ], id: 43)
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(text(result).contains("someday"))
    }

    func testUpdateFollowupStatus() throws {
        let followupID = UUID()
        _ = try callTool("save_followups", [
            "meeting_id": meeting.id.uuidString,
            "items": [["id": followupID.uuidString, "title": "Ship it", "kind": "action"]],
        ], id: 44)
        let before = archive.followups(for: meeting.id)[0]

        let result = try callTool("update_followup_status", [
            "meeting_id": meeting.id.uuidString,
            "followup_id": followupID.uuidString,
            "status": "done",
            "result_url": "https://github.com/example/pull/1",
        ], id: 45)
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertTrue(text(result).contains("Ship it"))
        XCTAssertTrue(text(result).contains("done"))

        let after = archive.followups(for: meeting.id)[0]
        XCTAssertEqual(after.status, .done)
        XCTAssertEqual(after.resultURL, "https://github.com/example/pull/1")
        XCTAssertEqual(after.createdAt, before.createdAt)
        XCTAssertGreaterThanOrEqual(after.updatedAt, before.updatedAt)
    }

    func testUpdateFollowupStatusUnknownIDIsError() throws {
        let result = try callTool("update_followup_status", [
            "meeting_id": meeting.id.uuidString,
            "followup_id": UUID().uuidString,
            "status": "done",
        ], id: 46)
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    // MARK: - list_meetings since

    func testListMeetingsSinceFilters() throws {
        var old = Meeting(title: "Ancient retro", createdAt: Date().addingTimeInterval(-30 * 86400))
        old.state = .ready
        try archive.createFolder(for: old.id)
        try archive.save(old)

        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86400))
        let result = try callTool("list_meetings", ["since": since], id: 47)
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertTrue(text(result).contains("Roadmap sync"))
        XCTAssertFalse(text(result).contains("Ancient retro"))
    }

    func testListMeetingsBadSinceIsError() throws {
        let result = try callTool("list_meetings", ["since": "last tuesday"], id: 48)
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    // MARK: - publish_meeting

    func testPublishMeetingWithoutNotesIsError() throws {
        var m = Meeting(title: "Unsummarized", createdAt: Date())
        m.state = .ready
        try archive.createFolder(for: m.id)
        try archive.save(m)
        // No summary saved: publish refuses before ever probing gh or the network.
        let result = try callTool("publish_meeting", ["meeting_id": m.id.uuidString], id: 49)
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(text(result).contains("no notes"))
    }

    // MARK: - Resources (MCP Apps follow-up card)

    func testInitializeAdvertisesResourcesAndUIExtension() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 60, "method": "initialize",
            "params": ["protocolVersion": "2025-11-25", "capabilities": [:]],
        ])
        let capabilities = (resp["result"] as! [String: Any])["capabilities"] as! [String: Any]
        XCTAssertNotNil(capabilities["resources"])
        let extensions = capabilities["extensions"] as! [String: Any]
        let ui = extensions["io.modelcontextprotocol/ui"] as! [String: Any]
        XCTAssertEqual(ui["mimeTypes"] as? [String], ["text/html;profile=mcp-app"])
    }

    func testResourcesListShowsFollowupCard() throws {
        let resp = try roundTrip(["jsonrpc": "2.0", "id": 61, "method": "resources/list"])
        let resources = (resp["result"] as! [String: Any])["resources"] as! [[String: Any]]
        XCTAssertEqual(resources.count, 1)
        XCTAssertEqual(resources[0]["uri"] as? String, "ui://parfait/followup-card.html")
        XCTAssertEqual(resources[0]["mimeType"] as? String, "text/html;profile=mcp-app")
    }

    func testResourcesReadReturnsCardHTML() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 62, "method": "resources/read",
            "params": ["uri": "ui://parfait/followup-card.html"],
        ])
        let contents = (resp["result"] as! [String: Any])["contents"] as! [[String: Any]]
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents[0]["uri"] as? String, "ui://parfait/followup-card.html")
        XCTAssertEqual(contents[0]["mimeType"] as? String, "text/html;profile=mcp-app")
        let html = contents[0]["text"] as! String
        XCTAssertTrue(html.contains("data-testid=\"parfait-followup-card\""))
        XCTAssertTrue(html.contains("ui/initialize")) // the postMessage glue is present
    }

    func testResourcesReadUnknownURIIsError() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 63, "method": "resources/read",
            "params": ["uri": "ui://parfait/nope.html"],
        ])
        let error = resp["error"] as! [String: Any]
        XCTAssertEqual(error["code"] as? Int, -32002)
    }

    func testGetFollowupsToolDeclaresUIResource() throws {
        let tool = MCPServer.toolDefinitions.first { $0["name"] as? String == "get_followups" }!
        let meta = tool["_meta"] as! [String: Any]
        let ui = meta["ui"] as! [String: Any]
        XCTAssertEqual(ui["resourceUri"] as? String, FollowupCard.uri)
    }

    func testGetFollowupsResultCarriesStructuredContent() throws {
        let result = try callTool("get_followups", ["meeting_id": meeting.id.uuidString], id: 64)
        XCTAssertEqual(result["isError"] as? Bool, false)
        let structured = result["structuredContent"] as! [String: Any]
        XCTAssertEqual(structured["meeting_id"] as? String, meeting.id.uuidString)
        XCTAssertEqual((structured["items"] as! [Any]).count, 0)
    }
}
