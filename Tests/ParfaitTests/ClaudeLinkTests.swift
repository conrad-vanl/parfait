import XCTest
@testable import Parfait

final class ClaudeLinkTests: XCTestCase {
    func testDigInPromptNamesSkillMeetingAndFallback() {
        let id = UUID()
        let prompt = ClaudeLink.digInPrompt(meetingID: id, title: "Roadmap sync")
        XCTAssertTrue(prompt.hasPrefix("/parfait:dig-in \(id.uuidString)"))
        XCTAssertTrue(prompt.contains("Roadmap sync"))
        // The fallback sentence keeps the prompt working without the plugin.
        XCTAssertTrue(prompt.contains("Parfait meeting"))
        XCTAssertTrue(prompt.contains("follow-ups"))
    }

    func testMeetingPromptCarriesTitleAndId() {
        let id = UUID()
        let prompt = ClaudeLink.meetingPrompt(meetingID: id, title: "Roadmap sync")
        XCTAssertTrue(prompt.contains("Parfait meeting"))
        XCTAssertTrue(prompt.contains("Roadmap sync"))
        XCTAssertTrue(prompt.contains(id.uuidString))
        XCTAssertTrue(prompt.contains("key decisions and action items"))
    }

    func testLibraryPromptAsksAcrossMeetings() {
        let prompt = ClaudeLink.libraryPrompt()
        XCTAssertTrue(prompt.contains("Parfait meetings"))
        XCTAssertTrue(prompt.contains("talking about"))
    }

    func testLivePromptWordingPreserved() {
        XCTAssertEqual(
            ClaudeLink.livePrompt(),
            "I'm in a Parfait meeting happening right now — What's being discussed, and is there anything I should add or ask?")
    }

    func testScoopPromptNamesSkillAndEventTitle() {
        let prompt = ClaudeLink.scoopPrompt(eventTitle: "Q3 planning")
        XCTAssertTrue(prompt.hasPrefix("/parfait:scoop Q3 planning"))
        XCTAssertTrue(prompt.contains("my upcoming meeting \"Q3 planning\""))
    }

    func testScoopPromptWithoutEventTitle() {
        for title in [nil, "", "   "] {
            let prompt = ClaudeLink.scoopPrompt(eventTitle: title)
            XCTAssertTrue(prompt.hasPrefix("/parfait:scoop\n"))
            XCTAssertTrue(prompt.contains("my upcoming meeting —"))
        }
    }

    func testAllPromptsFitTheDeepLinkWithoutTruncation() {
        let id = UUID()
        let title = String(repeating: "Very long meeting title ", count: 8)
        let prompts = [
            ClaudeLink.digInPrompt(meetingID: id, title: title),
            ClaudeLink.meetingPrompt(meetingID: id, title: title),
            ClaudeLink.libraryPrompt(),
            ClaudeLink.livePrompt(),
            ClaudeLink.scoopPrompt(eventTitle: title),
        ]
        for prompt in prompts {
            XCTAssertLessThanOrEqual(prompt.count, ClaudeDesktop.maxPromptLength)
            let url = ClaudeDesktop.newChatURL(prompt: prompt)!
            let decoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value
            XCTAssertEqual(decoded, prompt)
        }
    }
}
