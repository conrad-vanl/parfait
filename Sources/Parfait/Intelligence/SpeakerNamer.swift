import Foundation

/// Post-labeling pass that puts participant names (calendar attendees, plus
/// screenshot-derived names when the opt-in capture ran) on diarized speakers
/// ("Speaker 1" → "Sarah Chen") using transcript evidence: self-introductions
/// ("hey, it's Sarah"), being addressed ("thanks, Mike"), context. Confidence-
/// gated and fail-closed — a speaker is renamed only when the model clearly
/// identifies them AND the name validates against the attendee pool; anything
/// unclear (or malformed model output) leaves the speaker as "Speaker N". This
/// file owns the pure pieces — candidate-pool construction, excerpt/prompt
/// building, verdict parsing, validation — plus the engine call; the pipeline
/// decides when to run it.
enum SpeakerNamer {

    // MARK: - Candidate pool

    /// The participant names offered to the model: trimmed, de-duplicated
    /// (case-insensitively — callers may union calendar attendees with
    /// screenshot-derived names), minus the user themself. The mic channel is
    /// always the user (labeled with the OS user name), so their entry must
    /// never be assignable to a diarized system speaker.
    static func candidates(attendees: [String], speakers: [Speaker]) -> [String] {
        let myNames = Set(speakers.filter(\.isMe).map { $0.name.lowercased() })
        var seen = Set<String>()
        return attendees
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter {
                !$0.isEmpty
                    && !myNames.contains($0.lowercased())
                    && seen.insert($0.lowercased()).inserted
            }
    }

    // MARK: - Transcript excerpt

    /// Bounded excerpt for the prompt: the opening of the call (where people
    /// introduce themselves) plus later lines that mention a candidate's first
    /// name (where people get addressed), capped so it fits the on-device
    /// context window alongside the instructions.
    static func excerpt(_ transcript: String, candidates: [String], cap: Int = 6000) -> String {
        guard transcript.count > cap else { return transcript }
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        var used = 0
        var openingCount = 0
        var opening: [String] = []
        for line in lines {
            guard used + line.count + 1 <= (cap * 2) / 3 else { break }
            opening.append(line)
            used += line.count + 1
            openingCount += 1
        }

        // First-name tokens of the candidates ("sarah" out of "Sarah Chen" or
        // "sarah.chen@example.com"), matched against word tokens so "Al" doesn't
        // hit "also".
        let firstNames = Set(candidates.compactMap { TranscriptText.wordTokens($0).first })
        var evidence: [String] = []
        for line in lines.dropFirst(openingCount) {
            guard used + line.count + 1 <= cap else { break }
            guard TranscriptText.wordTokens(line).contains(where: firstNames.contains) else { continue }
            evidence.append(line)
            used += line.count + 1
        }

        let head = opening.joined(separator: "\n")
        return evidence.isEmpty ? head : head + "\n…\n" + evidence.joined(separator: "\n")
    }

    // MARK: - Prompt

    /// Shared task description for both engines: the labels, the candidate
    /// pool, the confidence bar, and the excerpt. The Claude path appends a
    /// strict-JSON reply instruction; the Apple path uses structured output.
    static func promptBody(
        speakerLabels: [String], candidates: [String], myName: String?, excerpt: String
    ) -> String {
        let labelList = speakerLabels.map { "\"\($0)\"" }.joined(separator: ", ")
        let meNote = myName.map {
            "\"\($0)\" in the transcript is the local user, already identified — never a candidate. "
        } ?? ""
        return """
        A meeting transcript labels the remote participants with placeholders: \(labelList). \
        These attendees are known from the calendar invite or the meeting app's participant list:

        \(candidates.map { "- \($0)" }.joined(separator: "\n"))

        Decide which attendee each placeholder speaker is, using only transcript evidence: \
        self-introductions ("hi, it's Sarah"), being addressed by name ("thanks, Mike"), or \
        equally clear context. Assign a name ONLY on clear evidence — when unsure, leave that \
        speaker unassigned. \(meNote)Some attendees may not have spoken at all. Ignore attendee \
        entries that aren't a person's name, like conference rooms or bare email addresses. \
        Never assign the same attendee to two speakers.

        Transcript excerpt:

        \(excerpt)
        """
    }

