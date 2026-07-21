# Parfait as a Claude plugin — design (2026-07-20)

> Status: DESIGN — reviewed by Conrad 2026-07-20; open questions resolved
> (see Decisions at bottom). Ready for phase-1 implementation on go-ahead.
> Supersedes the "post-meeting AI follow-ups" section of the 2026-07-20
> improvements plan (which stayed deliberately in discussion).

## What Conrad asked for

> "I'm hesitant to try and build a lot of this into the parfait standalone app
> versus a deeper integration with Claude. Ideally, parfait is an extension of a
> user's claude experience. How might we get more of the experience into the
> claude app, and let claude be that executive assistant?"

And, expanding scope:

> "I'd like to expand the plan to make sure we're thinking through any other app
> side affects we need to handle by shipping this as a claude plugin. What do we
> need to change in onboarding? etc. Also, are there other Parfait features that
> we should consider folding into new functionality available via the plugin or
> via MCP App?"

## The boundary rule

**If it improves the artifact — audio, transcript, notes, titles, speakers —
it's Parfait. If it synthesizes across sources or acts on the world, it's
Claude.** Parfait is the senses; Claude is the brain and hands. Parfait's job in
this design is to be the best possible *meeting data source and capture tool*
for Claude, and to make the handoff moments (meeting ended, meeting starting)
feel native.

## Where we are today

- One binary, two personalities: the menu-bar app and `Parfait --mcp`, a stdio
  MCP server over the same on-disk meeting library (14 tools: meetings,
  transcripts, live transcript, summaries, templates).
- Three disjoint "Claude" surfaces are baked in: Claude Desktop deep links
  (`claude://claude.ai/new` — Ask Claude tab, library launcher, live button),
  Claude Code deep links (`claude://code/new` — MCP/GitHub setup), and the
  headless `claude` CLI (summaries). Three different install checks.
- MCP registration is manual UX: onboarding steps 5–6 detect-and-link-out;
  Settings → "Connect Claude to your meetings" has Add-to-Code /
  Add-to-Desktop buttons plus copyable `claude mcp add` / JSON snippets.
- No plugin, no skill, no `.mcp.json` in the repo. No MCP tool can publish
  notes (publishing is app-side via `gh`).
- Platform facts (verified 2026-07): **MCP Apps** shipped Jan 2026 — local
  stdio servers can render interactive cards/carousels/fullscreen UI inside
  Claude Desktop, claude.ai, and mobile. **Plugins** bundle skills +
  `.mcp.json` and install into Claude Code and Desktop in one step.
  **Connectors** configured in claude.ai flow automatically into Claude Code
  under the same login. **Cloud routines cannot reach a local stdio server**
  — ambient jobs must run locally.

## Design

### 1. The plugin is the product's Claude half

Ship a `parfait` plugin from a **`plugin/` directory in this repo** (decided
2026-07-20: one release train; a marketplace is just a repo with
`.claude-plugin/marketplace.json`, and entries can point at subdirectories.
Known trade-off: the repo must stay accessible to anyone installing the
plugin — extract to its own repo only if the app repo ever needs to be
private while the plugin is public). It contains:

- **`.mcp.json`** — registers the stdio server. The binary lives inside
  `Parfait.app/Contents/MacOS/`, which moves and isn't known at plugin-author
  time; the plugin therefore invokes a **stable launcher** (e.g.
  `~/Library/Application Support/Parfait/bin/parfait-mcp`, a tiny script the
  app writes/refreshes on every launch that execs the current bundle binary
  with `--mcp`). App updates then never break the plugin.
- **Skills** — the executive-assistant playbook as prompts, not app code:
  - `parfait-dig-in` (the flagship, "Dig in"): post-meeting flow — read the latest
    meeting, extract commitments/questions/follow-ups *with connector
    context* (match against existing Linear issues, email threads, calendar),
    propose actions, execute only on approval, write outcomes back.
  - `parfait-scoop` ("Get the scoop"): pre-meeting — given an upcoming event, pull past meetings
    with the same attendees, open commitments, related mail/tasks; one-screen
    brief.
  - `parfait-digest`: weekly rollup — decisions made, commitments open (mine
    and theirs), questions still unanswered.
