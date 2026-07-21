import AppKit
import Foundation

/// Deep-link launcher for Claude Desktop, replacing the in-app chat engines.
/// support.claude.com: claude://claude.ai/new?q=<url-encoded prompt> opens a
/// NEW chat with the prompt PRE-FILLED — the user still reviews and hits send.
/// There is no parameter to enable a connector, so the prompt text itself must
/// name "parfait" and its tools (see ClaudeLink, the prompt builder).
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

/// Deep-link launcher for a Claude Code session (claude://code/new). Unlike
/// ClaudeDesktop's chat link, Claude Code can actually run the setup — e.g.
/// install the GitHub CLI — so the "do it for you" buttons in
/// Settings/Onboarding open a Code session pre-filled with a prompt that
/// performs the step (the user still reviews and approves before anything
/// runs). MCP registration no longer needs this path: the Parfait plugin
/// carries the server config (see ParfaitPlugin).
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

}
