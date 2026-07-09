import XCTest
@testable import Parfait

final class StoreTests: XCTestCase {
    var tmp: URL!
    var archive: MeetingArchive!

    override func setUp() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parfait-tests-\(UUID().uuidString)")
        archive = MeetingArchive(root: tmp)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
    }

    func makeMeeting(title: String = "Standup") -> Meeting {
        // Whole-millisecond date so it survives the ISO8601 round-trip exactly.
        let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)
        var m = Meeting(title: title, createdAt: now)
        m.speakers = [
            Speaker(id: "me", name: "Me", isMe: true),
            Speaker(id: "s1", name: "Speaker 1"),
        ]
        m.state = .ready
        return m
    }

    func testMeetingRoundTrip() throws {
        let m = makeMeeting()
        try archive.save(m)
        XCTAssertEqual(archive.meeting(id: m.id), m)
        XCTAssertEqual(archive.allMeetings(), [m])
    }

    func testTranscriptRoundTrip() throws {
        let m = makeMeeting()
        try archive.save(m)
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 2.5, text: "Morning everyone."),
            TranscriptSegment(speakerID: "s1", start: 3, end: 6, text: "Hey! Ready to start?"),
        ]
        try archive.saveTranscript(segments, for: m.id)
        XCTAssertEqual(archive.transcript(for: m.id), segments)
    }

    func testSummaryRoundTrip() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("## TL;DR\nShipped it.", for: m.id)
        XCTAssertEqual(archive.summary(for: m.id), "## TL;DR\nShipped it.")
    }

    func testDelete() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.delete(id: m.id)
        XCTAssertNil(archive.meeting(id: m.id))
        XCTAssertEqual(archive.allMeetings(), [])
    }

    func testSearchRanksTitleAboveTranscript() throws {
        let titled = makeMeeting(title: "Budget review")
        try archive.save(titled)
        var other = makeMeeting(title: "Standup")
        other.createdAt = Date(timeIntervalSinceNow: -60)
        try archive.save(other)
        try archive.saveTranscript(
            [TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "We touched on the budget briefly.")],
            for: other.id
        )
        let hits = archive.search("budget")
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].meeting.id, titled.id)
        XCTAssertEqual(hits[1].meeting.id, other.id)
        XCTAssertTrue(hits[1].excerpts[0].contains("Me @ 0:00"))
    }

    func testSearchNoResults() {
        XCTAssertTrue(archive.search("zebra").isEmpty)
        XCTAssertTrue(archive.search("   ").isEmpty)
    }
}
