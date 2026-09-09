import XCTest
@testable import Parfait

/// The map-reduce path itself needs the on-device model, so these cover the two pure
/// pieces it leans on: the chunker that bounds every prompt, and the check that stops a
/// stack of summaries from being saved as a meeting's notes.
final class AppleSummarizerTests: XCTestCase {
    func testChunkKeepsEveryPieceUnderBudget() {
        let text = (1...200).map { "Speaker 1 @ 0:\($0 % 60): line number \($0)" }
            .joined(separator: "\n")
        let chunks = AppleSummarizer.chunk(text, budget: 300)

        XCTAssertGreaterThan(chunks.count, 1)
        for piece in chunks {
            XCTAssertLessThanOrEqual(piece.count, 300, "chunk over budget: \(piece.count)")
        }
        XCTAssertEqual(chunks.joined(separator: "\n"), text)
    }

    func testChunkKeepsAnOversizedLineWhole() {
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(AppleSummarizer.chunk("a\n\(long)\nb", budget: 100), ["a", long, "b"])
    }

    func testOneCohesiveSummaryReadsAsOne() {
        XCTAssertFalse(AppleSummarizer.readsAsSeveralSummaries("""
        # Roadmap sync

        ## TL;DR

        We ship Friday.

        ## Action Items

        - Dana files the release notes.
        """))
    }

    func testRepeatedHeadingReadsAsSeveral() {
        XCTAssertTrue(AppleSummarizer.readsAsSeveralSummaries("""
        ## Meeting Summary

        - Budget approved.

        ## Meeting Summary

        - Vincent owns QA.
        """))
    }

    func testPartMarkerAndRulesReadAsSeveral() {
        XCTAssertTrue(AppleSummarizer.readsAsSeveralSummaries("## Meeting Summary: Part 2 of 7"))
        XCTAssertTrue(AppleSummarizer.readsAsSeveralSummaries("- Budget approved.\n\n---\n\n- Vincent owns QA."))
    }
}
