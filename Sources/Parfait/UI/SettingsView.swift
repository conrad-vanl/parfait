import AppKit
import AVFoundation
import SwiftUI
import UserNotifications

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            IntelligenceSettings()
                .tabItem { Label("Intelligence", systemImage: "sparkles") }
            TemplateSettings()
                .tabItem { Label("Templates", systemImage: "doc.text") }
        }
        .frame(width: 560, height: 480)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SettingsKey.detectMeetings) private var detectMeetings = true
    @AppStorage(SettingsKey.autoRecord) private var autoRecord = false
    @AppStorage(SettingsKey.autoStopRecording) private var autoStopRecording = true
    @AppStorage(SettingsKey.identifySpeakers) private var identifySpeakers = true
    @AppStorage(SettingsKey.useCalendar) private var useCalendar = true
    @AppStorage(SettingsKey.defaultTemplate) private var defaultTemplate = "Meeting Notes"
    @AppStorage(SettingsKey.systemAudioConfirmed) private var systemAudioConfirmed = false
    @AppStorage(SettingsKey.captureScreenshots) private var captureScreenshots = false

    @State private var micStatus = MicRecorder.permissionGranted
    @State private var calendarStatus = CalendarMatcher.isAuthorized
    @State private var launchAtLogin = LaunchAtLogin.isOn

    var body: some View {
        Form {
            Section("Setup") {
                Toggle("Launch Parfait at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { applyLaunchAtLogin() }
                Text(LaunchAtLogin.requiresApproval
                     ? "Approve Parfait under System Settings → General → Login Items to finish enabling this."
                     : "Starts Parfait in the menu bar automatically when you log in.")
                    .font(.parfait(11))
                    .foregroundStyle(.secondary)
                Button("Run setup walkthrough again") { openWindow(id: "onboarding") }
                    .buttonStyle(.plain)
                    .font(.parfait(12))
                    .foregroundStyle(Theme.blueberry)
            }

            Section("Meetings") {
                Toggle("Detect meetings automatically", isOn: $detectMeetings)
                    .onChange(of: detectMeetings) {
                        detectMeetings ? app.startDetection() : app.stopDetection()
                    }
                Toggle("Start recording without asking", isOn: $autoRecord)
                    .disabled(!detectMeetings)
                Text("Parfait notices when another app starts using your microphone — Zoom, Meet, Teams, anything — and offers to record. Nothing is captured until recording starts.")
                    .font(.parfait(11))
                    .foregroundStyle(.secondary)
                Toggle("Stop recording automatically when the meeting ends", isOn: $autoStopRecording)
                    .disabled(!detectMeetings)
                Text("Waits ~8s after the meeting app releases the microphone, in case it reconnects.")
                    .font(.parfait(11))
                    .foregroundStyle(.secondary)
                Toggle("Capture screenshots to name participants (experimental)", isOn: $captureScreenshots)
                Text("Takes a few screenshots while recording and asks Claude to read the participant names off your video-call window — helpful when a meeting has no calendar invite. Screenshots are analyzed only to identify participants and deleted right after processing. Needs Screen Recording permission and Claude Code.")
                    .font(.parfait(11))
                    .foregroundStyle(.secondary)
                if detectMeetings {
                    HStack(alignment: .top) {
                        StatusDot(ok: app.activeMicAppNames.isEmpty ? nil : true)
                        Text(app.activeMicAppNames.isEmpty
                             ? "No other app is using the microphone right now."
                             : "Currently hearing: \(app.activeMicAppNames.joined(separator: ", "))")
                            .font(.parfait(11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Understanding") {
                Toggle("Identify individual speakers", isOn: $identifySpeakers)
                Text("Separates different voices on the call using a small on-device model (~22 MB, downloaded once).")
                    .font(.parfait(11))
                    .foregroundStyle(.secondary)
                Toggle("Match calendar events", isOn: $useCalendar)
                if useCalendar, !calendarStatus {
                    HStack {
                        StatusDot(ok: false)
                        Text("Calendar access needed for titles and attendee names")
                            .font(.parfait(11))
                        Button("Grant…") {
                            Task {
                                calendarStatus = await CalendarMatcher.requestAccess()
                            }
                        }
                        .controlSize(.small)
                    }
                }
                Picker("Default template", selection: $defaultTemplate) {
                    ForEach(app.templates.list()) { Text($0.name).tag($0.name) }
                }
            }

            Section("Permissions") {
                permissionRow(
                    ok: micStatus,
                    title: "Microphone",
                    detail: "Records your side of the call.") {
                    Task { micStatus = await MicRecorder.requestPermission() }
                }
                HStack(alignment: .firstTextBaseline) {
                    StatusDot(ok: systemAudioConfirmed ? true : nil)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("System Audio Recording").font(.parfait(12, .medium))
                        Text(systemAudioConfirmed
                             ? "Records the other participants. Confirmed capturing audio in a previous recording."
                             : "Records the other participants. macOS asks the first time a recording starts; manage it under Privacy & Security → Screen & System Audio Recording.")
                            .font(.parfait(11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(
                            string: "x-apple.systempreferences:com.apple.preference.security")!)
                    }
                    .controlSize(.small)
                }
                HStack(alignment: .firstTextBaseline) {
                    StatusDot(ok: app.notificationAuthStatus == .authorized
                               ? true : (app.notificationAuthStatus == .denied ? false : nil))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notifications").font(.parfait(12, .medium))
                        Text("Lets Parfait notify you when a recording finishes processing and your notes are ready.")
                            .font(.parfait(11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if app.notificationAuthStatus == .notDetermined {
                        Button("Grant…") { Task { await app.requestNotificationAuthorization() } }
                            .controlSize(.small)
                    } else {
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(
                                string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                        }
                        .controlSize(.small)
                    }
                }
                .task { await app.refreshNotificationStatus() }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            micStatus = MicRecorder.permissionGranted
            calendarStatus = CalendarMatcher.isAuthorized
            launchAtLogin = LaunchAtLogin.isOn
        }
    }

    private func applyLaunchAtLogin() {
        try? LaunchAtLogin.set(launchAtLogin)
        launchAtLogin = LaunchAtLogin.isOn // reflect what actually took effect
    }

    private func permissionRow(
        ok: Bool, title: String, detail: String, action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            StatusDot(ok: ok)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.parfait(12, .medium))
                Text(detail).font(.parfait(11)).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok {
                Button("Grant…", action: action).controlSize(.small)
            }
        }
    }
}

private struct IntelligenceSettings: View {
    @State private var claudeInstalled = false
    @State private var claudeLoggedIn = false
    @State private var ghAvailable = false
    @State private var claudeCodeAvailable = false
    @AppStorage(SettingsKey.preferClaudeSummaries) private var preferClaudeSummaries = true

    var body: some View {
        Form {
            Section("On-device") {
                statusRow(
                    ok: AppleSummarizer.isAvailable,
                    title: "Apple Intelligence",
                    detail: AppleSummarizer.isAvailable
                        ? "Summaries, titles, and meeting chat run entirely on this Mac."
                        : (AppleSummarizer.unavailableReason ?? "Unavailable"))
                statusRow(
                    ok: true,
                    title: "Speech transcription",
                    detail: "Apple's on-device speech model. Language packs download automatically on first use.")
            }

            Section("Your Claude account") {
                statusRow(
                    ok: claudeInstalled && claudeLoggedIn,
                    title: claudeInstalled
                        ? (claudeLoggedIn ? "Claude Code — connected" : "Claude Code — not logged in")
                        : "Claude Code — not installed",
                    detail: claudeInstalled
                        ? (claudeLoggedIn
                            ? "Used as a fallback when a meeting is too long for the on-device model to summarize. Billed to your own Claude plan."
                            : "Open Claude Code and log in once to enable this.")
                        : "Install from claude.com/claude-code to unlock long-meeting summaries when Apple Intelligence can't fit the transcript.")
                actionRow(
                    ok: ghAvailable,
                    title: ghAvailable ? "GitHub CLI — ready" : "GitHub CLI — not found",
                    detail: "Publishes meeting pages as secret gists on your own GitHub account."
                ) {
                    if !ghAvailable {
                        Button("Set it up with Claude") { ClaudeCode.setUpGitHubCLI() }
                            .controlSize(.small)
                            .disabled(!claudeCodeAvailable)
                    }
                }

                Toggle("Always use Claude for summaries", isOn: $preferClaudeSummaries)
                    .disabled(!(claudeInstalled && claudeLoggedIn))
                Text("Claude writes higher-quality notes, but runs on your own plan and is a little slower. Off: Apple Intelligence summarizes on-device, and Claude steps in only when a meeting is too long to fit.")
                    .font(.parfait(11))
                    .foregroundStyle(.secondary)
            }

            Section("Connect Claude to your meetings") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Give Claude access to your meeting library so you can ask about your meetings from anywhere. Everything stays local — the connector just reads Parfait's on-disk library.")
                        .font(.parfait(12))

                    HStack {
                        Button("Add to Claude Code") { ClaudeCode.addMCPServer(binary: binaryPath) }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.raspberry)
                        Button("Add to Claude Desktop") {
                            ClaudeCode.addToClaudeDesktop(
                                binary: binaryPath, configPath: claudeDesktopConfigURL.path)
                        }
                    }
                    .controlSize(.small)
                    .disabled(!claudeCodeAvailable)

                    Text(claudeCodeAvailable
                         ? "Claude Code runs the setup for you and confirms it worked."
                         : "Install Claude Desktop (it includes Claude Code) to use these buttons.")
                        .font(.parfait(11))
                        .foregroundStyle(.secondary)

                    DisclosureGroup("Prefer to run it yourself?") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(mcpCommand)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(mcpCommand, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.plain)
                                .help("Copy the claude mcp add command")
                            }
                            Text("Or add the \"parfait\" entry to Claude Desktop's config (merge into any existing \"mcpServers\"):")
                                .font(.parfait(11))
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Copy JSON") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(mcpDesktopConfigSnippet, forType: .string)
                                }
                                Button("Reveal config in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([claudeDesktopConfigURL])
                                }
                            }
                            .controlSize(.small)
                        }
                        .padding(.top, 4)
                    }
                    .font(.parfait(11))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            claudeInstalled = ClaudeCLI.isInstalled
            ghAvailable = GitHubGist.isAvailable
            claudeCodeAvailable = ClaudeCode.isAvailable
            Task.detached {
                let loggedIn = ClaudeCLI.isLoggedIn()
                await MainActor.run { claudeLoggedIn = loggedIn }
            }
        }
    }

    private var binaryPath: String {
        Bundle.main.executablePath ?? "/Applications/Parfait.app/Contents/MacOS/Parfait"
    }

    private var mcpCommand: String {
        "claude mcp add parfait -s user -- \"\(binaryPath)\" --mcp"
    }

    private var mcpDesktopConfigSnippet: String {
        """
        {
          "mcpServers": {
            "parfait": {
              "command": "\(binaryPath)",
              "args": ["--mcp"]
            }
          }
        }
        """
    }

    private var claudeDesktopConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    private func statusRow(ok: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            StatusDot(ok: ok)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.parfait(12, .medium))
                Text(detail).font(.parfait(11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func actionRow<Action: View>(
        ok: Bool, title: String, detail: String, @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            StatusDot(ok: ok)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.parfait(12, .medium))
                Text(detail).font(.parfait(11)).foregroundStyle(.secondary)
            }
            Spacer()
            action()
        }
    }
}

