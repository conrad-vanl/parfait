import XCTest
@testable import Parfait

final class ScreenshotTests: XCTestCase {

    // MARK: - Sampling schedule (2 min, then the interval doubles; keep last 3)

    func testCaptureTimesDouble() {
        XCTAssertEqual(ScreenshotSampler.nextCaptureTime(after: nil), 120)
        XCTAssertEqual(ScreenshotSampler.nextCaptureTime(after: 120), 240)
        XCTAssertEqual(ScreenshotSampler.nextCaptureTime(after: 960), 1920)
    }

    func testFiveMinuteMeetingKeepsBothEarlyShots() {
        let times = ScreenshotSampler.captureTimes(through: 5 * 60)
        XCTAssertEqual(times, [120, 240]) // 2 and 4 minutes in
        XCTAssertEqual(ScreenshotSampler.surviving(times), [120, 240]) // fewer than 3 — all kept
    }

    func testThirtyMinuteMeetingSurvivors() {
        let times = ScreenshotSampler.captureTimes(through: 30 * 60)
        XCTAssertEqual(times, [120, 240, 480, 960]) // 2, 4, 8, 16 min
        // Pruning keeps the newest 3: the 2-minute shot is shed.
        XCTAssertEqual(ScreenshotSampler.surviving(times), [240, 480, 960])
    }

    func testNinetyMinuteMeetingSurvivors() {
        let times = ScreenshotSampler.captureTimes(through: 90 * 60)
        XCTAssertEqual(times, [120, 240, 480, 960, 1920, 3840]) // 2…64 min
        // The survivors spread across the back half: 16, 32, and 64 minutes in.
        XCTAssertEqual(ScreenshotSampler.surviving(times), [960, 1920, 3840])
    }

    func testMeetingShorterThanFirstCaptureHasNoShots() {
        XCTAssertEqual(ScreenshotSampler.captureTimes(through: 90), [])
    }

    // MARK: - Analyzer prompt

    func testPromptCarriesPathsAndJSONInstruction() {
        let prompt = ScreenshotAnalyzer.prompt(paths: ["/tmp/a/shot-000120.png", "/tmp/a/shot-000240.png"])
        XCTAssertTrue(prompt.contains("- /tmp/a/shot-000120.png"))
        XCTAssertTrue(prompt.contains("- /tmp/a/shot-000240.png"))
        XCTAssertTrue(prompt.contains("video-conferencing app"))
        XCTAssertTrue(prompt.contains("JSON object"))
        XCTAssertTrue(prompt.contains("No other text"))
    }

    // MARK: - Analyzer parsing (fail closed)

    func testParseReadsPlainAndFencedJSON() {
        let plain = ScreenshotAnalyzer.parse(
            #"{"participants": ["Sarah Chen", "Mike Ross"], "activeSpeakers": {"shot-000480.png": "Sarah Chen"}}"#)
        XCTAssertEqual(plain?.participants, ["Sarah Chen", "Mike Ross"])
        XCTAssertEqual(plain?.activeSpeakers, ["shot-000480.png": "Sarah Chen"])

        let fenced = ScreenshotAnalyzer.parse("```json\n{\"participants\": [\"Sarah Chen\"]}\n```")
        XCTAssertEqual(fenced?.participants, ["Sarah Chen"])
        XCTAssertEqual(fenced?.activeSpeakers, [:]) // activeSpeakers is optional
    }

    func testParseTrimsAndDeduplicatesParticipants() {
        let result = ScreenshotAnalyzer.parse(
            #"{"participants": [" Sarah Chen ", "sarah chen", "", "Mike Ross"]}"#)
        XCTAssertEqual(result?.participants, ["Sarah Chen", "Mike Ross"])
    }

    func testParseFailsClosedOnMalformedOutput() {
        XCTAssertNil(ScreenshotAnalyzer.parse(""))
        XCTAssertNil(ScreenshotAnalyzer.parse("I see Sarah and Mike in the Zoom window."))
        XCTAssertNil(ScreenshotAnalyzer.parse(#"{"names": ["Sarah Chen"]}"#)) // wrong key
        XCTAssertNil(ScreenshotAnalyzer.parse(#"{"participants": "Sarah Chen"}"#)) // not an array
        XCTAssertNil(ScreenshotAnalyzer.parse(#"{"participants": [1, 2]}"#)) // not strings
    }

    func testParseEmptyParticipantsIsAValidNoFindingsReply() {
        // "No video app visible" is a real answer, distinct from a parse failure.
        XCTAssertEqual(ScreenshotAnalyzer.parse(#"{"participants": []}"#), .empty)
    }

    // MARK: - Candidate-pool union (calendar attendees ∪ screenshot names)

    private let me = Speaker(id: "me", name: "Conrad VanLandingham", isMe: true)
    private let s1 = Speaker(id: "s1", name: "Speaker 1")

    func testUnionDeduplicatesAcrossSourcesCaseInsensitively() {
        let pool = SpeakerNamer.candidates(
            attendees: ["Sarah Chen", "Mike Ross"] + ["sarah chen", "Priya Patel"],
            speakers: [me, s1])
        // Screenshot's "sarah chen" collapses into the calendar entry (calendar
        // casing wins — it came first); genuinely new names are appended.
        XCTAssertEqual(pool, ["Sarah Chen", "Mike Ross", "Priya Patel"])
    }

    func testUnionStillExcludesTheUser() {
        // Screenshots include the user's own tile; their name must never enter
        // the pool ("me" is the mic channel, already identified).
        let pool = SpeakerNamer.candidates(
            attendees: [] + ["Conrad VanLandingham", "Sarah Chen"],
            speakers: [me, s1])
        XCTAssertEqual(pool, ["Sarah Chen"])
    }

    func testScreenshotOnlyPoolWorksWithoutCalendarAttendees() {
        // The no-invite meeting: an empty calendar list plus screenshot names
        // still yields a pool, so the naming step now runs.
        let pool = SpeakerNamer.candidates(
            attendees: [] + ["Sarah Chen", "Mike Ross"],
            speakers: [me, s1])
        XCTAssertEqual(pool, ["Sarah Chen", "Mike Ross"])
    }
}
