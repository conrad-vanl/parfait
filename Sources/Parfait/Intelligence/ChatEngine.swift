import Foundation
import SwiftUI

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    var role: Role
    var text: String
    /// "apple" or "claude" — shown as a small badge on assistant messages.
    var provider: String?
}

/// Chat about one meeting. Routes to the on-device model when the context fits,
/// otherwise to the user's Claude CLI (which also carries multi-turn memory
/// via --resume).
@MainActor
final class MeetingChat: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isThinking = false
    @Published var errorText: String?

    private let meeting: Meeting
    private let context: String
    private var claudeSessionID: String?

    init(meeting: Meeting, store: MeetingStore) {
        self.meeting = meeting
        let transcript = TranscriptFormatter.plainText(
            store.transcript(for: meeting.id), speakers: meeting.speakers)
        let summary = store.summary(for: meeting.id)
        context = """
        Meeting: \(meeting.title)

        Summary:
        \(summary)

        Transcript:
        \(transcript)
        """
    }

    var canChat: Bool { AppleSummarizer.isAvailable || ClaudeCLI.isInstalled }

    func send(_ question: String) async {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isThinking else { return }
        messages.append(ChatMessage(role: .user, text: question))
        isThinking = true
        errorText = nil
        defer { isThinking = false }

        // The on-device model has no session memory, so recent turns ride along
        // in the context. Claude keeps its own memory via --resume.
        let recentTurns = messages.suffix(7).dropLast().map {
            "\($0.role == .user ? "User" : "Assistant"): \($0.text)"
        }.joined(separator: "\n")

        if AppleSummarizer.isAvailable,
           AppleSummarizer.fits(context + recentTurns + question),
           claudeSessionID == nil {
            do {
                let localContext = recentTurns.isEmpty
                    ? context : context + "\n\nConversation so far:\n" + recentTurns
                let answer = try await AppleSummarizer.answer(question: question, context: localContext)
                messages.append(ChatMessage(role: .assistant, text: answer, provider: "apple"))
                return
            } catch {
                // Fall through to Claude.
            }
        }

        guard ClaudeCLI.isInstalled else {
            errorText = "No AI available for this meeting's size. Install Claude Code or enable Apple Intelligence."
            messages.removeLast()
            return
        }
        do {
            // --system-prompt is per-invocation (sessions persist only the
            // transcript), so it rides on resumed turns too or Claude reverts
            // to its coding-assistant persona.
            let persona = "You are Parfait's meeting assistant. Answer based only on the provided meeting record. Be concise and cite speakers/timestamps when useful."
            func ask(resume: String?) async throws -> ClaudeCLI.RunResult {
                if let resume {
                    return try await ClaudeCLI.run(prompt: question, systemPrompt: persona, resume: resume)
                }
                return try await ClaudeCLI.run(
                    prompt: "Answer questions about this meeting.\n\nQuestion: \(question)",
                    stdin: context,
                    systemPrompt: persona
                )
            }
            let result: ClaudeCLI.RunResult
            do {
                result = try await ask(resume: claudeSessionID)
            } catch let error as ClaudeCLIError where error.isSessionNotFound {
                // The persisted session was pruned — start a fresh one.
                claudeSessionID = nil
                result = try await ask(resume: nil)
            }
            claudeSessionID = result.sessionID
            messages.append(ChatMessage(role: .assistant, text: result.text, provider: "claude"))
        } catch {
            errorText = error.localizedDescription
            messages.removeLast()
        }
    }
}

/// Chat across every recorded meeting: Claude as the agent, Parfait's own MCP
/// server (this same binary, --mcp) as the tool layer.
@MainActor
final class LibraryChat: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isThinking = false
    @Published var errorText: String?

    private var sessionID: String?

    var isAvailable: Bool { ClaudeCLI.isInstalled }

    static var mcpConfigJSON: String {
        let binary = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let escaped = binary.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"mcpServers":{"parfait":{"type":"stdio","command":"\#(escaped)","args":["--mcp"]}}}"#
    }

    static let allowedTools = [
        "mcp__parfait__list_meetings",
        "mcp__parfait__search_meetings",
        "mcp__parfait__get_meeting",
        "mcp__parfait__get_transcript",
    ]

    func send(_ question: String) async {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isThinking else { return }
        messages.append(ChatMessage(role: .user, text: question))
        isThinking = true
        errorText = nil
        defer { isThinking = false }

        do {
            // MCP config, tool allowances, AND the system prompt are all
            // per-invocation, so they ride on every turn; only the session
            // transcript persists via --resume.
            func ask(resume: String?) async throws -> ClaudeCLI.RunResult {
                try await ClaudeCLI.run(
                    prompt: question,
                    systemPrompt: """
                    You are Parfait's meeting librarian. You answer questions about the user's \
                    recorded meetings using the parfait MCP tools (search_meetings, list_meetings, \
                    get_meeting, get_transcript). Search before answering; name the meeting and date \
                    you found things in. If nothing matches, say so plainly.
                    """,
                    resume: resume,
                    allowedTools: Self.allowedTools,
                    mcpConfigJSON: Self.mcpConfigJSON,
                    maxTurns: 12
                )
            }
            let result: ClaudeCLI.RunResult
            do {
                result = try await ask(resume: sessionID)
            } catch let error as ClaudeCLIError where error.isSessionNotFound {
                // This chat outlives the window now, so a pruned session must
                // self-heal instead of failing for the rest of the app's life.
                sessionID = nil
                result = try await ask(resume: nil)
            }
            sessionID = result.sessionID
            messages.append(ChatMessage(role: .assistant, text: result.text, provider: "claude"))
        } catch {
            errorText = error.localizedDescription
            messages.removeLast()
        }
    }
}
