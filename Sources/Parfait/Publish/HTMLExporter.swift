import Foundation

/// Renders a meeting as a single self-contained HTML page (inline CSS, no external
/// assets) suitable for publishing as a gist.
enum HTMLExporter {
    static func html(meeting: Meeting, summaryMarkdown: String, segments: [TranscriptSegment]) -> String {
        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .short
        let title = escape(meeting.title)
        let date = escape(df.string(from: meeting.createdAt))
        let duration = escape(TemplateRenderer.duration(meeting.duration))

        let attendeeNames = meeting.attendees.isEmpty ? meeting.speakers.map(\.name) : meeting.attendees
        let chips = attendeeNames.isEmpty ? "" : """
        <div class="chips">
        \(attendeeNames.map { "<span class=\"chip\">\(escape($0))</span>" }.joined(separator: "\n"))
        </div>
        """

        // Models sometimes echo unfilled {{placeholders}} from the template; fill them
        // so none leak into the published page.
        let summaryBody = renderMarkdown(TemplateRenderer.fill(summaryMarkdown, meeting: meeting))
        let summaryBlock = summaryBody.isEmpty ? "" : """
        <h2 class="section-title">Summary</h2>
        <section class="card">
        \(summaryBody)
        </section>
        """

        let turns = transcriptTurns(segments: segments, speakers: meeting.speakers)
        let transcriptBlock = turns.isEmpty ? "" : """
        <h2 class="section-title">Transcript</h2>
        <section class="card">
        \(turns)
        </section>
        """

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <meta name="generator" content="parfait/1">
        <title>\(title)</title>
        <style>
        :root{
          --page:#FFF9F2; --card:#FBF1E4; --accent:#E0396B; --honey:#F2A93B;
          --link:#5A6ACF; --ink:#43322B; --muted:rgba(67,50,43,.62);
          --border:rgba(67,50,43,.12); --chip:rgba(224,57,107,.09);
        }
        @media (prefers-color-scheme: dark){
          :root{
            --page:#252017; --card:#322B27; --accent:#F0708F; --honey:#F2B24F;
            --link:#98A4EE; --ink:#F2E9DE; --muted:rgba(242,233,222,.6);
            --border:rgba(242,233,222,.12); --chip:rgba(240,112,143,.14);
          }
        }
        *{box-sizing:border-box}
        body{
          margin:0; background:var(--page); color:var(--ink);
          font:16px/1.65 ui-rounded,"SF Pro Rounded",-apple-system,system-ui,"Segoe UI",sans-serif;
          -webkit-font-smoothing:antialiased; text-rendering:optimizeLegibility;
        }
        main{max-width:720px; margin:0 auto; padding:44px 24px 56px}
        .parfait-bar{
          height:6px; border-radius:3px; margin-bottom:30px;
          background:linear-gradient(90deg,#FFF9F2 0 25%,#F2A93B 25% 50%,#E0396B 50% 75%,#5A6ACF 75% 100%);
          box-shadow:inset 0 0 0 1px var(--border);
        }
        header h1{margin:0 0 10px; font-size:2.1rem; line-height:1.15; letter-spacing:-.015em; color:var(--accent)}
        .meta{color:var(--muted); font-size:.95rem}
        .chips{display:flex; flex-wrap:wrap; gap:8px; margin-top:14px}
        .chip{
          background:var(--chip); color:var(--accent); font-size:.82rem; font-weight:600;
          padding:4px 13px; border-radius:999px; border:1px solid var(--border);
          white-space:nowrap; overflow:hidden; text-overflow:ellipsis;
          max-width:220px; min-width:0; display:inline-block; vertical-align:top;
        }
        .section-title{
          margin:36px 0 12px; color:var(--honey); font-size:.78rem; font-weight:700;
          text-transform:uppercase; letter-spacing:.14em;
        }
        .card{
          background:var(--card); border-radius:16px; padding:26px 30px;
          box-shadow:inset 0 0 0 1px var(--border); overflow-x:auto;
        }
        .card h1{margin:.2em 0 .5em; font-size:1.3rem; color:var(--accent)}
        .card h2{margin:1.5em 0 .5em; font-size:1.02rem; color:var(--accent)}
        .card h1:first-child,.card h2:first-child{margin-top:.1em}
        .card h3{margin:1.2em 0 .4em; font-size:.95rem}
        .card p{margin:.55em 0}
        .card ul{margin:.55em 0; padding-left:1.4em}
        .card li{margin:.3em 0}
        li.task{list-style:none; margin-left:-1.4em}
        input[type=checkbox]{accent-color:var(--accent); pointer-events:none; vertical-align:-2px; margin-right:6px}
        a{color:var(--link)}
        .turn{padding:16px 0; border-top:1px solid var(--border)}
        .turn:first-child{border-top:none; padding-top:2px}
        .turn:last-child{padding-bottom:2px}
        .speaker{font-weight:700}
        .time{margin-left:10px; color:var(--muted); font-size:.82rem; font-variant-numeric:tabular-nums}
        .turn p{margin:6px 0 0}
        footer{
          margin-top:44px; padding-top:18px; border-top:1px solid var(--border);
          text-align:center; color:var(--muted); font-size:.85rem;
        }
        footer a{font-weight:600; text-decoration:none}
        @media (max-width:540px){
          main{padding:28px 16px 40px}
          header h1{font-size:1.6rem}
          .card{padding:20px 18px}
        }
        </style>
        </head>
        <body>
        <main>
        <div class="parfait-bar"></div>
        <header>
        <h1>\(title)</h1>
        <div class="meta">\(date) · \(duration)</div>
        \(chips)
        </header>
        \(summaryBlock)
        \(transcriptBlock)
        <footer>Recorded with <a href="https://github.com/conrad-vanl/parfait">Parfait</a></footer>
        </main>
        </body>
        </html>
        """
    }

    /// Minimal markdown subset: #/##/### headings, paragraphs (blank-line separated),
    /// **bold**, *italic*, "- " bullets, and "- [ ]"/"- [x]" checkboxes. Anything else
    /// becomes paragraph text. Input is escaped, so model output can't inject markup.
    static func renderMarkdown(_ md: String) -> String {
        var blocks: [String] = []
        var paragraph: [String] = []
        var items: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append("<p>\(paragraph.joined(separator: " "))</p>")
            paragraph.removeAll()
        }
        func flushList() {
            guard !items.isEmpty else { return }
            blocks.append("<ul>\n\(items.joined(separator: "\n"))\n</ul>")
            items.removeAll()
        }

        for raw in md.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                flushList()
            } else if line.hasPrefix("### ") {
                flushParagraph()
                flushList()
                blocks.append("<h3>\(inline(String(line.dropFirst(4))))</h3>")
            } else if line.hasPrefix("## ") {
                flushParagraph()
                flushList()
                blocks.append("<h2>\(inline(String(line.dropFirst(3))))</h2>")
            } else if line.hasPrefix("# ") {
                flushParagraph()
                flushList()
                blocks.append("<h1>\(inline(String(line.dropFirst(2))))</h1>")
            } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
                flushParagraph()
                let checked = !line.hasPrefix("- [ ] ")
                items.append("<li class=\"task\"><input type=\"checkbox\" disabled\(checked ? " checked" : "")> \(inline(String(line.dropFirst(6))))</li>")
            } else if line.hasPrefix("- ") {
                flushParagraph()
                items.append("<li>\(inline(String(line.dropFirst(2))))</li>")
            } else {
                flushList()
                paragraph.append(inline(line))
            }
        }
        flushParagraph()
        flushList()
        return blocks.joined(separator: "\n")
    }

    static func escape(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&#39;")
        return out
    }

    private static func inline(_ s: String) -> String {
        var out = escape(s)
        out = out.replacing(#/\*\*([^*]+)\*\*/#) { "<strong>\($0.1)</strong>" }
        out = out.replacing(#/\*([^*]+)\*/#) { "<em>\($0.1)</em>" }
        return out
    }

    /// Consecutive segments by the same speaker merge into one turn, mirroring
    /// TranscriptFormatter.markdown but emitting HTML.
    private static func transcriptTurns(segments: [TranscriptSegment], speakers: [Speaker]) -> String {
        let names = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.name) })
        var turns: [String] = []
        var currentSpeaker: String?
        var texts: [String] = []
        var start: TimeInterval = 0

        func flush() {
            guard let s = currentSpeaker, !texts.isEmpty else { return }
            let who = escape(names[s] ?? s)
            turns.append("""
            <div class="turn">
            <div class="turn-head"><span class="speaker">\(who)</span><span class="time">\(MeetingArchive.timestamp(start))</span></div>
            <p>\(escape(texts.joined(separator: " ")))</p>
            </div>
            """)
        }

        for seg in segments {
            if seg.speakerID != currentSpeaker {
                flush()
                currentSpeaker = seg.speakerID
                texts = []
                start = seg.start
            }
            texts.append(seg.text)
        }
        flush()
        return turns.joined(separator: "\n")
    }
}
