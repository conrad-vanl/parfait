import AVFoundation
import Foundation
import Speech

/// Real-time, on-device transcription that runs *alongside* recording to feed the
/// live UI and the `get_live_transcript` MCP tool. Two streaming SpeechTranscribers
/// consume the same buffers the recorders already capture — mic tagged "You", the
/// system tap tagged "Others" — and their finalized results merge by wall-clock
/// time into one rolling transcript.
///
/// This is a real-time *approximation*: volatile results are interim and finalized
/// streaming results commit with limited look-ahead. The accurate, diarized
/// transcript is still produced post-hoc by the batch pipeline over the `.m4a`
/// (see the design doc, docs/plans/2026-07-09-live-transcription.md). The streaming
/// SpeechAnalyzer API is pinned in tasks/research/research-speechanalyzer.md.
final class LiveTranscriber: @unchecked Sendable {
    static let youSpeakerID = "me"
    static let othersSpeakerID = "them"

    /// How far apart, in seconds, a mic echo and its clean system copy may land.
    /// The two channels finalize the same utterance independently, so their
    /// point-in-time stamps drift; wider than the batch tolerance to absorb that.
    static let liveEchoWindow: TimeInterval = 4

    /// Synthetic speakers used to format the live transcript.
    static let speakers = [
        Speaker(id: youSpeakerID, name: "You", isMe: true),
        Speaker(id: othersSpeakerID, name: "Others"),
    ]

    static func name(for speakerID: String) -> String {
        speakers.first { $0.id == speakerID }?.name ?? speakerID
    }

    /// A run of consecutive same-speaker segments, for rendering. `id` is the
    /// running index so SwiftUI ForEach stays stable as segments append.
    struct Turn: Identifiable {
        let id: Int
        let speakerID: String
        let text: String
    }

    static func turns(from segments: [TranscriptSegment]) -> [Turn] {
        var out: [Turn] = []
        var speaker: String?
        var texts: [String] = []
        func flush() {
            if let speaker, !texts.isEmpty {
                out.append(Turn(id: out.count, speakerID: speaker, text: texts.joined(separator: " ")))
            }
        }
        for seg in segments {
            if seg.speakerID != speaker { flush(); speaker = seg.speakerID; texts = [] }
            texts.append(seg.text)
        }
        flush()
        return out
    }

    /// Called (on an arbitrary task, not the main actor) whenever the rolling
    /// transcript changes: time-sorted finalized segments + the current volatile
    /// (in-progress) fragment. The caller is responsible for hopping to the main
    /// actor / persisting.
    var onUpdate: (@Sendable ([TranscriptSegment], String) -> Void)?

    private let startDate: Date
    private let lock = NSLock()
    private var finalized: [TranscriptSegment] = []
    private var volatile: [String: String] = [:] // speakerID -> in-progress text
    private var channels: [Channel] = []
    private var started = false
    private var stopped = false

    init(startDate: Date) {
        self.startDate = startDate
    }

    /// Sets up both channels. Throws only if no transcriber model is available at
    /// all (the caller then simply skips live transcription — recording is
    /// unaffected). Safe to call once.
    func start(locale: Locale) async throws {
        let alreadyStarted = lock.withLock { let was = started; started = true; return was }
        guard !alreadyStarted else { return }

        guard SpeechTranscriber.isAvailable,
              let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        else { throw TranscriberError.modelUnavailable }

        // Channel setup can block for a while on first-run model asset download. If
        // the second channel fails to build, tear down the first rather than leak it.
        let mic = try await makeChannel(locale: resolved, speakerID: Self.youSpeakerID)
        let system: Channel
        do {
            system = try await makeChannel(locale: resolved, speakerID: Self.othersSpeakerID)
        } catch {
            await Self.teardown([mic])
            throw error
        }

        // stop() may have already run while we were awaiting the downloads above —
        // its `channels` was empty then, so it tore nothing down. If so, tear down
        // what we just built instead of publishing orphaned analyzer sessions.
        let published = lock.withLock {
            guard !stopped else { return false }
            channels = [mic, system]
            return true
        }
        if !published { await Self.teardown([mic, system]) }
    }

    func feedMic(_ buffer: AVAudioPCMBuffer) { feed(buffer, speakerID: Self.youSpeakerID) }
    func feedSystem(_ buffer: AVAudioPCMBuffer) { feed(buffer, speakerID: Self.othersSpeakerID) }

    private func feed(_ buffer: AVAudioPCMBuffer, speakerID: String) {
        // The tap/engine buffer is only valid for this callback — deep-copy before
        // handing it to another task.
        guard let copy = Self.copy(buffer) else { return }
        let channel = lock.withLock { channels.first { $0.speakerID == speakerID } }
        channel?.rawContinuation.yield(copy)
    }

    /// Ends input and finalizes; the per-channel tasks then complete. Sets `stopped`
    /// so a still-in-flight start() tears down rather than publishes its channels.
    func stop() async {
        let chans = lock.withLock { stopped = true; let c = channels; channels = []; return c }
        await Self.teardown(chans)
    }

    /// Finishes each channel's input and awaits its tasks to completion.
    private static func teardown(_ channels: [Channel]) async {
        for c in channels { c.rawContinuation.finish() }
        for c in channels { await c.finish() }
    }

    // MARK: - Channel setup

