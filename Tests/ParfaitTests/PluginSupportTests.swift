import XCTest
@testable import Parfait

final class PluginSupportTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginSupportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - Launcher script

    func testWriteLauncherScriptCreatesExecutableShellScript() throws {
        let dir = try makeTempDir()
        let binary = "/Applications/Parfait.app/Contents/MacOS/Parfait"
        XCTAssertTrue(MCPLauncher.writeLauncherScript(binaryPath: binary, to: dir))

        let script = dir.appendingPathComponent("parfait-mcp")
        let content = try String(contentsOf: script, encoding: .utf8)
        XCTAssertEqual(content.components(separatedBy: "\n").first, "#!/bin/sh")
        XCTAssertTrue(content.contains(#"exec "/Applications/Parfait.app/Contents/MacOS/Parfait" --mcp "$@""#))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script.path))
        let perms = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int)
        XCTAssertEqual(perms, 0o755)
    }

    func testRewriteLauncherScriptUpdatesBinaryPath() throws {
        let dir = try makeTempDir()
        XCTAssertTrue(MCPLauncher.writeLauncherScript(binaryPath: "/old/Parfait", to: dir))
        XCTAssertTrue(MCPLauncher.writeLauncherScript(binaryPath: "/new/Parfait", to: dir))

        let script = dir.appendingPathComponent("parfait-mcp")
        let content = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(content.contains(#"exec "/new/Parfait" --mcp "$@""#))
        XCTAssertFalse(content.contains("/old/Parfait"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script.path))
    }

    func testWriteLauncherScriptCreatesMissingDirectory() throws {
        let dir = try makeTempDir().appendingPathComponent("nested/bin", isDirectory: true)
        XCTAssertTrue(MCPLauncher.writeLauncherScript(binaryPath: "/x/Parfait", to: dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("parfait-mcp").path))
    }

    // MARK: - `claude plugin list --json` parsing (fixtures match the observed shape)

    func testParseStatusInstalled() {
        let json = """
        [
          {
            "id": "superpowers@claude-plugins-official",
            "version": "6.1.1",
            "scope": "user",
            "enabled": true,
            "installPath": "/Users/x/.claude/plugins/cache/claude-plugins-official/superpowers/6.1.1",
            "installedAt": "2026-03-14T00:58:56.291Z",
            "lastUpdated": "2026-07-07T12:32:33.433Z"
          },
          {
            "id": "parfait@parfait",
            "version": "0.1.0",
            "scope": "user",
            "enabled": true,
            "installPath": "/Users/x/.claude/plugins/cache/parfait/parfait/0.1.0",
            "installedAt": "2026-07-20T00:00:00.000Z",
            "lastUpdated": "2026-07-20T00:00:00.000Z",
            "mcpServers": {
              "parfait": { "type": "stdio", "command": "/Users/x/Library/Application Support/Parfait/bin/parfait-mcp" }
            }
          }
        ]
        """
        let status = ParfaitPlugin.parseStatus(json: Data(json.utf8))
        XCTAssertTrue(status.installed)
        XCTAssertTrue(status.enabled)
        XCTAssertEqual(status.version, "0.1.0")
    }

    func testParseStatusDisabledEntry() {
        let json = """
        [{"id": "parfait@parfait", "version": "0.1.0", "scope": "user", "enabled": false}]
        """
        let status = ParfaitPlugin.parseStatus(json: Data(json.utf8))
        XCTAssertTrue(status.installed)
        XCTAssertFalse(status.enabled)
    }

    func testParseStatusUnknownVersionNormalizedToNil() {
        // The CLI reports the literal string "unknown" when a plugin manifest has no version.
        let json = """
        [{"id": "parfait@parfait", "version": "unknown", "scope": "user", "enabled": true}]
        """
        let status = ParfaitPlugin.parseStatus(json: Data(json.utf8))
        XCTAssertTrue(status.installed)
        XCTAssertNil(status.version)
    }

    func testParseStatusNotInstalled() {
        let json = """
        [{"id": "superpowers@claude-plugins-official", "version": "6.1.1", "scope": "user", "enabled": true}]
        """
        let status = ParfaitPlugin.parseStatus(json: Data(json.utf8))
        XCTAssertFalse(status.installed)
        XCTAssertNil(status.version)
    }

    func testParseStatusDoesNotMatchOtherMarketplacesPluginsWithParfaitPrefix() {
        // "parfait-extras@other" must not read as the parfait plugin.
        let json = """
        [{"id": "parfait-extras@other", "version": "1.0.0", "scope": "user", "enabled": true}]
        """
        XCTAssertFalse(ParfaitPlugin.parseStatus(json: Data(json.utf8)).installed)
    }

    func testParseStatusEmptyAndMalformed() {
        XCTAssertFalse(ParfaitPlugin.parseStatus(json: Data("[]".utf8)).installed)
        XCTAssertFalse(ParfaitPlugin.parseStatus(json: Data("{}".utf8)).installed)
        XCTAssertFalse(ParfaitPlugin.parseStatus(json: Data("not json".utf8)).installed)
        XCTAssertFalse(ParfaitPlugin.parseStatus(json: Data()).installed)
    }
}
