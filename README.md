<p align="center">
  <img src="Resources/AppIcon-1024.png" width="140" alt="Parfait icon — a layered parfait glass">
</p>

<h1 align="center">Parfait</h1>

<p align="center"><em>The meeting notetaker that follows through.</em></p>

<p align="center">
An open-source, on-device meeting notetaker for macOS. Parfait lives in your menu bar,
records both sides of the call, and writes a transcript with named speakers plus templated
notes — without audio ever leaving your Mac. Then it goes past notes: the follow-ups are
extracted from every meeting, you curate them once, and <strong>Claude</strong> actually does
them — through your own email, calendar, and issue tracker — reporting the results back.
</p>

<p align="center">
<sub>📦 <strong>A signed <code>.app</code> download is coming soon.</strong> Until then, <code>make install</code>
(below) builds it in about two minutes — the way to try it today.</sub>
</p>

---

## What it does

- **Notices and records your meetings.** A floating card appears when a calendar meeting is
  about to start (**Join & record**) or when any app — Zoom, Meet, Teams, FaceTime — picks up
  your microphone. Both sides are captured straight from the system: your mic and everyone
  else's audio. No virtual audio drivers, no bots joining your calls.
- **Transcribes and names the speakers, on device.** Apple's SpeechAnalyzer transcribes with
  timestamps while a live transcript streams during the meeting; a small local diarization
  model ([FluidAudio](https://github.com/FluidInference/FluidAudio), ~22 MB, downloaded once)
  separates the voices. Calendar attendees are offered as names, and renaming a speaker fixes
  the whole transcript — notes included.
- **Notes in seconds, in your templates.** When you stop, a draft streams in from the live
  transcript, then is quietly refined against the accurate one. With Claude Code installed,
  your own Claude account writes the notes by default; a Settings toggle keeps everything
  on-device with Apple Intelligence, with Claude stepping in only for meetings too long for
  the local model. Title, notes, transcript, and speakers are all editable.
- **Follow-ups, extracted and actually done.** Parfait pulls follow-up items out of each
  meeting as the notes are written ("Notes ready — N follow-ups suggested"). Curate the queue
  in the Follow-ups tab — edit each item's instructions, mark Done, Dismiss — then click
  **Work on my follow-ups with Claude**: Claude works every item through your connectors
  (Linear, Gmail, Slack, Calendar…) and records results and links back into Parfait. Your
  review of the list is the approval — anything ambiguous or high-risk, Claude skips and
  asks about instead.
- **An assistant before, during, and after.** `/parfait:scoop` briefs you before a meeting
  from your history with the same people; **Ask Claude live** answers mid-call from the
  running transcript — even over full-screen Zoom; `/parfait:digest` rolls up the week's
  decisions and commitments. **Open in Claude** on any meeting — or **Ask Claude** on the
  whole library — starts a conversation with your meetings already readable; nothing copied in.
- **Publish, with the work attached.** **Create shareable link** turns a meeting into a
  self-contained page at a short **notes.parfait.to** URL — transcript optional — backed by a
  secret gist on your own GitHub. Open follow-ups appear on the page with per-item
  **Hand to Claude** buttons that work for any recipient, no Parfait needed. Or preview and
  export the HTML locally, and nothing leaves your Mac.
- **Plain files, no database.** Every meeting is a folder of JSON + Markdown + m4a in
  `~/Library/Application Support/Parfait`. Your data is greppable, backupable, yours.

## The stack is the feature

Parfait has no backend holding your data, no accounts, and no API keys. It composes things
your Mac already has:

| Need | Provider |
|---|---|
| Meeting detection | Core Audio process objects + your calendar (EventKit) |
| Recording, both sides | AVAudioEngine (your mic) + Core Audio process taps (system audio) |
| Transcription | SpeechAnalyzer / SpeechTranscriber (macOS 26, on device) |
| Speaker separation | FluidAudio CoreML diarization (on device) |
| Notes and titles | **Your own** Claude account (default when installed), or Apple Intelligence on device |
| Follow-ups, briefs, digests | **Your own** Claude — Desktop or Code — via the Parfait plugin |
| Publishing | **Your own** GitHub via `gh` (secret gist), rendered at **notes.parfait.to** |

## Requirements

- **macOS 26 (Tahoe)** on Apple Silicon, with **Apple Intelligence enabled**
  (Settings → Apple Intelligence & Siri)
- For the assistant: [Claude Desktop](https://claude.ai/download) and/or
  [Claude Code](https://claude.com/claude-code), plus the Parfait plugin — one click from
  onboarding or Settings → Intelligence
- Optional: [GitHub CLI](https://cli.github.com) (`gh auth login`) to publish shareable links

## Install

```bash
git clone https://github.com/conrad-vanl/parfait.git
cd parfait
make install        # builds, assembles Parfait.app, copies to /Applications
open /Applications/Parfait.app
```

Look for the parfait glass in your menu bar. On first recording, macOS will ask for
**Microphone** and **System Audio Recording** permission (the latter lives under
Privacy & Security → Screen & System Audio Recording → "System Audio Recording Only").

> **Signing note:** `make install` ad-hoc signs with a stable designated requirement so TCC
> permissions survive rebuilds; pass `SIGN_ID` to use an Apple Development certificate.

## Connect Claude: the Parfait plugin

The **Install plugin** button in onboarding (or Settings → Intelligence) runs this for you:

```bash
claude plugin marketplace add conrad-vanl/parfait
claude plugin install parfait@parfait
```

The plugin registers Parfait's local MCP server (via a launcher script the app maintains at
`~/Library/Application Support/Parfait/bin/parfait-mcp`, so app updates never break it) and
adds the three skills — `/parfait:followups`, `/parfait:scoop`, `/parfait:digest` — to Claude
Code and Claude Desktop alike. Launch Parfait.app at least once first so the launcher exists.

Then, from any Claude conversation:

> "Search my meetings for when I last discussed hiring, and summarize what was decided."
>
> "Work on my follow-ups."

The MCP server (`Parfait --mcp`) speaks stdio over your on-disk library: read tools for
meetings, transcripts (including the live one), and follow-ups; write tools for summaries,
follow-ups, publishing, and templates — 18 in all. In MCP Apps hosts like Claude Desktop,
the follow-up queue renders as an interactive card. For hosts without plugin support:

```bash
claude mcp add parfait -s user -- "$HOME/Library/Application Support/Parfait/bin/parfait-mcp"
```

## Templates

Notes are shaped by markdown templates you can edit in **Settings → Templates** (or any editor —
they're just files in `~/Library/Application Support/Parfait/Templates/`). Headings guide the
model; prose under a heading tells it what belongs there. Placeholders: `{{title}}`, `{{date}}`,
`{{attendees}}`, `{{duration}}`, `{{app}}`. Ships with **Meeting Notes**, **1-on-1**, and
**Interview**; a Settings picker chooses the default.

## Privacy model

- Audio never leaves your Mac. Recording, transcription, and speaker separation are always
  local; transcripts, notes, and follow-ups stay local too unless Claude touches them.
- The only network calls Parfait itself makes: one-time model downloads (Apple speech assets
  via the OS; the diarization models from Hugging Face).
- Anything involving Claude or GitHub happens through **your** already-authenticated apps and
  CLIs, on your own accounts — chat, follow-ups, publishing, and note-writing (Claude writes
  notes by default when Claude Code is installed; a Settings toggle keeps summaries on-device).
- Publishing is always an explicit action. Links are compact tokens that keep your GitHub
  username and gist path out of the address bar (obfuscation, not a secret); "secret" gists
  are unlisted on your own account and deletable, though the rendered page can keep serving
  from edge and browser caches for up to about a day after deletion.

## Development

```bash
swift build          # debug build
swift test           # unit tests: store, pipeline, follow-ups, templates, MCP, HTML, publishing, …
make app             # assemble dist/Parfait.app
make icon            # regenerate the icon from scripts/MakeIcon.swift
```

Every significant change gets an entry on [parfait.to/changelog](https://parfait.to/changelog)
(`site/changelog.html` — policy in [CLAUDE.md](CLAUDE.md)). The audio/ML paths need live
permissions no CI box has; they're covered by the manual checklist in
[docs/TESTING.md](docs/TESTING.md). Architecture and design decisions live in
[docs/superpowers/specs/](docs/superpowers/specs/2026-07-09-parfait-design.md).

```
Sources/Parfait/
  Audio/           MeetingDetector · MicRecorder · SystemAudioTap · RecordingSession
  Transcription/   Transcriber (SpeechAnalyzer) · LiveTranscriber · Diarizer (FluidAudio) · SpeakerLabeler
  Intelligence/    AppleSummarizer · ClaudeCLI · FollowupExtractor · CalendarMatcher · TemplateStore
  Store/           Meeting models · follow-ups · file-backed archive
  MCP/             stdio MCP server (same binary, --mcp) · follow-up card (MCP Apps)
  Publish/         HTMLExporter · GitHubGist
  App/ UI/         AppState · pipeline · SwiftUI menu bar + windows
```

## Acknowledgements

- [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0) for CoreML speaker
  diarization; model weights (CC-BY-4.0) derive from pyannote and WeSpeaker.
- [Granola](https://granola.ai) for showing how good meeting notes can feel.

## License

[MIT](LICENSE)
