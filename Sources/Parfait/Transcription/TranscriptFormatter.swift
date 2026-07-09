import Foundation

/// Renders transcripts as text for prompts, export, editing, and MCP responses.
enum TranscriptFormatter {
    /// "Alice @ 12:04: We should ship on Friday."
    static func plainText(_ segments: [TranscriptSegment], speakers: [Speaker]) -> String {
        let names = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.name) })
        return segments.map { seg in
            let who = names[seg.speakerID] ?? seg.speakerID
            return "\(who) @ \(MeetingArchive.timestamp(seg.start)): \(seg.text)"
        }
        .joined(separator: "\n")
    }

    /// Markdown with bolded speaker turns; consecutive segments by the same speaker merge
    /// into one paragraph for readability.
    static func markdown(_ segments: [TranscriptSegment], speakers: [Speaker]) -> String {
        let names = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.name) })
        var out: [String] = []
        var currentSpeaker: String?
        var currentTexts: [String] = []
        var currentStart: TimeInterval = 0

        func flush() {
            guard let s = currentSpeaker, !currentTexts.isEmpty else { return }
            let who = names[s] ?? s
            out.append("**\(who)** · \(MeetingArchive.timestamp(currentStart))\n\(currentTexts.joined(separator: " "))")
        }

        for seg in segments {
            if seg.speakerID != currentSpeaker {
                flush()
                currentSpeaker = seg.speakerID
                currentTexts = []
                currentStart = seg.start
            }
            currentTexts.append(seg.text)
        }
        flush()
        return out.joined(separator: "\n\n")
    }

    /// Parse the editable plain-text form back into segments. Lines that match
    /// "Name @ m:ss: text" update speaker/text; unmatched lines append to the previous
    /// segment. Unknown speaker names create new speakers. Returns updated segments+speakers.
    static func parseEdited(
        _ text: String,
        originalSegments: [TranscriptSegment],
        speakers: [Speaker]
    ) -> ([TranscriptSegment], [Speaker]) {
        var speakers = speakers
        var idsByName = Dictionary(speakers.map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })
        var segments: [TranscriptSegment] = []
        var nextSpeakerNum = speakers.filter { !$0.isMe }.count + 1

        let pattern = #/^(.+?) @ (\d+):(\d{2}): ?(.*)$/#
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if let m = try? pattern.wholeMatch(in: line) {
                let name = String(m.1).trimmingCharacters(in: .whitespaces)
                let minutes: Int = Int(m.2) ?? 0
                let seconds: Int = Int(m.3) ?? 0
                let start = TimeInterval(minutes * 60 + seconds)
                let body = String(m.4)
                let speakerID: String
                if let existing = idsByName[name] {
                    speakerID = existing
                } else {
                    speakerID = "s\(nextSpeakerNum)"
                    nextSpeakerNum += 1
                    speakers.append(Speaker(id: speakerID, name: name))
                    idsByName[name] = speakerID
                }
                // Reuse the original end time when the segment lines up, else estimate.
                let original = originalSegments.first { abs($0.start - start) < 0.5 }
                segments.append(TranscriptSegment(
                    speakerID: speakerID,
                    start: start,
                    end: original?.end ?? start,
                    text: body
                ))
            } else if !segments.isEmpty {
                segments[segments.count - 1].text += " " + line.trimmingCharacters(in: .whitespaces)
            }
        }
        return (segments, speakers)
    }
}