private struct TemplateSettings: View {
    @EnvironmentObject private var app: AppState
    @State private var templates: [SummaryTemplate] = []
    @State private var selected: String?
    @State private var draftName = ""
    @State private var draftBody = ""
    @State private var saveError: String?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List(templates, id: \.name, selection: $selected) { template in
                    Text(template.name).font(.parfait(12)).tag(template.name)
                }
                HStack(spacing: 8) {
                    Button {
                        var name = "New Template"
                        var n = 2
                        while templates.contains(where: { $0.name == name }) {
                            name = "New Template \(n)"; n += 1
                        }
                        try? app.templates.save(SummaryTemplate(
                            name: name,
                            body: "# {{title}}\n\n## Highlights\nWhat mattered most.\n"))
                        reload(select: name)
                    } label: { Image(systemName: "plus") }
                    Button {
                        if let selected {
                            try? app.templates.delete(named: selected)
                            reload(select: nil)
                        }
                    } label: { Image(systemName: "minus") }
                        .disabled(selected == nil)
                    Spacer()
                }
                .buttonStyle(.plain)
                .padding(8)
            }
            .frame(minWidth: 150, maxWidth: 200)

            VStack(alignment: .leading, spacing: 10) {
                if selected != nil {
                    TextField("Template name", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .font(.parfait(13, .medium))
                    TextEditor(text: $draftBody)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    Text("Placeholders: {{title}} {{date}} {{attendees}} {{duration}} {{app}} — headings guide the AI; text under a heading tells it what belongs there.")
                        .font(.parfait(10))
                        .foregroundStyle(.secondary)
                    HStack {
                        if let saveError {
                            Label(saveError, systemImage: "exclamationmark.triangle")
                                .font(.parfait(11))
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Button("Save") { save() }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.raspberry)
                            .disabled(!TemplateStore.isValid(name: draftName))
                    }
                } else {
                    EmptyStateView(
                        title: "Templates",
                        message: "Pick a template to edit, or add one. Templates shape every summary Parfait writes.")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { reload(select: selected ?? templates.first?.name) }
        .onChange(of: selected) { loadDraft() }
    }

    private func reload(select: String?) {
        templates = app.templates.list()
        selected = select ?? templates.first?.name
        loadDraft()
    }

    private func loadDraft() {
        saveError = nil // don't carry a rename error onto another template
        guard let selected, let t = templates.first(where: { $0.name == selected }) else {
            draftName = ""; draftBody = ""
            return
        }
        draftName = t.name
        draftBody = t.body
    }

    private func save() {
        guard let selected else { return }
        let newName = draftName.trimmingCharacters(in: .whitespaces)
        do {
            try app.templates.rename(from: selected, to: newName, body: draftBody)
            saveError = nil
            reload(select: newName)
        } catch {
            saveError = error.localizedDescription
        }
    }
}

struct StatusDot: View {
    /// true = green, false = orange, nil = neutral (informational).
    let ok: Bool?

    init(ok: Bool?) { self.ok = ok }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .padding(.top, 3)
    }

    private var color: Color {
        switch ok {
        case .some(true): Theme.mint
        case .some(false): Color.orange
        case .none: Color.secondary.opacity(0.4)
        }
    }
}
