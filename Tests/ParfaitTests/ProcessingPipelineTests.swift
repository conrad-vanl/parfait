import XCTest
@testable import Parfait

final class ProcessingPipelineTests: XCTestCase {
    private func seg(_ speakerID: String, _ text: String) -> TranscriptSegment {
        TranscriptSegment(speakerID: speakerID, start: 0, end: 0, text: text)
    }

    // MARK: - sameContent (drives skipping a redundant improvement pass)

    func testSameContentIgnoresSpeakerLabelsAndPunctuation() {
        // Live approximation vs. diarized transcript: same words, different speaker
        // ids and punctuation. The improvement pass would add nothing, so skip it.
        let live = [
            seg("me", "Let's ship the release today"),
            seg("them", "Sounds good, I'll cut the branch"),
        ]
        let accurate = [
            seg("s1", "Let's ship the release today."),
            seg("Conrad", "Sounds good — I'll cut the branch"),
        ]
        XCTAssertTrue(ProcessingPipeline.sameContent(live, accurate))
    }

    func testSameContentFalseWhenWordsDiffer() {
        let live = [seg("me", "ship the release today")]
        let accurate = [seg("s1", "ship the release tomorrow")]
        XCTAssertFalse(ProcessingPipeline.sameContent(live, accurate))
    }

    func testSameContentFalseWhenAccurateAddsWords() {
        // The batch transcript usually recovers words the live pass dropped.
        let live = [seg("me", "quarterly numbers")]
        let accurate = [seg("s1", "the quarterly numbers look strong")]
        XCTAssertFalse(ProcessingPipeline.sameContent(live, accurate))
    }

    // MARK: - titleStep (gating: generate vs. calendar-title check vs. hands off)

    private func meeting(title: String, calendarTitle: String?) -> Meeting {
        var m = Meeting(title: title, createdAt: Date())
        m.calendarEventTitle = calendarTitle
        return m
    }

    func testTitleStepGeneratesWithoutCalendarTitle() {
        let m = meeting(title: "Meeting · Tuesday 2:00 PM", calendarTitle: nil)
        XCTAssertEqual(ProcessingPipeline.titleStep(for: m, summary: "## Notes\nDiscussed Q3."), .generate)
    }

    func testTitleStepChecksIntactCalendarTitle() {
        let m = meeting(title: "Focus Time", calendarTitle: "Focus Time")
        XCTAssertEqual(
            ProcessingPipeline.titleStep(for: m, summary: "## Notes\nDiscussed Q3."),
            .check(calendarTitle: "Focus Time"))
    }

    func testTitleStepKeepsUserRenamedTitle() {
        // The user renamed the meeting away from the calendar title — never
        // second-guess that, even though calendarEventTitle (provenance) remains.
        let m = meeting(title: "Budget sync with Sam", calendarTitle: "Focus Time")
        XCTAssertEqual(ProcessingPipeline.titleStep(for: m, summary: "## Notes\nDiscussed Q3."), .keep)
    }

    func testTitleStepKeepsWhenNotesAreEmpty() {
        let calendar = meeting(title: "Focus Time", calendarTitle: "Focus Time")
        let untitled = meeting(title: "Meeting · Tuesday 2:00 PM", calendarTitle: nil)
        XCTAssertEqual(ProcessingPipeline.titleStep(for: calendar, summary: "  \n"), .keep)
        XCTAssertEqual(ProcessingPipeline.titleStep(for: untitled, summary: ""), .keep)
    }

    // MARK: - parseTitleVerdict (mismatch verdict → replacement; anything else → keep)

    func testVerdictKeepSentinelKeepsCalendarTitle() {
        XCTAssertNil(ProcessingPipeline.parseTitleVerdict("KEEP", calendarTitle: "Focus Time"))
        XCTAssertNil(ProcessingPipeline.parseTitleVerdict("keep.\n", calendarTitle: "Focus Time"))
        XCTAssertNil(ProcessingPipeline.parseTitleVerdict("\"Keep\"", calendarTitle: "Focus Time"))
    }

    func testVerdictReplacementTitleReplaces() {
        XCTAssertEqual(
            ProcessingPipeline.parseTitleVerdict(
                "\"Q3 Budget Review with Sam\"\n", calendarTitle: "Focus Time"),
            "Q3 Budget Review with Sam")
    }

    func testVerdictEchoOfCalendarTitleKeeps() {
        // A model that "replaces" with the same title changed nothing — keep.
        XCTAssertNil(ProcessingPipeline.parseTitleVerdict("Focus Time", calendarTitle: "Focus Time"))
        XCTAssertNil(ProcessingPipeline.parseTitleVerdict("focus time", calendarTitle: "Focus Time"))
    }

    func testVerdictMalformedOutputKeeps() {
        // Chatty multi-line or over-long replies fail closed: calendar title stays.
        XCTAssertNil(ProcessingPipeline.parseTitleVerdict(
            "The title does not fit.\nBetter: Q3 Budget Review", calendarTitle: "Focus Time"))
        XCTAssertNil(ProcessingPipeline.parseTitleVerdict(
            String(repeating: "long ", count: 30), calendarTitle: "Focus Time"))
        XCTAssertNil(ProcessingPipeline.parseTitleVerdict("", calendarTitle: "Focus Time"))
    }

    // MARK: - titleCheckPrompt

    func testTitleCheckPromptCarriesTitleNotesAndBias() {
        let prompt = ProcessingPipeline.titleCheckPrompt(
            calendarTitle: "Focus Time", summary: "Discussed the Q3 budget.")
        XCTAssertTrue(prompt.contains("\"Focus Time\""))
        XCTAssertTrue(prompt.contains("Discussed the Q3 budget."))
        XCTAssertTrue(prompt.contains("KEEP"))
        XCTAssertTrue(prompt.contains("Strongly prefer keeping"))
    }

    func testTitleCheckPromptTruncatesLongNotes() {
        let prompt = ProcessingPipeline.titleCheckPrompt(
            calendarTitle: "Focus Time", summary: String(repeating: "x", count: 5000))
        XCTAssertLessThan(prompt.count, 3000)
    }
}