    /// Full prompt for the Claude path. The transcript is untrusted data —
    /// ClaudeCLI.run pins `--tools ""`, so there is nothing for injected
    /// instructions to execute.
    static func claudePrompt(
        speakerLabels: [String], candidates: [String], myName: String?, excerpt: String
    ) -> String {
        promptBody(speakerLabels: speakerLabels, candidates: candidates, myName: myName, excerpt: excerpt)
            + """


            Reply with only a JSON object mapping every placeholder label to the attendee name \
            copied exactly from the list, or "" when unsure — for example \
            {"Speaker 1": "Sarah Chen", "Speaker 2": ""}. No other text.
            """
    }

    // MARK: - Verdict parsing

    /// Parses the Claude reply into a raw label → name map. Tolerates a stray
    /// code fence or preamble around the object, but fails closed — anything
    /// that isn't a JSON object of strings returns nil (no renames).
    static func parseAssignments(_ response: String) -> [String: String]? {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}"),
              start < end
        else { return nil }
        let json = Data(response[start...end].utf8)
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: String] else {
            return nil
        }
        return object
    }

    // MARK: - Validation

    /// Acceptance rules, applied to a raw label → name map from either engine.
    /// A speaker is renamed only when ALL hold:
    ///  - the label matches a non-"me" pipeline speaker (the user is never renamed),
    ///  - the assigned name is exactly one of the offered candidates
    ///    (case-insensitive; the candidate's own casing wins),
    ///  - no earlier speaker already claimed that candidate (two speakers must
    ///    not both become "Sarah" — the first in speaker order keeps it).
    /// Returns speakerID → attendee name; unmentioned speakers stay "Speaker N".
    static func validated(
        _ assignments: [String: String], speakers: [Speaker], candidates: [String]
    ) -> [String: String] {
        let canonical = Dictionary(
            candidates.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var claimed = Set<String>()
        var renames: [String: String] = [:]
        for speaker in speakers where !speaker.isMe {
            guard let raw = assignments[speaker.name]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let name = canonical[raw.lowercased()],
                  claimed.insert(name.lowercased()).inserted
            else { continue }
            renames[speaker.id] = name
        }
        return renames
    }

    /// The speakers array with accepted renames applied (by speaker id).
    static func applying(_ renames: [String: String], to speakers: [Speaker]) -> [Speaker] {
        speakers.map { speaker in
            var speaker = speaker
            if let name = renames[speaker.id] { speaker.name = name }
            return speaker
        }
    }

    // MARK: - Engine

    /// One naming pass. Provider-aware ordering mirrors the title helpers: the
    /// on-device model goes first when Apple is (or would be) the summarizer,
    /// with a small Claude call (haiku, tools pinned off — the transcript is
    /// untrusted input) as the fallback either way. Returns the validated
    /// speakerID → name map; empty on any failure (no renames).
    static func assign(
        speakers: [Speaker], candidates: [String], transcript: String, provider: String
    ) async -> [String: String] {
        let labels = speakers.filter { !$0.isMe }.map(\.name)
        guard !labels.isEmpty, !candidates.isEmpty else { return [:] }
        let myName = speakers.first(where: \.isMe)?.name
        let bounded = excerpt(transcript, candidates: candidates)

        if provider == "apple" {
            do {
                // do/catch, not try?: an Apple verdict of "no clear matches" is a
                // real answer and must not fall through to Claude the way an
                // availability or generation error does.
                let raw = try await AppleSummarizer.matchSpeakers(
                    prompt: promptBody(
                        speakerLabels: labels, candidates: candidates,
                        myName: myName, excerpt: bounded))
                return validated(raw, speakers: speakers, candidates: candidates)
            } catch {}
        }
        if ClaudeCLI.isInstalled,
           let result = try? await ClaudeCLI.run(
               prompt: claudePrompt(
                   speakerLabels: labels, candidates: candidates,
                   myName: myName, excerpt: bounded),
               model: "haiku"),
           let raw = parseAssignments(result.text) {
            return validated(raw, speakers: speakers, candidates: candidates)
        }
        return [:]
    }
}
