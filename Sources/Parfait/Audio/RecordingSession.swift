import Foundation
import SwiftUI

/// Owns the two capture paths for one meeting. Either side may fail to start
/// (missing permission, no tap grant) — a session is viable with at least one.
@MainActor
final class RecordingSession: ObservableObject {
    let meetingID: UUID
    let startedAt = Date()

    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    private(set) var micStarted = false
    private(set) var systemStarted = false

    private let mic = MicRecorder()
    private let tap = SystemAudioTap()
    private var ticker: Timer?

    enum SessionError: LocalizedError {
        case nothingStarted(String)
        var errorDescription: String? {
            if case .nothingStarted(let detail) = self {
                return "Could not start recording: \(detail)"
            }
            return nil
        }
    }

    init(meetingID: UUID) {
        self.meetingID = meetingID
    }

    func start(micURL: URL, systemURL: URL) throws {
        var problems: [String] = []

        mic.levelHandler = { [weak self] level in
            Task { @MainActor in self?.micLevel = level }
        }
        do {
            try mic.start(writingTo: micURL)
            micStarted = true
        } catch {
            problems.append("microphone: \(error.localizedDescription)")
        }
        tap.signalDetectedHandler = { AppSettings.markSystemAudioConfirmed() }
        do {
            try tap.start(writingTo: systemURL)
            systemStarted = true
        } catch {
            problems.append("system audio: \(error.localizedDescription)")
        }
        guard micStarted || systemStarted else {
            throw SessionError.nothingStarted(problems.joined(separator: "; "))
        }

        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(self.startedAt)
            }
        }
    }

    /// Returns the parts that had problems starting, for the meeting notice.
    var startupNotice: String? {
        switch (micStarted, systemStarted) {
        case (true, true): return nil
        case (false, true): return "Microphone wasn't recorded (permission missing?) — only the other side of the call was captured."
        case (true, false): return "System audio wasn't recorded — only your microphone was captured. Grant System Audio Recording in Privacy & Security."
        case (false, false): return nil
        }
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        if micStarted { mic.stop() }
        if systemStarted { tap.stop() }
    }
}
