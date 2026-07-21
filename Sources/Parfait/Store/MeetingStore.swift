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

    func followups(for id: UUID) -> [Followup] { archive.followups(for: id) }

    func saveSummary(_ markdown: String, for id: UUID) {
        try? archive.saveSummary(markdown, for: id)
    }

    /// Rename a speaker everywhere in one meeting. Returns whether the rename
    /// actually applied (the speaker existed).
    @discardableResult
    func renameSpeaker(meetingID: UUID, speakerID: String, to newName: String) -> Bool {
        guard var m = meeting(id: meetingID) else { return false }
        guard let i = m.speakers.firstIndex(where: { $0.id == speakerID }) else { return false }
        m.speakers[i].name = newName
        upsert(m)
        return true
    }

    /// Merge one speaker into another: every transcript segment of `fromID` is
    /// remapped to the survivor and the now-empty speaker entry is removed.
    /// The survivor keeps `intoID`'s id and name — except that "me" (and its
    /// isMe flag) always survives a merge, whichever direction it ran.
    @discardableResult
    func mergeSpeakers(meetingID: UUID, from fromID: String, into intoID: String) -> Bool {
        guard fromID != intoID, var m = meeting(id: meetingID),
              let into = m.speakers.first(where: { $0.id == intoID })
        else { return false }
        let from = m.speakers.first(where: { $0.id == fromID })
        let survivorID = from?.isMe == true ? fromID : intoID
        let removedID = survivorID == fromID ? intoID : fromID
        let segments = transcript(for: meetingID).map { segment in
            var segment = segment
            if segment.speakerID == removedID { segment.speakerID = survivorID }
            return segment
        }
        saveTranscript(segments, for: meetingID)
        m.speakers.removeAll { $0.id == removedID }
        if let i = m.speakers.firstIndex(where: { $0.id == survivorID }) {
            m.speakers[i].name = into.name
            m.speakers[i].isMe = from?.isMe == true || into.isMe
        }
        upsert(m)
        return true
    }
}
