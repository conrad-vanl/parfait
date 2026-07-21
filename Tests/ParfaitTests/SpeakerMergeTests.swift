import XCTest
@testable import Parfait

final class SpeakerMergeTests: XCTestCase {
    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parfait-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    @MainActor
    private func makeStore(
        speakers: [Speaker], segments: [TranscriptSegment]
    ) throws -> (MeetingStore, Meeting) {
        let archive = MeetingArchive(root: tmp)
        var m = Meeting(title: "Standup", createdAt: Date())
        m.speakers = speakers
        m.state = .ready
        try archive.createFolder(for: m.id)
        try archive.save(m)
        try archive.saveTranscript(segments, for: m.id)
        return (MeetingStore(archive: archive), m)
    }

    private func seg(_ speakerID: String, _ text: String) -> TranscriptSegment {
        TranscriptSegment(speakerID: speakerID, start: 0, end: 1, text: text)
    }

    @MainActor
    func testMergeRemapsSegmentsAndRemovesSpeaker() async throws {
        let (store, m) = try makeStore(
            speakers: [
                Speaker(id: "me", name: "Me", isMe: true),
                Speaker(id: "s1", name: "Clayton"),
                Speaker(id: "s2", name: "Speaker 2"),
            ],
            segments: [seg("me", "Hi"), seg("s1", "Hello"), seg("s2", "Hey"), seg("s2", "Again")])

        XCTAssertTrue(store.mergeSpeakers(meetingID: m.id, from: "s2", into: "s1"))

        let merged = try XCTUnwrap(store.meeting(id: m.id))
        XCTAssertEqual(merged.speakers.map(\.id), ["me", "s1"])
        XCTAssertEqual(merged.speakers.last?.name, "Clayton")
        XCTAssertEqual(merged.speakers.last?.isMe, false)
        XCTAssertEqual(store.transcript(for: m.id).map(\.speakerID), ["me", "s1", "s1", "s1"])
    }

    @MainActor
    func testMergeIntoMeKeepsMe() async throws {
        let (store, m) = try makeStore(
            speakers: [
                Speaker(id: "me", name: "Conrad", isMe: true),
                Speaker(id: "s1", name: "Speaker 1"),
            ],
            segments: [seg("s1", "Hello"), seg("me", "Hi")])

        XCTAssertTrue(store.mergeSpeakers(meetingID: m.id, from: "s1", into: "me"))

        let merged = try XCTUnwrap(store.meeting(id: m.id))
        XCTAssertEqual(merged.speakers.map(\.id), ["me"])
        XCTAssertEqual(merged.speakers.first?.name, "Conrad")
        XCTAssertEqual(merged.speakers.first?.isMe, true)
        XCTAssertEqual(store.transcript(for: m.id).map(\.speakerID), ["me", "me"])
    }

    @MainActor
    func testMergeFromMeKeepsMeIDAndTargetName() async throws {
        // Renaming "me" onto another speaker's name and merging: the "me" id
        // (and isMe) survive, but the merged speaker takes the target's name.
        let (store, m) = try makeStore(
            speakers: [
                Speaker(id: "me", name: "Me", isMe: true),
                Speaker(id: "s1", name: "Clayton"),
            ],
            segments: [seg("me", "Hi"), seg("s1", "Hello")])

        XCTAssertTrue(store.mergeSpeakers(meetingID: m.id, from: "me", into: "s1"))

        let merged = try XCTUnwrap(store.meeting(id: m.id))
        XCTAssertEqual(merged.speakers.map(\.id), ["me"])
        XCTAssertEqual(merged.speakers.first?.name, "Clayton")
        XCTAssertEqual(merged.speakers.first?.isMe, true)
        XCTAssertEqual(store.transcript(for: m.id).map(\.speakerID), ["me", "me"])
    }

    @MainActor
    func testMergeNoOpsOnSelfOrUnknownTarget() async throws {
        let speakers = [
            Speaker(id: "me", name: "Me", isMe: true),
            Speaker(id: "s1", name: "Speaker 1"),
        ]
        let (store, m) = try makeStore(speakers: speakers, segments: [seg("s1", "Hello")])

        XCTAssertFalse(store.mergeSpeakers(meetingID: m.id, from: "s1", into: "s1"))
        XCTAssertFalse(store.mergeSpeakers(meetingID: m.id, from: "s1", into: "ghost"))

        XCTAssertEqual(store.meeting(id: m.id)?.speakers, speakers)
        XCTAssertEqual(store.transcript(for: m.id).map(\.speakerID), ["s1"])
    }

    @MainActor
    func testMergeFromSpeakerMissingFromRoster() async throws {
        // Segments can reference a speaker id that has no roster entry; merging
        // still remaps them and leaves the roster intact.
        let (store, m) = try makeStore(
            speakers: [Speaker(id: "s1", name: "Clayton")],
            segments: [seg("ghost", "Hello"), seg("s1", "Hi")])

        XCTAssertTrue(store.mergeSpeakers(meetingID: m.id, from: "ghost", into: "s1"))

        XCTAssertEqual(store.meeting(id: m.id)?.speakers.map(\.id), ["s1"])
        XCTAssertEqual(store.transcript(for: m.id).map(\.speakerID), ["s1", "s1"])
    }
}
