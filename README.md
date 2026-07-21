<p align="center">
  <img src="Resources/AppIcon-1024.png" width="140" alt="Parfait icon — a layered parfait glass">
</p>

<h1 align="center">Parfait</h1>

<p align="center"><em>Layered meeting notes. Perfectly local.</em></p>

<p align="center">
An open-source, on-device meeting notetaker for macOS — a lightweight alternative to Granola.<br>
It lives in your menu bar, notices when a meeting starts, records both sides of the call,<br>
and writes a transcript with named speakers plus templated notes — without audio ever leaving your Mac.<br>
Then it hands any meeting to <strong>Claude</strong> through a built-in MCP server — one call, your whole
history, or the meeting happening <em>right now</em> — with nothing uploaded.
</p>

<p align="center">
<sub>📦 <strong>A signed <code>.app</code> download is coming soon.</strong> Until then, <code>make install</code>
(below) builds it in about two minutes — the way to try it today.</sub>
</p>

---

## What it does

- **Auto-detects meetings.** When Zoom, Meet, Teams, FaceTime — anything — starts using your
  microphone, Parfait offers to record (or just starts, if you tell it to). Manual recording is
  one click in the menu bar.
- **Records both sides.** Your mic through AVAudioEngine; everyone else through a Core Audio
  process tap on system audio. No virtual audio drivers, no kernel extensions, no bots joining
  your calls.
- **Transcribes on device** with Apple's SpeechAnalyzer (the macOS 26 speech engine) — with
  per-segment timestamps.
