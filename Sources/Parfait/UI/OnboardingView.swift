import AppKit
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.colorScheme) private var scheme
    @AppStorage(SettingsKey.didCompleteOnboarding) private var didCompleteOnboarding = false
    @AppStorage(SettingsKey.systemAudioConfirmed) private var systemAudioConfirmed = false

    @State private var micStatus = MicRecorder.permissionGranted
    @State private var calendarStatus = CalendarMatcher.isAuthorized
    @State private var claudeInstalled = ClaudeCLI.isInstalled
    @State private var claudeCodeAvailable = ClaudeCode.isAvailable
    @State private var pluginStatus: ParfaitPlugin.Status?   // nil = still probing
    @State private var installingPlugin = false
    @State private var pluginError: String?
    @State private var ghAvailable = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                ParfaitStripes()
                Text("Welcome to Parfait").font(.parfait(20, .bold))
                Text("A quick, optional setup — you can change any of this later in Settings.")
                    .font(.parfait(12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            .padding(.top, 28).padding(.bottom, 20)

            ScrollView {
                VStack(spacing: 12) {
                    micRow
                    systemAudioRow
                    notificationsRow
                    calendarRow
                    claudePluginRow
                    githubRow
                }
                .padding(.horizontal, 24)
            }

            Divider()
            HStack {
                Spacer()
                Button("Finish") { finish() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.raspberry)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520)
        .background(Theme.surface(scheme))
        .onAppear {
            micStatus = MicRecorder.permissionGranted
            calendarStatus = CalendarMatcher.isAuthorized
            claudeInstalled = ClaudeCLI.isInstalled
            claudeCodeAvailable = ClaudeCode.isAvailable
            Task { await app.refreshNotificationStatus() }
            Task.detached {
                let status = ParfaitPlugin.status() // shells out; keep off-main here
                let cliFound = ClaudeCLI.resolveBlocking() != nil
                let gh = GitHubGist.isAvailable
                await MainActor.run {
                    pluginStatus = status
                    claudeInstalled = cliFound
                    ghAvailable = gh
                }
            }
        }
    }

    private func finish() {
        didCompleteOnboarding = true
        dismissWindow(id: "onboarding")
    }

    // MARK: - Steps

    private var micRow: some View {
        OnboardingStepRow(
            icon: "mic.fill", title: "Microphone", required: true,
            detail: "Records your side of the call.", ok: micStatus
        ) {
            if !micStatus {
                Button("Grant…") { Task { micStatus = await MicRecorder.requestPermission() } }
                    .controlSize(.small)
            }
        }
    }

    private var systemAudioRow: some View {
        // No public preflight/request API exists for kTCCServiceAudioCapture (verified against
        // the macOS 26 SDK — no CGPreflightScreenCaptureAccess analog, and tap start/IO succeed
        // silently whether or not it's granted). So we go green only once a real recording has
        // actually captured non-silent system audio (systemAudioConfirmed, set from SystemAudioTap).
        OnboardingStepRow(
            icon: "waveform", title: "System Audio Recording", required: true,
            detail: systemAudioConfirmed
                ? "Confirmed — captured system audio in a previous recording."
                : "Records the other participants. macOS will ask the first time you record; you can also enable it under Privacy & Security → Screen & System Audio Recording.",
            ok: systemAudioConfirmed ? true : nil
        ) {
            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
            }.controlSize(.small)
        }
    }

    private var notificationsRow: some View {
        let status = app.notificationAuthStatus
        return OnboardingStepRow(
            icon: "bell.badge.fill", title: "Notifications", required: false,
            detail: status == .denied
                ? "Denied — Parfait can't tell you when your notes are ready. Turn it on in System Settings → Notifications → Parfait."
                : status == .authorized
                    ? "On — Parfait will let you know when your meeting notes are ready."
                    : "Lets Parfait notify you when a recording finishes processing and your notes are ready.",
            ok: status == .authorized ? true : (status == .denied ? false : nil)
        ) {
            if status == .notDetermined {
                Button("Grant…") { Task { await app.requestNotificationAuthorization() } }
                    .controlSize(.small)
            } else if status != .authorized {
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                }.controlSize(.small)
            }
        }
    }

    private var calendarRow: some View {
        OnboardingStepRow(
            icon: "calendar", title: "Calendar", required: false,
            detail: "Matches your current meeting for titles and attendees.", ok: calendarStatus
        ) {
            if !calendarStatus {
                Button("Grant…") { Task { calendarStatus = await CalendarMatcher.requestAccess() } }
                    .controlSize(.small)
            }
        }
    }

    private var claudePluginRow: some View {
        OnboardingStepRow(
            icon: "sparkles", title: "Claude plugin", required: false,
            detail: pluginError.map { "Install failed: \($0)" }
                ?? (pluginStatus?.installed == true
                    ? "Installed — ask Claude to dig into any of your meetings."
                    : "Install the Parfait plugin so Claude can dig into your meetings."),
            ok: pluginStatus.map(\.installed) // neutral while probing
        ) {
            if installingPlugin {
                ProgressView().controlSize(.small)
            } else if pluginStatus?.installed != true {
                if claudeInstalled {
                    Button("Install plugin") { installPlugin() }
                        .controlSize(.small)
                } else {
                    Button("Get Claude Code") { NSWorkspace.shared.open(URL(string: "https://claude.com/claude-code")!) }
                        .controlSize(.small)
                }
            }
        }
    }

    private func installPlugin() {
        installingPlugin = true
        pluginError = nil
        Task.detached {
            let result = ParfaitPlugin.install()
            let status = ParfaitPlugin.status()
            await MainActor.run {
                installingPlugin = false
                pluginStatus = status
                if case .failure(let error) = result, !status.installed {
                    pluginError = error.localizedDescription
                }
            }
        }
    }

    private var githubRow: some View {
        OnboardingStepRow(
            icon: "chevron.left.forwardslash.chevron.right", title: "GitHub access", required: false,
            detail: ghAvailable ? "Ready — publishes meeting pages as secret gists on your own account." : "Optional — needed only to publish meeting pages.",
            ok: ghAvailable
        ) {
            if !ghAvailable {
                Button("Set it up with Claude") { ClaudeCode.setUpGitHubCLI() }
                    .controlSize(.small)
                    .disabled(!claudeCodeAvailable)
            }
        }
    }
}

private struct OnboardingStepRow<Action: View>: View {
    let icon: String
    let title: String
    let required: Bool
    let detail: String
    let ok: Bool?          // nil = informational, no pass/fail
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusDot(ok: ok)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: icon).foregroundStyle(Theme.raspberry).font(.parfait(12))
                    Text(title).font(.parfait(13, .semibold))
                    if !required { Chip(text: "Optional") }
                }
                Text(detail).font(.parfait(11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            action()
        }
        .cardStyle()
    }
}
