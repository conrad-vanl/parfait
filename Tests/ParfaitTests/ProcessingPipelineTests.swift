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
}
