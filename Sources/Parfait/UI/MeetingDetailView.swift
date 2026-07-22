import AppKit
import SwiftUI

struct MeetingDetailView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.colorScheme) private var scheme

    @State private var meeting: Meeting
    @State private var tab: Tab = .notes
    @State private var title: String
    @State private var publishState: PublishState = .idle
    @State private var showDeleteConfirm = false
    @AppStorage(SettingsKey.publishTranscript) private var publishTranscript = true
    // Edit drafts live here, not in the tab views, so an accidental tab switch
    // can't destroy ten minutes of transcript fixes. nil = not editing.
    @State private var notesDraft: String?
    @State private var transcriptDraft: String?

    enum Tab: String, CaseIterable {
        case notes = "Notes"
        case transcript = "Transcript"
        case followups = "Follow ups"
    }

    enum PublishState: Equatable {
        case idle, working
        case done(URL)
        case failed(String)
    }

    init(meeting: Meeting) {
        _meeting = State(initialValue: meeting)
        _title = State(initialValue: meeting.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(20)
            Divider()
            content
        }
        .background(Theme.surface(scheme))
        .onChange(of: app.store.meetings) {
            if let fresh = app.store.meetings.first(where: { $0.id == meeting.id }) {
                meeting = fresh
                if !isEditingTitle { title = fresh.title }
            }
        }
    }

    @FocusState private var isEditingTitle: Bool

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Meeting title", text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.parfait(24, .bold))
                    .lineLimit(2)
                    .focused($isEditingTitle)
                    .onSubmit(saveTitle)
                    .onChange(of: isEditingTitle) { if !isEditingTitle { saveTitle() } }
                Spacer()
                if meeting.state == .ready {
                    Button {
                        ClaudeLink.open(prompt: ClaudeLink.meetingPrompt(
                            meetingID: meeting.id, title: meeting.title))
                    } label: {
                        Label("Open in Claude", systemImage: "sparkles")
                            .font(.parfait(13, .medium))
                    }
                    .buttonStyle(.borderless)
                    .help("Ask Claude about this meeting")
                }
                publishMenu
            }

            HStack(spacing: 8) {
                Text(meeting.createdAt.formatted(date: .complete, time: .shortened))
                    .font(.parfait(12))
                    .foregroundStyle(.secondary)
                if meeting.duration > 0 {
                    Text("·").foregroundStyle(.tertiary)
                    Text(TemplateRenderer.duration(meeting.duration))
                        .font(.parfait(12))
                        .foregroundStyle(.secondary)
                }
                if let source = meeting.sourceApp {
                    Text("·").foregroundStyle(.tertiary)
                    Text(source).font(.parfait(12)).foregroundStyle(.secondary)
                }
                ProviderBadge(provider: meeting.summaryProvider)
                Spacer()
                if let stage = app.processingStage[meeting.id] {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text(stage).font(.parfait(12)).foregroundStyle(.secondary)
                    }
                }
            }

            if !meeting.attendees.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(meeting.attendees, id: \.self) { Chip(text: $0) }
                }
            }

            if let notice = meeting.notice {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.parfait(12))
                        .foregroundStyle(.orange)
                    Button(meeting.state == .failed ? "Retry" : "Regenerate") {
                        Task { await app.retry(meetingID: meeting.id) }
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            }

            if case .done(let url) = publishState {
                HStack(spacing: 8) {
                    Label("Published", systemImage: "checkmark.circle.fill")
                        .font(.parfait(12, .medium))
                        .foregroundStyle(Theme.mint)
                    Link(url.absoluteString, destination: url)
                        .font(.parfait(12))
                        .lineLimit(1)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                    .controlSize(.small)
                }
            } else if case .failed(let why) = publishState {
                Label(why, systemImage: "xmark.circle")
                    .font(.parfait(12))
                    .foregroundStyle(.orange)
            }

            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 340, alignment: .leading)
            .padding(.top, 6)
        }
    }

    private var publishMenu: some View {
        Menu {
            if GitHubGist.isAvailable {
                Button("Create shareable link") { publish() }
            } else {
                Button("Create shareable link (needs gh)") {}
                    .disabled(true)
            }
            Button("Preview in browser") { previewInBrowser() }
            Toggle("Include transcript", isOn: $publishTranscript)
            if let existing = meeting.publishedURL, let url = URL(string: existing) {
                Divider()
                Link("Open published page", destination: url)
            }
            Divider()
            Button("Export HTML…") { exportHTML() }
            Button("Show files in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [app.store.archive.folder(for: meeting.id)])
            }
            Divider()
            Button("Delete meeting…", role: .destructive) { showDeleteConfirm = true }
        } label: {
            if publishState == .working {
                ProgressView().controlSize(.small)
            } else {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.parfait(13, .medium))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .confirmationDialog("Delete “\(meeting.title)”?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { app.store.delete(id: meeting.id) }
        } message: {
            Text("This permanently removes the audio, transcript, and notes from your Mac.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .notes:
            NotesTab(meeting: meeting, draft: $notesDraft)
        case .transcript:
            TranscriptTab(meeting: meeting, draft: $transcriptDraft)
        case .followups:
            MeetingFollowupsTab(meeting: meeting)
        }
    }

    private func saveTitle() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != meeting.title else { return }
        var m = meeting
        m.title = t
        app.store.upsert(m)
    }

    private func publish() {
        publishState = .working
        let m = meeting
        let summary = app.store.summary(for: m.id)
        let segments = publishTranscript ? app.store.transcript(for: m.id) : []
        let followups = app.store.followups(for: m.id)
        Task {
            do {
                let html = HTMLExporter.html(meeting: m, summaryMarkdown: summary, segments: segments, followups: followups)
                let (_, rendered) = try await GitHubGist.publish(
                    html: html,
                    filename: "meeting.html",
                    description: "Parfait meeting notes — \(m.title)")
                // Re-fetch: the upload took a while and the meeting may have been
                // edited (merge) or deleted (then don't resurrect it) meanwhile.
                if var fresh = app.store.meeting(id: m.id) {
                    fresh.publishedURL = rendered.absoluteString
                    app.store.upsert(fresh)
                }
                publishState = .done(rendered)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rendered.absoluteString, forType: .string)
            } catch {
                publishState = .failed(error.localizedDescription)
            }
        }
    }

    /// No dependencies: render the page to a temp file and open it in the default
    /// browser. Nothing is uploaded — the honest way to see the styled page (and
    /// share the file) without gh.
    private func previewInBrowser() {
        let html = HTMLExporter.html(
            meeting: meeting,
            summaryMarkdown: app.store.summary(for: meeting.id),
            segments: publishTranscript ? app.store.transcript(for: meeting.id) : [],
            followups: app.store.followups(for: meeting.id))
        let safeName = meeting.title.replacingOccurrences(of: "/", with: "-")
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("Parfait — \(safeName).html")
        do {
            try html.data(using: .utf8)?.write(to: file)
            NSWorkspace.shared.open(file)
        } catch {
            publishState = .failed(error.localizedDescription)
        }
    }

    private func exportHTML() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = meeting.title.replacingOccurrences(of: "/", with: "-") + ".html"
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let html = HTMLExporter.html(
            meeting: meeting,
            summaryMarkdown: app.store.summary(for: meeting.id),
            segments: publishTranscript ? app.store.transcript(for: meeting.id) : [],
            followups: app.store.followups(for: meeting.id))
        try? html.data(using: .utf8)?.write(to: dest)
    }
}
