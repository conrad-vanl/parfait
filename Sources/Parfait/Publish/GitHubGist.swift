import Foundation

enum GistError: LocalizedError {
    case ghMissing
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .ghMissing:
            return "GitHub CLI not found. Install it (brew install gh) and run gh auth login."
        case .failed(let message):
            return message
        }
    }
}

enum GitHubGist {
    static func discover() -> URL? {
        for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Login shell picks up PATH additions (mise, custom prefixes) that a
        // menu-bar app's environment doesn't inherit.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v gh"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let path = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    static var isAvailable: Bool { discover() != nil }

    /// Derives a rendered-HTML URL from a gist's raw URL by swapping the host only —
    /// the path (including the SHA-pinned /raw/ segment) is preserved byte-for-byte.
    /// `.parfaitTo` targets notes.parfait.to (see docs/plans/2026-07-09-parfait-to-notes-cdn.md);
    /// `.githack` is the transition-only fallback onto gistcdn.githack.com.
    static func renderedURL(fromRaw raw: String, host: RenderHost) -> URL? {
        guard !raw.isEmpty else { return nil }
        let target: String
        switch host {
        case .parfaitTo:
            target = raw.replacingOccurrences(of: "gist.githubusercontent.com", with: "notes.parfait.to")
        case .githack:
            target = raw.replacingOccurrences(of: "gist.githubusercontent.com", with: "gistcdn.githack.com")
        }
        return URL(string: target)
    }

    /// Creates a secret gist — unlisted, NOT private: anyone with the link can read it —
    /// and derives a rendered-HTML URL by host-swapping the commit-SHA-pinned raw URL
    /// (see `renderedURL(fromRaw:host:)`).
    static func publish(
        html: String, filename: String, description: String, host: RenderHost = AppSettings.renderHost
    ) async throws -> (gist: URL, rendered: URL) {
        guard let gh = discover() else { throw GistError.ghMissing }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parfait-gist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // The gist filename comes from the file on disk, so it must carry the real name.
        let file = dir.appendingPathComponent(filename)
        try html.data(using: .utf8)!.write(to: file, options: .atomic)

        // gh prints progress to stderr and only the gist URL to stdout.
        let created = try await run(gh, ["gist", "create", file.path, "--desc", description])
        guard let line = created.split(whereSeparator: \.isNewline).last,
              let gistURL = URL(string: line.trimmingCharacters(in: .whitespaces)),
              gistURL.scheme?.hasPrefix("http") == true
        else { throw GistError.failed("Unexpected gh gist create output: \(created)") }

        let id = gistURL.lastPathComponent
        let raw = try await run(gh, ["api", "gists/\(id)", "--jq", ".files[\"\(filename)\"].raw_url"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rendered = renderedURL(fromRaw: raw, host: host)
        else { throw GistError.failed("Could not resolve raw URL for gist \(id)") }
        return (gist: gistURL, rendered: rendered)
    }

    private static func readAll(_ handle: FileHandle) async -> Data {
        var data = Data()
        do {
            for try await byte in handle.bytes { data.append(byte) }
        } catch {}
        return data
    }

    private static func run(_ tool: URL, _ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Drain both pipes while the process runs; a full pipe buffer would deadlock gh.
        async let stdout = readAll(outPipe.fileHandleForReading)
        async let stderr = readAll(errPipe.fileHandleForReading)

        let status: Int32
        do {
            status = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            // Never launched: close our write ends so the readers see EOF and unwind.
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            throw error
        }

        let out = String(data: await stdout, encoding: .utf8) ?? ""
        guard status == 0 else {
            let err = String(data: await stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw GistError.failed(err.isEmpty ? "gh exited with status \(status)" : err)
        }
        return out
    }
}
