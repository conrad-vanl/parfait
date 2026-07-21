import XCTest
@testable import Parfait

final class SpeakerNamerTests: XCTestCase {
    private let me = Speaker(id: "me", name: "Conrad VanLandingham", isMe: true)
    private let s1 = Speaker(id: "s1", name: "Speaker 1")
    private let s2 = Speaker(id: "s2", name: "Speaker 2")

    // MARK: - Candidate pool

    func testCandidatesExcludeTheUserAndJunk() {
        let pool = SpeakerNamer.candidates(
            attendees: ["Sarah Chen", " Conrad VanLandingham ", "", "  ", "Mike Ross"],
            speakers: [me, s1, s2])
        // The mic speaker (the user) is never offered as a candidate.
        XCTAssertEqual(pool, ["Sarah Chen", "Mike Ross"])
    }

    func testCandidatesDeduplicateCaseInsensitively() {
        let pool = SpeakerNamer.candidates(
            attendees: ["Sarah Chen", "sarah chen", "Mike Ross"], speakers: [me, s1])
        XCTAssertEqual(pool, ["Sarah Chen", "Mike Ross"])
    }

    func testCandidatesKeepEmailsAndRooms() {
        // Non-person entries stay in the pool (the prompt tells the model to
        // ignore them); filtering is the model's judgment call, not string logic.
        let pool = SpeakerNamer.candidates(
            attendees: ["sarah.chen@example.com", "Conference Room 4B"], speakers: [me, s1])
        XCTAssertEqual(pool, ["sarah.chen@example.com", "Conference Room 4B"])
    }

    // MARK: - Excerpt bounding

    func testExcerptPassesShortTranscriptsThrough() {
        let transcript = "Speaker 1 @ 0:01: Hi, it's Sarah."
        XCTAssertEqual(
            SpeakerNamer.excerpt(transcript, candidates: ["Sarah Chen"]), transcript)
    }

    func testExcerptKeepsOpeningAndNameMentions() {
        let opening = "Speaker 1 @ 0:01: Hey everyone, Sarah here."
        let filler = Array(repeating: "Speaker 2 @ 5:00: Numbers look fine to me.", count: 200)
        let mention = "Speaker 2 @ 40:00: Thanks Sarah, that helps."
        let transcript = ([opening] + filler + [mention]).joined(separator: "\n")

        let excerpt = SpeakerNamer.excerpt(transcript, candidates: ["Sarah Chen"], cap: 600)
        XCTAssertTrue(excerpt.contains("Sarah here"))
        XCTAssertTrue(excerpt.contains("Thanks Sarah"))
        XCTAssertLessThanOrEqual(excerpt.count, 700)
    }

    func testExcerptMatchesWholeWordsOnly() {
        let opening = String(repeating: "Speaker 1 @ 0:01: Let's get started on the plan.\n", count: 20)
        let transcript = opening
            + "Speaker 2 @ 9:00: We also considered the alternative.\n"
            + "Speaker 2 @ 9:30: Al, what do you think?"
        let excerpt = SpeakerNamer.excerpt(transcript, candidates: ["Al Green"], cap: 500)
        // "also" and "alternative" must not count as mentions of "Al".
        XCTAssertFalse(excerpt.contains("alternative"))
        XCTAssertTrue(excerpt.contains("Al, what do you think?"))
    }

    // MARK: - Prompt

    func testPromptCarriesLabelsCandidatesRulesAndExcerpt() {
        let prompt = SpeakerNamer.claudePrompt(
            speakerLabels: ["Speaker 1", "Speaker 2"],
            candidates: ["Sarah Chen", "Mike Ross"],
            myName: "Conrad VanLandingham",
            excerpt: "Speaker 1 @ 0:01: Hi, it's Sarah.")
        XCTAssertTrue(prompt.contains("\"Speaker 1\", \"Speaker 2\""))
        XCTAssertTrue(prompt.contains("- Sarah Chen"))
        XCTAssertTrue(prompt.contains("- Mike Ross"))
        XCTAssertTrue(prompt.contains("ONLY on clear evidence"))
        XCTAssertTrue(prompt.contains("Conrad VanLandingham"))
        XCTAssertTrue(prompt.contains("may not have spoken"))
        XCTAssertTrue(prompt.contains("conference rooms"))
        XCTAssertTrue(prompt.contains("Hi, it's Sarah."))
        XCTAssertTrue(prompt.contains("JSON object"))
    }