- Later: **MCP App resources** (see §4).

Because connectors sync from claude.ai into Claude Code, the skills
automatically see whatever the user has connected (Linear, Slack, Gmail…) —
Parfait builds zero connector plumbing. Extraction of action items moves *out*
of the pipeline plan entirely: Claude extracts at dig-in time, when it can see
the outside world.

### 2. Commitment state: `followups.json`, written by Claude

New MCP tools `get_followups` / `save_followups` (and
`update_followup_status`) that read/write `followups.json` beside `summary.md`.
Claude (via the dig-in skill) is the writer; Parfait just stores and displays.
Meeting folders become the substrate for cross-meeting commitment tracking —
the brief and digest skills fold over them. The app may show a small read-only
"Follow-ups" section on the meeting detail view rendered from this file, with
one action: "Dig in with Claude." No approval cards in the app.

### 3. The handoff moments

Claude is pull-based; Parfait owns the trigger moments and bridges them:

- **Meeting processed** → notification "Notes ready — dig in with Claude" →
  deep link with a prefilled prompt invoking the dig-in skill for that meeting
  UUID. Reuses `ClaudeDesktop.openNewChat` machinery.
- **Meeting starting** (detection prompt already exists) → optional "Brief me"
  affordance → same deep-link pattern into `parfait-scoop`.
- **Ambient** (later): local scheduled Claude runs (weekly digest, morning
  brief). Must be local — cloud routines can't reach the stdio server. The
  skill docs can teach users to set this up; the app shouldn't own a scheduler.
- Collapse the three Claude surfaces while we're here: one
  `ClaudeLink` helper that prefers Claude Desktop, knows the plugin's skill
  names, and is the only deep-link builder.

### 4. MCP Apps (phase 3): Parfait UI inside Claude

Once the skill loop is proven, serve `ui://` resources from the existing
server. **Start with the follow-up card only** (decided 2026-07-20), as the
test of the whole MCP-Apps approach:

- **Follow-up card** — approve/dismiss inline during dig-in (inline cards are
  capped at ~2 actions — approve/dismiss fits exactly). Cost is small: a
  `ui://` resource is one self-contained vanilla HTML/JS file (~150–300 lines
  incl. the postMessage JSON-RPC glue and host theming variables), no build
  tooling, shipped as a single resource in the bundle.
- Later, if the card proves out: **meeting picker carousel** (ambiguous "dig
  into my last meeting") and **fullscreen meeting view** (notes + transcript
  browser).

This replaces the previously-proposed in-app Follow-ups tab wholesale.

## App-side effects

### Onboarding (`OnboardingView`)

