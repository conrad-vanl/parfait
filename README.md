<p align="center">
  <img src="Resources/AppIcon-1024.png" width="140" alt="Parfait icon — a layered parfait glass">
</p>

<h1 align="center">Parfait</h1>

<p align="center"><em>Layered meeting notes. Perfectly local.</em></p>

<p align="center">
An open-source, on-device meeting notetaker for macOS — a lightweight alternative to Granola.<br>
It lives in your menu bar, notices when a meeting starts, records both sides of the call,<br>
and writes a transcript with named speakers plus templated notes — without audio ever leaving your Mac.
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
- **Chat with a meeting.** Ask "what did we decide?" — answered on device when it fits, by
  Claude when it doesn't.
- **Chat with *all* your meetings.** Parfait ships an MCP server over your meeting library;
  the in-app "Ask your meetings" chat runs your own Claude as the agent against it — and you can
  point Claude Code or Claude Desktop at the same server.
- **Publish** a beautiful self-contained page (notes + transcript) as a secret gist on your own
  GitHub (`gh`), with a rendered URL to share — or preview/export the HTML locally with no
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
| Summaries, titles, chat | Apple Intelligence FoundationModels (on device) |
| Long meetings, cross-meeting chat, publishing | **Your own** Claude account via the `claude` CLI |
| Publish target | **Your own** GitHub via `gh` (secret gist), or a local browser preview / HTML export |

## Requirements

- **macOS 26 (Tahoe)** on Apple Silicon
- **Apple Intelligence enabled** (Settings → Apple Intelligence & Siri) for on-device summaries
- Optional: [Claude Code](https://claude.com/claude-code) (`claude` CLI, logged in) — unlocks
  cross-meeting chat and long-meeting summaries, billed to your own plan
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

## Connect Claude to your meeting library

```bash
claude mcp add parfait -s user -- "/Applications/Parfait.app/Contents/MacOS/Parfait" --mcp
```

Then from any `claude` session (or Claude Desktop with the same server):

> "Search my meetings for when I last discussed hiring, and summarize what was decided."

The MCP server (`Parfait --mcp`) is a thin stdio reader over the on-disk library — tools:
`list_meetings`, `search_meetings`, `get_meeting`, `get_transcript`. Nothing leaves your Mac
except what the model you're talking to reads through those tools.

### Claude Desktop

Claude Desktop reads MCP servers from a config file, not a CLI command. Open (or create)
`~/Library/Application Support/Claude/claude_desktop_config.json` and merge this into the
`mcpServers` object — **don't overwrite the file** if you already have other servers configured:

```json
{
  "mcpServers": {
    "parfait": {
      "command": "/Applications/Parfait.app/Contents/MacOS/Parfait",
      "args": ["--mcp"]
    }
  }
}
```

Restart Claude Desktop after saving. Settings → "Connect Claude to your meetings" in the app
has a "Copy JSON" button that fills in your actual install path, and a "Reveal in Finder" button
that jumps straight to the config file.

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
  leave your Mac.

## Development

```bash
swift build          # debug build
swift test           # 54 unit tests (store, labeling, formatting, templates, MCP, HTML, CLI args)
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
  Intelligence/    AppleSummarizer · ClaudeCLI · ChatEngine · CalendarMatcher · TemplateStore
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
