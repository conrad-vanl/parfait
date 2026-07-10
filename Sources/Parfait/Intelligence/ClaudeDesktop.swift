import AppKit
import Foundation

/// Deep-link launcher for Claude Desktop, replacing the in-app chat engines.
/// support.claude.com: claude://claude.ai/new?q=<url-encoded prompt> opens a
/// NEW chat with the prompt PRE-FILLED — the user still reviews and hits send.
/// There is no parameter to enable a connector, so the prompt text itself must
/// name "parfait" and its tools (see ClaudeDesktopPrompt below).
enum ClaudeDesktop {
    /// The q value is truncated around 14,000 characters server-side. We never
    /// get close in practice — Claude fetches meeting content itself via MCP,
    /// so the prompt only carries instructions + the user's typed question —
    /// but a generous cap keeps a runaway typed question from breaking the link.
    static let maxPromptLength = 4000

    /// NSWorkspace resolving the scheme handler is a fast Launch Services
    /// lookup (no shell-out), unlike ClaudeCLI.isInstalled's login-shell
    /// fallback — safe to call directly from a view body.
    static var isInstalled: Bool {
        guard let probe = URL(string: "claude://") else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: probe) != nil
    }

    /// Pure — no side effects — so it's unit-testable without NSWorkspace.
    static func newChatURL(prompt: String) -> URL? {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "claude.ai"
        components.path = "/new"
        components.queryItems = [URLQueryItem(name: "q", value: String(prompt.prefix(maxPromptLength)))]
        // URLComponents encodes & and = in the value but leaves a literal + (a Foundation
        // quirk); a parser that form-decodes would read + as a space, so encode it too.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    /// Side-effecting half of the pair above.
    @discardableResult
    static func openNewChat(prompt: String) -> Bool {
        guard let url = newChatURL(prompt: prompt) else { return false }
        return NSWorkspace.shared.open(url)
    }
}

/// Builds the instruction text that steers Claude Desktop to Parfait's own
/// "parfait" MCP connector — the deep link has no param for this, so the
/// prompt has to say it explicitly, by name, every time.
enum ClaudeDesktopPrompt {
    private static let defaultMeetingQuestion =
        "Give me a quick overview of this meeting — key decisions and action items."
    private static let defaultLibraryQuestion =
        "What have I been talking about across my recent meetings?"

    static func meeting(id: UUID, title: String, question: String) -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        // Claude has the parfait connector's tools available and can decide which to
        // call — naming the meeting + its id is enough to steer it.
        return """
        Answer a question about my Parfait meeting "\(title)" (id: \(id.uuidString)).

        \(q.isEmpty ? defaultMeetingQuestion : q)
        """
    }

    static func library(question: String) -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Answer using my Parfait meetings:

        \(q.isEmpty ? defaultLibraryQuestion : q)
        """
    }

    /// For the "Ask Claude live" button during a recording. Claude has the live
    /// transcript tool available and uses it on its own.
    static func live(question: String) -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let ask = q.isEmpty ? "What's being discussed, and is there anything I should add or ask?" : q
        return "I'm in a Parfait meeting happening right now — \(ask)"
    }
}

/// Deep-link launcher for a Claude Code session (claude://code/new). Unlike
/// ClaudeDesktop's chat link, Claude Code can actually run the setup — install
/// the GitHub CLI, register the MCP server, edit the Claude Desktop config — so
/// the "do it for you" buttons in Settings/Onboarding open a Code session
/// pre-filled with a prompt that performs the step (the user still reviews and
/// approves before anything runs).
enum ClaudeCode {
    /// Same claude:// scheme handler as Claude Desktop; if that resolves, the
    /// code/new deep link is handled too.
    static var isAvailable: Bool { ClaudeDesktop.isInstalled }

    /// Pure — no side effects — so it's unit-testable without NSWorkspace.
    static func codeSessionURL(prompt: String, folder: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/new"
        var items = [URLQueryItem(name: "q", value: String(prompt.prefix(ClaudeDesktop.maxPromptLength)))]
        if let folder { items.append(URLQueryItem(name: "folder", value: folder)) }
        components.queryItems = items
        // Same literal-+ quirk ClaudeDesktop.newChatURL guards against.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    @discardableResult
    static func open(prompt: String, folder: String? = nil) -> Bool {
        let workdir = folder ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard let url = codeSessionURL(prompt: prompt, folder: workdir) else { return false }
        return NSWorkspace.shared.open(url)
    }

    // MARK: - Pre-filled setup prompts

    @discardableResult
    static func setUpGitHubCLI() -> Bool {
        open(prompt: """
        Set up the GitHub CLI so Parfait can publish my meeting notes as secret gists on my own \
        GitHub account. Check whether the gh command is installed; if not, install it (use \
        Homebrew if it is available, otherwise recommend the best option for my Mac). Then run \
        gh auth login and confirm it worked with gh auth status.
        """)
    }

    @discardableResult
    static func addMCPServer(binary: String) -> Bool {
        open(prompt: """
        Connect Parfait to Claude Code as an MCP server so you can read my meeting library. Run \
        this command, then confirm it is connected with claude mcp list:

        claude mcp add parfait -s user -- "\(binary)" --mcp
        """)
    }

    @discardableResult
    static func addToClaudeDesktop(binary: String, configPath: String) -> Bool {
        open(prompt: """
        Add Parfait to my Claude Desktop MCP config. Edit the JSON file at \(configPath) and add a \
        "parfait" entry under "mcpServers" with "command" set to "\(binary)" and "args" set to \
        ["--mcp"]. Merge it with any servers already there instead of overwriting them, and create \
        the file with just the parfait entry if it does not exist. When you are done, tell me to \
        quit and reopen Claude Desktop.
        """)
    }
}
