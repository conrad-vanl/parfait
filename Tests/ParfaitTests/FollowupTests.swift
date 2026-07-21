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
    private func makeFollowup(title: String) -> Followup {
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        return Followup(
            id: UUID(), kind: .action, title: title,
            owner: "Me", sourceQuote: "I'll send the deck", suggestedAction: "Email the Q3 deck",
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

    func testSaveOnDeletedMeetingThrows() throws {
        try archive.delete(id: meeting.id)
        XCTAssertThrowsError(try archive.saveFollowups([makeFollowup(title: "x")], for: meeting.id)) {
            XCTAssertTrue($0 is MeetingArchive.ArchiveError)
        }
        // And the folder wasn't resurrected by the attempt.
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.folder(for: meeting.id).path))
    }
}
