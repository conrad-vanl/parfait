# parfait.to — Marketing Site + Rendered-Notes CDN: Implementation Plan

*Plan, 2026-07-09. Produced by a research → design → adversarial-critique → revise workflow; reconciled against the companion CDN plan by the orchestrator.*

> **Synthesis notes (orchestrator, override the body where they conflict):**
>
> - **§4.3 (proxy detail) is superseded** by [`2026-07-09-parfait-to-notes-cdn.md`](2026-07-09-parfait-to-notes-cdn.md) — that doc's Worker spec, header stack, and URL scheme win wherever the two differ. Two corrections to this doc specifically: (1) the gist-ID regex is `[0-9a-f]{20,32}` — §4.3.1's "20-hex only" correction is wrong for every newly created gist (verified live 2026-07-09: new gists are all 32-hex; legacy ones are 20-hex); (2) the shared-link URL **keeps** GitHub's `/raw/` path segment — a pure host swap is a one-line app change and lets one regex mirror the upstream path exactly (CDN plan §2/§6).
> - **§2.7 chat copy is stale as of commit 38c0ed5** (landed after this plan was drafted): in-app chat was replaced with Claude Desktop deep-link launchers. Chat no longer "answers on device" — both chat surfaces open Claude Desktop with a pre-filled prompt steered at the parfait MCP connector, and Claude Desktop is a *requirement* for chat (the `claude` CLI is now only for long-meeting summaries). Replacement copy: "Ask a meeting 'what did we decide?' — the Chat tab opens Claude Desktop with that meeting loaded through Parfait's MCP connector, prompt pre-filled. 'Ask your meetings' does the same across your whole library. Point Claude Code at the same server: [command]. The MCP server is a thin, read-only reader over your meeting folder: four tools, nothing else leaves your Mac."
> - **Repo layout:** use the CDN plan's tree — `site/` and `workers/notes-proxy/` at the repo root. Read `web/site/` in this doc as `site/`.
> - **Hosting:** serve the static site via **Workers Static Assets** rather than Cloudflare Pages (CDN plan §1) — same $0, and one wrangler-based deploy path for site and proxy alike. The Pages-specific steps in §4.4/§5 map 1:1 to Workers custom-domain equivalents.
> - **§2.6 copy holds** ("delete the gist and the link dies") because the CDN plan's cache policy is amended to bounded TTLs (edge 1 day, browser 1 hour) — see that doc's synthesis notes. Without that amendment this sentence would have been false.
> - **Verified facts:** "about 5,800 lines of Swift" → 5,812 at plan time (re-verify at ship; the codebase moved). Open question 1 (§6) is answered: the registrar is Namecheap on default parking DNS with no email or services on the zone — free to repoint nameservers to Cloudflare.

## 1. Goals + Audience

**Primary goal:** a one-pager at `parfait.to` that explains what Parfait is and gets a technical visitor to either star/clone the repo or run the install command. Secondary goal: replace `gistcdn.githack.com` with a `parfait.to` subdomain as the host that serves rendered, shared meeting pages — keeping the "user owns the gist" model, adding real abuse protection, at effectively $0/month.

**Who lands here:**
- Someone who received a shared meeting-notes link (`notes.parfait.to/...`) and clicks through out of curiosity about what made it — the rendered page's footer link is the single biggest source of new traffic to the marketing site, bigger than any ad or post.
- A developer who heard "open-source, on-device alternative to Granola" somewhere (HN, Reddit, a tweet) and wants to verify the claim before installing anything.
- Someone already sold, arriving to get the install command as fast as possible.

**What they should do:** read the hero and requirements line in well under 10 seconds, decide if their Mac qualifies, then either click **View on GitHub** or copy the four install lines. There is no email capture, no account, no pricing decision — the entire "conversion" is `git clone`.

## 2. Information Architecture + Copy

Eight sections, single column, no nav bar. Longer than a minimal 6-section one-pager only because this task requires standalone publish/share and chat/MCP sections; each stays short to preserve the airy feel. **Measured** (not estimated) body-copy word count — hero subhead plus every section paragraph, excluding code blocks, the headline, CTA button labels, the requirements strip, the install caption, and the footer — is **373 words**, under the 400-word target. Counting everything on the page that isn't a code block (including captions, CTAs, and footer) comes to 427 words total.

