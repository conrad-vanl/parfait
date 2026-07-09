import Foundation

/// Post-recording pipeline: transcribe both channels → identify speakers →
/// label segments → summarize + title. Pure orchestration; every stage is
/// resilient — a meeting with any transcript at all ends up .ready.
enum ProcessingPipeline {
    /// Everything the pipeline is allowed to change on a meeting. AppState
    /// merges this onto a FRESH copy of the meeting, so user edits made during
    /// the (minutes-long) run are never clobbered by a stale snapshot.
    struct Outcome: Sendable {
        var state: MeetingState
        var notice: String?
        var speakers: [Speaker]?
        var summaryProvider: String?
        var generatedTitle: String?
    }

    static func run(
        meeting: Meeting,
        archive: MeetingArchive,
        onProgress: @escaping @Sendable (String) -> Void
    ) async -> Outcome {
        let micURL = archive.micURL(for: meeting.id)
        let systemURL = archive.systemURL(for: meeting.id)
        let hasMic = FileManager.default.fileExists(atPath: micURL.path)
        let hasSystem = FileManager.default.fileExists(atPath: systemURL.path)
        var notices: [String] = meeting.notice.map { [$0] } ?? []

        // 1. Transcribe.
        onProgress("Preparing speech model…")
        try? await Transcriber.ensureModel(locale: .current, progress: { fraction in
            onProgress("Downloading speech model… \(Int(fraction * 100))%")
        })

        var micOut: TranscriptionOutput?
        var systemOut: TranscriptionOutput?
        if hasMic {
            onProgress("Transcribing your microphone…")
            do { micOut = try await Transcriber.transcribeFile(at: micURL, locale: .current) }
            catch { notices.append("Mic transcription failed: \(error.localizedDescription)") }
        }
        if hasSystem {
            onProgress("Transcribing the call audio…")
            do { systemOut = try await Transcriber.transcribeFile(at: systemURL, locale: .current) }
            catch { notices.append("Call transcription failed: \(error.localizedDescription)") }
        }

        guard micOut != nil || systemOut != nil else {
            return Outcome(
                state: .failed,
                notice: notices.isEmpty ? "No audio could be transcribed." : notices.joined(separator: " "))
        }

        // 2. Speakers.
        var turns: [DiarizedTurn]?
        if AppSettings.identifySpeakers, let out = systemOut, !out.segments.isEmpty {
            onProgress("Identifying speakers…")
            do {
                turns = try await Diarizer.diarize(
                    fileURL: systemURL,
                    maxSpeakers: meeting.attendees.isEmpty ? nil : meeting.attendees.count + 1)
            }
            catch { notices.append("Speaker identification unavailable: \(error.localizedDescription)") }
        }

        let myName = NSFullUserName().isEmpty ? "Me" : NSFullUserName()
        let (segments, speakers) = SpeakerLabeler.label(
            mic: micOut, system: systemOut, systemTurns: turns, myName: myName)
        try? archive.saveTranscript(segments, for: meeting.id)

        var outcome = Outcome(state: .ready, speakers: speakers)
        var labeled = meeting
        labeled.speakers = speakers

        // 3. Summary + title.
        onProgress("Summarizing…")
        let transcriptText = TranscriptFormatter.plainText(segments, speakers: speakers)
        let summaryOutcome = await summarize(meeting: labeled, transcript: transcriptText)
        switch summaryOutcome {
        case .success(let summary, let provider):
            try? archive.saveSummary(summary, for: meeting.id)
            outcome.summaryProvider = provider
            if meeting.calendarEventTitle == nil {
                onProgress("Naming the meeting…")
                outcome.generatedTitle = await generateTitle(summary: summary, provider: provider)
            }
        case .failure(let why):
            notices.append(why)
        }

        outcome.notice = notices.isEmpty ? nil : notices.joined(separator: " ")
        return outcome
    }

    enum SummaryOutcome {
        case success(String, provider: String)
        case failure(String)
    }

    /// On-device first; the user's Claude account when the local model can't.
    static func summarize(meeting: Meeting, transcript: String) async -> SummaryOutcome {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("The transcript was empty, so there is nothing to summarize.")
        }
        let templates = TemplateStore()
        let template = templates.template(named: meeting.templateName ?? AppSettings.defaultTemplate)
            ?? TemplateStore.builtins[0]
        let filled = TemplateRenderer.fill(template.body, meeting: meeting)

        if AppleSummarizer.isAvailable {
            do {
                let summary = try await AppleSummarizer.summarize(
                    transcript: transcript, filledTemplate: filled)
                return .success(summary, provider: "apple")
            } catch {
                // Fall through to Claude.
            }
        }
        if ClaudeCLI.isInstalled {
            do {
                let result = try await ClaudeCLI.run(
                    prompt: """
                    Write meeting notes from the transcript provided as input, following this \
                    template exactly (keep its headings; omit sections that would be empty):

                    \(filled)
                    """,
                    stdin: transcript,
                    systemPrompt: "You are Parfait, a meeting notetaker. Output only clean Markdown notes — no preamble, no code fences."
                )
                return .success(result.text, provider: "claude")
            } catch {
                return .failure("Summary failed via Claude: \(error.localizedDescription)")
            }
        }
        let reason = AppleSummarizer.unavailableReason ?? "Apple Intelligence is unavailable"
        return .failure("\(reason), and Claude Code isn't installed — transcript saved, summary skipped. Fix either one and press Regenerate.")
    }

    static func generateTitle(summary: String, provider: String) async -> String? {
        if provider == "apple", let title = try? await AppleSummarizer.generateTitle(fromSummary: summary) {
            return cleaned(title)
        }
        if ClaudeCLI.isInstalled,
           let result = try? await ClaudeCLI.run(
               prompt: "Reply with only a specific 3–8 word title for the meeting with these notes, no quotes:\n\n\(String(summary.prefix(2000)))",
               model: "haiku"
           ) {
            return cleaned(result.text)
        }
        return nil
    }

    private static func cleaned(_ title: String) -> String? {
        let t = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”.#"))
            .trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 80, !t.contains("\n") else { return nil }
        return t
    }
}