- **Names the speakers.** You're "you" (mic channel); remote voices are separated with a small
  on-device diarization model ([FluidAudio](https://github.com/FluidInference/FluidAudio), ~22 MB,
  downloaded once). Calendar attendees are offered as rename suggestions, and renaming a speaker
  fixes the whole transcript.
- **Summarizes on device** with Apple Intelligence (FoundationModels), following **your**
  editable markdown templates. Long meetings map-reduce through the model; meetings too big for
  it route to your own Claude account.
- **Everything is editable** — title, notes, transcript, speakers.
- **Ask Claude live, mid-meeting.** A floating card shows the transcript as it happens; one button
  opens Claude on the call in progress. Parfait exposes the running transcript through a
  `get_live_transcript` MCP tool, so Claude can answer "what did I miss?" or "what should I ask
  next?" — no pasting, and it rides over full-screen Zoom.
- **Claude as your executive assistant.** Parfait extracts follow-up items when it writes a
  meeting's notes — the notification says "Notes ready — N follow-ups suggested" — and you curate
  them in the app's Follow-ups tab: edit each item's instructions, dismiss what you don't want.
  Then hand the queue to Claude: **followups** (`/parfait:followups`, or just "Work on my
  followups" — works each item autonomously through your Linear/email/Slack/calendar connectors
  and records results back into Parfait; your review of the list is the approval). The plugin
  adds two more skills: **scoop** (`/parfait:scoop` — a pre-meeting brief from past meetings with
  the same people and their open commitments) and **digest** (`/parfait:digest` — a weekly rollup
  of decisions and commitments).
- **Chat with one meeting, natively in Claude.** "Open in Claude" on any meeting opens Claude
  with that meeting loaded through Parfait's MCP server — Claude reads it itself; nothing is
  copied in. "Ask Claude" in the toolbar points it at your whole library the same way, and once
  the plugin is installed you can skip the app entirely and just ask Claude — Code or Desktop —
  anytime. Claude can even regenerate a meeting's notes against a different template, edit them,
  or publish them, through the same server.
- **Publish** a beautiful self-contained page (notes + transcript) as a secret gist on your own
  GitHub (`gh`), with a rendered **notes.parfait.to** URL to share — Parfait's own CDN serving
  your gist back rendered, not a raw-file host — or preview/export the HTML locally with no
  dependencies at all.
- **Plain files, no database.** Every meeting is a folder of JSON + Markdown + m4a in
  `~/Library/Application Support/Parfait`. Your data is greppable, backupable, yours.

## The stack is the feature

Parfait has no backend, no accounts, and no API keys. It composes things your Mac already has:

| Need | Provider |
|---|---|
| Meeting detection | Core Audio process objects (mic-in-use by other apps) |
| System-audio capture | Core Audio process taps (macOS 14.4+) |
| Transcription | SpeechAnalyzer / SpeechTranscriber (macOS 26, on device) |
| Speaker separation | FluidAudio CoreML diarization (on device) |
| Summaries, titles | Apple Intelligence FoundationModels (on device) |
| Long meetings, publishing | **Your own** Claude account via the `claude` CLI |
| Chat + assistant skills (followups, scoop, digest) | **Your own** Claude — Desktop or Code — via the Parfait plugin (MCP server + skills) |
| Publish target | **Your own** GitHub via `gh` (secret gist), served back rendered by **notes.parfait.to** (Parfait's own CDN in front of your gist), or a local browser preview / HTML export |

## Requirements

- **macOS 26 (Tahoe)** on Apple Silicon
- **Apple Intelligence enabled** (Settings → Apple Intelligence & Siri) for on-device summaries
- **Required for chat + assistant skills:** [Claude Desktop](https://claude.ai/download) and the
  Parfait plugin (one-click install from onboarding or Settings → Intelligence) — the "Open in
  Claude" and "Work on my follow-ups with Claude" buttons open a pre-filled prompt there
- Optional: [Claude Code](https://claude.com/claude-code) (`claude` CLI, logged in) — installs the
  plugin, and unlocks long-meeting summaries billed to your own plan
- Optional: [GitHub CLI](https://cli.github.com) (`gh auth login`) — to publish a shareable rendered
  URL as a gist on your own account (without it, you can still preview and export the HTML locally)

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

> **Signing note:** `make install` ad-hoc signs with a stable designated requirement, so TCC
> permissions survive rebuilds. If you have an Apple Development certificate, prefer
> `make install SIGN_ID="Apple Development: you@example.com (TEAMID)"`.

## Connect Claude: install the Parfait plugin

The easiest path is the **Install plugin** button in onboarding (or Settings → Intelligence).
It runs, and you can also run it yourself:

```bash
claude plugin marketplace add conrad-vanl/parfait
claude plugin install parfait@parfait
```

The plugin registers Parfait's MCP server (via a launcher script the app maintains at
`~/Library/Application Support/Parfait/bin/parfait-mcp`, so app updates never break it) and adds
the three skills — `/parfait:followups`, `/parfait:scoop`, `/parfait:digest` — to Claude Code and
Claude Desktop alike. Launch Parfait.app at least once first so the launcher script exists.

Then from any `claude` session or Claude Desktop chat:

> "Search my meetings for when I last discussed hiring, and summarize what was decided."

The MCP server (`Parfait --mcp`) speaks stdio over your on-disk library. Read tools:
`list_meetings`, `search_meetings`, `get_meeting`, `get_transcript`, `get_live_transcript`
(the meeting in progress), `get_followups`, and `get_all_followups` (the cross-meeting queue).
Write tools: `regenerate_summary`,
`update_summary`, `save_followups`, `update_followup`, `publish_meeting`, and the template
tools (`list_templates`, `get_template`, `create_template`, `update_template`, `rename_template`,
`delete_template`). Nothing leaves your Mac except what the model reads or writes through them.

Prefer not to use the plugin? The server also registers the classic way:

```bash
claude mcp add parfait -s user -- "$HOME/Library/Application Support/Parfait/bin/parfait-mcp"
```

## Templates

Notes are shaped by markdown templates you can edit in **Settings → Templates** (or any editor —
they're just files in `~/Library/Application Support/Parfait/Templates/`). Headings guide the
model; prose under a heading tells it what belongs there. Placeholders: `{{title}}`, `{{date}}`,
`{{attendees}}`, `{{duration}}`, `{{app}}`. Ships with **Meeting Notes**, **1-on-1**, and
**Interview**.

## Privacy model

- Audio, transcripts, and notes never leave your Mac by default.
- The only network calls Parfait itself makes: one-time model downloads (Apple speech assets via
  the OS; the diarization model from Hugging Face).
- Anything involving Claude or GitHub happens through **your** already-authenticated CLIs, at
  your explicit request (chat, publish, or when a meeting exceeds the on-device model), on your
  own accounts.
- Publishing is always an explicit action. "Secret" gists are unlisted (on your own account,
  deletable) — anyone with the link can view the page; the browser preview and HTML export never
  leave your Mac. Deleting the gist stops new visits, but the rendered link is cached at the
  edge and in browsers, so it can keep serving for up to about a day after deletion.

## Development

```bash
swift build          # debug build
swift test           # 102 unit tests (store, labeling, formatting, templates, MCP, HTML, live transcription, Claude deep-links, CLI args)
make app             # assemble dist/Parfait.app
make icon            # regenerate the icon from scripts/MakeIcon.swift
```

The audio/ML paths need live permissions no CI box has; they're covered by the manual checklist
in [docs/TESTING.md](docs/TESTING.md). Architecture and design decisions live in
[docs/superpowers/specs/](docs/superpowers/specs/2026-07-09-parfait-design.md).

```
Sources/Parfait/
  Audio/           MeetingDetector · MicRecorder · SystemAudioTap · RecordingSession
  Transcription/   Transcriber (SpeechAnalyzer) · Diarizer (FluidAudio) · SpeakerLabeler
  Intelligence/    AppleSummarizer · ClaudeCLI · ClaudeDesktop · CalendarMatcher · TemplateStore
  Store/           Meeting models · file-backed archive
  MCP/             stdio MCP server (same binary, --mcp)
  Publish/         HTMLExporter · GitHubGist
  App/ UI/         AppState · pipeline · SwiftUI menu bar + windows
```

## Acknowledgements

- [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0) for CoreML speaker
  diarization; model weights (CC-BY-4.0) derive from
  [pyannote](https://github.com/pyannote/pyannote-audio) and
  [WeSpeaker](https://github.com/wenet-e2e/wespeaker).
- [Granola](https://granola.ai) for showing how good meeting notes can feel.

## License

[MIT](LICENSE)