Order: Hero → Requirements strip → Install → What it is → How it works → Publish & share → Chat with your meetings → Your data never leaves your Mac → Footer.

---

### 2.1 Hero

**Headline:**
> Layered meeting notes. Perfectly local.

**Subhead (one sentence):**
> Parfait notices when a meeting starts, records both sides, transcribes with named speakers, and writes notes into your own templates.

**Small-type line directly below** (separate from the subhead sentence, so the core claim reads fast — see §3.2 for sizing):
> Transcribed and summarized entirely on your Mac. Free and open source.

**CTAs (side by side on desktop; see §3.9 for mobile stacking):**
- Primary button: **View on GitHub** → `https://github.com/conrad-vanl/parfait`
- Secondary text link: **How to install ↓** → `#install` (anchor to §2.3)

### 2.2 Requirements strip

Small, plain caption-sized text directly under the hero — a fact, not a warning:

> Requires macOS 26 (Tahoe) on Apple Silicon, with Apple Intelligence enabled.

### 2.3 Install (`id="install"`)

One eyebrow label — **INSTALL** — then a single code block, verbatim from the README:

```bash
git clone https://github.com/conrad-vanl/parfait.git
cd parfait
make install        # builds, assembles Parfait.app, copies to /Applications
open /Applications/Parfait.app
```

Caption below the block:
> About two minutes, no App Store or developer account. `make install` signs the app so mic and system-audio permissions survive rebuilds.

### 2.4 What it is

One paragraph, no bullets:

> Parfait is an open-source alternative to Granola: a menu-bar app that records your mic and everyone else's audio, transcribes and separates speakers, and writes notes into a template you control — no bot in your call, no server to reach.

### 2.5 How it works

Eyebrow label **HOW IT WORKS**, four one-line beats, each with a screenshot placeholder (see §5 checklist — do not ship with mockup art, capture real screenshots):

1. **Detects the meeting.** Notices your mic come into use by a call app and offers to record, or starts automatically. *[screenshot: menu-bar prompt]*
2. **Records both sides.** Your mic through AVAudioEngine; everyone else through a Core Audio system-audio tap — no virtual driver, no bot. *[screenshot: menu-bar recording state]*
3. **Transcribes and names speakers.** SpeechAnalyzer timestamps the transcript; FluidAudio tells voices apart; calendar attendees become name suggestions. *[screenshot: transcript with speaker labels]*
4. **Writes your notes.** Apple Intelligence summarizes into an editable template — Meeting Notes, 1-on-1, Interview, or your own. *[screenshot: notes view]*

### 2.6 Publish & share

Eyebrow label **PUBLISH**:

> When a meeting's worth sharing, Parfait renders notes and transcript into one self-contained page, then publishes it as a secret gist on your own GitHub. A **notes.parfait.to** link serves it back rendered, shareable with anyone; delete the gist and the link dies. Or skip publishing: preview in-browser or export the HTML, nothing leaving your Mac.

*(This copy names `notes.parfait.to` explicitly — the hostname question from the draft plan is resolved in §4.2/§6 below, so the marketing copy and the actual architecture no longer disagree.)*

### 2.7 Chat with your meetings

Eyebrow label **CHAT WITH YOUR MEETINGS** (renamed from "CHAT & MCP" — MCP is explained inline instead of assumed):

> Ask a meeting "what did we decide?" and Parfait answers on device, or via your own Claude account for meetings too long to fit locally. Point Claude Code or Desktop at the same library over **MCP** (the protocol AI tools use to read local data), and ask across every meeting you've recorded:

```bash
claude mcp add parfait -s user -- "/Applications/Parfait.app/Contents/MacOS/Parfait" --mcp
```

> The MCP server is a thin, read-only reader over your meeting folder: four tools, nothing else leaves your Mac.

### 2.8 Your data never leaves your Mac

Eyebrow label **PRIVACY**:

