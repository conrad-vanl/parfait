import Foundation
import FoundationModels

enum AppleSummarizerError: LocalizedError {
    case unavailable(String)
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .generationFailed(let message): return message
        }
    }
}

@Generable
private struct GeneratedTitle {
    @Guide(description: "Specific 3-8 word meeting title, no quotes, no trailing period")
    var title: String
}

@Generable
private struct TitleVerdict {
    @Guide(description: "Whether the scheduled calendar title describes the meeting content, even loosely. False only on a clear mismatch — a generic busy-block name, or content plainly about something else.")
    var scheduledTitleFits: Bool
    @Guide(description: "Specific 3-8 word replacement title from the meeting content, used only when the scheduled title does not fit. Empty when it fits.")
    var replacementTitle: String
}

@Generable
private struct SpeakerMatch {
    @Guide(description: "A placeholder speaker label exactly as given, e.g. \"Speaker 1\"")
    var speaker: String
    @Guide(description: "The attendee this speaker clearly is, copied exactly from the attendee list — empty when the evidence is not clear")
    var attendee: String
}

@Generable
private struct SpeakerAssignments {
    @Guide(description: "One entry per placeholder speaker label")
    var matches: [SpeakerMatch]
}

enum AppleSummarizer {
    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    static var unavailableReason: String? {
        guard case .unavailable(let reason) = SystemLanguageModel.default.availability else { return nil }
        switch reason {
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence isn't enabled on this Mac. Turn it on in System Settings to use on-device summaries."
        case .deviceNotEligible:
            return "This Mac doesn't support Apple Intelligence."
        case .modelNotReady:
            return "The on-device model is still downloading. Try again in a few minutes."
        @unknown default:
            return "The on-device model is unavailable."
        }
    }

    private static let summarizeInstructions = """
    You summarize meeting transcripts. Fill in the headings of the user's template from the \
    transcript, omitting any section with no content. Use speaker names as they appear in the \
    transcript. Output ONLY the finished markdown — no preamble or commentary.
    """

    static func summarize(transcript: String, filledTemplate: String) async throws -> String {
        try ensureAvailable()
        let model = transformationModel
        let fullPrompt = "Template:\n\(filledTemplate)\n\nTranscript:\n\(transcript)"

        do {
            return try await respondOnce(model: model, instructions: summarizeInstructions, prompt: fullPrompt)
        } catch let error as LanguageModelSession.GenerationError {
            guard case .exceededContextWindowSize = error else { throw wrap(error) }
        } catch {
            throw wrap(error)
        }
        return try await mapReduce(transcript: transcript, filledTemplate: filledTemplate, model: model)
    }

    /// Same as `summarize`, but streams the answer: `onDelta` is called with the
    /// growing markdown after each snapshot. Falls back to the non-streaming
    /// map-reduce for transcripts that overflow the context window (no deltas for
    /// that branch — those are the long meetings that need chunking anyway).
    static func summarizeStreaming(
        transcript: String,
        filledTemplate: String,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try ensureAvailable()
        let model = transformationModel
        let fullPrompt = "Template:\n\(filledTemplate)\n\nTranscript:\n\(transcript)"

        do {
            return try await streamOnce(
                model: model, instructions: summarizeInstructions, prompt: fullPrompt, onDelta: onDelta)
        } catch let error as LanguageModelSession.GenerationError {
            guard case .exceededContextWindowSize = error else { throw wrap(error) }
        } catch {
            throw wrap(error)
        }
        return try await mapReduce(transcript: transcript, filledTemplate: filledTemplate, model: model)
    }

    private static let noteInstructions = """
    You take notes on meetings. Output plain markdown bullet points only — no headings, no \
    title, no preamble or commentary.
    """

    private static let writeUpInstructions = """
    You write up meeting notes. The user gives you rough notes from one meeting; write them up \
    under the headings of the user's template, using each heading exactly once and omitting any \
    section with no content. Never mention excerpts or parts, never repeat a heading, and never \
    echo the template's placeholder text. Output ONLY the finished markdown — no preamble or \
    commentary.
    """

