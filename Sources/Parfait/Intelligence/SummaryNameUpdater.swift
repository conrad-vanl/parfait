import Foundation

/// Targeted rewrite of already-written meeting notes after speaker renames or
/// merges: swap the old names for the new ones (and consolidate duplicate
/// references after a merge) without regenerating the summary. This file owns
/// the pure pieces — rename-map coalescing, the run/skip decision, prompt
/// construction, fail-closed output validation — plus the engine call itself;
/// debouncing and write-back discipline live in AppState.
enum SummaryNameUpdater {
    static let systemPrompt = "You are Parfait, a meeting notetaker. Output only the complete updated Markdown notes — no preamble, no code fences."

    // MARK: - Rename-map coalescing

    /// Folds one rename into the accumulated old-name → new-name map. A rename
    /// of an already-renamed speaker chains (a→b then b→c becomes a→c, since
    /// the notes only ever said "a"), and a rename back to the original name
    /// cancels out entirely. Name comparison is case-insensitive, matching the
    /// merge check in the rename sheet.
    static func coalescing(
        _ map: [String: String], renaming oldName: String, to newName: String
    ) -> [String: String] {
        var result = map
        var chained = false
        for (key, value) in result where value.caseInsensitiveCompare(oldName) == .orderedSame {
            result[key] = newName
            chained = true
        }
        if !chained { result[oldName] = newName }
        return result.filter { $0.key.caseInsensitiveCompare($0.value) != .orderedSame }
    }

    /// True when two old names map to one new name — a speaker merge, which
    /// needs the notes to consolidate duplicate references.
    static func hasMerge(_ renames: [String: String]) -> Bool {
        Set(renames.values.map { $0.lowercased() }).count < renames.count
    }

    // MARK: - Run/skip decision

    /// Whether a queued name-update pass should run now. When it shouldn't,
    /// the pending map is safe to DROP rather than defer: any summary written
    /// later (the pipeline or a regeneration) is generated from the current,
    /// already-renamed speakers.
    static func shouldRun(meetingState: MeetingState, summary: String, summaryBusy: Bool) -> Bool {
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard meetingState != .recording, meetingState != .processing else { return false }
        return !summaryBusy
    }

    /// Whether the finished pass may write back: only if the notes on disk are
    /// still exactly what the pass started from. A concurrent user edit or
    /// regeneration aborts the write instead of being clobbered.
    static func canCommit(original: String, current: String) -> Bool {
        original == current
    }

    // MARK: - Prompt

    static func prompt(renames: [String: String]) -> String {
        let lines = renames.sorted { $0.key < $1.key }
            .map { "- \"\($0.key)\" is now named \"\($0.value)\"" }
        var prompt = """
        Speakers in the meeting notes provided as input were renamed:

        \(lines.joined(separator: "\n"))

        Rewrite the notes applying ONLY these name changes: replace every reference to \
        an old name (including possessives and attendee/owner lists) with its new name, \
        and change nothing else — keep all other wording, formatting, and structure \
        exactly as they are.
        """
        if hasMerge(renames) {
            prompt += """
             Old names that share one new name were the same person: consolidate their \
            references so that person is listed once, not twice (e.g. in attendee or \
            owner lists).
            """
        }
        prompt += "\n\nOutput the complete updated Markdown notes."
        return prompt
    }

    // MARK: - Output validation

    /// Fail-closed check on the model output: strips a stray surrounding code
    /// fence, then rejects empty output and anything so short the model clearly
    /// dropped content (a merge removes a few duplicate name mentions, never
    /// half the notes).
    static func validated(_ output: String?, original: String) -> String? {
        guard var text = output?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        if text.hasPrefix("```") {
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty, text.count * 2 >= original.count else { return nil }
        return text
    }

    // MARK: - Engine

    /// One targeted pass over the notes. Provider-aware ordering mirrors the
    /// title helpers: the on-device model goes first when it wrote the summary,
    /// with a small Claude call (haiku, tools pinned off — the notes are
    /// untrusted input) as the fallback either way. Returns nil on failure so
    /// the caller keeps the original.
    static func rewrite(summary: String, renames: [String: String], provider: String) async -> String? {
        guard !renames.isEmpty else { return nil }
        let instruction = prompt(renames: renames)
        if provider == "apple",
           let updated = validated(
               try? await AppleSummarizer.rewriteNotes(prompt: instruction, notes: summary),
               original: summary) {
            return updated
        }
        if ClaudeCLI.isInstalled,
           let result = try? await ClaudeCLI.run(
               prompt: instruction, stdin: summary, systemPrompt: systemPrompt, model: "haiku") {
            return validated(result.text, original: summary)
        }
        return nil
    }
}
