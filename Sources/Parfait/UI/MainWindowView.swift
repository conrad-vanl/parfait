import SwiftUI

enum SidebarItem: Hashable {
    case meeting(UUID)
}

struct MainWindowView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.colorScheme) private var scheme
    @State private var selection: SidebarItem?
    @State private var query = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 270)
        } detail: {
            detail
        }
        .toolbar {
            Button {
                ClaudeLink.open(prompt: ClaudeLink.libraryPrompt())
            } label: {
                Label("Ask Claude", systemImage: "sparkles")
            }
            .help("Ask Claude across your whole meeting library")
        }
        .background(Theme.surface(scheme))
        .onAppear { adoptPendingSelection() }
        .onChange(of: app.openMeetingID) { adoptPendingSelection() }
    }

    private func adoptPendingSelection() {
        if let id = app.openMeetingID {
            selection = .meeting(id)
            app.openMeetingID = nil
        } else if selection == nil, let first = app.store.meetings.first {
            selection = .meeting(first.id)
        }
    }

    private var filtered: [Meeting] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return app.store.meetings }
        return app.store.meetings.filter { m in
            m.title.lowercased().contains(q)
                || m.attendees.contains { $0.lowercased().contains(q) }
                || (m.sourceApp?.lowercased().contains(q) ?? false)
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Meetings") {
                ForEach(filtered) { meeting in
                    MeetingRow(meeting: meeting, stage: app.processingStage[meeting.id])
                        .tag(SidebarItem.meeting(meeting.id))
                        .contextMenu {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [app.store.archive.folder(for: meeting.id)])
                            }
                            Button("Delete…", role: .destructive) {
                                app.store.delete(id: meeting.id)
                                if selection == .meeting(meeting.id) { selection = nil }
                            }
                        }
                }
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Filter meetings")
        .safeAreaInset(edge: .bottom) {
            if let session = app.session {
                SidebarRecordingStrip(session: session)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .meeting(let id):
            if let meeting = app.store.meetings.first(where: { $0.id == id }) {
                MeetingDetailView(meeting: meeting)
                    .id(id)
            } else {
                EmptyStateView(
                    title: "Meeting not found",
                    message: "It may have been deleted.")
            }
        case nil:
            EmptyStateView(
                title: "No meeting selected",
                message: "Record your first meeting from the parfait glass in the menu bar — it all stays on this Mac.")
        }
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    let stage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title)
                .font(.parfait(13, .medium))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.parfait(11))
                    .foregroundStyle(.secondary)
                if meeting.duration > 0 {
                    Text(TemplateRenderer.duration(meeting.duration))
                        .font(.parfait(11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                StateBadge(meeting: meeting, stage: stage)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SidebarRecordingStrip: View {
    @ObservedObject var session: RecordingSession
    @EnvironmentObject private var app: AppState

    var body: some View {
        HStack(spacing: 8) {
            RecordDot()
            Text(timeString(session.elapsed))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
            Spacer()
            Button("Stop") { Task { await app.stopRecording() } }
                .buttonStyle(.borderedProminent)
                .tint(Theme.raspberry)
                .controlSize(.small)
        }
        .padding(10)
        .background(.thinMaterial)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
