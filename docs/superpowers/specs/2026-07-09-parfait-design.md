# Parfait — Design

**Date:** 2026-07-09
**Status:** Approved for implementation (autonomous build; requirements fully specified by owner)

## What

Parfait is an open-source, on-device meeting notetaker for macOS — a lightweight alternative
to Granola. It lives in the menu bar, notices when a meeting starts, records both sides of the
call, and produces an editable transcript with named speakers and a templated summary — all
without meeting audio leaving the machine. Claude (the user's own account, via the `claude`
CLI and MCP) powers the advanced features: chatting across all meetings and publishing.

**Name:** "Parfait" — a granola-adjacent dictionary word (yogurt + granola + fruit, layered,
like the app's layers: audio → transcript → summary → chat). Verified no popular OSS project
claims the name. French for "perfect."

## Requirements (from owner)

1. macOS menu bar app; auto-detects meetings (mic active in another app) and records
2. Manual start/stop recording too
3. On-device transcription and summarization; local AI + macOS services first
4. Claude (user's own account) when local models aren't suitable
5. Speakers identified; user can rename
6. Editable summary templates
7. Editable meeting title / summary / transcript
8. Chat with one meeting; chat with all meetings (MCP integration with Claude)
9. Publish summary + transcript to an external URL
10. Simple, lightweight, modern/airy/minimalist; bright welcoming palette derived from the name

## Platform decision

**macOS 26 (Tahoe) only, Apple Silicon.** This unlocks the full on-device stack and keeps the
app radically simpler than multi-OS-version support:

- **SpeechAnalyzer / SpeechTranscriber** (macOS 26) — on-device, long-form transcription with
  per-segment timestamps. No cloud, no speech-recognition permission dance of the old API.
- **FoundationModels** (macOS 26, Apple Intelligence) — on-device LLM for summarization,
  titles, and per-meeting chat when it fits in context.
- **Core Audio process taps** (macOS 14.4+) — capture other apps' audio (the remote side of a
  call) without kernel extensions or virtual devices.
- **`kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyIsRunningInput`** —
  detect that *another process* started using the microphone → meeting detection.

Considered alternatives:
- *Electron/Tauri + whisper.cpp*: heavier, duplicates what the OS now ships, worse battery.
  Rejected — the whole point is leaning on macOS services.
- *Support macOS 15*: needs SFSpeechRecognizer + no on-device LLM → Claude-only summaries.
  Rejected for v1; macOS 26 has been GA since Sept 2025.

## Architecture

Pure SwiftUI + Swift Package Manager. No Xcode project; a `Makefile` assembles `Parfait.app`
(binary + Info.plist + icon) and ad-hoc code-signs it. One binary, two modes:

- default: the menu bar app (`MenuBarExtra`) + main window
- `parfait --mcp` (same executable): a stdio MCP server over the meeting store

### Modules

| Module | Purpose | Key APIs |
|---|---|---|
| `Audio/MeetingDetector` | Watch for other processes opening the mic; identify the app | CoreAudio process objects |
| `Audio/MicRecorder` | Record the user's mic to `mic.m4a` | AVAudioEngine |
| `Audio/SystemAudioTap` | Record other apps' output (remote participants) to `system.m4a` | Process tap + aggregate device |
| `Transcription/Transcriber` | Transcribe both files, per-segment timestamps | SpeechAnalyzer |
| `Transcription/SpeakerLabeler` | Mic channel = "Me"; diarize system channel into Speaker 1..N | FluidAudio (CoreML, optional) |
| `Intelligence/Summarizer` | Render template → summary; generate title | FoundationModels, Claude CLI fallback |
| `Intelligence/ChatEngine` | Per-meeting chat (local model or Claude); all-meetings chat (Claude + own MCP) | FoundationModels, `claude -p` |
| `Intelligence/ClaudeCLI` | Detect + shell out to the user's `claude` binary | Process |
| `Store/MeetingStore` | One folder per meeting: `meeting.json`, `transcript.json`, `summary.md`, audio | FileManager, Codable |
| `Templates` | Markdown summary templates, editable in-app | files in Application Support |
| `Publish/Publisher` | Export themed HTML → `gh gist create` URL; or hand to Claude for an Artifact | Process (`gh`), `claude -p` |
| `MCP/MCPServer` | stdio JSON-RPC: list/search/get meetings | Foundation |
| `Calendar/` | Optional: current event → title + attendee names | EventKit |
| `UI/` | Menu bar popover, main window (list + detail), chat, settings, template editor | SwiftUI |

### Data flow

```
mic active in Zoom/Meet/Teams…            user clicks Record
        │                                        │
        ▼                                        ▼
  MeetingDetector ──notification──▶  RecordingSession
                                      ├─ MicRecorder      → mic.m4a
                                      └─ SystemAudioTap   → system.m4a
                                                 │  (stop)
                                                 ▼
                                     Transcriber (both files, timestamps)
                                                 ▼
                                     SpeakerLabeler (Me + diarized remote)
                                                 ▼
                                     Summarizer (template → summary.md, title)
                                                 ▼
                                     MeetingStore (~/Library/Application Support/Parfait/Meetings/…)
```

Transcription is **post-recording** (not live). It's simpler, more accurate, and the on-device
models run faster than realtime. The recording UI shows elapsed time + level meters.

### Speaker identification

- Two physical channels: the mic file is always the owner ("Me", from `NSFullUserName()`);
  the system file is everyone else.
- The system channel is diarized on-device with FluidAudio (CoreML; models fetched once on
  first use, toggleable in Settings). Segments become "Speaker 1", "Speaker 2", …
- If the meeting matched a calendar event, attendee names are offered as rename suggestions.
- Renaming a speaker in the transcript editor renames them everywhere in that meeting.
- If diarization is off/unavailable, the remote channel is a single "Them" speaker. Everything
  still works.

### Intelligence routing

| Task | First choice | Fallback |
|---|---|---|
| Summary + title | FoundationModels (on-device) | Claude CLI (`claude -p`) |
| Long transcript that exceeds the on-device context | chunked map-reduce on-device | Claude CLI |
| Chat with one meeting | FoundationModels w/ transcript in context | Claude CLI |
| Chat with **all** meetings | Claude CLI + Parfait's own MCP server (`--mcp-config`) | — (needs Claude) |
| Publish | HTML export → `gh gist create` → URL | Claude Artifact via `claude -p` |

The app never asks for an API key. "Claude" means the user's existing `claude` CLI login.
Settings shows three status dots: Apple Intelligence, Claude CLI, gh CLI.

### Storage

Plain files, user-inspectable, trivially backed up:

```
~/Library/Application Support/Parfait/
  Meetings/<uuid>/
    meeting.json      # title, date, app, attendees, speaker names, state
    transcript.json   # [{speaker, start, end, text}]
    summary.md
    mic.m4a  system.m4a
  Templates/*.md      # editable summary templates ({{transcript}}, {{attendees}}, …)
  settings.json
```

No database. Search (for MCP + in-app) scans JSON — fine for thousands of meetings.

### MCP server

`parfait --mcp` speaks MCP over stdio (JSON-RPC 2.0). Tools: `list_meetings`,
`search_meetings(query)`, `get_meeting(id)` (summary + metadata), `get_transcript(id)`.
README documents: `claude mcp add parfait -- /Applications/Parfait.app/Contents/MacOS/Parfait --mcp`.
The in-app "Ask across meetings" chat shells `claude -p` with an inline `--mcp-config` pointing
at the same binary — the app uses Claude as its agent runtime and itself as the tool layer.

### Permissions (all requested lazily, each with a plain-language explainer in Settings)

Microphone · System Audio Recording (process tap) · Notifications · Calendar (optional).

### Error handling

- Detector fires but user ignores → notification simply expires; optional auto-record setting.
- Apple Intelligence unavailable/model busy → route to Claude; neither → summary shows a
  "waiting for AI" card with a retry button; transcript is still produced.
- Transcription failure on one channel → keep the other channel's transcript, surface a banner.
- Recording interrupted (sleep/crash) → files are flushed continuously; on next launch,
  orphaned in-progress meetings are finalized through the normal pipeline.

### Testing

Unit tests (XCTest via `swift test`) for the pure logic: store round-trips, transcript
merge/relabel, template rendering, MCP request/response framing, Claude CLI arg construction,
HTML export. Audio/ML paths are protocol-seamed and covered by a manual smoke checklist in
`docs/TESTING.md` (they need live TCC grants a CI box can't give).

## Visual identity

Bright, airy, layered like the dessert. Cream `#FFF9F2` surfaces, raspberry `#E0396B` primary,
honey `#F2A93B` secondary, blueberry `#5A6ACF` for chat/links, mint `#3FB27F` for the live
recording state. Rounded SF Pro (`.rounded`), generous whitespace, soft 16pt-radius cards,
subtle layered "parfait stripe" motif in the icon and empty states. Menu bar icon: a minimal
parfait-glass glyph (template image, adapts to menu bar appearance).

## Out of scope (v1)

Live captions during the meeting · video capture · Windows/Linux · cloud sync · sharing
backends beyond gist/Artifact · Intel Macs · localization.
