# Parfait

On-device meeting notetaker for macOS with a Claude plugin for follow-through
(followups / scoop / digest). Swift Package Manager app (`Sources/Parfait/`),
marketing site (`site/`, deploys to parfait.to on push to main), notes CDN worker
(`workers/notes-proxy/`, notes.parfait.to), Claude plugin (`plugin/`).

## Changelog policy

**Every significant commit must update the changelog page: `site/changelog.html`.**

- "Significant" = a user would notice: new capability, visible behavior change,
  fix for a bug users hit, copy/UX changes on the site or published pages.
  Pure-internal work (CI, gitignore, build config, planning docs, refactors with
  no visible effect) does not need an entry.
- Add the entry in the same commit as the change, at the top of the current
  date group (newest first). Create a new date group if the day changed.
- Entry style: plain-language, user-facing. A short `<b>` headline plus 1–2
  sentences on what changed and why it matters. No internal class names or
  codenames; MCP tool names and UI labels are fine.
- Match the existing markup pattern in `site/changelog.html` (one `<li class="entry">`
  per change). The site auto-deploys on push to main, so a committed entry is live.
