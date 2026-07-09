import Foundation
import SwiftUI

/// Observable, main-actor face of MeetingArchive for the UI.
@MainActor
final class MeetingStore: ObservableObject {
    let archive: MeetingArchive
    @Published private(set) var meetings: [Meeting] = []

    init(archive: MeetingArchive = MeetingArchive()) {
        self.archive = archive
        reload()
    }

    func reload() {
        meetings = archive.allMeetings()
    }

    func meeting(id: UUID) -> Meeting? {
        meetings.first { $0.id == id } ?? archive.meeting(id: id)
    }

    @discardableResult
    func upsert(_ meeting: Meeting) -> Meeting {
        do {
            try archive.save(meeting)
        } catch MeetingArchive.ArchiveError.meetingDeleted {
            // The meeting was deleted out from under a long-running task —
            // don't resurrect it in memory either.
            meetings.removeAll { $0.id == meeting.id }
            return meeting
        } catch {
            // A transient write failure (disk full, permissions): keep the
            // in-memory entry so the meeting doesn't vanish from the UI.
            return meeting
        }
        if let i = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[i] = meeting
        } else {
            meetings.insert(meeting, at: 0)
            meetings.sort { $0.createdAt > $1.createdAt }
        }
        return meeting
    }

    func delete(id: UUID) {
        try? archive.delete(id: id)
        meetings.removeAll { $0.id == id }
    }

    func transcript(for id: UUID) -> [TranscriptSegment] { archive.transcript(for: id) }

    func saveTranscript(_ segments: [TranscriptSegment], for id: UUID) {
        try? archive.saveTranscript(segments, for: id)
    }

    func summary(for id: UUID) -> String { archive.summary(for: id) }

    func saveSummary(_ markdown: String, for id: UUID) {
        try? archive.saveSummary(markdown, for: id)
    }

    /// Rename a speaker everywhere in one meeting.
    func renameSpeaker(meetingID: UUID, speakerID: String, to newName: String) {
        guard var m = meeting(id: meetingID) else { return }
        guard let i = m.speakers.firstIndex(where: { $0.id == speakerID }) else { return }
        m.speakers[i].name = newName
        upsert(m)
    }
}
