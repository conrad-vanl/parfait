import Foundation

/// Word-level text helpers shared by the batch (SpeakerLabeler) and live
/// (LiveTranscriber) echo dedup. Both decide whether one transcript segment is a
/// re-transcription of another by comparing their word sets.
enum TranscriptText {
    /// Lowercased alphanumeric word tokens.
    static func wordTokens(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// True when at least `threshold` of `text`'s words also appear in `other`.
    static func covers(_ text: String, by other: String, atLeast threshold: Double) -> Bool {
        let words = wordTokens(text)
        guard !words.isEmpty else { return false }
        let vocab = Set(wordTokens(other))
        let hits = words.filter { vocab.contains($0) }.count
        return Double(hits) / Double(words.count) >= threshold
    }
}
