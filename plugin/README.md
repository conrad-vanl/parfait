# Parfait plugin for Claude

Claude-side half of [Parfait](https://github.com/conrad-vanl/parfait), the
local-first macOS menu-bar meeting notetaker. The plugin connects Claude to
your meeting library (via Parfait's local MCP server) and adds three
executive-assistant skills.

## Requirements

- **Parfait.app installed and launched at least once.** The app writes the
  launcher script (`~/Library/Application Support/Parfait/bin/parfait-mcp`)
  that this plugin uses to reach your meetings; without one launch, the MCP
  server won't start.
- Claude Code (or Claude Desktop with plugin support).

## Install

```sh
claude plugin marketplace add conrad-vanl/parfait
claude plugin install parfait@parfait
```

## Skills

- **followups** — the batch worker. Parfait extracts follow-up items when it
  writes a meeting's notes; you curate them in the app's Follow-ups tab (edit
  each item's instructions, dismiss what you don't want). Then say "Work on my
  followups" and Claude works the queue autonomously through your connectors
  (Linear, Gmail, Slack, Calendar…), recording status and result links back
  into Parfait. Your review of the list is the approval — no per-item
  confirmations.
- **scoop** — pre-meeting brief. Finds past meetings with the same people,
  collects open commitments and unanswered questions, and hands you a
  one-screen brief with talking points.
- **digest** — weekly rollup. Decisions made, commitments open (yours and
  theirs, with aging flagged), and questions still unanswered across the
  week's meetings.

Claude invokes these automatically when relevant, and each is also a slash
command: `/parfait:followups`, `/parfait:scoop`, `/parfait:digest`.
