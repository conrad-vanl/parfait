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
            "create_template", "delete_template", "get_meeting", "get_template",
            "get_transcript", "list_meetings", "list_templates", "rename_template",
            "search_meetings", "update_template",
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
        let resp = try roundTrip(["jsonrpc": "2.0", "id": 8, "method": "resources/list"])
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
}