> Recording, transcription, diarization, and summarization happen on your Mac: SpeechAnalyzer (Apple's on-device speech engine) transcribes, a small third-party model (FluidAudio) separates speakers, and Apple Intelligence's FoundationModels summarizes. Parfait makes one network call, downloading those models once. Everything else — Claude for long meetings and chat, GitHub for publishing — runs through your own already-logged-in `claude` and `gh` CLIs, on your own accounts. No server means nowhere to send your data.
>
> MIT-licensed, about 5,800 lines of Swift: recording in `Sources/Parfait/Audio`, transcription and diarization in `Sources/Parfait/Transcription`, summaries in `Sources/Parfait/Intelligence`.
>
> Granola runs a bot in your meeting and sends your audio to a server. Parfait doesn't.

*(FluidAudio is now correctly described as a small third-party model, not folded into "frameworks Apple ships" — the README's own Acknowledgements section credits it as Apache-2.0 from FluidInference, separate from Apple's frameworks.)*

### 2.9 Footer

> [GitHub](https://github.com/conrad-vanl/parfait) · [Issues](https://github.com/conrad-vanl/parfait/issues) · MIT License
>
> This page has no analytics, no trackers, and no third-party scripts.

---

## 3. Design Spec

The page is a sibling of the published notes page, not a clone — same palette and motif, more room to breathe.

### 3.1 Palette (identical CSS custom properties to `HTMLExporter.swift`, reused verbatim)

```css
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
```

No `data-theme` overrides are needed here — unlike Claude-hosted artifacts, this is a real site with its own document; `prefers-color-scheme` is the only signal, which matches the shipped `HTMLExporter` output exactly.

### 3.2 Type scale

Font stack: identical to the notes page — `ui-rounded,"SF Pro Rounded",-apple-system,system-ui,"Segoe UI",sans-serif`. Monospace for code: `ui-monospace,"SF Mono",Menlo,monospace`.

| Element | Size | Weight | Color | Notes |
|---|---|---|---|---|
| Hero H1 | `clamp(2.25rem, 5vw, 3.25rem)` | 700 | `--accent` | line-height 1.1, letter-spacing -.02em |
| Hero subhead | `clamp(1.05rem, 2vw, 1.25rem)` | 400 | `--ink` | line-height 1.6, max-width 34em |
| Hero small-type line | 0.9rem | 400 | `--muted` | sits directly below the subhead, its own line — this is what keeps the hero's core claim readable in well under 10 seconds (see §3.8 for why it isn't `--honey`) |
| Requirements strip | 0.85rem | 500 | `--muted` | plain sentence, no letter-spacing |
| Eyebrow label (section) | 0.78rem | 700 | **`--ink`** | uppercase, letter-spacing .14em |
| Section H2 | 1.5–1.75rem | 700 | `--ink` | sits directly under its eyebrow |
| Body copy | 1rem | 400 | `--ink` | line-height 1.65 |
| Caption / meta | 0.85rem | 400 | `--muted` | |
| Code block | 0.92rem | 400 | `--ink` on `--card` | inset border like `.card`, horizontal scroll on overflow |

**Eyebrow color change from the draft:** `--honey` on `--page` measures **≈1.91:1** (computed: honey `#F2A93B` L=0.4756, page `#FFF9F2` L=0.9534 → (0.9534+.05)/(0.4756+.05)=1.91), nowhere near the 4.5:1 normal-text AA floor. Eyebrow labels now use `--ink` (which clears AA by a wide margin on `--page`). `--honey` is reserved for decorative, non-text uses only (§3.4) — decorative graphics marked `aria-hidden` aren't subject to text-contrast rules.

**Side note, not part of this plan's scope but worth flagging:** the *already-shipped* `HTMLExporter.swift` (`.section-title` rule, line 82) uses this exact same `color:var(--honey)` on `--page` for its section titles today — meaning the live published-notes page has this identical contrast failure right now. Worth a fast-follow fix to `HTMLExporter.swift` independent of this plan.

### 3.3 Spacing rhythm

8px base unit. Section vertical padding: 96px desktop / 56px mobile (breakpoint at 540px, matching `HTMLExporter`'s existing breakpoint). Content column max-width 760px (40px wider than the notes page's 720px, to give the hero and code blocks slightly more room without losing the single-column feel). Side gutters 24px on mobile.

### 3.4 Layered-stripe motif

Reuse the exact four-stop gradient from `.parfait-bar` (`#FFF9F2 → #F2A93B → #E0396B → #5A6ACF`), used sparingly in three places only — using it more starts to feel busy:
1. A 6px bar at the very top of the page, identical to the notes page — the immediate visual handshake between the two.
2. A 3–4px rounded divider between two or three major sections (not all of them), replacing a plain `border-top`.
3. A very low-opacity (6–8%) wash of the same gradient behind the hero only, as a soft horizontal band — restrained, not a background texture.

All three are decorative and `aria-hidden="true"`.

### 3.5 App-icon usage

`Resources/AppIcon-1024.png` re-exported at 256px, optimized, as its own sibling file `web/site/icon.png` (see §3.7 for why this is no longer base64-inlined). `<img src="icon.png" width="112">` centered above the headline, mirroring the README's centered icon treatment. Alt text: "Parfait app icon, a layered parfait glass."

### 3.6 Favicon

A separate small (32×32/64×64) PNG export of the same icon, `web/site/favicon.png`, referenced normally:
```html
<link rel="icon" type="image/png" href="/favicon.png">
```
Same icon at every size — do not swap art between favicon and hero.

### 3.7 Static-file structure (dropping the single-file constraint)

The "single self-contained HTML file, zero JS, zero external subresources" rule is a hard requirement for the *published meeting notes* — that file has to survive as a standalone artifact fetched through a gist/CDN with no server of its own behind it. The marketing site has no such requirement: Cloudflare Pages serves a plain directory of files exactly as easily as one file, and normal sibling files get real browser caching that a base64-inlined asset doesn't. So the marketing site ships as ordinary static files, not one inlined blob:

```
web/site/
  index.html
  icon.png
  favicon.png
  og-image.png
  404.html
```

The self-contained/inline/zero-JS rule stays exactly as strict as before, but only for `HTMLExporter`'s actual output — the thing that has to survive as a portable artifact. `index.html` and `404.html` still ship with zero JavaScript (nothing on this page needs it), just not zero external files.

### 3.8 OG / meta tags

```html
<title>Parfait — Layered meeting notes. Perfectly local.</title>
<meta name="description" content="An open-source, on-device meeting notetaker for macOS. Records both sides of your calls, transcribes and summarizes on your Mac — no backend, no accounts, no API keys.">
<meta property="og:title" content="Parfait — Layered meeting notes. Perfectly local.">
<meta property="og:description" content="An open-source, on-device meeting notetaker for macOS — a private, free alternative to Granola.">
<meta property="og:type" content="website">
<meta property="og:url" content="https://parfait.to">
<meta property="og:image" content="https://parfait.to/og-image.png">
<meta name="twitter:card" content="summary_large_image">
<meta name="theme-color" media="(prefers-color-scheme: light)" content="#FFF9F2">
<meta name="theme-color" media="(prefers-color-scheme: dark)" content="#252017">
```

`og-image.png` (1200×630 — icon, layered-stripe bar, tagline, on `--page` cream) is required regardless of §3.7's change, since link-preview crawlers need a reachable `http(s)` URL, not a `data:` URI — it's just one more ordinary sibling file now instead of a special-cased exception.

### 3.9 Primary/secondary CTA button spec

Not specified at all in the draft, despite being the single highest-value element on the page:

- **Primary ("View on GitHub"):** solid fill using a **button-only darkened raspberry token** (`--accent-solid`), white (`#FFFFFF`) text, weight 600, radius 12px, padding `12px 24px`. `--accent` itself (raspberry `#E0396B`) measures **4.04:1** against `--page`/white (computed: L(accent)=0.1984, L(white-ish page)=0.9534 → (0.9534+.05)/(0.1984+.05)=4.04) — enough for large text (H1) but short of the 4.5:1 normal-text floor a ~16px button label needs. `--accent-solid` must therefore be a darkened variant of `--accent`, defined separately for light and dark mode, validated to ≥4.5:1 against its paired text color before ship (this is the same automated-contrast-check step already in the checklist — do not ship a hand-picked hex without running it).
- **Secondary ("How to install ↓"):** text-only link in `--link` (periwinkle), underlined by default (per §3.10), same font-weight as the primary button's label, vertically centered next to it on desktop.
- **Hover/active (primary):** darken fill ~8%, gated behind no animation requirement beyond a simple color transition; respects `prefers-reduced-motion` per §3.10.
- **Focus-visible:** `outline: 2px solid var(--link); outline-offset: 2px` on both.

### 3.10 Accessibility

- Semantic `<header>`, `<main>`, `<section aria-labelledby="…">` per block; no `<nav>` needed since there is no nav bar.
- `--accent` (raspberry) on `--page` (cream) measures **≈4.04:1** (corrected from the draft's estimated ~3.2:1 — see the computation in §3.9) — clears the 3:1 large-text AA floor comfortably, still reserved for the hero H1 only, never body copy at normal sizes.
- `--ink` on `--page` clears AA comfortably for body text and is now also used for eyebrow labels (§3.2).
- Inline body links get `text-decoration: underline` by default (not just on hover) so they aren't color-only affordances against the periwinkle link color.
- `:focus-visible { outline: 2px solid var(--link); outline-offset: 2px }` on both CTA buttons and inline links.
- No animation is planned; if any hover transition is added later, gate it behind `@media (prefers-reduced-motion: reduce)`.
- Decorative stripe bars get `aria-hidden="true"`.
- The install/MCP commands are real, selectable `<pre><code>` text — no copy-button widget, which would require JS the page otherwise has none of. That's an accepted trade-off, stated here explicitly rather than silently.
- Re-validate all of the above with an automated checker (axe or Lighthouse) per the §5 checklist — the numbers above are computed by hand in this doc for planning purposes but should be re-confirmed against the actual shipped CSS.

### 3.11 Mobile CTA behavior

Below the 540px breakpoint (§3.3), the hero CTA row stops being side-by-side: the primary button becomes full-width, and the secondary text link centers directly below it with 12px of vertical gap — matching the existing responsive rhythm already defined for section padding, and avoiding cramped/mis-tappable adjacent targets on a 320–375px screen.

---

## 4. Tech + Deploy

### 4.1 Where the code lives

**Recommendation: a `web/` directory inside the existing `parfait` repo, not a separate repo.**

```
web/
  site/
    index.html       # the one-pager
    icon.png          # hero icon, 256px re-export
    favicon.png       # 32x64 favicon export
    og-image.png      # sidecar OG asset (see §3.8)
    404.html          # branded 404, same palette/motif
  worker/
    src/index.ts      # Cloudflare Worker: rendered-notes proxy
    wrangler.toml
  README.md            # deploy notes for this directory
```

Justification: Conrad is a solo maintainer; the marketing copy makes factual claims about the app (line counts, feature list, requirements) that must stay in lockstep with the actual code and README — a single PR can update a feature and its marketing sentence together. The brand asset (`Resources/AppIcon-1024.png`) already lives in this repo, so nothing needs duplicating across repos. There's no second set of collaborators who need repo access to the site but not the app, which is the usual reason to split a marketing site into its own repo. One CI, one issue tracker, one place secrets (the Cloudflare API token, added as a repo/deploy secret) need to be managed.

### 4.2 Hosting: Cloudflare (Pages + Workers), one account, one DNS zone

Both goals land on Cloudflare because goal 2 requires a Worker on the same domain family as the marketing site, and Cloudflare is the only platform here that gives static hosting, a serverless proxy, DNS, and edge caching under one free tier with no cold-start billing surprises.

- **Marketing site** (`parfait.to`, `www.parfait.to`) → **Cloudflare Pages**, deployed from `web/site/`.
- **Rendered-notes proxy** → **Cloudflare Workers**, deployed from `web/worker/`, bound to its own hostname: **`notes.parfait.to`**. **This is now a final decision, not an open question** (it was Open Question 2 in the draft — resolved here; see §6). It mirrors the industry pattern of isolating user-supplied content on its own host (`githubusercontent.com` vs `github.com`, `googleusercontent.com` vs `google.com`) so a future issue with rendered gist content can't touch the marketing origin's cookies or reputation — moot today since neither origin sets cookies, but free to do and worth doing. The marketing copy in §2.6 now names this hostname explicitly rather than saying "parfait.to serves it back," removing the contradiction the draft had between its committed copy and its own unresolved open question.

### 4.3 The rendered-notes proxy, in detail

URL shape, chosen to mirror GitHub's own raw-URL structure so validation is a single regex, with the `/raw/` segment dropped in the public-facing URL (this is now a firm decision, not "either works" as in the draft — see the fix below):

```
https://notes.parfait.to/{owner}/{gistId}/{sha}/{filename}
  → Worker re-inserts /raw/ and fetches →
https://gist.githubusercontent.com/{owner}/{gistId}/raw/{sha}/{filename}
```

This requires one small change to `Sources/Parfait/Publish/GitHubGist.swift`: instead of host-swapping the raw URL to `gistcdn.githack.com` (line 71), the URL-construction code drops the `/raw/` path segment and swaps the host to `notes.parfait.to`, producing the 4-segment shape above. The Worker is the only thing that knows about `/raw/`; it reconstructs the full `gist.githubusercontent.com` URL internally before fetching. That's the only app-code change goal 2 requires; everything else is new Worker code.

**Abuse protections (this proxy serves arbitrary user-supplied HTML — treat it accordingly):**

1. **Strict path validation.** Reject anything that doesn't match `^/[\w-]+/[0-9a-f]{20}/[0-9a-f]{40}/[\w.-]+\.html$` — GitHub username / **20-hex-character gist ID** (corrected from the draft's incorrect 32; GitHub's own REST API docs use a 20-hex example ID, e.g. `aa5a315d61ae9438b18d`) / 40-hex commit SHA / filename ending `.html`. No query strings, no other extensions — this also closes off any use of the Worker as a generic open proxy. **Before deploy, run a real `gh gist create` raw URL through this validator as a test case** — the draft's wrong ID length would have 404'd 100% of real shared links, so this check is not optional.
2. **Origin allowlist.** The Worker only ever fetches from `gist.githubusercontent.com`. Nothing else, hardcoded.
3. **Immutable edge caching.** Because the URL is commit-SHA-pinned, content at a given URL never changes. Cache every response at the edge (Cache API, `Cache-Control: public, max-age=31536000, immutable`) keyed on the full URL. Repeat visits and most abuse traffic (hotlinking, scraping, re-shares) hit cache, not GitHub or Worker CPU time — this is the single biggest cost and abuse control, and it's free.
4. **Size cap.** Reject/abort responses over ~2 MB (`HTMLExporter` targets 50 KB–1 MB; 2x headroom, hard stop beyond that) — prevents someone using a hand-crafted giant gist to run up bandwidth.
5. **Origin fetch timeout** (~5s) so a slow/hung GitHub response can't tie up Worker execution.
6. **Rate limiting on cache misses.** A Cloudflare Rate Limiting Rule (available on the free plan, at least one custom rule) capping requests-per-minute per IP specifically for cache-miss traffic — legitimate shared links stay fast and unaffected (they're cached), while scraping fresh/unknown URLs gets throttled.
7. **Response hardening**, regardless of what's inside the fetched HTML:
   - Force `Content-Type: text/html; charset=utf-8`.
   - `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src data:` — since `HTMLExporter` guarantees no JS and no external assets, this CSP costs the legitimate page nothing but blocks script execution outright if a user hand-edits their gist to add one.
   - `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `X-Frame-Options: SAMEORIGIN` (or a `frame-ancestors` CSP directive) to block clickjacking wraps.
8. **No state.** The Worker is a pure function of the request; the Cache API is edge cache, not application state — consistent with "no backend state beyond what's strictly needed."
9. **Takedown path.** Since the actual bytes live on GitHub's gist infrastructure, abuse/DMCA reports route to GitHub, not to Conrad running a hosting business. State this plainly on the footer of rendered pages or in the repo's README so it's unambiguous where content actually lives.

### 4.4 DNS records (apex `parfait.to`)

1. Point the domain's nameservers (at whatever registrar it was bought through) to the two nameservers Cloudflare assigns when the zone is created — this is required for both Pages custom domains at the apex and Workers custom domains, and is the one manual step that has to happen outside Cloudflare's dashboard.
2. In the Cloudflare Pages project, add `parfait.to` as a custom domain — Cloudflare auto-creates the flattened apex record (proxied).
3. Add `www.parfait.to` as a CNAME → the Pages project (proxied), plus a Cloudflare Redirect Rule `www.parfait.to/* → https://parfait.to/*` so there's one canonical URL.
4. On the Worker, add `notes.parfait.to` as a Custom Domain (Workers → Triggers → Custom Domains) — Cloudflare auto-creates that CNAME too.
5. No MX/email records needed for this deploy; skip entirely unless Conrad separately wants email at `@parfait.to`.

### 4.5 HTTPS

Cloudflare Universal SSL, automatic, on both the Pages and Workers custom domains, no cert management needed. Set SSL/TLS mode to **Full (strict)**, enable **Always Use HTTPS**. HSTS can be turned on once both hostnames have been verified working over HTTPS for a few days (optional, not blocking).

### 4.6 Cost

Cloudflare Pages: free. Workers: free tier (100,000 requests/day) — at the traffic volumes a project like this sees, effectively $0/month indefinitely; the aggressive immutable caching in §4.3.3 keeps actual Worker invocations to roughly one per unique shared meeting, not one per view.

---

## 5. Implementation Checklist

- [ ] Create `web/site/index.html` with the copy from §2, styled per §3 (ordinary static files, inline CSS, zero JS — icon/favicon/og-image as sibling PNGs, not base64-inlined).
- [ ] Create `web/site/404.html`, same palette/motif, with a link back to `/`.
- [ ] Capture the four real screenshots for §2.5 (menu-bar prompt, recording state, transcript with speaker labels, notes view) — do not ship placeholder/mockup art.
- [ ] Produce `web/site/og-image.png` (1200×630) per §3.8.
- [ ] Define and validate `--accent-solid` (the button-fill token from §3.9) at ≥4.5:1 against its paired text color, in both light and dark mode.
- [ ] Validate all contrast pairs in §3.10 with an automated checker (e.g. axe or Lighthouse) in both light and dark rendering, including the corrected eyebrow-label color and button fill.
- [ ] Create Cloudflare account/zone for `parfait.to`; move nameservers at the registrar.
- [ ] Create the Cloudflare Pages project from `web/site/`; add `parfait.to` and `www.parfait.to` custom domains; add the `www → apex` redirect rule.
- [ ] Write `web/worker/src/index.ts` implementing the proxy + all nine protections in §4.3, including the corrected 20-hex-character gist-ID regex; write `wrangler.toml`.
- [ ] Deploy the Worker; add `notes.parfait.to` as its Custom Domain.
- [ ] Add a Cloudflare Rate Limiting Rule scoped to cache-miss requests on `notes.parfait.to`.
- [ ] Set SSL/TLS mode to Full (strict); confirm HTTPS works on all three hostnames (`parfait.to`, `www.parfait.to`, `notes.parfait.to`).
- [ ] Update `Sources/Parfait/Publish/GitHubGist.swift` to drop the `/raw/` segment and host-swap to `notes.parfait.to` instead of `gistcdn.githack.com`; add a unit test that runs a real `gh gist create` raw URL through both the Swift URL-construction code and the Worker's path regex.
- [ ] Manually publish one real meeting end-to-end and confirm the `notes.parfait.to` link renders correctly, in both light and dark system appearance.
- [ ] Confirm an invalid/malformed path to `notes.parfait.to` (wrong hex length, non-`.html` extension, extra query string, `/raw/` still present) returns a clean 404, not a proxied fetch.
- [ ] Update the README's publish description once the Swift change ships, so docs and behavior stay in sync.
- [ ] Add `web/README.md` documenting the deploy steps above for future reference.
- [ ] (Fast-follow, out of scope for this plan but flagged in §3.2) Fix `HTMLExporter.swift`'s `.section-title` rule, which uses the same low-contrast `--honey`-on-`--page` text color this plan corrected on the marketing site.

---

## 6. Open Questions for Conrad

1. **Domain/DNS control:** is `parfait.to`'s registrar one where nameservers can be freely repointed to Cloudflare (no registrar lock-in, no existing DNS-dependent email/services on that domain today)? This is the one manual step in §4.4 outside Cloudflare's dashboard, and everything else in the deploy plan depends on it.
2. ~~Hostname for shared links~~ **Resolved in this revision:** the serving host is `notes.parfait.to`, not the bare apex — isolates user-supplied content from the marketing origin, matches the `githubusercontent.com`/`github.com` pattern, and the marketing copy in §2.6 now names it explicitly instead of leaving the hostname ambiguous.
3. **Sequencing:** should the marketing site ship now (still pointing shared-link examples/screenshots at whatever's live at publish time), or should it hold until the `notes.parfait.to` Worker is live, so the site never shows a URL scheme that's about to change under it?