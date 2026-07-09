import XCTest
@testable import Parfait

final class TemplateTests: XCTestCase {
    func testFillSubstitutesPlaceholders() {
        var m = Meeting(title: "Kickoff", createdAt: Date(timeIntervalSince1970: 1_750_000_000))
        m.attendees = ["Alice", "Bob"]
        m.duration = 65 * 60
        m.sourceApp = "zoom.us"
        let out = TemplateRenderer.fill(
            "# {{title}}\n{{attendees}} · {{duration}} · {{app}}", meeting: m)
        XCTAssertTrue(out.contains("# Kickoff"))
        XCTAssertTrue(out.contains("Alice, Bob"))
        XCTAssertTrue(out.contains("1 hr 5 min"))
        XCTAssertTrue(out.contains("zoom.us"))
        XCTAssertFalse(out.contains("{{"))
    }

    func testFillFallsBackToSpeakersWhenNoAttendees() {
        var m = Meeting(title: "Chat", createdAt: Date())
        m.speakers = [Speaker(id: "me", name: "Me", isMe: true), Speaker(id: "s1", name: "Dana")]
        let out = TemplateRenderer.fill("{{attendees}}", meeting: m)
        XCTAssertEqual(out, "Me, Dana")
    }

    func testTemplateStoreSeedsAndRoundTrips() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parfait-tpl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TemplateStore(root: tmp)
        XCTAssertTrue(store.list().map(\.name).contains("Meeting Notes"))
        try store.save(SummaryTemplate(name: "Retro", body: "## Went well"))
        XCTAssertEqual(store.template(named: "Retro")?.body, "## Went well")
        try store.delete(named: "Retro")
        XCTAssertNil(store.template(named: "Retro"))
    }
}

final class FormatterTests: XCTestCase {
    let speakers = [
        Speaker(id: "me", name: "Me", isMe: true),
        Speaker(id: "s1", name: "Alice"),
    ]
    let segments = [
        TranscriptSegment(speakerID: "me", start: 0, end: 2, text: "Hi Alice."),
        TranscriptSegment(speakerID: "s1", start: 3, end: 5, text: "Hey!"),
        TranscriptSegment(speakerID: "s1", start: 5, end: 8, text: "Ready when you are."),
        TranscriptSegment(speakerID: "me", start: 70, end: 72, text: "Let's start."),
    ]

    func testPlainText() {
        let text = TranscriptFormatter.plainText(segments, speakers: speakers)
        XCTAssertEqual(text.split(separator: "\n").count, 4)
        XCTAssertTrue(text.contains("Me @ 0:00: Hi Alice."))
        XCTAssertTrue(text.contains("Alice @ 0:03: Hey!"))
        XCTAssertTrue(text.contains("Me @ 1:10: Let's start."))
    }

    func testMarkdownMergesConsecutiveTurns() {
        let md = TranscriptFormatter.markdown(segments, speakers: speakers)
        XCTAssertTrue(md.contains("Hey! Ready when you are."))
        XCTAssertEqual(md.components(separatedBy: "**Alice**").count, 2) // one Alice block
    }

    func testParseEditedRoundTrip() {
        let text = TranscriptFormatter.plainText(segments, speakers: speakers)
        let (parsed, outSpeakers) = TranscriptFormatter.parseEdited(
            text, originalSegments: segments, speakers: speakers)
        XCTAssertEqual(parsed.count, 4)
        XCTAssertEqual(parsed.map(\.text), segments.map(\.text))
        XCTAssertEqual(parsed.map(\.speakerID), segments.map(\.speakerID))
        XCTAssertEqual(parsed[3].start, 70)
        XCTAssertEqual(outSpeakers.count, 2)
    }

    func testParseEditedRenamesAndNewSpeaker() {
        let edited = """
        Me @ 0:00: Hi Alice.
        Bob @ 0:03: Actually it's Bob.
        """
        let (parsed, outSpeakers) = TranscriptFormatter.parseEdited(
            edited, originalSegments: segments, speakers: speakers)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(outSpeakers.count, 3)
        XCTAssertTrue(outSpeakers.contains { $0.name == "Bob" })
        XCTAssertEqual(parsed[1].speakerID, outSpeakers.first { $0.name == "Bob" }!.id)
        // reused original end time for the matching 0:03 segment
        XCTAssertEqual(parsed[1].end, 5)
    }

    func testParseEditedContinuationLines() {
        let edited = """
        Me @ 0:00: First line
        and a continuation.
        """
        let (parsed, _) = TranscriptFormatter.parseEdited(
            edited, originalSegments: [], speakers: speakers)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].text, "First line and a continuation.")
    }
}
