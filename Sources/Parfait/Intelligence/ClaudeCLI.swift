import Foundation

enum ClaudeCLIError: LocalizedError {
    case notInstalled
    case notLoggedIn
    case failed(status: Int32, stderr: String)
    case badOutput

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Claude Code CLI not found. Install it from claude.com/claude-code."
        case .notLoggedIn:
            return "Claude Code is not signed in. Run claude in Terminal to log in."
        case .failed(let status, let stderr):
            return stderr.isEmpty
                ? "Claude exited with status \(status)."
                : "Claude failed (status \(status)): \(stderr)"
        case .badOutput:
            return "Claude returned unexpected output."
        }
    }

    /// A resumed session that no longer exists (Claude Code prunes sessions after
    /// ~30 days). The caller should drop the session id and retry fresh.
    var isSessionNotFound: Bool {
        if case .failed(_, let stderr) = self {
            return stderr.localizedCaseInsensitiveContains("No conversation found")
        }
        return false
    }
}

struct ClaudeCLI {
    struct RunResult: Sendable {
        let text: String
        let sessionID: String?
    }

    // `which claude` from a GUI app is unreliable (no login-shell PATH, wrapper shims
    // can shadow the real binary) — probe known install paths first, login shell last.
    // The login-shell probe can take seconds (nvm etc. in ~/.zprofile), so it never
    // runs on the main thread: UI reads `isInstalled` (fast paths + cache only) and
    // bootstrap() warms the full resolution in the background.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedResolution: URL??

    private static func fastProbe() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func shellProbe() -> URL? {
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/zsh")
        sh.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        sh.standardOutput = pipe
        sh.standardError = FileHandle.nullDevice
        guard (try? sh.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        sh.waitUntilExit()
        guard sh.terminationStatus == 0,
              let path = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Full discovery including the slow login-shell fallback. Memoized. Call
    /// off the main thread.
    static func resolveBlocking() -> URL? {
        cacheLock.lock()
        if let cached = cachedResolution {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let found = fastProbe() ?? shellProbe()
        cacheLock.lock()
        cachedResolution = .some(found)
        cacheLock.unlock()
        return found
    }

    /// Main-thread-safe: uses the cached resolution when available, otherwise
    /// only the fast path probes (a shell-only install shows up once
    /// bootstrap's warm-up completes).
    static var isInstalled: Bool {
        cacheLock.lock()
        let cached = cachedResolution
        cacheLock.unlock()
        if let cached { return cached != nil }
        return fastProbe() != nil
    }

    /// Neutral cwd for every invocation: --resume session lookup is scoped to cwd, and an
    /// app-owned dir keeps stray project CLAUDE.md files out of the model context.
    static var workDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Parfait/claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func isLoggedIn() -> Bool {
        guard let cli = resolveBlocking() else { return false }
        let process = Process()
        process.executableURL = cli
        process.arguments = ["auth", "status", "--json"]
        process.currentDirectoryURL = workDir
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        guard (try? process.run()) != nil else { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        struct AuthStatus: Decodable { let loggedIn: Bool }
        // Exit code when logged out is undocumented — trust only the JSON field.
        return (try? JSONDecoder().decode(AuthStatus.self, from: data))?.loggedIn ?? false
    }

    static func run(
        prompt: String,
        stdin: String? = nil,
        systemPrompt: String? = nil,
        model: String = "sonnet",
        resume: String? = nil,
        builtinTools: [String] = [],
        disallowedTools: [String] = [],
        allowedTools: [String] = [],
        mcpConfigJSON: String? = nil,
        maxTurns: Int = 1
    ) async throws -> RunResult {
        guard let cli = resolveBlocking() else { throw ClaudeCLIError.notInstalled }
        guard isLoggedIn() else { throw ClaudeCLIError.notLoggedIn }

        let process = Process()
        process.executableURL = cli
        process.arguments = buildArgs(
            prompt: prompt, systemPrompt: systemPrompt, model: model, resume: resume,
            builtinTools: builtinTools, disallowedTools: disallowedTools,
            allowedTools: allowedTools, mcpConfigJSON: mcpConfigJSON, maxTurns: maxTurns)
        process.currentDirectoryURL = workDir

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain both pipes while waiting for exit — output can exceed the 64KB pipe buffer.
        async let stdoutData = readToEnd(stdoutPipe.fileHandleForReading)
        async let stderrData = readToEnd(stderrPipe.fileHandleForReading)

        let stdinData = stdin.map { Data($0.utf8) }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                // Close write ends so the pipe readers see EOF instead of hanging.
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                continuation.resume(throwing: ClaudeCLIError.failed(status: -1, stderr: error.localizedDescription))
                return
            }
            DispatchQueue.global(qos: .utility).async {
                let writer = stdinPipe.fileHandleForWriting
                if let stdinData { try? writer.write(contentsOf: stdinData) }
                try? writer.close()
            }
        }

        let out = await stdoutData
        let err = await stderrData

        guard status == 0 else {
            throw ClaudeCLIError.failed(status: status, stderr: tail(String(decoding: err, as: UTF8.self)))
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: out) else {
            throw ClaudeCLIError.badOutput
        }
        if envelope.isError == true {
            throw ClaudeCLIError.failed(status: status, stderr: tail(envelope.result ?? ""))
        }
        guard let text = envelope.result else { throw ClaudeCLIError.badOutput }
        return RunResult(text: text, sessionID: envelope.sessionID)
    }

    // Never --bare (breaks subscription/keychain auth); never --no-session-persistence
    // (resume must keep working). The built-in tool set is ALWAYS pinned explicitly:
    // the default "" means even a run that enables MCP tools loads no Bash/Write/etc.,
    // so prompt injection in meeting content has nothing to execute with.
    static func buildArgs(
        prompt: String,
        systemPrompt: String? = nil,
        model: String = "sonnet",
        resume: String? = nil,
        builtinTools: [String] = [],
        disallowedTools: [String] = [],
        allowedTools: [String] = [],
        mcpConfigJSON: String? = nil,
        maxTurns: Int = 1
    ) -> [String] {
        var args = ["-p", prompt,
                    "--output-format", "json",
                    "--model", model,
                    "--max-turns", String(maxTurns),
                    "--strict-mcp-config",
                    "--tools", builtinTools.joined(separator: ",")]
        if let systemPrompt { args += ["--system-prompt", systemPrompt] }
        if let resume { args += ["--resume", resume] }
        if !disallowedTools.isEmpty { args += ["--disallowedTools", disallowedTools.joined(separator: ",")] }
        if !allowedTools.isEmpty { args += ["--allowedTools", allowedTools.joined(separator: ",")] }
        if let mcpConfigJSON { args += ["--mcp-config", mcpConfigJSON] }
        return args
    }

    /// Built-in tools that can mutate the machine or run code. The Artifact
    /// publish path loads the default tool set (so ToolSearch can reach the
    /// deferred Artifact tool) but bans these so injected content can't act.
    static let executionTools = [
        "Bash", "Edit", "Write", "Agent", "Task", "Workflow", "Skill", "ScheduleWakeup",
    ]

    private struct Envelope: Decodable {
        let result: String?
        let sessionID: String?
        let isError: Bool?

        enum CodingKeys: String, CodingKey {
            case result
            case sessionID = "session_id"
            case isError = "is_error"
        }
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: (try? handle.readToEnd()) ?? Data())
            }
        }
    }

    private static func tail(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(2000))
    }
}
