import XCTest
@testable import Parfait

final class HTMLExporterTests: XCTestCase {
    // MARK: - renderMarkdown

    func testHeadings() {
        let html = HTMLExporter.renderMarkdown("# One\n## Two\n### Three")
        XCTAssertTrue(html.contains("<h1>One</h1>"))
        XCTAssertTrue(html.contains("<h2>Two</h2>"))
        XCTAssertTrue(html.contains("<h3>Three</h3>"))
    }

    func testParagraphsSeparatedByBlankLines() {
        let html = HTMLExporter.renderMarkdown("First line\nstill first.\n\nSecond.")
        XCTAssertTrue(html.contains("<p>First line still first.</p>"))
        XCTAssertTrue(html.contains("<p>Second.</p>"))
    }

    func testBoldAndItalic() {
        let html = HTMLExporter.renderMarkdown("Ship **now** and *fast*.")
        XCTAssertTrue(html.contains("<strong>now</strong>"))
        XCTAssertTrue(html.contains("<em>fast</em>"))
        XCTAssertFalse(html.contains("*"))
    }

    func testBullets() {
        let html = HTMLExporter.renderMarkdown("- one\n- two\n\nafter")
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("<li>one</li>"))
        XCTAssertTrue(html.contains("<li>two</li>"))
        XCTAssertTrue(html.contains("</ul>"))
        XCTAssertTrue(html.contains("<p>after</p>"))
    }

    func testCheckboxes() {
        let html = HTMLExporter.renderMarkdown("- [ ] open item\n- [x] done item")
        XCTAssertTrue(html.contains("<li class=\"task\"><input type=\"checkbox\" disabled> open item</li>"))
        XCTAssertTrue(html.contains("<li class=\"task\"><input type=\"checkbox\" disabled checked> done item</li>"))
    }

    func testUnknownLinesBecomeParagraphs() {
        let html = HTMLExporter.renderMarkdown("> not a supported quote")
        XCTAssertTrue(html.contains("<p>&gt; not a supported quote</p>"))
    }

    // MARK: - escape

    func testEscapeNeutralizesScriptTag() {
        let out = HTMLExporter.escape("<script>alert('x & y')</script>")
        XCTAssertFalse(out.contains("<script>"))
        XCTAssertEqual(out, "&lt;script&gt;alert(&#39;x &amp; y&#39;)&lt;/script&gt;")
    }

    // MARK: - html

    func testHTMLDocument() {
        var m = Meeting(title: "Design Sync <Q3>", createdAt: Date(timeIntervalSince1970: 1_750_000_000))
        m.duration = 30 * 60
        m.attendees = ["Alice", "Bob"]
        m.speakers = [
            Speaker(id: "me", name: "Me", isMe: true),
            Speaker(id: "s1", name: "Alice"),
        ]
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 2, text: "Hi <everyone>."),
            TranscriptSegment(speakerID: "me", start: 2, end: 4, text: "Let's begin."),
            TranscriptSegment(speakerID: "s1", start: 65, end: 70, text: "Sounds good."),
        ]
        let html = HTMLExporter.html(
            meeting: m,
            summaryMarkdown: "# {{title}}\n\n{{date}} · {{attendees}}\n\n## TL;DR\nWe met.",
            segments: segments,
            followups: [])

        // title (escaped) in <title> and header; raw user markup never survives
        XCTAssertTrue(html.contains("<title>Design Sync &lt;Q3&gt;</title>"))
        XCTAssertTrue(html.contains("<h1>Design Sync &lt;Q3&gt;</h1>"))
        XCTAssertFalse(html.contains("<Q3>"))

        // speaker names and attendee chips
        XCTAssertTrue(html.contains("<span class=\"speaker\">Me</span>"))
        XCTAssertTrue(html.contains("<span class=\"speaker\">Alice</span>"))
        XCTAssertTrue(html.contains("<span class=\"chip\">Bob</span>"))

        // timestamps, with consecutive same-speaker segments merged into one turn
        XCTAssertTrue(html.contains("0:00"))
        XCTAssertTrue(html.contains("1:05"))
        XCTAssertTrue(html.contains("<p>Hi &lt;everyone&gt;. Let&#39;s begin.</p>"))

        // template placeholders were filled — none leak into the page
        XCTAssertFalse(html.contains("{{"))
        XCTAssertTrue(html.contains("30 min"))
    }

    func testGeneratorMetaPresentOnceBeforeTitle() {
        let m = Meeting(title: "Solo", createdAt: Date())
        let html = HTMLExporter.html(meeting: m, summaryMarkdown: "", segments: [], followups: [])
        let marker = "<meta name=\"generator\" content=\"parfait/1\">"
        XCTAssertEqual(html.components(separatedBy: marker).count - 1, 1)
        guard let markerRange = html.range(of: marker), let titleRange = html.range(of: "<title>") else {
            return XCTFail("expected both generator meta and <title> in output")
        }
        XCTAssertTrue(markerRange.upperBound <= titleRange.lowerBound)
    }

    func testHTMLOmitsEmptySections() {
        let m = Meeting(title: "Solo", createdAt: Date())
        let html = HTMLExporter.html(meeting: m, summaryMarkdown: "", segments: [], followups: [])
        XCTAssertFalse(html.contains("Transcript"))
        XCTAssertFalse(html.contains("Summary"))
        XCTAssertFalse(html.contains("Follow-ups"))
        XCTAssertTrue(html.contains("Recorded with"))
    }

    // MARK: - followups section

    private func makeFollowup(
        title: String, owner: String? = nil, status: Followup.Status = .approved,
        suggestedAction: String? = nil, sourceQuote: String? = nil
    ) -> Followup {
        let now = Date()
        return Followup(
            id: UUID(), kind: .action, title: title,
            owner: owner, sourceQuote: sourceQuote, suggestedAction: suggestedAction,
            status: status, resultURL: nil, note: nil,
            createdAt: now, updatedAt: now)
    }

    private func renderFollowups(_ followups: [Followup], meeting: Meeting? = nil) -> String {
        HTMLExporter.html(
            meeting: meeting ?? Meeting(title: "Sync", createdAt: Date()),
            summaryMarkdown: "", segments: [], followups: followups)
    }

    func testOpenFollowupRendersTitleAndClaudeButton() {
        let html = renderFollowups([makeFollowup(title: "Send the deck", suggestedAction: "Email it to Bob")])
        XCTAssertTrue(html.contains("Follow-ups"))
        XCTAssertTrue(html.contains("Send the deck"))
        XCTAssertTrue(html.contains("Email it to Bob"))
        XCTAssertTrue(html.contains("<a class=\"claude-btn\" href=\"https://claude.ai/new?q="))
        XCTAssertTrue(html.contains(">Hand to Claude</a>"))
        XCTAssertTrue(html.contains("PARFAIT_PAGE_URL"), "href must carry the worker's page-URL marker")
    }

    func testDoneFollowupIsCheckedWithoutButton() {
        let html = renderFollowups([makeFollowup(title: "Ship it", status: .done)])
        XCTAssertTrue(html.contains("<input type=\"checkbox\" disabled checked>"))
        XCTAssertFalse(html.contains("<a class=\"claude-btn\""))
        XCTAssertFalse(html.contains("Hand to Claude"))
    }

    func testFollowupsRailPrecedesSummary() {
        let html = HTMLExporter.html(
            meeting: Meeting(title: "Sync", createdAt: Date()),
            summaryMarkdown: "# Notes", segments: [],
            followups: [makeFollowup(title: "Send the deck")])
        guard let followupsAt = html.range(of: "<h2 class=\"section-title\">Follow-ups</h2>"),
              let summaryAt = html.range(of: "<h2 class=\"section-title\">Summary</h2>") else {
            return XCTFail("expected both section titles")
        }
        XCTAssertTrue(followupsAt.upperBound <= summaryAt.lowerBound)
        XCTAssertTrue(html.contains("<div class=\"followup-rail\">"))
    }

    func testDismissedFollowupIsAbsent() {
        let html = renderFollowups([makeFollowup(title: "Never mind", status: .dismissed)])
        XCTAssertFalse(html.contains("Never mind"))
        XCTAssertFalse(html.contains("Follow-ups"))
    }

    func testOwnerMeRendersTheLocalSpeakerName() {
        var m = Meeting(title: "Sync", createdAt: Date())
        // Attendees keep the header chips off the speaker name, so the
        // Conrad chip below can only come from the follow-up owner mapping.
        m.attendees = ["Someone Else"]
        m.speakers = [Speaker(id: "me", name: "Conrad", isMe: true)]
        let html = renderFollowups([makeFollowup(title: "Send the deck", owner: "Me")], meeting: m)
        XCTAssertTrue(html.contains("<span class=\"chip\">Conrad</span>"))
        XCTAssertFalse(html.contains("<span class=\"chip\">Me</span>"))
    }

    func testTrimmedAndUnresolvableOwnersDegradeSafely() {
        var m = Meeting(title: "Sync", createdAt: Date())
        m.attendees = ["Someone Else"]
        m.speakers = [Speaker(id: "me", name: "Conrad", isMe: true)]
        let padded = renderFollowups([makeFollowup(title: "Send the deck", owner: " me ")], meeting: m)
        XCTAssertTrue(padded.contains("<span class=\"chip\">Conrad</span>"))
        XCTAssertFalse(padded.contains("<span class=\"chip\"> me </span>"))
        // With no isMe speaker the exporter falls back to the account name
        // (asserted precisely in FollowupTests); here just pin that no empty
        // chip artifact ever renders.
        var noSelf = Meeting(title: "Sync", createdAt: Date())
        noSelf.attendees = ["Someone Else"]
        noSelf.speakers = [Speaker(id: "s1", name: "Alice", isMe: false)]
        let fallback = renderFollowups([makeFollowup(title: "Send the deck", owner: "me")], meeting: noSelf)
        XCTAssertFalse(fallback.contains("<span class=\"chip\"></span>"))
    }

    func testHostileFollowupTitleStaysEscapedEverywhere() {
        let html = renderFollowups([makeFollowup(title: "Do <script>alert(1)</script> \"now\"")])
        XCTAssertFalse(html.contains("<script"))
        guard let hrefStart = html.range(of: "href=\"https://claude.ai/new?q=") else {
            return XCTFail("expected a claude.ai href")
        }
        let rest = html[hrefStart.upperBound...]
        let value = rest.prefix(while: { $0 != "\"" })
        XCTAssertTrue(value.contains("%3C"))
        XCTAssertTrue(rest.dropFirst(value.count).hasPrefix("\"><svg"))
        XCTAssertTrue(rest.contains("Hand to Claude</a>"))
    }

    func testOpenFollowupsPrecedeDoneOnes() {
        let html = renderFollowups([
            makeFollowup(title: "Already shipped", status: .done),
            makeFollowup(title: "Still open", status: .proposed),
        ])
        guard let open = html.range(of: "Still open"), let done = html.range(of: "Already shipped") else {
            return XCTFail("expected both items rendered")
        }
        XCTAssertTrue(open.lowerBound < done.lowerBound)
    }
}