    /// TN3193 map-reduce for a transcript that overflows the on-device context window:
    /// take notes on each chunk, condense those notes until they fit in one prompt, then
    /// write them up against the template.
    ///
    /// Both stages are bounded on purpose. An unbounded answer ran past the context window
    /// mid-generation and threw, which dropped that chunk; an unbounded pile of notes made
    /// the write-up prompt overflow, at which point the model stopped merging and copied its
    /// input back — that is how finished notes ended up holding one summary per chunk.
    private static func mapReduce(
        transcript: String, filledTemplate: String, model: SystemLanguageModel
    ) async throws -> String {
        do {
            var notes: [String] = []
            for piece in chunk(transcript, budget: inputBudgetChars) {
                notes.append(try await respondOnce(
                    model: model,
                    instructions: noteInstructions,
                    prompt: """
                    Take notes on this excerpt of a meeting transcript, in at most 80 words of \
                    bullet points. Keep decisions, action items, owners, and dates. Do not write \
                    a heading.

                    \(piece)
                    """,
                    maxResponseTokens: chunkResponseTokens))
            }

            while joined(notes).count > notesBudgetChars, notes.count > 1 {
                var condensed: [String] = []
                for group in chunk(joined(notes), budget: notesBudgetChars) {
                    condensed.append(try await respondOnce(
                        model: model,
                        instructions: noteInstructions,
                        prompt: """
                        Condense these notes from one meeting into at most 100 words of bullet \
                        points, keeping decisions, action items, owners, and dates. Do not write \
                        a heading.

                        \(group)
                        """,
                        maxResponseTokens: chunkResponseTokens))
                }
                // A pass that doesn't shrink won't ever converge — write up what we have.
                guard joined(condensed).count < joined(notes).count else { break }
                notes = condensed
            }

            let prompt = "Template:\n\(filledTemplate)\n\nNotes:\n\n\(joined(notes))"
            let writeUp = try await respondOnce(
                model: model, instructions: writeUpInstructions, prompt: prompt)
            guard readsAsSeveralSummaries(writeUp) else { return writeUp }
            // The model does this sporadically rather than consistently, so a second run of
            // the same prompt usually lands clean.
            let retry = try await respondOnce(
                model: model, instructions: writeUpInstructions, prompt: prompt)
            guard readsAsSeveralSummaries(retry) else { return retry }
            throw AppleSummarizerError.generationFailed(
                "The on-device model couldn't write these notes up as one summary.")
        } catch {
            throw wrap(error)
        }
    }

