import Foundation

/// One Claude vision pass over the mid-meeting screenshots (opt-in, captured
/// by ScreenshotSampler): find the video-conferencing app in each shot and
/// read off the participant names. The names enrich SpeakerNamer's candidate
/// pool, which otherwise only knows calendar attendees.
///
/// Claude-only — Apple's on-device model is text-only. The call runs with the
/// Read builtin as its sole tool, allow-listed to exactly the screenshot files,
/// so a prompt injection lurking on screen has nothing else to reach. Fail
/// closed: any error or malformed reply yields `.empty` and the pipeline
/// proceeds exactly as if screenshots were never taken.
enum ScreenshotAnalyzer {

    struct Result: Equatable, Sendable {
        /// Distinct participant names read across all screenshots.
        var participants: [String] = []
        /// Screenshot file name → the participant highlighted as actively
        /// speaking in it, when one was clearly indicated. Unused in v1 —
        /// TODO: each file name encodes its capture offset (shot-000480.png =
        /// 480 s in), so these observations can anchor names directly onto the
        /// diarized speaker talking at that moment.
        var activeSpeakers: [String: String] = [:]

        static let empty = Result()
    }

    // MARK: - Prompt

    static func prompt(paths: [String]) -> String {
        """
        The screenshot files listed below were taken during a recorded video meeting. Read \
        each one, find the video-conferencing app visible in it (Zoom, Google Meet, Teams, \
        FaceTime, Webex, or similar), and collect the participant names it shows — name \
        labels on video tiles, the participant list, or the active-speaker banner. Ignore \
        every other window, and ignore names that appear only outside the meeting app \
        (chat apps, documents, notifications).

        Screenshot files:

        \(paths.map { "- \($0)" }.joined(separator: "\n"))

        Reply with only a JSON object like {"participants": ["Sarah Chen", "Mike Ross"], \
        "activeSpeakers": {"shot-000480.png": "Sarah Chen"}} — "participants" is every \
        distinct participant name you could read across all screenshots, and \
        "activeSpeakers" maps a screenshot's file name to the participant visibly \
        highlighted as speaking in it (omit entries when no one clearly is). If no \
        video-conferencing app is visible, reply {"participants": []}. No other text.
        """
    }

    // MARK: - Parsing (fail closed)

    /// Parses the reply into a Result. Tolerates a stray code fence or preamble
    /// around the object, but anything without a well-formed `participants`
    /// string array returns nil (→ empty pool, pipeline unchanged).
    static func parse(_ response: String) -> Result? {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}"),
              start < end,
              let object = try? JSONSerialization.jsonObject(
                  with: Data(response[start...end].utf8)) as? [String: Any],
              let rawParticipants = object["participants"] as? [String]
        else { return nil }

        var seen = Set<String>()
        let participants = rawParticipants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        let activeSpeakers = (object["activeSpeakers"] as? [String: String] ?? [:])
            .compactMapValues { name -> String? in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        return Result(participants: participants, activeSpeakers: activeSpeakers)
    }

    // MARK: - Engine

    /// Runs the single Claude call. Returns `.empty` when Claude is missing,
    /// the call fails, or the reply is malformed — never throws, never blocks
    /// the pipeline beyond this one call.
    static func analyze(screenshots: [URL]) async -> Result {
        guard !screenshots.isEmpty, ClaudeCLI.isInstalled else { return .empty }
        guard let result = try? await ClaudeCLI.run(
            prompt: prompt(paths: screenshots.map(\.path)),
            builtinTools: ["Read"],
            // "//" prefix = absolute path in permission rules — Claude may read
            // exactly these files and nothing else.
            allowedTools: screenshots.map { "Read(/\($0.path))" },
            // One turn per screenshot read plus the final reply.
            maxTurns: screenshots.count + 2)
        else { return .empty }
        return parse(result.text) ?? .empty
    }
}
