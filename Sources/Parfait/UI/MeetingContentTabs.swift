import SwiftUI

struct NotesTab: View {
    @EnvironmentObject private var app: AppState
    let meeting: Meeting
    /// Owned by MeetingDetailView so tab switches can't drop an unsaved edit.
    @Binding var draft: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                templateMenu
                summaryBadge
                Spacer()
                if draft != nil {
                    Button("Cancel") { draft = nil }
                    Button("Save") {
                        if let draft { app.store.saveSummary(draft, for: meeting.id) }
                        draft = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.raspberry)
                } else {
                    Button {
                        draft = app.store.summary(for: meeting.id)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .disabled(summary.isEmpty || streaming != nil)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            if draft != nil {
                TextEditor(text: Binding(get: { draft ?? "" }, set: { draft = $0 }))
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .cardStyle()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            } else if displayed.isEmpty {
                if streaming != nil || app.processingStage[meeting.id] != nil {
                    EmptyStateView(
                        title: "Working on it…",
                        message: app.processingStage[meeting.id] ?? "Writing your notes…")
                } else {
                    EmptyStateView(
                        title: "No notes yet",
                        message: meeting.notice ?? "Press Regenerate once the transcript exists, or check Settings → Intelligence.")
                }
            } else {
                ScrollView {
                    MarkdownText(markdown: displayed)
                        .frame(maxWidth: 660, alignment: .leading)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var summary: String { app.store.summary(for: meeting.id) }
    /// Notes streaming in right now (nil once a pass is saved). Shown in place of
    /// the saved summary so the reader watches the draft fill in.
    private var streaming: String? { app.streamingSummaries[meeting.id] }
    private var displayed: String { streaming ?? summary }

    /// "Writing…" while the draft streams; "Draft · improving" while the accurate
    /// transcript is being turned into the better version.
    @ViewBuilder
    private var summaryBadge: some View {
        if let progress = app.summaryProgress[meeting.id] {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).scaleEffect(0.6)
                Text(progress == .improving ? "Draft · improving" : "Writing…")
                    .font(.parfait(11))
                    .foregroundStyle(.secondary)
            }
            .help(progress == .improving
                  ? "These notes were drafted from the live transcript. A more accurate version is on the way."
                  : "Writing notes from the transcript…")
        }
    }

    private var templateMenu: some View {
        Menu {
            ForEach(app.templates.list()) { template in
                Button(template.name) {
                    Task {
                        await app.regenerateSummary(
                            meetingID: meeting.id, templateName: template.name)
                    }
                }
            }
            Divider()
            Button("Regenerate with current template") {
                Task { await app.regenerateSummary(meetingID: meeting.id) }
            }
        } label: {
            Label(meeting.templateName ?? AppSettings.defaultTemplate,
                  systemImage: "doc.text")
                .font(.parfait(12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Rewrite the notes with a different template")
    }
}

struct TranscriptTab: View {
    @EnvironmentObject private var app: AppState
    let meeting: Meeting
    /// Owned by MeetingDetailView so tab switches can't drop an unsaved edit.
    @Binding var draft: String?

    @State private var renaming: Speaker?
    @State private var newName = ""

    private var segments: [TranscriptSegment] { app.store.transcript(for: meeting.id) }

    var body: some View {
        if let session = app.session, session.meetingID == meeting.id {
            LiveTranscriptView(session: session)
        } else {
            savedTranscript
        }
    }

    private var savedTranscript: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(segments.isEmpty ? "" : "\(segments.count) segments")
                    .font(.parfait(11))
                    .foregroundStyle(.tertiary)
                Spacer()
                if draft != nil {
                    Button("Cancel") { draft = nil }
                    Button("Save") { saveEdits() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.raspberry)
                } else {
                    Button {
                        draft = TranscriptFormatter.plainText(segments, speakers: meeting.speakers)
                    } label: {
                        Label("Edit as text", systemImage: "pencil")
                    }
                    .disabled(segments.isEmpty)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            if draft != nil {
                TextEditor(text: Binding(get: { draft ?? "" }, set: { draft = $0 }))
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .cardStyle()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            } else if segments.isEmpty {
                EmptyStateView(
                    title: "No transcript",
                    message: meeting.state == .processing
                        ? "Transcription is still running."
                        : "Nothing was transcribed for this meeting.")
            } else {
                turnsList
            }
        }
        .sheet(item: $renaming) { speaker in
            renameSheet(speaker)
        }
    }

    private var turnsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(groupedTurns, id: \.id) { turn in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Button {
                                newName = name(for: turn.speakerID)
                                renaming = meeting.speakers.first { $0.id == turn.speakerID }
                                    ?? Speaker(id: turn.speakerID, name: name(for: turn.speakerID))
                            } label: {
                                Text(name(for: turn.speakerID))
                                    .font(.parfait(12, .bold))
                                    .foregroundStyle(turn.speakerID == "me" ? Theme.blueberry : Theme.raspberry)
                            }
                            .buttonStyle(.plain)
                            .help("Rename this speaker everywhere")
                            Text(MeetingArchive.timestamp(turn.start))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Text(turn.text)
                            .font(.parfait(13))
                            .textSelection(.enabled)
                            .lineSpacing(2)
                    }
                }
            }
            .frame(maxWidth: 660, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private struct Turn: Identifiable {
        let id = UUID()
        let speakerID: String
        let start: TimeInterval
        let text: String
    }

    private var groupedTurns: [Turn] {
        var turns: [Turn] = []
        var speaker: String?
        var start: TimeInterval = 0
        var texts: [String] = []
        func flush() {
            if let s = speaker, !texts.isEmpty {
                turns.append(Turn(speakerID: s, start: start, text: texts.joined(separator: " ")))
            }
        }
        for seg in segments {
            if seg.speakerID != speaker {
                flush()
                speaker = seg.speakerID
                start = seg.start
                texts = []
            }
            texts.append(seg.text)
        }
        flush()
        return turns
    }

    private func name(for speakerID: String) -> String {
        meeting.speakers.first { $0.id == speakerID }?.name ?? speakerID
    }

    private func renameSheet(_ speaker: Speaker) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \(speaker.name)")
                .font(.parfait(15, .semibold))
            TextField("Name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { commitRename(speaker) }
            if !meeting.attendees.isEmpty {
                Text("From the calendar invite:")
                    .font(.parfait(11))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(meeting.attendees, id: \.self) { attendee in
                        Button { newName = attendee } label: { Chip(text: attendee) }
                            .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { renaming = nil }
                Button("Rename") { commitRename(speaker) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.raspberry)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func commitRename(_ speaker: Speaker) {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        app.store.renameSpeaker(meetingID: meeting.id, speakerID: speaker.id, to: n)
        renaming = nil
    }

    private func saveEdits() {
        guard let text = draft else { return }
        let (parsed, speakers) = TranscriptFormatter.parseEdited(
            text, originalSegments: segments, speakers: meeting.speakers)
        guard !parsed.isEmpty else { draft = nil; return }
        app.store.saveTranscript(parsed, for: meeting.id)
        // Re-fetch: don't clobber concurrent changes with the view's snapshot.
        if var fresh = app.store.meeting(id: meeting.id) {
            fresh.speakers = speakers
            app.store.upsert(fresh)
        }
        draft = nil
    }
}

/// Read-only live transcript shown in the Transcript tab while a meeting is being
/// recorded (and mirrored by the floating recording card). Observes the session so
/// it updates in real time; the accurate, diarized transcript replaces it once
/// processing finishes.
struct LiveTranscriptView: View {
    @ObservedObject var session: RecordingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                RecordDot()
                Text("Live — transcribing as the meeting happens. The final, more accurate transcript is created when you stop.")
                    .font(.parfait(11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            if session.liveSegments.isEmpty, session.volatileText.isEmpty {
                EmptyStateView(
                    title: "Listening…",
                    message: "The live transcript appears here as people speak.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(LiveTranscriber.turns(from: session.liveSegments)) { turn in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(LiveTranscriber.name(for: turn.speakerID))
                                        .font(.parfait(12, .bold))
                                        .foregroundStyle(turn.speakerID == LiveTranscriber.youSpeakerID
                                                         ? Theme.blueberry : Theme.raspberry)
                                    Text(turn.text)
                                        .font(.parfait(13))
                                        .textSelection(.enabled)
                                        .lineSpacing(2)
                                }
                            }
                            if !session.volatileText.isEmpty {
                                Text(session.volatileText)
                                    .font(.parfait(13))
                                    .foregroundStyle(.secondary)
                                    .italic()
                            }
                            Color.clear.frame(height: 1).id("live-bottom")
                        }
                        .frame(maxWidth: 660, alignment: .leading)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: session.liveSegments.count) { proxy.scrollTo("live-bottom", anchor: .bottom) }
                    .onChange(of: session.volatileText) { proxy.scrollTo("live-bottom", anchor: .bottom) }
                }
            }
        }
    }
}