    // MARK: - Verdict parsing (fail closed)

    func testParseAssignmentsReadsPlainAndFencedJSON() {
        XCTAssertEqual(
            SpeakerNamer.parseAssignments(#"{"Speaker 1": "Sarah Chen", "Speaker 2": ""}"#),
            ["Speaker 1": "Sarah Chen", "Speaker 2": ""])
        XCTAssertEqual(
            SpeakerNamer.parseAssignments("```json\n{\"Speaker 1\": \"Sarah Chen\"}\n```"),
            ["Speaker 1": "Sarah Chen"])
    }

    func testParseAssignmentsFailsClosedOnMalformedOutput() {
        XCTAssertNil(SpeakerNamer.parseAssignments(""))
        XCTAssertNil(SpeakerNamer.parseAssignments("Speaker 1 is Sarah."))
        XCTAssertNil(SpeakerNamer.parseAssignments(#"{"Speaker 1": ["Sarah"]}"#))
        XCTAssertNil(SpeakerNamer.parseAssignments(#"{"Speaker 1": 1}"#))
    }

    // MARK: - Validation (the acceptance rules)

    func testValidatedAcceptsOnlyOfferedCandidates() {
        let renames = SpeakerNamer.validated(
            ["Speaker 1": "sarah chen", "Speaker 2": "Peter Parker"],
            speakers: [me, s1, s2],
            candidates: ["Sarah Chen", "Mike Ross"])
        // s1 matches (case-insensitive, canonical casing wins); "Peter Parker"
        // was never offered — a hallucinated name is rejected.
        XCTAssertEqual(renames, ["s1": "Sarah Chen"])
    }

    func testValidatedRejectsDuplicateAssignments() {
        let renames = SpeakerNamer.validated(
            ["Speaker 1": "Sarah Chen", "Speaker 2": "Sarah Chen"],
            speakers: [me, s1, s2],
            candidates: ["Sarah Chen", "Mike Ross"])
        // Two speakers must not both become Sarah — the first keeps the name.
        XCTAssertEqual(renames, ["s1": "Sarah Chen"])
    }

    func testValidatedNeverRenamesMe() {
        let renames = SpeakerNamer.validated(
            ["Conrad VanLandingham": "Mike Ross", "Speaker 1": "Sarah Chen"],
            speakers: [me, s1],
            candidates: ["Sarah Chen", "Mike Ross"])
        XCTAssertEqual(renames, ["s1": "Sarah Chen"])
    }

    func testValidatedSkipsEmptyAndUnknownLabels() {
        let renames = SpeakerNamer.validated(
            ["Speaker 1": "  ", "Speaker 9": "Sarah Chen"],
            speakers: [me, s1, s2],
            candidates: ["Sarah Chen"])
        // "" = model unsure; "Speaker 9" isn't a pipeline speaker. No renames.
        XCTAssertTrue(renames.isEmpty)
    }

    // MARK: - Applying

    func testApplyingRenamesByIDAndLeavesOthers() {
        let renamed = SpeakerNamer.applying(["s1": "Sarah Chen"], to: [me, s1, s2])
        XCTAssertEqual(renamed.map(\.name), ["Conrad VanLandingham", "Sarah Chen", "Speaker 2"])
        XCTAssertEqual(renamed.map(\.id), ["me", "s1", "s2"])
        XCTAssertTrue(renamed[0].isMe)
    }
}
