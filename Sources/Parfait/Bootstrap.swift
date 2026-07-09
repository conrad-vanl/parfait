import Foundation

/// One binary, two personalities:
///   Parfait          → the menu bar app
///   Parfait --mcp    → an MCP stdio server over the meeting archive
///   Parfait --version
@main
enum Bootstrap {
    static let version = "0.1.0"

    static func main() {
        let args = CommandLine.arguments
        if args.contains("--version") {
            print("parfait \(version)")
            return
        }
        if args.contains("--mcp") {
            MCPServer(archive: MeetingArchive()).runBlocking()
            return
        }
        ParfaitApp.main()
    }
}
