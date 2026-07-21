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

    /// Progressive summary signal for the UI. The draft streams in seconds after
    /// Stop; the improvement replaces it once the accurate transcript is ready.
    enum SummaryUpdate: Sendable {
        /// Growing markdown of the pass currently streaming (draft, or the sole pass
        /// when there is no live transcript). May be empty at the very start.
        case streaming(String)
        /// A draft is saved; an improvement pass will follow (badge: "Draft · improving").
        case draftSaved
        /// The progressive phase is over — the UI should read the saved summary.
        case done
    }

    static func run(
        meeting: Meeting,
        archive: MeetingArchive,
        onProgress: @escaping @Sendable (String) -> Void,
        onSummary: @escaping @Sendable (SummaryUpdate) -> Void = { _ in }
    ) async -> Outcome {
        let id = meeting.id
        let micURL = archive.micURL(for: id)
        let systemURL = archive.systemURL(for: id)
        let hasMic = FileManager.default.fileExists(atPath: micURL.path)
        let hasSystem = FileManager.default.fileExists(atPath: systemURL.path)
        var notices: [String] = meeting.notice.map { [$0] } ?? []
        var outcome = Outcome(state: .ready)

        // Opt-in screenshots are single-use input to this run: whatever path the
        // pipeline exits through (success, failure, early return), nothing
        // image-related outlives processing.
        defer { archive.removeScreenshots(for: id) }

        // 0. Draft the notes from the live transcript first, so they appear seconds
        //    after Stop (streamed token by token) while the accurate transcript is
        //    still being built. A failed draft just falls through to the batch pass.
        let liveSegments = archive.liveTranscript(for: id)
        let liveText = TranscriptFormatter.plainText(liveSegments, speakers: LiveTranscriber.speakers)
        var draft: (text: String, provider: String)?
        if !liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onSummary(.streaming(""))
            switch await summarize(
                meeting: meeting, transcript: liveText, onDelta: { onSummary(.streaming($0)) }) {
            case .success(let text, let provider):
                // Only treat the draft as real if it actually persisted. If the write
                // fails, leaving `draft` nil lets the improvement pass save normally
                // rather than the edit-guard (disk == draft.text) blocking it too.
                do {
                    try archive.saveSummary(text, for: id)
                    draft = (text, provider)
                    outcome.summaryProvider = provider
                    onSummary(.draftSaved)
                } catch {
                    onSummary(.done)
                }
            case .failure:
                // No draft — clear the transient streaming UI so it doesn't linger
                // through transcription; the batch pass will write the notes.
                onSummary(.done)
            }
        }

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
            // No accurate transcript. If a draft (and the live transcript AppState
            // already surfaced) exist, keep them rather than failing the meeting —
            // and still name (or title-check) the meeting from the draft.
            if let draft, titleStep(for: meeting, summary: draft.text) != .keep {
                onProgress("Naming the meeting…")
                outcome.generatedTitle = await resolveTitle(
                    meeting: meeting, summary: draft.text, provider: draft.provider)
            }
            onSummary(.done)
            outcome.state = draft == nil ? .failed : .ready
            outcome.summaryProvider = draft?.provider
            outcome.notice = notices.isEmpty
                ? (draft == nil ? "No audio could be transcribed." : nil)
                : notices.joined(separator: " ")
            return outcome
        }

        // 2. Speakers.
        var turns: [DiarizedTurn]?
        if AppSettings.identifySpeakers, let out = systemOut, !out.segments.isEmpty {
            onProgress("Identifying speakers…")
            do {
                turns = try await Diarizer.diarize(
                    fileURL: systemURL,
                    // The diarizer only ever sees the system (remote-only) channel — the
                    // local mic is a separate track labeled "me" — so the ceiling is the
                    // remote-attendee count itself, not +1. The old +1 let a single remote
                    // voice stay split into "Speaker 1" + "Speaker 2" on a 1:1.
                    maxSpeakers: meeting.attendees.isEmpty ? nil : meeting.attendees.count)
            }
            catch { notices.append("Speaker identification unavailable: \(error.localizedDescription)") }
        }

        let myName = NSFullUserName().isEmpty ? "Me" : NSFullUserName()
        let (segments, labeledSpeakers) = SpeakerLabeler.label(
            mic: micOut, system: systemOut, systemTurns: turns, myName: myName)
        try? archive.saveTranscript(segments, for: id)
        var speakers = labeledSpeakers

        // 2a. Opt-in screenshots: one Claude vision pass over the mid-meeting
        //    captures reads participant names off the video-call window, covering
        //    meetings with no calendar invite. Fail-closed — no Claude, no
        //    screenshots, or a bad reply leaves the pool as calendar attendees.
        var participantNames = meeting.attendees
        let screenshots = archive.screenshots(for: id)
        if !screenshots.isEmpty, ClaudeCLI.isInstalled {
            onProgress("Reading participant names from screenshots…")
            participantNames += await ScreenshotAnalyzer.analyze(screenshots: screenshots).participants
        }

        // 2b. Put participant names on the diarized speakers BEFORE summarizing,
        //    so the notes are written with real names instead of "Speaker 2".
        //    The pool is calendar attendees ∪ screenshot names — candidates()
        //    dedupes case-insensitively and drops the user themself.
        //    Confidence-gated inside SpeakerNamer: no clear transcript evidence
        //    (or no model) means no renames, and "me" is never touched.
        let candidates = SpeakerNamer.candidates(attendees: participantNames, speakers: speakers)
        if !candidates.isEmpty, speakers.contains(where: { !$0.isMe }) {
            onProgress("Naming speakers…")
            let renames = await SpeakerNamer.assign(
                speakers: speakers,
                candidates: candidates,
                transcript: TranscriptFormatter.plainText(segments, speakers: speakers),
                provider: outcome.summaryProvider ?? "apple")
            speakers = SpeakerNamer.applying(renames, to: speakers)
        }
        outcome.speakers = speakers
        var labeled = meeting
        labeled.speakers = speakers

        // 3. Improve the notes off the accurate transcript (or write them for the
        //    first time if there was no draft).
        onProgress("Summarizing…")
        let accurateText = TranscriptFormatter.plainText(segments, speakers: speakers)
        let finalOutcome: SummaryOutcome
        if let draft, sameContent(liveSegments, segments) {
            // The accurate transcript carries the same words as the live one, so the
            // draft already reflects them — skip a second model call.
            finalOutcome = .success(draft.text, provider: draft.provider)
        } else if draft != nil {
            // Improve quietly: the draft stays on screen (badge: "Draft · improving")
            // and is replaced atomically when the better version lands.
            finalOutcome = await summarize(meeting: labeled, transcript: accurateText)
        } else {
            // No draft — stream the sole pass into the notes.
            onSummary(.streaming(""))
            finalOutcome = await summarize(
                meeting: labeled, transcript: accurateText, onDelta: { onSummary(.streaming($0)) })
        }

        switch finalOutcome {
        case .success(let summary, let provider):
            // Edit-guard: if the user edited the draft while we were transcribing,
            // keep their version rather than clobbering it with the improvement.
            if draft == nil || archive.summary(for: id) == draft?.text {
                try? archive.saveSummary(summary, for: id)
                outcome.summaryProvider = provider
            }
        case .failure(let why):
            // Improvement failed but the draft (if any) stands.
            if draft == nil { notices.append(why) }
        }

        // Name the meeting from whatever notes we ended up with — the improvement,
        // the draft it fell back to, or the user's own edit — so a draft-only or
        // improve-failed meeting still gets a title, not just the happy path. A
        // meeting still carrying its calendar title gets that title sanity-checked
        // against the notes instead (replaced only on a clear mismatch).
        let finalText = archive.summary(for: id)
        if titleStep(for: meeting, summary: finalText) != .keep {
            onProgress("Naming the meeting…")
            outcome.generatedTitle = await resolveTitle(
                meeting: meeting, summary: finalText, provider: outcome.summaryProvider ?? "apple")
        }

        // 4. Follow-ups, from whatever notes the meeting ended up with. Only when
        //    the meeting has none yet — a reprocess must never clobber a list the
        //    user already curated (regenerateSummary doesn't extract at all).
        if FollowupExtractor.shouldExtract(notes: finalText, existing: archive.followups(for: id)) {
            onProgress("Extracting follow-ups…")
            let items = await FollowupExtractor.extract(
                notes: finalText, transcript: segments, speakers: speakers,
                provider: outcome.summaryProvider ?? "apple")
            if !items.isEmpty {
                try? archive.saveFollowups(items, for: id)
            }
        }

        onSummary(.done)
        outcome.notice = notices.isEmpty ? nil : notices.joined(separator: " ")
        return outcome
    }

    enum SummaryOutcome {
        case success(String, provider: String)
        case failure(String)
    }

    /// True when two transcripts carry the same words (ignoring speaker labels and
    /// timing) — used to skip a redundant improvement pass.
    static func sameContent(_ a: [TranscriptSegment], _ b: [TranscriptSegment]) -> Bool {
        func signature(_ segs: [TranscriptSegment]) -> [String] {
            TranscriptText.wordTokens(segs.map(\.text).joined(separator: " "))
        }
        return signature(a) == signature(b)
    }

    /// On-device first; the user's Claude account when the local model can't. When
    /// `onDelta` is given, the chosen engine streams its markdown as it's generated
    /// (`onDelta` receives the growing text); otherwise it runs buffered.
    static func summarize(
        meeting: Meeting,
        transcript: String,
        onDelta: (@Sendable (String) -> Void)? = nil
    ) async -> SummaryOutcome {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("The transcript was empty, so there is nothing to summarize.")
        }
        let templates = TemplateStore()
        let template = templates.template(named: meeting.templateName ?? AppSettings.defaultTemplate)
            ?? TemplateStore.builtins[0]
        let filled = TemplateRenderer.fill(template.body, meeting: meeting)
        let prompt = """
        Write meeting notes from the transcript provided as input, following this \
        template exactly (keep its headings; omit sections that would be empty):

        \(filled)
        """
        let systemPrompt = "You are Parfait, a meeting notetaker. Output only clean Markdown notes — no preamble, no code fences."

        // Each engine returns a summary, or nil if it's unavailable or errors (so we
        // fall through to the other). Claude records its error so a Claude-only
        // failure still surfaces a useful message.
        func apple() async -> SummaryOutcome? {
            guard AppleSummarizer.isAvailable else { return nil }
            let summary: String?
            if let onDelta {
                summary = try? await AppleSummarizer.summarizeStreaming(
                    transcript: transcript, filledTemplate: filled, onDelta: onDelta)
            } else {
                summary = try? await AppleSummarizer.summarize(
                    transcript: transcript, filledTemplate: filled)
            }
            return summary.map { .success($0, provider: "apple") }
        }
        var claudeError: String?
        func claude() async -> SummaryOutcome? {
            guard ClaudeCLI.isInstalled else { return nil }
            do {
                let result: ClaudeCLI.RunResult
                if let onDelta {
                    // Fall back to the buffered run if the streaming path itself fails
                    // (e.g. a stream-json parse issue) — same CLI, same result shape.
                    do {
                        result = try await ClaudeCLI.stream(
                            prompt: prompt, stdin: transcript, systemPrompt: systemPrompt, onDelta: onDelta)
                    } catch {
                        result = try await ClaudeCLI.run(
                            prompt: prompt, stdin: transcript, systemPrompt: systemPrompt)
                    }
                } else {
                    result = try await ClaudeCLI.run(
                        prompt: prompt, stdin: transcript, systemPrompt: systemPrompt)
                }
                return .success(result.text, provider: "claude")
            } catch {
                claudeError = error.localizedDescription
                return nil
            }
        }

        // Claude first when the user prefers it and it's available (its summaries are
        // higher quality); otherwise on-device first with Claude as the long-meeting
        // fallback. Either way, the second engine covers the first one's failure.
        let order: [() async -> SummaryOutcome?] =
            AppSettings.preferClaudeSummaries && ClaudeCLI.isInstalled
            ? [claude, apple]
            : [apple, claude]
        for engine in order {
            if let outcome = await engine() { return outcome }
        }

        if let claudeError {
            return .failure("Summary failed via Claude: \(claudeError)")
        }
        let reason = AppleSummarizer.unavailableReason ?? "Apple Intelligence is unavailable"
        return .failure("\(reason), and Claude Code isn't installed — transcript saved, summary skipped. Fix either one and press Regenerate.")
    }

    /// What the title step should do once notes exist. Pure decision, so the
    /// gating is unit-testable without a model.
    enum TitleStep: Equatable {
        /// No calendar title — generate one from the notes.
        case generate
        /// The meeting still carries its calendar title — sanity-check it against the notes.
        case check(calendarTitle: String)
        /// Leave the title alone: no notes, or the user already renamed the meeting.
        case keep
    }

    static func titleStep(for meeting: Meeting, summary: String) -> TitleStep {
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .keep }
        guard let calendarTitle = meeting.calendarEventTitle else { return .generate }
        // Only vet the calendar title while it's still the meeting's title — a user
        // rename always wins, and `calendarEventTitle` itself is provenance and
        // never changes.
        return meeting.title == calendarTitle ? .check(calendarTitle: calendarTitle) : .keep
    }

    /// Title step for a finished set of notes. Returns a new title, or nil to
    /// leave the meeting's title as it is.
    static func resolveTitle(meeting: Meeting, summary: String, provider: String) async -> String? {
        switch titleStep(for: meeting, summary: summary) {
        case .generate:
            return await generateTitle(summary: summary, provider: provider)
        case .check(let calendarTitle):
            return await reviseCalendarTitle(calendarTitle, summary: summary, provider: provider)
        case .keep:
            return nil
        }
    }

    /// Asks the model whether the calendar title actually fits the notes; returns
    /// a better title only on a clear mismatch (generic busy blocks like "Focus
    /// Time", or content about something else entirely), nil to keep it. One call
    /// judges and proposes; same engine order as `generateTitle`.
    static func reviseCalendarTitle(
        _ calendarTitle: String, summary: String, provider: String
    ) async -> String? {
        if provider == "apple" {
            do {
                // do/catch, not try?: a successful "keep" verdict is nil too, and
                // must not fall through to Claude the way an error does.
                let verdict = try await AppleSummarizer.reviseTitle(
                    calendarTitle: calendarTitle, summary: summary)
                return verdict.flatMap { parseTitleVerdict($0, calendarTitle: calendarTitle) }
            } catch {}
        }
        if ClaudeCLI.isInstalled,
           let result = try? await ClaudeCLI.run(
               prompt: titleCheckPrompt(calendarTitle: calendarTitle, summary: summary),
               model: "haiku"
           ) {
            return parseTitleVerdict(result.text, calendarTitle: calendarTitle)
        }
        return nil
    }

    /// Prompt for the calendar-title sanity check (Claude path). The notes are
    /// untrusted data — ClaudeCLI.run pins `--tools ""`, so there is nothing for
    /// injected instructions to execute.
    static func titleCheckPrompt(calendarTitle: String, summary: String) -> String {
        """
        A meeting was recorded during a calendar event titled "\(calendarTitle)". Decide whether \
        that title describes the meeting notes below. Strongly prefer keeping it — replace only \
        on a CLEAR mismatch, like a generic busy-block name ("Focus Time", "Busy", "Lunch") or \
        notes plainly about something else. A borderline fit keeps the title.

        Reply with exactly KEEP to keep the title, or with only a specific 3-8 word replacement \
        title, no quotes.

        Notes:

        \(String(summary.prefix(2000)))
        """
    }

    /// Maps the check's reply to an outcome: nil keeps the calendar title (the
    /// KEEP sentinel, an echo of the same title, or anything malformed); a string
    /// replaces it.
    static func parseTitleVerdict(_ response: String, calendarTitle: String) -> String? {
        guard let title = cleaned(response) else { return nil }
        if title.caseInsensitiveCompare("KEEP") == .orderedSame { return nil }
        if title.caseInsensitiveCompare(calendarTitle) == .orderedSame { return nil }
        return title
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
