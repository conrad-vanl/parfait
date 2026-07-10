import XCTest
@testable import Parfait

final class SpeakerLabelerTests: XCTestCase {
    private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TranscribedWord {
        TranscribedWord(text: text, start: start, end: end)
    }

    private func turn(_ speaker: String, _ start: TimeInterval, _ end: TimeInterval) -> DiarizedTurn {
        DiarizedTurn(speaker: speaker, start: start, end: end)
    }

    // MARK: - Mic only

    func testMicOnlyUsesSegmentsVerbatim() {
        let mic = TranscriptionOutput(
            words: [word("hello", 0, 0.4), word("there", 0.5, 0.9)],
            segments: [word("Hello there.", 0, 0.9), word("Second thought.", 2, 3)]
        )
        let (segments, speakers) = SpeakerLabeler.label(
            mic: mic, system: nil, systemTurns: nil, myName: "Conrad")

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map(\.speakerID), ["me", "me"])
        XCTAssertEqual(segments.map(\.text), ["Hello there.", "Second thought."])
        XCTAssertEqual(segments[0].start, 0)
        XCTAssertEqual(segments[0].end, 0.9)
        XCTAssertEqual(segments[1].start, 2)
        XCTAssertEqual(segments[1].end, 3)
        XCTAssertEqual(speakers, [Speaker(id: "me", name: "Conrad", isMe: true)])
    }

    // MARK: - System with diarized turns

    func testTwoSpeakerTurnsGroupOrderAndNames() {
        let system = TranscriptionOutput(
            words: [
                word("Good", 0.0, 0.3), word("morning", 0.4, 0.8),
                word("Hi", 5.0, 5.2), word("everyone", 5.3, 5.9),
                word("Thanks", 10.0, 10.5),
            ],
            segments: []
        )
        let turns = [turn("S1", 0, 4), turn("S2", 4.5, 9), turn("S1", 9.5, 12)]
        let (segments, speakers) = SpeakerLabeler.label(
            mic: nil, system: system, systemTurns: turns, myName: "Me")

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.map(\.speakerID), ["s1", "s2", "s1"])
        XCTAssertEqual(segments.map(\.text), ["Good morning", "Hi everyone", "Thanks"])
        XCTAssertEqual(segments[0].start, 0.0)
        XCTAssertEqual(segments[0].end, 0.8)
        XCTAssertEqual(segments[1].start, 5.0)
        XCTAssertEqual(segments[1].end, 5.9)
        XCTAssertEqual(speakers, [
            Speaker(id: "s1", name: "Speaker 1"),
            Speaker(id: "s2", name: "Speaker 2"),
        ])
    }

    func testDiarizerKeysMappedInFirstAppearanceOrder() {
        // Diarizer key "S2" speaks first, so it becomes "s1".
        let system = TranscriptionOutput(
            words: [word("first", 0, 1), word("second", 3, 4)],
            segments: []
        )
        let turns = [turn("S2", 0, 2), turn("S1", 2.5, 5)]
        let (segments, speakers) = SpeakerLabeler.label(
            mic: nil, system: system, systemTurns: turns, myName: "Me")

        XCTAssertEqual(segments.map(\.speakerID), ["s1", "s2"])
        XCTAssertEqual(speakers.map(\.id), ["s1", "s2"])
        XCTAssertEqual(speakers.map(\.name), ["Speaker 1", "Speaker 2"])
    }

    func testOverlapAttributionPicksDominantTurn() {
        let turns = [turn("S1", 0, 2), turn("S2", 2, 6)]
        // Anchor pins S1 to id "s1" so attribution of the spanning word is observable.
        let anchor = word("anchor", 0, 1)

        // Spanning word: 0.3s in S1 vs 0.7s in S2 -> S2.
        let system = TranscriptionOutput(
            words: [anchor, word("mostly-two", 1.7, 2.7)],
            segments: []
        )
        let (segments, _) = SpeakerLabeler.label(
            mic: nil, system: system, systemTurns: turns, myName: "Me")
        XCTAssertEqual(segments.map(\.speakerID), ["s1", "s2"])
        XCTAssertEqual(segments.map(\.text), ["anchor", "mostly-two"])

        // Shifted earlier: 0.7s in S1 vs 0.3s in S2 -> S1, so it merges with the anchor.
        let system2 = TranscriptionOutput(
            words: [anchor, word("mostly-one", 1.3, 2.3)],
            segments: []
        )
        let (segments2, _) = SpeakerLabeler.label(
            mic: nil, system: system2, systemTurns: turns, myName: "Me")
        XCTAssertEqual(segments2.map(\.speakerID), ["s1"])
        XCTAssertEqual(segments2.map(\.text), ["anchor mostly-one"])
    }

    func testNoOverlapFallsBackToNearestTurnMidpoint() {
        let turns = [turn("S1", 0, 2), turn("S2", 6, 8)]
        // Anchor pins S1 to id "s1" so the fallback choice is observable.
        let anchor = word("anchor", 0.2, 0.8)

        // Gap word midpoint 4.5: distance 3.5 to S1's midpoint (1), 2.5 to S2's (7) -> S2.
        let system = TranscriptionOutput(
            words: [anchor, word("gapword", 4.4, 4.6)],
            segments: []
        )
        let (segments, speakers) = SpeakerLabeler.label(
            mic: nil, system: system, systemTurns: turns, myName: "Me")
        XCTAssertEqual(segments.map(\.speakerID), ["s1", "s2"])
        XCTAssertEqual(speakers.map(\.id), ["s1", "s2"])

        // Midpoint 2.6 is nearer S1's midpoint -> S1 (split from anchor by the 1.7s gap).
        let system2 = TranscriptionOutput(
            words: [anchor, word("early", 2.5, 2.7)],
            segments: []
        )
        let (segments2, _) = SpeakerLabeler.label(
            mic: nil, system: system2, systemTurns: turns, myName: "Me")
        XCTAssertEqual(segments2.map(\.speakerID), ["s1", "s1"])
    }

    func testSameSpeakerSplitsAtSilenceGap() {
        let system = TranscriptionOutput(
            words: [
                word("part", 0.0, 0.5), word("one", 0.6, 1.0),
                // 2.0s gap > 1.5s threshold
                word("part", 3.0, 3.5), word("two", 3.6, 4.0),
            ],
            segments: []
        )
        let turns = [turn("S1", 0, 5)]
        let (segments, speakers) = SpeakerLabeler.label(
            mic: nil, system: system, systemTurns: turns, myName: "Me")

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map(\.speakerID), ["s1", "s1"])
        XCTAssertEqual(segments.map(\.text), ["part one", "part two"])
        XCTAssertEqual(segments[1].start, 3.0)
        XCTAssertEqual(segments[1].end, 4.0)
        XCTAssertEqual(speakers.count, 1)
    }

    func testGapAtExactlyThresholdDoesNotSplit() {
        let system = TranscriptionOutput(
            words: [word("a", 0.0, 0.5), word("b", 2.0, 2.5)],  // gap == 1.5
            segments: []
        )
        let turns = [turn("S1", 0, 3)]
        let (segments, _) = SpeakerLabeler.label(
            mic: nil, system: system, systemTurns: turns, myName: "Me")

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "a b")
    }

    func testGroupTextJoinsWithSingleSpacesTrimmed() {
        let system = TranscriptionOutput(
            words: [word(" Hello ", 0, 0.4), word("world", 0.5, 0.9), word(" ", 1.0, 1.1)],
            segments: []
        )
        let turns = [turn("S1", 0, 2)]
        let (segments, _) = SpeakerLabeler.label(
            mic: nil, system: system, systemTurns: turns, myName: "Me")

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "Hello world")
    }

    // MARK: - System without turns

    func testNoTurnsFallbackUsesSegmentsUnderSpeakerOne() {
        let system = TranscriptionOutput(
            words: [word("ignored", 0, 1)],
            segments: [word("First sentence.", 0, 2), word("Second sentence.", 3, 5)]
        )
        for turns in [nil, [DiarizedTurn]()] {
            let (segments, speakers) = SpeakerLabeler.label(
                mic: nil, system: system, systemTurns: turns, myName: "Me")
            XCTAssertEqual(segments.count, 2)
            XCTAssertEqual(segments.map(\.speakerID), ["s1", "s1"])
            XCTAssertEqual(segments.map(\.text), ["First sentence.", "Second sentence."])
            XCTAssertEqual(speakers, [Speaker(id: "s1", name: "Speaker 1")])
        }
    }

    // MARK: - Merging

    func testInterleavedMergeSortsByStartMicFirstOnTies() {
        let mic = TranscriptionOutput(
            words: [],
            segments: [word("mic early", 1, 2), word("mic tie", 5, 6)]
        )
        let system = TranscriptionOutput(
            words: [word("sys", 0, 0.5), word("tie", 5, 5.5), word("late", 8, 8.5)],
            segments: []
        )
        let turns = [turn("S1", 0, 10)]
        let (segments, speakers) = SpeakerLabeler.label(
            mic: mic, system: system, systemTurns: turns, myName: "Conrad")

        XCTAssertEqual(segments.map(\.start), [0, 1, 5, 5, 8])
        XCTAssertEqual(segments.map(\.speakerID), ["s1", "me", "me", "s1", "s1"])
        XCTAssertEqual(speakers.map(\.id), ["me", "s1"])
        XCTAssertTrue(speakers[0].isMe)
        XCTAssertFalse(speakers[1].isMe)
    }

    func testSpeakersListOrderMeFirstThenSystemSpeakers() {
        let mic = TranscriptionOutput(words: [], segments: [word("hi", 0, 1)])
        let system = TranscriptionOutput(
            words: [word("a", 2, 3), word("b", 6, 7)],
            segments: []
        )
        let turns = [turn("S1", 2, 4), turn("S2", 5, 8)]
        let (_, speakers) = SpeakerLabeler.label(
            mic: mic, system: system, systemTurns: turns, myName: "Conrad")

        XCTAssertEqual(speakers.map(\.id), ["me", "s1", "s2"])
        XCTAssertEqual(speakers.map(\.name), ["Conrad", "Speaker 1", "Speaker 2"])
    }

    // MARK: - Empty inputs

    func testAllNilInputsProduceNothing() {
        let (segments, speakers) = SpeakerLabeler.label(
            mic: nil, system: nil, systemTurns: nil, myName: "Me")
        XCTAssertTrue(segments.isEmpty)
        XCTAssertTrue(speakers.isEmpty)
    }

    func testEmptyOutputsProduceNoSpeakers() {
        let empty = TranscriptionOutput(words: [], segments: [])
        let (segments, speakers) = SpeakerLabeler.label(
            mic: empty, system: empty, systemTurns: [turn("S1", 0, 5)], myName: "Me")
        XCTAssertTrue(segments.isEmpty)
        XCTAssertTrue(speakers.isEmpty)
    }

    func testMicEmptySystemPresentOmitsMeSpeaker() {
        let mic = TranscriptionOutput(words: [], segments: [])
        let system = TranscriptionOutput(words: [], segments: [word("only sys", 0, 1)])
        let (segments, speakers) = SpeakerLabeler.label(
            mic: mic, system: system, systemTurns: nil, myName: "Me")

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].speakerID, "s1")
        XCTAssertEqual(speakers.map(\.id), ["s1"])
    }

    // MARK: - Cleanup (phantom speakers + echo dedup)

    func testMergesPhantomSystemSpeaker() {
        // FluidAudio fragments one remote voice: a substantial turn plus a 0.2s sliver.
        let system = TranscriptionOutput(
            words: [
                word("we", 0.0, 0.5), word("should", 0.6, 1.1), word("ship", 1.2, 1.7),
                word("it", 1.8, 2.2), word("today", 2.3, 2.9),
                word("blip", 8.0, 8.2),
            ],
            segments: []
        )
        let turns = [turn("S1", 0, 3), turn("S2", 7.9, 8.3)]
        let (_, speakers) = SpeakerLabeler.label(
            mic: nil, system: system, systemTurns: turns, myName: "Me")
        XCTAssertEqual(speakers.count, 1, "the 0.2s sliver should fold into the dominant speaker")
    }

    func testKeepsTwoRealSystemSpeakers() {
        // Both speakers hold a real share, so neither is merged away.
        let system = TranscriptionOutput(
            words: [
                word("alpha", 0.0, 1.0), word("alpha", 1.1, 2.0),
                word("beta", 5.0, 6.0), word("beta", 6.1, 7.0),
            ],
            segments: []
        )
        let turns = [turn("S1", 0, 3), turn("S2", 4, 8)]
        let (_, speakers) = SpeakerLabeler.label(
            mic: nil, system: system, systemTurns: turns, myName: "Me")
        XCTAssertEqual(speakers.count, 2)
    }

    func testDropsEchoedMicSegment() {
        // The far end says a full sentence; the mic picks up the same words off the
        // speakers (echo), plus one genuine local line.
        let phrase = [
            word("let's", 5.0, 5.3), word("lock", 5.3, 5.6), word("the", 5.6, 5.8),
            word("launch", 5.8, 6.1), word("date", 6.1, 6.4),
        ]
        let system = TranscriptionOutput(words: phrase, segments: [])
        let turns = [turn("S1", 5.0, 6.4)]
        let mic = TranscriptionOutput(
            words: [],
            segments: [
                word("let's lock the launch date", 5.0, 6.4),   // echo of the far end
                word("sounds good to me here", 10.0, 11.0),      // genuine local line
            ]
        )
        let (segments, _) = SpeakerLabeler.label(
            mic: mic, system: system, systemTurns: turns, myName: "Me")
        let meTexts = segments.filter { $0.speakerID == "me" }.map(\.text)
        XCTAssertFalse(meTexts.contains { $0.contains("launch date") }, "echoed mic line dropped")
        XCTAssertTrue(meTexts.contains { $0.contains("sounds good") }, "genuine mic line kept")
    }

    func testKeepsShortMicBackchannel() {
        // A brief affirmation that happens to echo shouldn't be nuked.
        let system = TranscriptionOutput(words: [word("yeah", 3.0, 3.4)], segments: [])
        let turns = [turn("S1", 3.0, 3.4)]
        let mic = TranscriptionOutput(words: [], segments: [word("yeah", 3.0, 3.4)])
        let (segments, _) = SpeakerLabeler.label(
            mic: mic, system: system, systemTurns: turns, myName: "Me")
        XCTAssertTrue(segments.contains { $0.speakerID == "me" && $0.text == "yeah" })
    }
}
