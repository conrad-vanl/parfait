import Foundation

/// File-backed meeting storage. One folder per meeting:
///
///     <root>/Meetings/<uuid>/
///         meeting.json      Meeting
///         transcript.json   [TranscriptSegment]
///         summary.md        markdown
///         mic.m4a           the user's microphone
///         system.m4a        everyone else (process tap)
///
/// Thread-safe for the app's usage pattern: the UI goes through the
/// @MainActor MeetingStore wrapper; the MCP server process is read-only.
final class MeetingArchive: @unchecked Sendable {
    let root: URL

    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parfait", isDirectory: true)
    }

    private let queue = DispatchQueue(label: "io.github.conrad-vanl.Parfait.archive")
    // ISO8601 with fractional seconds so Dates round-trip losslessly enough for Equatable.
    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(MeetingArchive.dateFormatter.string(from: date))
        }
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = MeetingArchive.dateFormatter.date(from: s)
                ?? ISO8601DateFormatter().date(from: s)
            else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: dec.codingPath, debugDescription: "Bad date: \(s)"))
            }
            return date
        }
        return d
    }()

    init(root: URL = MeetingArchive.defaultRoot) {
        self.root = root
        try? FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
    }

    var meetingsDir: URL { root.appendingPathComponent("Meetings", isDirectory: true) }

    func folder(for id: UUID) -> URL {
        meetingsDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }
    func micURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("mic.m4a") }
    func systemURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("system.m4a") }

    // MARK: - Meetings

    func allMeetings() -> [Meeting] {
        queue.sync {
            let dirs = (try? FileManager.default.contentsOfDirectory(
                at: meetingsDir, includingPropertiesForKeys: nil)) ?? []
            return dirs.compactMap { dir in
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("meeting.json"))
                else { return nil }
                return try? decoder.decode(Meeting.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
        }
    }

    func meeting(id: UUID) -> Meeting? {
        queue.sync {
            guard let data = try? Data(contentsOf: folder(for: id).appendingPathComponent("meeting.json"))
            else { return nil }
            return try? decoder.decode(Meeting.self, from: data)
        }
    }

    func save(_ meeting: Meeting) throws {
        try queue.sync {
            let dir = folder(for: meeting.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try encoder.encode(meeting)
            try data.write(to: dir.appendingPathComponent("meeting.json"), options: .atomic)
        }
    }

    func delete(id: UUID) throws {
        try queue.sync {
            try FileManager.default.removeItem(at: folder(for: id))
        }
    }

    // MARK: - Transcript

    func transcript(for id: UUID) -> [TranscriptSegment] {
        queue.sync {
            guard let data = try? Data(contentsOf: folder(for: id).appendingPathComponent("transcript.json"))
            else { return [] }
            return (try? decoder.decode([TranscriptSegment].self, from: data)) ?? []
        }
    }

    func saveTranscript(_ segments: [TranscriptSegment], for id: UUID) throws {
        try queue.sync {
            let data = try encoder.encode(segments)
            try data.write(to: folder(for: id).appendingPathComponent("transcript.json"), options: .atomic)
        }
    }

    // MARK: - Summary

    func summary(for id: UUID) -> String {
        queue.sync {
            (try? String(contentsOf: folder(for: id).appendingPathComponent("summary.md"), encoding: .utf8)) ?? ""
        }
    }

    func saveSummary(_ markdown: String, for id: UUID) throws {
        try queue.sync {
            try markdown.data(using: .utf8)!
                .write(to: folder(for: id).appendingPathComponent("summary.md"), options: .atomic)
        }
    }

    // MARK: - Search

    struct SearchHit: Sendable {
        var meeting: Meeting
        /// Segments (or summary lines) containing the query, capped per meeting.
        var excerpts: [String]
        var score: Int
    }

    /// Case-insensitive multi-word search over titles, summaries, transcripts, attendees.
    func search(_ query: String, limit: Int = 20) -> [SearchHit] {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for meeting in allMeetings() {
            var score = 0
            var excerpts: [String] = []
            let title = meeting.title.lowercased()
            for w in words where title.contains(w) { score += 10 }
            for name in meeting.attendees where words.contains(where: { name.lowercased().contains($0) }) {
                score += 6
                excerpts.append("Attendee: \(name)")
            }
            let summary = summary(for: meeting.id)
            for line in summary.split(separator: "\n") {
                let lower = line.lowercased()
                if words.contains(where: { lower.contains($0) }) {
                    score += 3
                    if excerpts.count < 6 { excerpts.append(String(line).trimmingCharacters(in: .whitespaces)) }
                }
            }
            let speakerNames = Dictionary(uniqueKeysWithValues: meeting.speakers.map { ($0.id, $0.name) })
            for seg in transcript(for: meeting.id) {
                let lower = seg.text.lowercased()
                if words.contains(where: { lower.contains($0) }) {
                    score += 1
                    if excerpts.count < 6 {
                        let who = speakerNames[seg.speakerID] ?? seg.speakerID
                        excerpts.append("\(who) @ \(Self.timestamp(seg.start)): \(seg.text)")
                    }
                }
            }
            if score > 0 { hits.append(SearchHit(meeting: meeting, excerpts: excerpts, score: score)) }
        }
        return hits.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    static func timestamp(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
