import AppKit
import Foundation
import os
import ScreenCaptureKit

/// Opt-in experimental capture (Settings → "Capture screenshots"): takes a few
/// screenshots of the main display over the course of a recording, later mined
/// by one Claude vision pass for participant names shown in the video-call
/// window — covering meetings with no calendar invite.
///
/// Schedule: the first capture lands 2 minutes in, then the interval doubles
/// (4, 8, 16, 32 min…), and only the newest `keepCount` files are kept — a
/// bounded sample spread across a meeting of ANY length, without knowing the
/// duration up front. Short meetings keep their early shots; long ones shed
/// them for later, more representative ones.
///
/// Best-effort throughout: the first capture triggers the Screen Recording TCC
/// prompt, and a denial (or any other capture failure) stops sampling with a
/// log line — never an error the user sees, never any effect on the recording.
/// Files live under the meeting folder's `screenshots/` subdir and are deleted
/// by the processing pipeline as soon as the run finishes, success or failure.
final class ScreenshotSampler: @unchecked Sendable {
    static let initialDelay: TimeInterval = 120
    static let keepCount = 3

    // MARK: - Schedule (pure)

    /// The doubling schedule: 2 min after start, then twice the previous
    /// offset (4, 8, 16 min…).
    static func nextCaptureTime(after previous: TimeInterval?) -> TimeInterval {
        previous.map { $0 * 2 } ?? initialDelay
    }

    /// Every capture time the schedule reaches within `duration`.
    static func captureTimes(through duration: TimeInterval) -> [TimeInterval] {
        var times: [TimeInterval] = []
        var next = nextCaptureTime(after: nil)
        while next <= duration {
            times.append(next)
            next = nextCaptureTime(after: next)
        }
        return times
    }

    /// The capture times whose files survive pruning — the newest `keep`.
    static func surviving(_ times: [TimeInterval], keep: Int = keepCount) -> [TimeInterval] {
        Array(times.suffix(keep))
    }

    // MARK: - Capture loop

    private let directory: URL
    private let log = Logger(subsystem: "io.github.conrad-vanl.Parfait", category: "screenshots")
    private var task: Task<Void, Never>?

    /// `directory` is the meeting's `screenshots/` subdir; created lazily on
    /// the first successful capture so a denied permission leaves no trace.
    init(directory: URL) {
        self.directory = directory
    }

    func start() {
        guard task == nil else { return }
        task = Task.detached(priority: .utility) { [self] in
            var offset: TimeInterval?
            while true {
                let at = Self.nextCaptureTime(after: offset)
                do { try await Task.sleep(for: .seconds(at - (offset ?? 0))) }
                catch { return } // cancelled — the recording stopped
                offset = at
                do {
                    try await captureOne(at: at)
                    prune()
                } catch {
                    // Screen Recording denied, no display, encoding failure —
                    // degrade silently: stop sampling, never touch the recording.
                    log.info("screenshot sampling stopped: \(error.localizedDescription, privacy: .public)")
                    return
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private enum CaptureError: Error {
        case noDisplay
        case pngEncodingFailed
    }

    /// One PNG of the main display, named by its capture offset so the file
    /// list sorts (and later maps to transcript time) chronologically.
    private func captureOne(at offset: TimeInterval) async throws {
        // First use triggers the Screen Recording TCC prompt; throws when denied.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let config = SCStreamConfiguration()
        config.width = display.width // points, not pixels — plenty to read name labels
        config.height = display.height
        config.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)

        guard let png = NSBitmapImageRep(cgImage: image)
            .representation(using: .png, properties: [:])
        else { throw CaptureError.pngEncodingFailed }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(
            to: directory.appendingPathComponent(String(format: "shot-%06d.png", Int(offset))),
            options: .atomic)
    }

    /// Drops all but the newest `keepCount` shots (file names sort by offset).
    private func prune() {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in files.dropLast(Self.keepCount) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
