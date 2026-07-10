import Foundation

enum SpeakerLabeler {
    /// Silence between consecutive words that forces a new segment even for the same speaker.
    private static let maxWordGap: TimeInterval = 1.5

    static func label(
        mic: TranscriptionOutput?,
        system: TranscriptionOutput?,
        systemTurns: [DiarizedTurn]?,
        myName: String
    ) -> (segments: [TranscriptSegment], speakers: [Speaker]) {
        var segments: [TranscriptSegment] = []
        var speakers: [Speaker] = []

        if let mic {
            let micSegments = mic.segments.map {
                TranscriptSegment(speakerID: "me", start: $0.start, end: $0.end, text: $0.text)
            }
            if !micSegments.isEmpty {
                speakers.append(Speaker(id: "me", name: myName, isMe: true))
            }
            segments.append(contentsOf: micSegments)
        }

        if let system {
            let (systemSegments, systemSpeakers) = labelSystem(system, turns: systemTurns)
            segments.append(contentsOf: systemSegments)
            speakers.append(contentsOf: systemSpeakers)
        }

        // Stable merge: mic segments precede system segments on start-time ties.
        let merged = segments.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)

        // On speakers (no headphones) the far end bleeds into the mic and gets
        // transcribed a second time under "me"; drop those echoed duplicates.
        let deduped = dropEchoedMic(merged)
        let present = Set(deduped.map(\.speakerID))
        return (deduped, speakers.filter { present.contains($0.id) })
    }

    private static func labelSystem(
        _ system: TranscriptionOutput,
        turns: [DiarizedTurn]?
    ) -> ([TranscriptSegment], [Speaker]) {
        guard let turns, !turns.isEmpty else {
            let segs = system.segments.map {
                TranscriptSegment(speakerID: "s1", start: $0.start, end: $0.end, text: $0.text)
            }
            return (segs, segs.isEmpty ? [] : [Speaker(id: "s1", name: "Speaker 1")])
        }

        var idForTurnKey: [String: String] = [:]
        var speakers: [Speaker] = []
        var segments: [TranscriptSegment] = []
        var groupWords: [TranscribedWord] = []
        var groupSpeakerID = ""

        func flush() {
            guard let first = groupWords.first, let last = groupWords.last else { return }
            let text = groupWords
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            segments.append(
                TranscriptSegment(speakerID: groupSpeakerID, start: first.start, end: last.end, text: text)
            )
            groupWords.removeAll()
        }

        for word in system.words {
            let key = turns[turnIndex(for: word, in: turns)].speaker
            let speakerID: String
            if let existing = idForTurnKey[key] {
                speakerID = existing
            } else {
                speakerID = "s\(speakers.count + 1)"
                idForTurnKey[key] = speakerID
                speakers.append(Speaker(id: speakerID, name: "Speaker \(speakers.count + 1)"))
            }
            let gap = groupWords.last.map { word.start - $0.end } ?? 0
            if speakerID != groupSpeakerID || gap > maxWordGap {
                flush()
            }
            groupSpeakerID = speakerID
            groupWords.append(word)
        }
        flush()
        return mergePhantomSpeakers(segments, speakers)
    }

    private static func turnIndex(for word: TranscribedWord, in turns: [DiarizedTurn]) -> Int {
        var bestIndex = 0
        var bestOverlap: TimeInterval = 0
        for (i, turn) in turns.enumerated() {
            let overlap = min(word.end, turn.end) - max(word.start, turn.start)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestIndex = i
            }
        }
        if bestOverlap > 0 { return bestIndex }

        let wordMid = (word.start + word.end) / 2
        var nearest = 0
        var bestDistance = TimeInterval.infinity
        for (i, turn) in turns.enumerated() {
            let distance = abs((turn.start + turn.end) / 2 - wordMid)
            if distance < bestDistance {
                bestDistance = distance
                nearest = i
            }
        }
        return nearest
    }

    // MARK: - Cleanup

    /// FluidAudio can fragment one remote voice into several clusters (worst on
    /// uncapped, no-calendar calls). Fold any speaker holding only a sliver of the
    /// total speech into the dominant speaker, so a 1:1 doesn't surface as
    /// "Speaker 1" + "Speaker 2" for the same person.
    private static func mergePhantomSpeakers(
        _ segments: [TranscriptSegment], _ speakers: [Speaker]
    ) -> ([TranscriptSegment], [Speaker]) {
        guard speakers.count > 1 else { return (segments, speakers) }
        var duration: [String: TimeInterval] = [:]
        for s in segments { duration[s.speakerID, default: 0] += max(0, s.end - s.start) }
        let total = duration.values.reduce(0, +)
        guard total > 0, let dominant = duration.max(by: { $0.value < $1.value })?.key else {
            return (segments, speakers)
        }
        // A real speaker holds more than a few seconds AND a non-trivial share.
        let phantoms = Set(speakers.map(\.id).filter { id in
            id != dominant
                && duration[id, default: 0] < 4
                && duration[id, default: 0] / total < 0.10
        })
        guard !phantoms.isEmpty else { return (segments, speakers) }
        let remapped = segments.map { seg in
            phantoms.contains(seg.speakerID)
                ? TranscriptSegment(speakerID: dominant, start: seg.start, end: seg.end, text: seg.text)
                : seg
        }
        let present = Set(remapped.map(\.speakerID))
        return (remapped, speakers.filter { present.contains($0.id) })
    }

    /// Drops a mic ("me") segment when a system segment overlaps it in time and
    /// carries essentially the same words — the local speakers played the far end
    /// back into the mic. The system tap is a clean digital copy of the far end, so
    /// the system segment is the real one to keep. Short backchannels ("yeah",
    /// "right") are left alone to avoid nuking genuine local speech.
    private static func dropEchoedMic(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let others = segments.filter { $0.speakerID != "me" }
        guard !others.isEmpty else { return segments }
        return segments.filter { seg in
            guard seg.speakerID == "me", wordTokens(seg.text).count >= 4 else { return true }
            let isEcho = others.contains { sys in
                overlaps(seg, sys, tolerance: 2) && covers(seg.text, by: sys.text, atLeast: 0.6)
            }
            return !isEcho
        }
    }

    private static func overlaps(
        _ a: TranscriptSegment, _ b: TranscriptSegment, tolerance: TimeInterval
    ) -> Bool {
        a.start - tolerance < b.end && b.start - tolerance < a.end
    }

    /// True when at least `threshold` of `text`'s words also appear in `other`.
    private static func covers(_ text: String, by other: String, atLeast threshold: Double) -> Bool {
        let words = wordTokens(text)
        guard !words.isEmpty else { return false }
        let vocab = Set(wordTokens(other))
        let hits = words.filter { vocab.contains($0) }.count
        return Double(hits) / Double(words.count) >= threshold
    }

    private static func wordTokens(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
