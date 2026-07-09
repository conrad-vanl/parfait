import AppKit
import SwiftUI

struct ParfaitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var app = AppState.shared
    // Captured once at launch (not re-read live) so .defaultLaunchBehavior below
    // is a stable, one-time decision — see Window("onboarding") for why.
    private let showOnboardingAtLaunch = !AppSettings.didCompleteOnboarding

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(app)
        } label: {
            MenuBarLabel(isRecording: app.isRecording)
        }
        .menuBarExtraStyle(.window)

        Window("Parfait", id: "main") {
            MainWindowView()
                .environmentObject(app)
        }
        .defaultSize(width: 980, height: 640)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Parfait") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(
                            string: "On-device meeting notes.\ngithub.com/conrad-vanl/parfait",
                            attributes: [.font: NSFont.systemFont(ofSize: 11)])
                    ])
                }
            }
        }

        Window("Welcome to Parfait", id: "onboarding") {
            OnboardingView()
                .environmentObject(app)
        }
        .defaultSize(width: 520, height: 640)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(showOnboardingAtLaunch ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environmentObject(app)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in AppState.shared.bootstrap() }
        observeWindowsForMenuBar()
    }

    /// .accessory apps (LSUIElement) have no Dock icon *and no menu bar at all* —
    /// promote to .regular only while a real Parfait window (main/Settings, not the
    /// MenuBarExtra popover panel) is open, so "Parfait" shows top-left like a normal
    /// app; drop back to accessory the moment the last real window closes.
    private func observeWindowsForMenuBar() {
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, Self.isRealAppWindow(window) else { return }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        })
        windowObservers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let closing = note.object as? NSWindow, Self.isRealAppWindow(closing) else { return }
            // isMiniaturized too: a minimized real window is still open, just not visible.
            let stillOpen = NSApp.windows.contains {
                $0 !== closing && ($0.isVisible || $0.isMiniaturized) && Self.isRealAppWindow($0)
            }
            if !stillOpen { NSApp.setActivationPolicy(.accessory) }
        })
    }

    /// Excludes the MenuBarExtra(.window)'s own backing window (an untitled,
    /// nonactivating NSPanel) — only "real" titled windows (main/Settings/onboarding) qualify.
    private static func isRealAppWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled)
    }

    /// Finalize in-flight audio files before quitting — an unclosed AAC file has
    /// no moov atom and would be unreadable on the next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            AppState.shared.prepareForTermination()
        }
        return .terminateNow
    }
}

struct MenuBarLabel: View {
    let isRecording: Bool

    var body: some View {
        if isRecording {
            Image(systemName: "record.circle.fill")
        } else if let icon = Self.templateIcon {
            Image(nsImage: icon)
        } else {
            Image(systemName: "cup.and.saucer.fill")
        }
    }

    static let templateIcon: NSImage? = {
        // Bundle image lookup pairs the @2x representation; NSImage(contentsOf:)
        // would load only the 1x bitmap and render blurry on Retina.
        guard let image = Bundle.module.image(forResource: "MenuBarIcon") else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}
