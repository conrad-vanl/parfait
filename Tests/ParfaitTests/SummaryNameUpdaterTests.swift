import XCTest
@testable import Parfait

final class SummaryNameUpdaterTests: XCTestCase {

    // MARK: - Rename-map coalescing

    func testCoalescingAccumulatesIndependentRenames() {
        var map = SummaryNameUpdater.coalescing([:], renaming: "Speaker 1", to: "Clayton")
        map = SummaryNameUpdater.coalescing(map, renaming: "Speaker 2", to: "Priya")
        XCTAssertEqual(map, ["Speaker 1": "Clayton", "Speaker 2": "Priya"])
    }

    func testCoalescingChainsRenamesOfARenamedSpeaker() {
        // The notes only ever said "Speaker 1", so a→b then b→c must become a→c.
        var map = SummaryNameUpdater.coalescing([:], renaming: "Speaker 1", to: "Clay")
        map = SummaryNameUpdater.coalescing(map, renaming: "clay", to: "Clayton")
        XCTAssertEqual(map, ["Speaker 1": "Clayton"])
    }

    func testCoalescingKeepsMergeShapedMap() {
        // Two old names onto one new name (a merge) both stay, driving dedup.
        var map = SummaryNameUpdater.coalescing([:], renaming: "Speaker 1", to: "Clayton")
        map = SummaryNameUpdater.coalescing(map, renaming: "Speaker 2", to: "Clayton")
        XCTAssertEqual(map, ["Speaker 1": "Clayton", "Speaker 2": "Clayton"])
        XCTAssertTrue(SummaryNameUpdater.hasMerge(map))
    }

    func testCoalescingRenameBackCancelsOut() {
        var map = SummaryNameUpdater.coalescing([:], renaming: "Speaker 1", to: "Clayton")
        map = SummaryNameUpdater.coalescing(map, renaming: "Clayton", to: "Speaker 1")
        XCTAssertTrue(map.isEmpty)
    }

    func testHasMergeFalseForPlainRenames() {
        XCTAssertFalse(SummaryNameUpdater.hasMerge(["Speaker 1": "Clayton", "Speaker 2": "Priya"]))
        XCTAssertFalse(SummaryNameUpdater.hasMerge([:]))
    }

    // MARK: - Run/skip decision

    func testShouldRunOnlyWithNotesAndSettledMeeting() {
        XCTAssertTrue(SummaryNameUpdater.shouldRun(
            meetingState: .ready, summary: "## Notes", summaryBusy: false))
        // No notes yet — nothing to rewrite.
        XCTAssertFalse(SummaryNameUpdater.shouldRun(
            meetingState: .ready, summary: "  \n", summaryBusy: false))
        // Recording/processing: the upcoming summary uses current names anyway.
        XCTAssertFalse(SummaryNameUpdater.shouldRun(
            meetingState: .recording, summary: "## Notes", summaryBusy: false))
        XCTAssertFalse(SummaryNameUpdater.shouldRun(
            meetingState: .processing, summary: "## Notes", summaryBusy: false))
        // A regeneration in flight wins over the targeted pass.
        XCTAssertFalse(SummaryNameUpdater.shouldRun(
            meetingState: .ready, summary: "## Notes", summaryBusy: true))
    }

    func testCanCommitOnlyWhenNotesUnchanged() {
        XCTAssertTrue(SummaryNameUpdater.canCommit(original: "## Notes", current: "## Notes"))
        // The user edited while the pass ran — abort rather than clobber.
        XCTAssertFalse(SummaryNameUpdater.canCommit(original: "## Notes", current: "## Notes v2"))
    }

    // MARK: - Prompt

    func testPromptCarriesRenamesAndNarrowInstruction() {
        let prompt = SummaryNameUpdater.prompt(renames: ["Speaker 1": "Clayton"])
        XCTAssertTrue(prompt.contains("\"Speaker 1\" is now named \"Clayton\""))
        XCTAssertTrue(prompt.contains("ONLY these name changes"))
        XCTAssertTrue(prompt.contains("change nothing else"))
        // No merge in the map — no consolidation instruction.
        XCTAssertFalse(prompt.contains("consolidate"))
    }

    func testPromptAddsConsolidationForMerges() {
        let prompt = SummaryNameUpdater.prompt(
            renames: ["Speaker 1": "Clayton", "Speaker 2": "Clayton"])
        XCTAssertTrue(prompt.contains("\"Speaker 1\" is now named \"Clayton\""))
        XCTAssertTrue(prompt.contains("\"Speaker 2\" is now named \"Clayton\""))
        XCTAssertTrue(prompt.contains("consolidate"))
        XCTAssertTrue(prompt.contains("listed once"))
    }

    // MARK: - Output validation (fail closed)

    func testValidatedRejectsEmptyOutput() {
        XCTAssertNil(SummaryNameUpdater.validated(nil, original: "## Notes"))
        XCTAssertNil(SummaryNameUpdater.validated("", original: "## Notes"))
        XCTAssertNil(SummaryNameUpdater.validated("  \n\n ", original: "## Notes"))
    }

    func testValidatedRejectsDrasticallyShortenedOutput() {
        // A reply that lost most of the notes is malformed — keep the original.
        let original = String(repeating: "All the meeting notes. ", count: 20)
        XCTAssertNil(SummaryNameUpdater.validated("Sure!", original: original))
    }

    func testValidatedStripsSurroundingCodeFence() {
        XCTAssertEqual(
            SummaryNameUpdater.validated(
                "```markdown\n## Notes\nClayton shipped it.\n```", original: "## Notes\nS1 shipped it."),
            "## Notes\nClayton shipped it.")
    }

    func testValidatedPassesThroughNormalOutput() {
        XCTAssertEqual(
            SummaryNameUpdater.validated(
                "## Notes\nClayton shipped it.\n", original: "## Notes\nS1 shipped it."),
            "## Notes\nClayton shipped it.")
    }
}
