import Foundation

/// Stable launcher for the plugin's `.mcp.json`. The bundle binary's path changes
/// across installs/updates, so the plugin invokes this script and the app rewrites
/// it on every launch to exec the current binary.
enum MCPLauncher {
    static var binDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Parfait/bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var scriptURL: URL { binDir.appendingPathComponent("parfait-mcp") }

    /// Parameters exist for tests; production callers take the defaults.
    @discardableResult
    static func writeLauncherScript(binaryPath: String? = nil, to dir: URL? = nil) -> Bool {
        let binary = binaryPath
            ?? Bundle.main.executablePath
            ?? "/Applications/Parfait.app/Contents/MacOS/Parfait"
        let target = (dir ?? binDir).appendingPathComponent("parfait-mcp")
        let script = """
        #!/bin/sh
        # Rewritten by Parfait.app on every launch — do not edit.
        exec "\(binary)" --mcp "$@"

        """
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(script.utf8).write(to: target, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: target.path)
            return true
        } catch {
            return false
        }
    }
}

/// Install/status for the `parfait` Claude plugin via the `claude` CLI.
enum ParfaitPlugin {
    static let marketplaceSource = "conrad-vanl/parfait"
    static let installRef = "parfait@parfait"
    static let pluginName = "parfait"

    struct Status: Sendable {
        var installed: Bool
        var enabled: Bool
        var version: String?
    }

    enum InstallError: LocalizedError {
        case cliMissing
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .cliMissing:
                return "Claude Code CLI not found. Install it from claude.com/claude-code."
            case .commandFailed(let message):
                return message
            }
        }
    }

    /// Blocking (shells out); call off the main thread.
    static func status() -> Status {
        guard let cli = ClaudeCLI.resolveBlocking(),
              case .success(let stdout) = run(cli, ["plugin", "list", "--json"])
        else { return Status(installed: false, enabled: false, version: nil) }
        return parseStatus(json: Data(stdout.utf8))
    }

    /// `claude plugin list --json` emits an array of entries keyed by
    /// `id` ("name@marketplace"); `version` can be the literal "unknown".
    static func parseStatus(json: Data) -> Status {
        struct Entry: Decodable {
            let id: String?
            let name: String?
            let version: String?
            let enabled: Bool?
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: json),
              let entry = entries.first(where: {
                  $0.id?.hasPrefix("\(pluginName)@") == true || $0.name == pluginName
              })
        else { return Status(installed: false, enabled: false, version: nil) }
        let version = entry.version.flatMap { $0.isEmpty || $0 == "unknown" ? nil : $0 }
        return Status(installed: true, enabled: entry.enabled ?? true, version: version)
    }

    /// Blocking; call off the main thread. Both steps tolerate already-added/installed.
    static func install() -> Result<Void, InstallError> {
        guard let cli = ClaudeCLI.resolveBlocking() else { return .failure(.cliMissing) }
        if case .failure(let error) = runTolerant(cli, ["plugin", "marketplace", "add", marketplaceSource]) {
            return .failure(error)
        }
        if case .failure(let error) = runTolerant(cli, ["plugin", "install", installRef]) {
            return .failure(error)
        }
        return .success(())
    }

    /// Blocking; call off the main thread. The bare plugin name is ambiguous to
    /// the CLI ("not found") — update requires the full plugin@marketplace ref.
    static func update() -> Result<Void, InstallError> {
        guard let cli = ClaudeCLI.resolveBlocking() else { return .failure(.cliMissing) }
        return run(cli, ["plugin", "update", installRef]).map { _ in () }
    }

    /// Treats a nonzero exit whose message says "already …" as success — both
    /// `marketplace add` and `plugin install` refuse re-runs that way.
    private static func runTolerant(_ cli: URL, _ args: [String]) -> Result<Void, InstallError> {
        switch run(cli, args) {
        case .success:
            return .success(())
        case .failure(.commandFailed(let message))
            where message.localizedCaseInsensitiveContains("already"):
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    private static func run(_ cli: URL, _ args: [String]) -> Result<String, InstallError> {
        let process = Process()
        process.executableURL = cli
        process.arguments = args
        process.currentDirectoryURL = ClaudeCLI.workDir
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        guard (try? process.run()) != nil else {
            return .failure(.commandFailed("Couldn't run the claude CLI."))
        }
        // Drain stderr concurrently so neither pipe filling up can deadlock the child.
        nonisolated(unsafe) var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()
        guard process.terminationStatus == 0 else {
            let stderr = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = String(decoding: outData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = stderr.isEmpty ? stdout : stderr
            return .failure(.commandFailed(
                message.isEmpty
                    ? "claude \(args.joined(separator: " ")) failed (status \(process.terminationStatus))."
                    : String(message.suffix(500))))
        }
        return .success(String(decoding: outData, as: UTF8.self))
    }
}