    /// True when a write-up reads as several summaries stacked together instead of one:
    /// a heading used twice, a leftover "part 3 of 7" marker, or the horizontal rules that
    /// separate one set of notes from the next. Cheaper to catch here and fall over to
    /// Claude than to save it as the meeting's notes.
    static func readsAsSeveralSummaries(_ markdown: String) -> Bool {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let headings = lines.filter { $0.hasPrefix("#") }
        if headings.count != Set(headings).count { return true }
        if lines.contains("---") { return true }
        return markdown.range(of: #"(?i)\bpart \d+ of \d+"#, options: .regularExpression) != nil
    }

    private static func joined(_ notes: [String]) -> String { notes.joined(separator: "\n") }

    static func generateTitle(fromSummary summary: String) async throws -> String {
        try ensureAvailable()
        do {
            let session = LanguageModelSession(instructions: "You write short, specific meeting titles.")
            let response = try await session.respond(
                to: "Write a title for the meeting with this summary:\n\n\(summary)",
                generating: GeneratedTitle.self,
                options: GenerationOptions(temperature: 0.3)
            )
            return polish(response.content.title)
        } catch {
            throw wrap(error)
        }
    }

    /// Sanity check for a calendar-sourced title: returns a replacement drawn from
    /// the summary when the scheduled title clearly doesn't describe the meeting,
    /// or nil to keep it. Strongly biased toward keeping — only a clear mismatch
    /// (a generic busy block like "Focus Time", or content about something else
    /// entirely) replaces.
    static func reviseTitle(calendarTitle: String, summary: String) async throws -> String? {
        try ensureAvailable()
        do {
            let session = LanguageModelSession(instructions: """
            You vet meeting titles. A meeting was recorded during a calendar event; decide \
            whether the event's title describes what was actually discussed. Keep it unless it \
            CLEARLY does not fit — a generic busy-block name (like "Focus Time", "Busy", or \
            "Lunch"), or content plainly about something else. When in doubt, keep it.
            """)
            let response = try await session.respond(
                to: "Scheduled title: \(calendarTitle)\n\nMeeting summary:\n\n\(summary)",
                generating: TitleVerdict.self,
                options: GenerationOptions(temperature: 0.3)
            )
            guard !response.content.scheduledTitleFits else { return nil }
            let title = polish(response.content.replacementTitle)
            return title.isEmpty ? nil : title
        } catch {
            throw wrap(error)
        }
    }

    /// Maps placeholder speaker labels to calendar-attendee names from
    /// transcript evidence. The caller builds the prompt (labels, candidate
    /// pool, excerpt) and validates the result; this just runs the structured
    /// generation. Returns a raw label → name map (empty string = unsure).
    static func matchSpeakers(prompt: String) async throws -> [String: String] {
        try ensureAvailable()
        do {
            let session = LanguageModelSession(model: transformationModel, instructions: """
            You identify who is speaking in meeting transcripts. Assign an attendee name to a \
            placeholder speaker only on clear evidence — a self-introduction, being addressed \
            by name, or equally unambiguous context. When unsure, leave the name empty.
            """)
            let response = try await session.respond(
                to: prompt,
                generating: SpeakerAssignments.self,
                options: GenerationOptions(temperature: 0.3)
            )
            return Dictionary(
                response.content.matches.map { ($0.speaker, $0.attendee) },
                uniquingKeysWith: { a, _ in a })
        } catch {
            throw wrap(error)
        }
    }

    /// Targeted transformation of finished notes (speaker-name updates): the
    /// caller builds the instruction, the notes ride along as input. Single
    /// shot on purpose — notes that overflow the context window just throw and
    /// fail over to the caller's Claude path.
    static func rewriteNotes(prompt: String, notes: String) async throws -> String {
        try ensureAvailable()
        do {
            return try await respondOnce(
                model: transformationModel,
                instructions: """
                You edit finished meeting notes. Apply exactly the change the user asks for \
                and output ONLY the complete updated markdown — no preamble or commentary.
                """,
                prompt: "\(prompt)\n\nNotes:\n\(notes)")
        } catch {
            throw wrap(error)
        }
    }

    private static func polish(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D}\u{2018}\u{2019}"))
        if title.hasSuffix(".") { title = String(title.dropLast()) }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Internals

    /// Relaxed guardrails for transformation tasks: meeting content is user-supplied,
    /// and default guardrails false-positive on sensitive-but-legitimate discussion.
    private static var transformationModel: SystemLanguageModel {
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }

    /// ~40% of the context window for one chunk of transcript, at English's ~3.5 chars/token
    /// (TN3193). contextSize is @backDeployed to 26.0 (fallback 4096) — don't hardcode.
    /// The obvious 55% overflows: transcripts tokenize denser than prose (measured 3.0–3.8
    /// chars/token across real meetings, worse around speaker labels and timestamps), and the
    /// chunk shares the window with the response.
    private static var inputBudgetChars: Int {
        Int(Double(SystemLanguageModel.default.contextSize) * 0.40 * 3.5)
    }

    /// The write-up prompt holds the notes, the template, AND a full set of finished notes
    /// as the answer, so the notes get a much smaller slice of the window than a transcript
    /// chunk does. Measured against real meetings: at ~8000 characters of notes the model
    /// stopped merging and echoed them back; at ~3000 it wrote one clean set of notes.
    private static var notesBudgetChars: Int {
        Int(Double(SystemLanguageModel.default.contextSize) * 0.18 * 3.5)
    }

    /// Response cap for the chunk-level passes. The word limits in those prompts are
    /// advisory and the model overruns them; left uncapped it generates until it hits the
    /// context window and throws, losing the chunk.
    private static let chunkResponseTokens = 300

    private static func ensureAvailable() throws {
        if let reason = unavailableReason {
            throw AppleSummarizerError.unavailable(reason)
        }
    }

    /// Fresh session per call: the 4096-token window covers instructions plus every turn
    /// in a session transcript, so reusing one session across calls overflows.
    private static func respondOnce(
        model: SystemLanguageModel,
        instructions: String,
        prompt: String,
        maxResponseTokens: Int? = nil,
        retryOnRateLimit: Bool = true
    ) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(temperature: 0.3, maximumResponseTokens: maxResponseTokens))
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            // A menu-bar (LSUIElement) app can count as background, where the system rate limit applies.
            if case .rateLimited = error, retryOnRateLimit {
                try await Task.sleep(for: .seconds(3))
                return try await respondOnce(
                    model: model, instructions: instructions, prompt: prompt,
                    maxResponseTokens: maxResponseTokens, retryOnRateLimit: false
                )
            }
            throw error
        }
    }

    /// Streaming counterpart to `respondOnce`. Each snapshot's `content` is the
    /// full text so far (String responses aren't partial structs), so we just
    /// forward it and keep the last one as the result.
    private static func streamOnce(
        model: SystemLanguageModel,
        instructions: String,
        prompt: String,
        onDelta: @escaping @Sendable (String) -> Void,
        retryOnRateLimit: Bool = true
    ) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            var last = ""
            let stream = session.streamResponse(to: prompt, options: GenerationOptions(temperature: 0.3))
            for try await snapshot in stream {
                last = snapshot.content
                onDelta(last)
            }
            return last
        } catch let error as LanguageModelSession.GenerationError {
            if case .rateLimited = error, retryOnRateLimit {
                try await Task.sleep(for: .seconds(3))
                return try await streamOnce(
                    model: model, instructions: instructions, prompt: prompt,
                    onDelta: onDelta, retryOnRateLimit: false)
            }
            throw error
        }
    }

    /// Splits on line boundaries so speaker turns stay whole. A single line longer than
    /// `budget` becomes an oversized chunk of its own rather than being cut mid-sentence.
    static func chunk(_ text: String, budget: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count + 1 > budget, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func wrap(_ error: Error) -> Error {
        if error is AppleSummarizerError { return error }
        return AppleSummarizerError.generationFailed(error.localizedDescription)
    }
}
