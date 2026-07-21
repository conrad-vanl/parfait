import SwiftUI

/// The cross-meeting follow-ups queue: every meeting's items in one place,
/// where instructions get reviewed and edited before the one-prompt handoff
/// ("Work on my follow-ups with Claude"). Reviewing here IS the approval —
/// Claude works whatever survives curation.
struct FollowupsView: View {
    private struct MeetingGroup: Identifiable {
        let meeting: Meeting
        let items: [Followup]
        var id: UUID { meeting.id }
    }

    @EnvironmentObject private var app: AppState
    /// Read fresh from disk on every appearance and after every mutation —
    /// followups.json is also written by Claude in a separate MCP process.
    @State private var groups: [MeetingGroup] = []
    @State private var showCompleted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if visibleGroups.isEmpty {
                EmptyStateView(
                    title: "No follow-ups",
                    message: showCompleted
                        ? "Nothing here yet — follow-ups are suggested when a meeting's notes are ready."
                        : "Nothing open. Follow-ups are suggested when a meeting's notes are ready; review them here, then hand them to Claude.")
            } else {
                list
            }
        }
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
    }

    private func reload() {
        groups = app.store.allFollowups().map { MeetingGroup(meeting: $0.meeting, items: $0.items) }
    }

    private var openCount: Int {
        groups.reduce(0) { $0 + $1.items.filter(\.isOpen).count }
    }

    /// Open items first within each meeting; done/dismissed only behind the
    /// toggle. Meetings with nothing visible drop out entirely.
    private var visibleGroups: [MeetingGroup] {
        groups.compactMap { group in
            let open = group.items.filter(\.isOpen)
            let items = showCompleted ? open + group.items.filter { !$0.isOpen } : open
            return items.isEmpty ? nil : MeetingGroup(meeting: group.meeting, items: items)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(openCount == 1 ? "1 open item" : "\(openCount) open items")
                .font(.parfait(12))
                .foregroundStyle(.secondary)
            Toggle("Show completed", isOn: $showCompleted)
                .toggleStyle(.checkbox)
                .font(.parfait(11))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                ClaudeLink.openFollowups(scope: .all)
            } label: {
                Label("Work on my follow-ups with Claude", systemImage: "sparkles")
                    .font(.parfait(12, .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.raspberry)
            .disabled(openCount == 0)
            .help("Hand every open follow-up to Claude in one chat")
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(visibleGroups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(group.meeting.title)
                                .font(.parfait(13, .semibold))
                                .lineLimit(1)
                            Text(group.meeting.createdAt.formatted(
                                .relative(presentation: .named)))
                                .font(.parfait(11))
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(group.items) { item in
                            FollowupItemCard(
                                meetingID: group.meeting.id,
                                item: item,
                                onMutate: reload)
                        }
                    }
                }
            }
            .frame(maxWidth: 660, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One editable follow-up: the read-only row plus the item's "instructions for
/// Claude" (suggestedAction) as an inline editor, and the act-on-it buttons.
private struct FollowupItemCard: View {
    @EnvironmentObject private var app: AppState
    let meetingID: UUID
    let item: Followup
    let onMutate: () -> Void

    @State private var instructions = ""
    @FocusState private var editingInstructions: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FollowupRow(item: item)
            if item.isOpen {
                TextField("Instructions for Claude…", text: $instructions, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.parfait(12))
                    .lineLimit(1...6)
                    .focused($editingInstructions)
                    .onSubmit { commitInstructions() }
                    .help("What Claude should do for this item — edit before handing it off")
                HStack(spacing: 14) {
                    Button("Done") { setStatus(.done) }
                        .help("Mark this item finished")
                    Button("Dismiss") { setStatus(.dismissed) }
                        .help("Drop this item — Claude never touches dismissed items")
                    Button {
                        commitInstructions()
                        ClaudeLink.openFollowups(scope: .item(
                            meetingID: meetingID, itemID: item.id, title: item.title))
                    } label: {
                        Label("Hand to Claude", systemImage: "sparkles")
                    }
                    .help("Have Claude work this one item")
                    Spacer()
                }
                .font(.parfait(11, .medium))
                .buttonStyle(.borderless)
            } else if let action = item.suggestedAction, !action.isEmpty {
                Text(action)
                    .font(.parfait(12))
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
        .onAppear { instructions = item.suggestedAction ?? "" }
        .onChange(of: item.id) { instructions = item.suggestedAction ?? "" }
        // An external writer (MCP process, another surface) may change the
        // instructions while this card is on screen — resync unless the user
        // is mid-edit, or a later focus-loss commit would clobber their write
        // with our stale copy.
        .onChange(of: item.suggestedAction) {
            if !editingInstructions { instructions = item.suggestedAction ?? "" }
        }
        .onChange(of: editingInstructions) {
            if !editingInstructions { commitInstructions() }
        }
    }

    private func commitInstructions() {
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue = trimmed.isEmpty ? nil : trimmed
        guard newValue != item.suggestedAction else { return }
        app.store.updateFollowup(meetingID: meetingID, itemID: item.id) {
            $0.suggestedAction = newValue
        }
        onMutate()
    }

    private func setStatus(_ status: Followup.Status) {
        app.store.updateFollowup(meetingID: meetingID, itemID: item.id) {
            $0.status = status
        }
        onMutate()
    }
}

/// The read-only follow-up row: kind icon, title, owner, result link, status
/// capsule. Shared by the Follow-ups tab (inside the editable card) and the
/// NotesTab followups section.
struct FollowupRow: View {
    let item: Followup

    private var muted: Bool { item.status == .done || item.status == .dismissed }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.parfait(12))
                .foregroundStyle(.secondary)
            Text(item.title)
                .font(.parfait(12))
                .strikethrough(item.status == .done)
                .foregroundStyle(muted ? Color.secondary : Color.primary)
                .lineLimit(2)
            if let owner = item.owner {
                Text(owner)
                    .font(.parfait(11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Claude-written field with untrusted provenance — only open web URLs,
            // matching the follow-up card's http(s) allow-list.
            if let result = item.resultURL, let url = URL(string: result),
               url.scheme == "http" || url.scheme == "https" {
                Link(destination: url) {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.parfait(11))
                }
                .help(result)
            }
            Text(statusLabel)
                .font(.parfait(10, .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(statusColor.opacity(0.16), in: Capsule())
                .foregroundStyle(.secondary)
        }
    }

    private var icon: String {
        switch item.kind {
        case .action: return "checkmark.circle"
        case .question: return "questionmark.circle"
        case .followup: return "arrow.uturn.right.circle"
        }
    }

    private var statusLabel: String {
        switch item.status {
        case .proposed: return "proposed"
        case .approved: return "approved"
        case .inProgress: return "in progress"
        case .done: return "done"
        case .dismissed: return "dismissed"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .proposed: return Theme.honey
        case .approved: return Theme.blueberry
        case .inProgress: return Theme.raspberry
        case .done: return Theme.mint
        case .dismissed: return .gray
        }
    }
}
