import Foundation
import SwiftUI

/// UserDefaults-backed settings. Keys are shared with @AppStorage in Settings UI.
enum SettingsKey {
    static let autoRecord = "autoRecord"                    // start recording on detection (vs. just show the prompt card)
    static let detectMeetings = "detectMeetings"            // watch for mic activity at all
    static let identifySpeakers = "identifySpeakers"        // run on-device diarization
    static let useCalendar = "useCalendar"                  // match calendar events for titles/attendees
    static let defaultTemplate = "defaultTemplate"
    static let ignoredBundleIDs = "ignoredBundleIDs"        // apps that never count as meetings
    static let autoStopRecording = "autoStopRecording"      // stop ~8s after the meeting app releases the mic
    static let didCompleteOnboarding = "didCompleteOnboarding" // first-run walkthrough finished
    static let systemAudioConfirmed = "systemAudioConfirmed"   // tap has captured real (non-silent) audio at least once
    static let preferClaudeSummaries = "preferClaudeSummaries" // when Claude is available, use it for summaries first (vs. Apple-first)
    static let echoCancellation = "echoCancellation"           // voice-processing AEC on the mic (removes far-end speaker bleed)
}

enum AppSettings {
    static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        defaults.register(defaults: [
            SettingsKey.autoRecord: false,
            SettingsKey.detectMeetings: true,
            SettingsKey.identifySpeakers: true,
            SettingsKey.useCalendar: true,
            SettingsKey.defaultTemplate: "Meeting Notes",
            SettingsKey.ignoredBundleIDs: defaultIgnoredBundleIDs,
            SettingsKey.autoStopRecording: true,
            SettingsKey.didCompleteOnboarding: false,
            SettingsKey.systemAudioConfirmed: false,
            SettingsKey.preferClaudeSummaries: true,
            SettingsKey.echoCancellation: true,
        ])
    }

    /// Apps whose mic use is never a meeting: voice assistants, dictation-ish utilities, ourselves.
    static let defaultIgnoredBundleIDs: [String] = [
        "com.apple.Siri",
        "com.apple.SiriNCService",
        "com.apple.VoiceMemos",
        "com.apple.controlcenter",
    ]

    static var autoRecord: Bool { defaults.bool(forKey: SettingsKey.autoRecord) }
    static var detectMeetings: Bool { defaults.bool(forKey: SettingsKey.detectMeetings) }
    static var identifySpeakers: Bool { defaults.bool(forKey: SettingsKey.identifySpeakers) }
    static var useCalendar: Bool { defaults.bool(forKey: SettingsKey.useCalendar) }
    static var defaultTemplate: String {
        defaults.string(forKey: SettingsKey.defaultTemplate) ?? "Meeting Notes"
    }
    static var ignoredBundleIDs: [String] {
        defaults.stringArray(forKey: SettingsKey.ignoredBundleIDs) ?? defaultIgnoredBundleIDs
    }
    static var autoStopRecording: Bool { defaults.bool(forKey: SettingsKey.autoStopRecording) }
    static var didCompleteOnboarding: Bool { defaults.bool(forKey: SettingsKey.didCompleteOnboarding) }
    static var systemAudioConfirmed: Bool { defaults.bool(forKey: SettingsKey.systemAudioConfirmed) }
    static func markSystemAudioConfirmed() { defaults.set(true, forKey: SettingsKey.systemAudioConfirmed) }
    static var preferClaudeSummaries: Bool { defaults.bool(forKey: SettingsKey.preferClaudeSummaries) }
    static var echoCancellation: Bool { defaults.bool(forKey: SettingsKey.echoCancellation) }
}