    private func makeChannel(locale: Locale, speakerID: String) async throws -> Channel {
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriberError.modelUnavailable
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Raw tap/engine buffers arrive here from the audio thread (bounded so a
        // slow converter drops audio rather than growing memory unbounded).
        let (rawStream, rawContinuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(64))
        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

        // Convert each raw buffer to the analyzer's required format on one task
        // (AVAudioConverter isn't thread-safe; keep it single-threaded here).
        let convertTask = Task.detached {
            var converter: AVAudioConverter?
            var converterInput: AVAudioFormat?
            for await raw in rawStream {
                if converter == nil || converterInput != raw.format {
                    converter = AVAudioConverter(from: raw.format, to: analyzerFormat)
                    converter?.primeMethod = .none
                    converterInput = raw.format
                }
                guard let converter, let out = Self.convert(raw, with: converter, to: analyzerFormat)
                else { continue }
                inputContinuation.yield(AnalyzerInput(buffer: out))
            }
            inputContinuation.finish()
        }

        let resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.handle(result, speakerID: speakerID)
                }
            } catch {
                // A live approximation: a stream error just ends this channel.
            }
        }

        let analyzerTask = Task {
            do {
                if let last = try await analyzer.analyzeSequence(inputStream) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch {
                await analyzer.cancelAndFinishNow()
            }
        }

        return Channel(
            speakerID: speakerID,
            rawContinuation: rawContinuation,
            tasks: [convertTask, resultsTask, analyzerTask])
    }

    private func handle(_ result: SpeechTranscriber.Result, speakerID: String) {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        let elapsed = max(0, Date().timeIntervalSince(startDate))
        lock.lock()
        if result.isFinal {
            volatile[speakerID] = nil
            if !text.isEmpty {
                // Insert in time order rather than re-sorting the whole (growing)
                // transcript on every final result. New segments are almost always
                // the latest, so the reverse scan is O(1) amortized vs. O(n log n).
                let seg = TranscriptSegment(
                    speakerID: speakerID, start: elapsed, end: elapsed, text: text)
                var idx = finalized.count
                while idx > 0, finalized[idx - 1].start > seg.start { idx -= 1 }
                finalized.insert(seg, at: idx)
                // On speakers (no headphones) the far end bleeds into the mic and
                // gets transcribed a second time as "You"; the system tap holds the
                // clean copy. Drop the echo so the live transcript and the MCP tool
                // don't attribute the other person to us. Bidirectional and bounded
                // to the window around the new segment, so cost stays O(k).
                Self.removeEchoedMicSegments(
                    around: seg.start, in: &finalized, window: Self.liveEchoWindow)
            }
        } else {
            volatile[speakerID] = text.isEmpty ? nil : text
        }
        let segments = finalized
        let vol = Self.speakers.compactMap { volatile[$0.id] }.joined(separator: " … ")
        let callback = onUpdate
        lock.unlock()
        callback?(segments, vol)
    }

    // MARK: - Echo dedup

    /// Removes mic ("You") echoes from the neighborhood of a just-inserted segment.
    /// Live segments are point-in-time, so this matches on a time window plus word
    /// coverage rather than the batch path's interval overlap. It runs on every
    /// final segment (either channel), which makes it bidirectional: a "You" echo
    /// is dropped whether the clean system copy arrives before or after it. Only the
    /// time-window tail slice is scanned, so it stays O(k), not O(n), per update.
    ///
    /// Short backchannels (< 4 tokens, e.g. "yeah", "right") are left alone so a
    /// genuine local affirmation that happens to echo isn't nuked.
    ///
    /// The word-coverage bar is higher than the batch path's (0.75 vs 0.6): live
    /// segments are point-in-time, so this can only match on a time window, not the
    /// batch path's interval overlap. A real echo is a near-verbatim re-transcription
    /// (coverage ~1.0), so the stricter bar still catches it while sparing a genuine
    /// local line that merely shares some vocabulary with a nearby far-end line.
    static func removeEchoedMicSegments(
        around anchor: TimeInterval, in segments: inout [TranscriptSegment], window: TimeInterval
    ) {
        let lo = anchor - window
        let hi = anchor + window
        // `segments` is time-ordered, so the window is a contiguous slice ending at
        // the tail. Walk back only until we fall out of it.
        var start = segments.count
        while start > 0, segments[start - 1].start >= lo { start -= 1 }
        let others = segments[start...].filter { $0.speakerID == othersSpeakerID && $0.start <= hi }
        guard !others.isEmpty else { return }
        var i = segments.count - 1
        while i >= start {
            let seg = segments[i]
            if seg.speakerID == youSpeakerID, seg.start <= hi,
               TranscriptText.wordTokens(seg.text).count >= 4,
               others.contains(where: { TranscriptText.covers(seg.text, by: $0.text, atLeast: 0.75) }) {
                segments.remove(at: i)
            }
            i -= 1
        }
    }

    // MARK: - Channel

    private final class Channel {
        let speakerID: String
        let rawContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation
        private let tasks: [Task<Void, Never>]

        init(
            speakerID: String,
            rawContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation,
            tasks: [Task<Void, Never>]
        ) {
            self.speakerID = speakerID
            self.rawContinuation = rawContinuation
            self.tasks = tasks
        }

        func finish() async { for t in tasks { _ = await t.value } }
    }

    // MARK: - Buffer helpers

    /// Deep-copies a float PCM buffer (the only sample format the mic engine and
    /// the Core Audio tap deliver). Returns nil for empty or non-float buffers —
    /// live transcription simply skips those; the batch pass still has them.
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let src = buffer.floatChannelData, let dst = out.floatChannelData
        else { return nil }
        out.frameLength = buffer.frameLength
        let bytes = Int(buffer.frameLength) * MemoryLayout<Float>.size
        for ch in 0 ..< Int(buffer.format.channelCount) { memcpy(dst[ch], src[ch], bytes) }
        return out
    }

    static func convert(
        _ input: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return input
        }
        return (status != .error && out.frameLength > 0) ? out : nil
    }
}
