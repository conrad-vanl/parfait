import XCTest
@testable import Parfait

final class ClaudeDesktopTests: XCTestCase {
    func testNewChatURLSchemeHostPath() {
        let url = ClaudeDesktop.newChatURL(prompt: "hello")!
        XCTAssertEqual(url.scheme, "claude")
        XCTAssertEqual(url.host, "claude.ai")
        XCTAssertEqual(url.path, "/new")
    }

    func testNewChatURLPercentEncodesSpecialCharacters() {
        let prompt = #"Hello, world! Use tool: get_meeting id=abc&def #tag "quoted" 100%"#
        let url = ClaudeDesktop.newChatURL(prompt: prompt)!
        XCTAssertEqual(
            url.absoluteString,
            #"claude://claude.ai/new?q=Hello,%20world!%20Use%20tool:%20get_meeting%20id%3Dabc%26def%20%23tag%20%22quoted%22%20100%25"#
        )
    }

    func testNewChatURLEncodesPlusSign() {
        // "C++ migration" must not arrive with a raw + that a form-decoder reads as a space.
        let url = ClaudeDesktop.newChatURL(prompt: "C++ migration")!
        XCTAssertTrue(url.absoluteString.contains("C%2B%2B"))
        XCTAssertFalse(url.query!.contains("+"))
        let decoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value
        XCTAssertEqual(decoded, "C++ migration")
    }

    func testNewChatURLRoundTripsOrdinaryPrompt() {
        let prompt = "What did we decide about the Q3 launch?"
        let url = ClaudeDesktop.newChatURL(prompt: prompt)!
        let decoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value
        XCTAssertEqual(decoded, prompt)
    }

    func testNewChatURLTruncatesLongPrompts() {
        let huge = String(repeating: "a", count: ClaudeDesktop.maxPromptLength + 500)
        let url = ClaudeDesktop.newChatURL(prompt: huge)!
        let decoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value
        XCTAssertEqual(decoded?.count, ClaudeDesktop.maxPromptLength)
    }

    func testNewChatURLHandlesEmptyPrompt() {
        let url = ClaudeDesktop.newChatURL(prompt: "")
        XCTAssertEqual(url?.query, "q=")
    }

    func testMeetingPromptCarriesTitleIdAndQuestion() {
        let id = UUID()
        let prompt = ClaudeDesktopPrompt.meeting(id: id, title: "Roadmap sync", question: "What did we decide?")
        XCTAssertTrue(prompt.contains("Parfait meeting"))
        XCTAssertTrue(prompt.contains("Roadmap sync"))
        XCTAssertTrue(prompt.contains(id.uuidString))
        XCTAssertTrue(prompt.contains("What did we decide?"))
    }

    func testMeetingPromptFallsBackOnEmptyQuestion() {
        let prompt = ClaudeDesktopPrompt.meeting(id: UUID(), title: "1:1", question: "   ")
        XCTAssertFalse(prompt.contains("Question: \n"))
        XCTAssertTrue(prompt.contains("overview"))
    }

    func testLibraryPromptCarriesQuestion() {
        let prompt = ClaudeDesktopPrompt.library(question: "When did I last talk about hiring?")
        XCTAssertTrue(prompt.contains("Parfait meetings"))
        XCTAssertTrue(prompt.contains("When did I last talk about hiring?"))
    }

    func testLibraryPromptFallsBackOnEmptyQuestion() {
        let prompt = ClaudeDesktopPrompt.library(question: "")
        XCTAssertTrue(prompt.contains("talking about"))
    }

    func testLivePromptDefaultsAndCarriesQuestion() {
        XCTAssertEqual(
            ClaudeDesktopPrompt.live(question: ""),
            "I'm in a Parfait meeting happening right now — What's being discussed, and is there anything I should add or ask?")
        XCTAssertEqual(
            ClaudeDesktopPrompt.live(question: "Summarize the last 5 minutes"),
            "I'm in a Parfait meeting happening right now — Summarize the last 5 minutes")
    }

    // MARK: - ClaudeCode (claude://code/new) deep links

    func testCodeSessionURLSchemeHostPath() {
        let url = ClaudeCode.codeSessionURL(prompt: "hello", folder: "/Users/me/repo")!
        XCTAssertEqual(url.scheme, "claude")
        XCTAssertEqual(url.host, "code")
        XCTAssertEqual(url.path, "/new")
    }

    func testCodeSessionURLCarriesPromptAndFolder() {
        let url = ClaudeCode.codeSessionURL(prompt: "install gh", folder: "/Users/me")!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "q" })?.value, "install gh")
        XCTAssertEqual(items.first(where: { $0.name == "folder" })?.value, "/Users/me")
    }

    func testCodeSessionURLOmitsFolderWhenNil() {
        let url = ClaudeCode.codeSessionURL(prompt: "hi", folder: nil)!
        let names = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name)
        XCTAssertFalse(names.contains("folder"))
    }

    func testCodeSessionURLEncodesPlusSign() {
        let url = ClaudeCode.codeSessionURL(prompt: "C++ migration", folder: nil)!
        XCTAssertTrue(url.absoluteString.contains("C%2B%2B"))
        XCTAssertFalse(url.query!.contains("+"))
    }

    func testCodeSessionURLTruncatesLongPrompts() {
        let huge = String(repeating: "a", count: ClaudeDesktop.maxPromptLength + 500)
        let url = ClaudeCode.codeSessionURL(prompt: huge, folder: nil)!
        let decoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value
        XCTAssertEqual(decoded?.count, ClaudeDesktop.maxPromptLength)
    }
}