- Replace steps 5 (Claude access) + 6 (Claude Desktop) with **one step:
  "Install the Parfait plugin for Claude"** — action runs the marketplace-add
  + plugin-install (via `claude` CLI when present, else deep-link fallback
  with the copyable commands), then verifies by probing `claude plugin list`
  (or the plugin's marker on disk). Detection-only rows die.
- Step 7 (GitHub) stays for now (publishing still uses `gh`), but moves below
  the plugin step and gets folded into the skill era later (§fold-ins).
- App launch writes/refreshes the `parfait-mcp` launcher script
  unconditionally — before onboarding, so install always works.

### Settings (`SettingsView`)

- "Connect Claude to your meetings" section (buttons + copyable
  `claude mcp add` + JSON snippet + Reveal-config) collapses to: plugin
  status (installed/version), an Install/Update button, and a "prefer to run
  it yourself?" disclosure that documents the launcher path for power users.
- `ClaudeCode.addMCPServer` / `addToClaudeDesktop` are superseded; keep them
  only as the manual fallback behind the disclosure, or delete once the
  plugin path is proven.
- `preferClaudeSummaries` stays — headless CLI summarization is artifact-side
  work and remains in-app per the boundary rule.

### Existing surfaces that become shims (fold-in candidates)

| Today (app) | Under the plugin | Disposition |
| --- | --- | --- |
| Ask Claude tab (deep-link composer) | Just open Claude; skill knows the meeting tools | Shrink to a single "Open in Claude" button on the detail view; drop the tab |
| "Ask your meetings" library entry | Same | Drop or same single button in toolbar |
| "Ask Claude live" button on recording card | Keep — it's a handoff moment (uses `get_live_transcript`) | Keep, route through `ClaudeLink` |
| Regenerate/template menu on Notes tab | Also possible via skill + `regenerate_summary` | Keep in app (cheap, artifact-side); no changes |
| Template management Settings tab | Fully mirrored by 6 MCP template tools; skill can manage templates conversationally | Keep for now; candidate for MCP App fullscreen editor later |
| Publish to gist / notes.parfait.to | **Gap: no MCP publish tool.** Skill can't share links | Add `publish_meeting` MCP tool wrapping the existing `GitHubGist` flow; app UI stays |
| In-app search (substring filter) | `search_meetings` MCP + Claude reasoning is strictly better for questions | Keep the filter (it's navigation, not search) |
| Detection probes (`isLoggedIn`, shell probes) | Only needed to gate setup buttons | Most die with the manual-setup UX |

### New MCP surface (summary)

- `get_followups` / `save_followups` / `update_followup_status` (§2)
- `publish_meeting` (gap found in inventory)
- `list_meetings` gains a `since`/"new since last dig-in" affordance so the
  dig-in and digest skills are cheap to run repeatedly
- Later: `ui://` resources for MCP Apps (§4)

## Phasing

1. **Plugin + dig-in skill + handoff.** Launcher script, `plugin/` dir with
   `.claude-plugin/marketplace.json` + `.mcp.json` + `parfait-dig-in` (as both
   skill and `/dig-in` slash command), followups MCP tools, "notes ready → dig
   in with Claude" notification deep link. Onboarding/Settings rewired to
   plugin install. This alone delivers "Claude as EA."
2. **Scoop + digest skills, publish tool, surface cleanup.** `parfait-scoop`
   on the detection moment, `parfait-digest`, `publish_meeting`, collapse the
   Ask-Claude shims and dead setup UX, unify deep links behind `ClaudeLink`.
3. **MCP Apps: follow-up card only**, served from the stdio server, as the
   test of the approach; carousel/fullscreen wait on its verdict.

Non-Claude users keep a fully working local notetaker (capture, on-device
notes, publish); they just don't get the assistant. That's the positioning.

## Verification

- Plugin install end-to-end on a clean machine/user: onboarding step →
  `claude plugin list` shows parfait → new Claude Code and Desktop sessions
  can call `mcp__parfait__*` and the skills appear.
- App update → launcher script still points at the new binary; plugin
  untouched and still works.
- Dig-in loop: record a meeting with action items → notification → deep link
  → skill reads the meeting, proposes, writes `followups.json` → app shows
  the follow-ups section; `update_followup_status` from a second Claude
  session round-trips.
- Existing MCP tests (`MCPServerTests`) extended for the new tools;
  `swift test` green.

## Decisions (Conrad, 2026-07-20 review)

1. **Plugin location: `plugin/` in this repo.** One release train; the
   marketplace manifest points at the subdirectory. Trade-off accepted: repo
   must remain accessible to installers; extract to its own repo only if the
   app repo ever needs to be private while the plugin is public.
2. **Skill invocation: both** — deep-linked prompts naming the skill AND
   `/dig-in` (and later `/scoop`, `/digest`) slash commands.
3. **Summarization stays in-app** (headless CLI, per the boundary rule) —
   revisit later only if maintaining two summary paths hurts.
4. **MCP Apps: follow-up card only to start**, as the test of the approach.
   The card is one self-contained vanilla HTML/JS `ui://` resource
   (~150–300 lines); carousel and fullscreen view wait on its verdict.
