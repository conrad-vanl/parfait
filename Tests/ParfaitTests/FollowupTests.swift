import XCTest
@testable import Parfait

final class FollowupTests: XCTestCase {
    var tmp: URL!
    var archive: MeetingArchive!
    var meeting: Meeting!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parfait-followups-\(UUID().uuidString)")
        archive = MeetingArchive(root: tmp)

        var m = Meeting(title: "Roadmap sync", createdAt: Date())
        m.state = .ready
        try archive.createFolder(for: m.id)
        try archive.save(m)
        meeting = m
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
    }

    // Whole-second dates so the ISO8601 encoding round-trips exactly for Equatable.
    private func makeFollowup(title: String, owner: String? = "Me") -> Followup {
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        return Followup(
            id: UUID(), kind: .action, title: title,
            owner: owner, sourceQuote: "I'll send the deck", suggestedAction: "Email the Q3 deck",
            status: .proposed, resultURL: nil, note: nil,
            createdAt: now, updatedAt: now)
    }

    func testSaveAndLoadRoundTrips() throws {
        let items = [makeFollowup(title: "Send deck"), makeFollowup(title: "Book follow-up call")]
        try archive.saveFollowups(items, for: meeting.id)
        XCTAssertEqual(archive.followups(for: meeting.id), items)
    }

    func testMissingFileIsEmpty() {
        XCTAssertEqual(archive.followups(for: meeting.id), [])
    }

    func testCorruptFileIsEmpty() throws {
        try Data("not json".utf8).write(
            to: archive.folder(for: meeting.id).appendingPathComponent("followups.json"))
        XCTAssertEqual(archive.followups(for: meeting.id), [])
    }

    func testAllFollowupsNewestFirstOmittingEmptyMeetings() throws {
        // The fixture meeting is newest (created "now"); add an older one with
        // followups and another older one without any.
        try archive.saveFollowups([makeFollowup(title: "Send deck")], for: meeting.id)

        var old = Meeting(title: "Old planning", createdAt: Date().addingTimeInterval(-86400))
        old.state = .ready
        try archive.createFolder(for: old.id)
        try archive.save(old)
        try archive.saveFollowups([makeFollowup(title: "Chase invoice")], for: old.id)

        var empty = Meeting(title: "Nothing to do", createdAt: Date().addingTimeInterval(-3600))
        empty.state = .ready
        try archive.createFolder(for: empty.id)
        try archive.save(empty)

        let all = archive.allFollowups()
        XCTAssertEqual(all.map(\.meeting.id), [meeting.id, old.id])
        XCTAssertEqual(all[0].items.map(\.title), ["Send deck"])
        XCTAssertEqual(all[1].items.map(\.title), ["Chase invoice"])
    }

    func testIsMineMatchesMeAndOwnNameInAnyCasing() {
        let name = "Pat Tester"
        XCTAssertTrue(makeFollowup(title: "x", owner: "me").isMine(myName: name))
        XCTAssertTrue(makeFollowup(title: "x", owner: "Me").isMine(myName: name))
        XCTAssertTrue(makeFollowup(title: "x", owner: "ME").isMine(myName: name))
        XCTAssertTrue(makeFollowup(title: "x", owner: "Pat Tester").isMine(myName: name))
        XCTAssertTrue(makeFollowup(title: "x", owner: "pat tester").isMine(myName: name))
        XCTAssertTrue(makeFollowup(title: "x", owner: "  me  ").isMine(myName: name))
        XCTAssertFalse(makeFollowup(title: "x", owner: "Alice").isMine(myName: name))
        XCTAssertFalse(makeFollowup(title: "x", owner: nil).isMine(myName: name))
        XCTAssertFalse(makeFollowup(title: "x", owner: "   ").isMine(myName: name))
    }

    func testInvolvesMeIncludesUnassigned() {
        let name = "Pat Tester"
        XCTAssertTrue(makeFollowup(title: "x", owner: nil).involvesMe(myName: name))
        XCTAssertTrue(makeFollowup(title: "x", owner: "   ").involvesMe(myName: name))
        XCTAssertTrue(makeFollowup(title: "x", owner: "me").involvesMe(myName: name))
        XCTAssertTrue(makeFollowup(title: "x", owner: "Pat Tester").involvesMe(myName: name))
        XCTAssertFalse(makeFollowup(title: "x", owner: "Alice").involvesMe(myName: name))
    }

    func testLocalUserNamePrefersIsMeSpeaker() {
        var m = Meeting(title: "t", createdAt: Date())
        m.speakers = [
            Speaker(id: "s1", name: "Priya"),
            Speaker(id: "me", name: "Pat Tester", isMe: true),
        ]
        XCTAssertEqual(m.localUserName(fallback: "Fallback Name"), "Pat Tester")

        m.speakers = [Speaker(id: "s1", name: "Priya")]
        XCTAssertEqual(m.localUserName(fallback: "Fallback Name"), "Fallback Name")

        m.speakers = [Speaker(id: "me", name: "", isMe: true)]
        XCTAssertEqual(m.localUserName(fallback: "Fallback Name"), "Fallback Name")
    }

    @MainActor
    func testStoreBadgeCountsOnlyMineAndUnassigned() throws {
        var m = meeting!
        m.speakers = [Speaker(id: "me", name: "Pat Tester", isMe: true)]
        try archive.save(m)
        try archive.saveFollowups([
            makeFollowup(title: "Mine", owner: "me"),
            makeFollowup(title: "Someone else's", owner: "Alice"),
            makeFollowup(title: "Unassigned", owner: nil),
        ], for: m.id)

        let store = MeetingStore(archive: archive)
        XCTAssertEqual(store.openFollowupCount, 2)
    }

    func testSaveOnDeletedMeetingThrows() throws {
        try archive.delete(id: meeting.id)
        XCTAssertThrowsError(try archive.saveFollowups([makeFollowup(title: "x")], for: meeting.id)) {
            XCTAssertTrue($0 is MeetingArchive.ArchiveError)
        }
        // And the folder wasn't resurrected by the attempt.
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.folder(for: meeting.id).path))
    }
}
