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
            segments: segments)

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
        let html = HTMLExporter.html(meeting: m, summaryMarkdown: "", segments: [])
        let marker = "<meta name=\"generator\" content=\"parfait/1\">"
        XCTAssertEqual(html.components(separatedBy: marker).count - 1, 1)
        guard let markerRange = html.range(of: marker), let titleRange = html.range(of: "<title>") else {
            return XCTFail("expected both generator meta and <title> in output")
        }
        XCTAssertTrue(markerRange.upperBound <= titleRange.lowerBound)
    }

    func testHTMLOmitsEmptySections() {
        let m = Meeting(title: "Solo", createdAt: Date())
        let html = HTMLExporter.html(meeting: m, summaryMarkdown: "", segments: [])
        XCTAssertFalse(html.contains("Transcript"))
        XCTAssertFalse(html.contains("Summary"))
        XCTAssertTrue(html.contains("Recorded with"))
    }
}
