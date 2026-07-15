import AppKit
import CoreFoundation
import Foundation

/// System Audio Recording (kTCCServiceAudioCapture). macOS has no public preflight/request
/// API; TCCAccessRequest via the TCC framework is the reliable way to surface the consent
/// dialog and register the app in System Settings (see insidegui/AudioCap).
enum SystemAudioPermission {
    enum Status: Equatable {
        case unknown
        case denied
        case authorized
    }

    static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture")!

    static func status() -> Status {
        guard let preflight = preflightSPI else { return .unknown }
        switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Presents the System Audio Recording consent dialog when status is unknown.
    /// Falls back to a brief Core Audio tap probe when TCC SPI is unavailable.
    @MainActor
    static func request() async {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let request = requestSPI, status() == .unknown {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                request("kTCCServiceAudioCapture" as CFString, nil) { _ in
                    continuation.resume()
                }
            }
            return
        }

        await probeTap()
    }

    private static func probeTap() async {
        await Task.detached(priority: .userInitiated) {
            let tap = SystemAudioTap()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("parfait-permission-probe-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                try tap.start(writingTo: url)
                try await Task.sleep(for: .seconds(2))
            } catch {}
            tap.stop()
        }.value
    }

    // MARK: - TCC SPI (private; same approach as AudioCap)

    private typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunc = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let apiHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    }()

    private static let preflightSPI: PreflightFunc? = {
        guard let apiHandle,
              let sym = dlsym(apiHandle, "TCCAccessPreflight")
        else { return nil }
        return unsafeBitCast(sym, to: PreflightFunc.self)
    }()

    private static let requestSPI: RequestFunc? = {
        guard let apiHandle,
              let sym = dlsym(apiHandle, "TCCAccessRequest")
        else { return nil }
        return unsafeBitCast(sym, to: RequestFunc.self)
    }()
}
