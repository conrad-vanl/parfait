# parfait.to notes CDN — replace gistcdn.githack.com

*Plan, 2026-07-09. Produced by a research → design → adversarial-critique → revise workflow; reconciled against the companion marketing plan by the orchestrator.*

> **Synthesis notes (orchestrator, override the body where they conflict):**
>
> - **Gist-ID regex:** use `[0-9a-f]{20,32}`, not `{32}`. Verified against the live GitHub API (2026-07-09): all newly created gists have 32-hex IDs, but legacy gists have 20-hex IDs (conrad-vanl's own account has 17 of them). `{20,32}` costs nothing and tolerates both. The companion marketing plan's "20-hex only" claim is wrong for every new gist — do not adopt it.
> - **Caching policy (overrides §3 steps 6–7):** the marketing copy promises "delete the gist and the link dies" — a privacy promise consistent with Parfait's whole brand, and `Cache-Control: max-age=31536000, immutable` breaks it (deleted content keeps serving from edge and browser caches ~forever). Replace with bounded TTLs: store at the edge with `s-maxage=86400`, serve browsers `max-age=3600`. Cost impact is negligible (~1 GitHub fetch per URL per colo per day instead of per forever); gist deletion and blocklist takedowns then propagate globally within ≤1 day (≤1 hour for browsers), and immediate takedown is available via Cloudflare's free purge-by-URL. The SHA-pinned immutability argument still holds for *content correctness* — it just shouldn't extend to *existence*.
> - **Linter amendment (overrides §3 step 5b):** the draft linter's bare-substring patterns (`javascript:`, `http-equiv`, `srcset=`, `src="http`) false-positive on legitimate meetings — people say and type those words in dev meetings, and HTML-escaping preserves them as plain transcript text. Since the exporter escapes `<` in all user-derived text, a tag opener can never appear in a legitimate export's user content. Lint only tag-opener contexts: `<script`, `<iframe`, `<object`, `<embed`, `<link`, `<base`, `<form`, and any `<meta` tag whose contents include `http-equiv`. CSP remains the actual security boundary; the linter is a cheap intent filter with zero false positives for real exports.
> - **This document is authoritative** for the Worker spec, URL scheme (host-swap only, `/raw/` segment preserved), security headers, repo layout (`site/` + `workers/notes-proxy/`), and legal/ops. The marketing plan's §4.3 is a parallel earlier sketch of the same Worker; where the two differ, this doc wins.
> - **DNS unblocked:** parfait.to is registered at Namecheap on default parking DNS (verified via whois/dig 2026-07-09; only a parking A record exists). Nothing depends on the current zone, so the nameserver repoint to Cloudflare is a clean first step.
> - **Decisions from Conrad (2026-07-09):** githack stays a *transition-only* fallback (remove the setting once notes.parfait.to is proven); DMCA designated-agent registration is deferred until there's an entity to attach it to (abuse intake = GitHub issue template; no personal-name registrations); site and proxy ship together.

## 1. Recommendation

**Cloudflare, one account, one zone (`parfait.to`), two isolated Workers/subdomains, both on the Free plan at launch:**

- `parfait.to` (apex) — **Workers Static Assets** serving the marketing one-pager. No user content, no cookies, no dynamic logic.
- `notes.parfait.to` (subdomain) — **a dedicated Cloudflare Worker** that validates, fetches, sanitizes, and re-serves gist content as rendered HTML, replacing the `gistcdn.githack.com` host-swap.

*(Correction from the draft: this is **one Cloudflare zone** — `notes.parfait.to` is a subdomain of the same registered domain, not a second zone. The isolation that matters — no shared cookies, independently deployed Worker code, a hostname-scoped Safe Browsing flag — is real, but the Free plan's zone-wide budgets (1 rate-limiting rule, 5 WAF custom rules) are **shared** between the marketing site and the notes proxy, not doubled. Any future rule added for the marketing site competes with the notes-proxy's existing rule.)*

**Rationale:** Cloudflare Workers Free gives everything this job needs at $0/month — custom domains on an owned zone with no upgrade required, an edge Cache API for near-zero-cost repeat views, KV for a blocklist, and free-tier SQLite-backed Durable Objects for rate-limit counters — while keeping unmetered egress (the one variable that could otherwise make a "serve arbitrary HTML for strangers" service expensive). It's also the same architecture raw.githack.com itself runs on (Cloudflare-fronted proxy over `raw.githubusercontent.com`), so this isn't a novel bet, it's a hardened rebuild of a proven pattern — hardened specifically where githack is weakest (no published size/rate limits, no content validation, only a clickthrough interstitial, case-sensitive-naive linting would be if it had one at all).

| Platform | Why not (for the render proxy) |
|---|---|
| **Deno Deploy** | Workable free tier (1M req/mo, 50ms CPU) but smaller ecosystem/tooling; no reason to prefer over Cloudflare given Cloudflare's superior KV/DO/Cache primitives for this exact job. |
| **Fastly Compute** | Free tier is a **usage credit**, not a hard cap — an abuse spike becomes a real invoice, which conflicts with the "~$0/month, no surprise bill" goal. (Ironically already powers GitHub's own raw-content CDN under the hood.) |
| **Vercel Hobby** | ToS explicitly restricts Hobby to non-commercial personal use; a public utility serving arbitrary strangers' content for an OSS project with a real GitHub identity is a bad fit for that fair-use language, and Pro is $20/mo. |
| **Netlify** | New credit-based free tier (300 credits/mo) is workable and non-billing (traffic just stops), but its Edge Functions model and credit accounting are more fiddly to reason about than Cloudflare's flat daily counters, for no offsetting benefit. |
| **GitHub Pages** | Fine for the marketing page alone, but static-only — cannot do the fetch/validate/re-serve proxy job (goal 2) at all. Irrelevant beyond goal 1, and Cloudflare already covers goal 1 on the same platform as the proxy. |

**Escape hatch:** Workers Paid is $5/month if free-tier ceilings are ever actually hit by legitimate traffic (see §5).

---

## 2. URL design

**Exact mapping** (mirrors the gist raw path 1:1, only the host changes — this is deliberate, see §6):

```
https://gist.githubusercontent.com/<user>/<gistid>/raw/<sha40>/<filename>.html
                              ↓  (host swap only, path untouched)
https://notes.parfait.to/<user>/<gistid>/raw/<sha40>/<filename>.html
```

Validation regex (applied against `url.pathname` before any network activity):

```
^/([A-Za-z0-9-]{1,39})/([0-9a-f]{32})/raw/([0-9a-f]{40})/([A-Za-z0-9._-]{1,120}\.html)$
```

- `user` — GitHub username shape (alnum + hyphen, ≤39 chars). **Lowercased immediately after capture** and used in that lowercased form for every downstream decision (blocklist key, cache key, upstream fetch) — see §3 and the fix for the case-variant bypass below. GitHub usernames are themselves case-insensitive, so this collapses all case spellings of one account into a single identity everywhere it matters.
- `gistid` — 32-char lowercase hex.
- literal `raw` segment — preserved from the gist path; also functions as a cheap reject for anyone hand-crafting a non-gist-shaped URL.
- `sha40` — full 40-char lowercase hex commit SHA. **This is the immutability anchor**; only this shape is ever fetched or cached.
- `filename` — must end in `.html`.

**Query strings and fragments are rejected outright, not just "treated as significant."** *(Fixing a real bug in the draft: the regex above only ever matched `url.pathname`, but Cloudflare's Cache API keys `caches.default` on the **full request URL including the query string** by default. A request to the same path with `?x=<random>` appended passed the pathname regex unchanged and was a guaranteed, free, unbounded-cardinality cache miss against any real published link — a cost-bomb / GitHub-rate-limit-exhaustion vector the draft claimed to close but didn't.)* Fix: **any request with a non-empty `url.search` is rejected with 400 before any other work**, full stop — this service has no legitimate use for query parameters, so there's no compatibility cost, and it makes the pathname regex the sole and sufficient cache key by construction (no separate canonical-key logic needed).

**Non-pinned / floating paths** (5 segments, no SHA): **reject with 400**, never fetched upstream. A floating URL is mutable by definition and this service only promises immutable, cache-forever responses.

**Malformed paths** (wrong segment count, non-hex IDs, path traversal, missing `.html`, wrong extension, non-empty query string): **400**, matched purely by the regex before any fetch or cache lookup. A short `Cache-Control: max-age=60` on 400 responses (keyed by the exact bad path) blunts naive scanner floods hitting the same malformed path repeatedly.

---

## 3. Worker behavior spec

Order of operations — **revised from the draft** to fix two real bugs: (a) the blocklist check used to run before the cache lookup, which means every cache **hit** still paid 2 KV reads, exhausting the 100,000-reads/day KV budget at roughly half the request volume needed to hit the Workers request ceiling; (b) content validation is only meaningful "once per SHA" within a single Cloudflare colo — Cache API is per-colo, not global, so a link opened from multiple regions still re-validates and re-fetches once per colo. Both are now handled explicitly rather than glossed over.

```
1. Request validation
   - method must be GET or HEAD; else 405
   - path must match the §2 regex against url.pathname; else 400
   - url.search must be empty; else 400 (closes the cache-key/query-string bug)
   - lowercase the captured `user` segment; all subsequent steps use the
     lowercased value

2. Edge-cache lookup (Cache API) — FIRST, before any KV read
   - cacheKey = canonical request built from scheme+host+pathname (user
     segment lowercased), since url.search is already guaranteed empty
   - match = await caches.default.match(cacheKey)
   - if match → return match immediately (headers already baked in,
     ~0 CPU, zero KV reads, zero origin fetch)
   - NOTE (documented residual risk, not silently assumed away): this is a
     per-colo cache. A URL opened from geographically distinct visitors
     independently cache-misses, re-fetches, and re-validates in each colo
     that sees it — "once per SHA" is only true per-colo, not globally.
     Realistic traffic volumes make this a bounded, not unbounded, cost;
     it is not eliminated, only accepted.

3. Blocklist check — ONLY on cache miss (this ordering, not the draft's
   "check on every request," is what keeps KV reads bounded to the
   cache-miss rate rather than the full request rate)
   - single KV read: BLOCKLIST.get(user)  →  a JSON value of the shape
     { blocked: bool, blockedGists: string[] } (collapses the draft's two
     separate KV.get calls into one; per-gist blocks are rare enough to
     live inside the per-user record instead of a second lookup)
   - if blocked (user-level, or gistId present in blockedGists) → 410 Gone,
     short cache (60s), no upstream fetch
   - KNOWN LIMITATION, documented not hidden: KV writes are only eventually
     consistent (commonly cited up to ~60s propagation) and every
     successful 200 response below carries a one-year immutable
     Cache-Control — a takedown stops *new* fetches through the Worker but
     cannot retroactively evict what a visitor's own browser, or another
     colo, already cached before the block landed. The blocklist raises
     the cost of *lazy, repeat* abuse from a static identity to zero; it
     is not a ceiling on a motivated attacker who can create a new,
     unlinked GitHub account per campaign for free. Treat it as exactly
     that tier of control, not a security boundary.

4. Upstream fetch (only on cache miss, past the blocklist check)
   - GET https://gist.githubusercontent.com/<user>/<gistid>/raw/<sha>/<filename>
   - UNAUTHENTICATED at launch — no GITHUB_PAT (see §5 and the disposition
     at the end of this doc for why the draft's PAT plan is dropped from
     day one)
   - stream the body; abort and return 502 if it exceeds SIZE_CAP (2 MiB)
     before completing — never buffer an unbounded body first
   - if upstream returns non-200 → cache that response for 5 minutes
     (short TTL, not immutable) before returning it, so a repeated flood
     against the same fake-but-real-shaped path doesn't re-hit GitHub on
     every request. (The draft's code sketch described this mitigation in
     §5 prose but never actually implemented the cache.put for it — fixed
     here.)

5. Content validation (only on cache miss — validated once per unique SHA
   per colo, then cached forever within that colo; see the per-colo caveat
   in step 2)
   a. Generator marker check, CASE-INSENSITIVE, on the first 8 KiB:
      lowercase the slice, must contain: <meta name="generator"
      content="parfait/1">
      absent → 403 (this is the intent/ToS gate, not a security boundary)
   b. Full-body linter, CASE-INSENSITIVE, over the capped body (lowercase
      the whole decoded body once, then do cheap substring/indexOf checks
      against the lowercased copy — not per-pattern regex, since this
      still only runs once per unique SHA per colo):
      reject (403) if the lowercased body contains any of:
        "<script"      "<object"       "<embed"        "<iframe"
        "http-equiv"   "javascript:"   " src=\"http"    " src='http"
        " src=\"//"    "srcset="       "<link "         (except our own <style>)
      (Draft bug fixed: the original checks were literal lowercase
      substrings against a format that is inherently case-insensitive in
      every browser — `<SCRIPT>`, `<IFRAME SRC=...>`, and especially
      `<meta HTTP-EQUIV="Refresh" content="0;url=https://evil.com">` all
      sailed through unmodified while executing identically to their
      lowercase forms. Lowercasing the body once before all checks closes
      this for a one-character-case attacker; it does not make substring
      linting a real HTML parser — see the explicit non-goal below.)
   c. EXPLICIT NON-GOAL, stated plainly rather than implied away: this
      linter does not and cannot stop static, anchor-only phishing. Any
      GitHub user can create a gist with the required generator marker,
      zero `<script>`/`<iframe>`/external-resource references, and a
      pixel-perfect fake "your invoice is ready" page whose only
      interactive element is `<a href="https://attacker.example/...">`
      or a `tel:`/`mailto:` link. Neither the linter (which never checks
      `href=`) nor the CSP in step 6 (which governs resource loading and
      form submission, not anchor navigation) touches this. This is the
      same failure mode that got RawGit blocklisted in 2018. The only
      real backstop for it is the blocklist + abuse-report pipeline in
      §4/§8, and that is treated honestly as a residual risk, not marketed
      as solved.

6. Response — full security header stack on every response, no exceptions:
   Content-Type: text/html; charset=utf-8
   Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline';
     img-src data:; form-action 'none'; base-uri 'none'; sandbox; frame-ancestors 'none'
   X-Frame-Options: DENY
   X-Content-Type-Options: nosniff
   X-Robots-Tag: noindex, nofollow
   Referrer-Policy: no-referrer
   Cache-Control: public, max-age=31536000, immutable

   PRE-LAUNCH VERIFICATION ITEM (not assumed): test the footer's single
   outbound `<a href="https://github.com/...">` against this exact header
   in Chrome/Firefox/Safari before shipping. MDN's own reference confirms
   a bare CSP `sandbox` directive does not block plain user-initiated
   anchor-click navigation (only script-driven top-level navigation,
   popups, forms, and plugins) — so the footer link is expected to keep
   working — but this is a testable invariant, not an assumption to ship
   on faith. If any tested browser disagrees, drop `sandbox` rather than
   add `allow-top-navigation-by-user-activation` (that token would apply
   to every anchor on the page, including a phishing-style href, re-
   opening exactly what `sandbox` is there to help close).

7. Cache write
   - build the Response with the headers above, keyed on the canonical
     (lowercased-user) cache key from step 2, cache.put(), return it.
```

Minimal sketch:

```js
export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (request.method !== "GET" && request.method !== "HEAD")
      return plain(405, "Method not allowed");

    const m = url.pathname.match(
      /^\/([A-Za-z0-9-]{1,39})\/([0-9a-f]{32})\/raw\/([0-9a-f]{40})\/([A-Za-z0-9._-]{1,120}\.html)$/
    );
    if (!m || url.search !== "") return plain(400, "Bad path");
    const [, userRaw, gistId, sha, filename] = m;
    const user = userRaw.toLowerCase();

    const cacheKey = new Request(
      `https://notes.parfait.to/${user}/${gistId}/raw/${sha}/${filename}`,
      { method: "GET" }
    );
    const cache = caches.default;
    const hit = await cache.match(cacheKey);
    if (hit) return hit;

    const blockRaw = await env.BLOCKLIST.get(user);
    if (blockRaw) {
      const block = JSON.parse(blockRaw);
      if (block.blocked || block.blockedGists?.includes(gistId))
        return plain(410, "Removed", 60);
    }

    const upstream = await fetch(
      `https://gist.githubusercontent.com/${user}/${gistId}/raw/${sha}/${filename}`
    ); // unauthenticated at launch — see §5
    if (!upstream.ok) {
      const errRes = plain(upstream.status, "Not found", 300);
      ctx.waitUntil(cache.put(cacheKey, errRes.clone()));
      return errRes;
    }

    const buf = await readCapped(upstream.body, 2 * 1024 * 1024);
    if (buf === null) return plain(502, "Too large");
    const text = new TextDecoder().decode(buf);
    const lower = text.toLowerCase();

    if (!lower.slice(0, 8192).includes('<meta name="generator" content="parfait/1">'))
      return plain(403, "Not a Parfait export");
    if (containsForbidden(lower)) return plain(403, "Rejected content");

    const res = new Response(text, { headers: SECURITY_HEADERS });
    ctx.waitUntil(cache.put(cacheKey, res.clone()));
    return res;
  },
};
```

**Cache-hit invocation cost:** Free-plan Workers are always invoked before any cache lookup — there is no way to route around the Worker at the platform layer, so every repeat view still counts as one of the 100,000 requests/day. What the design buys is that a cache hit costs essentially nothing on the axes that actually matter: `caches.default.match()` is a fast early-return, well under the 10ms/invocation CPU cap, no KV read (per the reordering above), and no origin fetch to GitHub happens. Repeat views are cheap in CPU/KV/GitHub-load terms but not free in request-count terms — that's the one number to watch (see §5).

---

## 4. Abuse mitigation stack

**Launch-day (Phase 1 — stateless-first, ships this weekend):**

| Control | Implementation |
|---|---|
| Subdomain isolation | `notes.parfait.to` never shares a zone-level cookie/session with `parfait.to`; enforced structurally by being a separate Worker with no cookie-setting code path at all. |
| Full security header stack | Applied unconditionally in the single response-building path (step 6) — no code path returns a response without it. |
| Case-insensitive content linter + generator gate | Steps 5a/5b, lowercased before every check — closes the `HTTP-EQUIV`/`<SCRIPT>` case-bypass, and honestly scoped: it stops script/iframe/external-resource injection and generic hotlinking, and is explicitly documented as **not** stopping anchor-only phishing (5c). |
| Path / upstream / size enforcement | Regex in §2 restricts fetches to exactly `gist.githubusercontent.com` (no open-proxy/SSRF surface), `.html`-only, non-empty-query rejection, streaming 2 MiB abort. |
| Immutable edge caching, ordered ahead of KV | Steps 2/7 — the actual defense against repeat-view cost, now also KV-read-cheap because blocklist checks only run on miss. |
| Negative caching of upstream errors | Step 4 — a real `cache.put()` on 4xx/5xx-from-origin with a 5-minute TTL, closing a gap the draft only described in prose. |
| One Free-plan WAF rate-limit rule | `>N req/10s per IP` on `notes.parfait.to/*` — coarse, zone-shared with the marketing site's budget (§1), but a real first-line burst brake that requires zero code. |
| Cloudflare Notification/alerting policy | On Worker 5xx-rate spike and on daily request count approaching the free-tier ceiling — a few minutes of dashboard config, moved from "later" to launch-day so a request-ceiling breach (a full ~24h domain-wide outage per Cloudflare's Error 1027 behavior) is caught by Conrad, not by a bug report. |
| Minimal ToS/AUP + abuse contact | See §8. |
| Unauthenticated origin fetch (no PAT) | See §5/dispositions — deliberately deferred, not a launch gap. |

**Fast-follow (Phase 2 — ship within 1–2 weeks, once real traffic/report signal exists to size and tune it):**

- KV-backed blocklist (the `BLOCKLIST.get(user)` path in step 3 above; can ship inert/empty at launch and populated the first time it's actually needed).
- Durable-Object-backed per-owner/per-IP daily request budget — the real answer to "who gets rate-limited when someone floods the service": on the Free plan today, the honest answer is *everyone*, via the coarse WAF rule and the shared Workers/GitHub request ceilings, until this lands. This is the mechanism that actually bounds a determined flood; the WAF rule alone does not (see §5).
- Empirical test of whether an authenticated `GITHUB_PAT` origin fetch measurably changes observed throttling (see §5/dispositions) — add the PAT only if that test shows a real effect, not on the assumption it will.
- Structured abuse-report intake (form + queue) once `mailto:` stops scaling.
- DMCA designated-agent registration ($6) and CDA §230 awareness (see §8).
- File the PSL submission for `notes.parfait.to` (won't land by launch — manual review — but starts the clock).
- Heuristic phishing-shape detection, per-owner reputation/throttling, Safe Browsing/Search Console polling — once there's real abuse data to tune against.

---

## 5. Cost model

**Realistic traffic (a few thousand views/day):** Trivially within every Free-plan ceiling — Workers 100,000 req/day; KV 100,000 reads/day, now touched only on cache misses per the §3 reorder (previously the blocklist-before-cache ordering would have exhausted the KV read budget at roughly **half** the request volume needed to hit the Workers ceiling — that bug is fixed, not just documented). Egress is unmetered on all Cloudflare plans regardless of volume, so bandwidth is never the constraint. This traffic level costs **$0/month** with headroom to spare.

**Worst case — cache-bust flood** (attacker churns thousands of fake SHA/gist-ID combinations to force cache misses): malformed or non-existent combinations are rejected at step 1 (regex) or step 4 (upstream 404, now negatively cached for 5 minutes) before ever reaching the cache-write path. **What breaks first: the Workers Free 100,000 req/day request-count ceiling.** A single Free-plan WAF rule (10-second window, per-IP, zone-shared) is a real but coarse brake — it does not stop a low-and-slow flood (e.g., ~2 req/sec sustained ≈ 7,200/hr) or one distributed across many IPs. **That gap is real and is exactly what the Phase 2 Durable-Object per-owner/per-IP daily budget exists to close** — until it ships, the honest answer to "who gets rate-limited" is *the whole service, for everyone*, via the shared request ceiling or Cloudflare's own Error 1027 domain-wide throttle. This is stated as a genuine residual risk during the Phase 1 → Phase 2 window, not papered over.

**Worst case — unique-real-gist flood** (attacker scripts many genuinely new secret gists, each hit once): every unique URL is a genuine cache miss, pressuring the 100k/day Workers request budget and GitHub's unauthenticated per-IP rate limit (tightened May 2025, exact threshold undocumented, and shared across **all** Cloudflare Workers customers using overlapping egress IP ranges — not just Parfait's traffic). Negative-caching 4xx/5xx (step 4) blunts repeats of the *same* fake gist; it does not blunt a flood of many distinct ones. This is the scenario an authenticated PAT was originally proposed to help with — see the disposition below for why it's not a launch dependency.

**Explicit non-goal:** do **not** silently fall back to `gistcdn.githack.com` on parfait.to failure — that reintroduces exactly the unvetted, no-content-validation service this plan replaces. Fail closed (429/503) instead; the user-facing resilience path is the gist URL itself, or the user-facing `renderHost = .githack` setting (§6), which is independent of parfait.to uptime.

**Escape hatch:** Workers Paid, $5/month — 10M requests included (then $0.30/million), 30s CPU/invocation, materially higher KV/DO quotas. A trivial lever the moment either failure mode above is observed with real users behind it — not something to pre-emptively pay for at launch.

---

## 6. App-side changes

**`GitHubGist.swift`** — one-line host swap, changed target only (path preserved byte-for-byte per §2, so no other logic changes):

```swift
guard !raw.isEmpty,
      let rendered = URL(string: raw.replacingOccurrences(
          of: "gist.githubusercontent.com", with: "notes.parfait.to"))
else { throw GistError.failed("Could not resolve raw URL for gist \(id)") }
```

Add a `renderHost` preference in `AppSettings.swift` (enum: `.parfaitTo` default, `.githack` fallback) that the host string above reads from, rather than hard-coding `notes.parfait.to`. That gives Conrad a way to fall back to githack for *newly generated* links during a `notes.parfait.to` outage without shipping an app update — pure config, zero new logic.

**`HTMLExporter.swift`** — insert the generator marker in `<head>`, right after the existing color-scheme meta and before `<title>`:

```swift
<meta name="color-scheme" content="light dark">
<meta name="generator" content="parfait/1">
<title>\(title)</title>
```

**Fallback behavior if `notes.parfait.to` is unreachable:** `publish()` never calls `parfait.to` itself at publish time — the host swap is pure string manipulation with no network round-trip, so publishing never fails because of parfait.to being down. The failure only manifests later, when a *recipient* opens the rendered link. Because `publish()` already returns both `gist` (the `gist.github.com/...` page) and `rendered` (the CDN URL), the UI should keep surfacing both — a primary "Copy link" (rendered) and a secondary, always-available "Copy gist link" — so a user whose recipient reports a broken link has an immediate manual alternative without needing an app update or Conrad's intervention.

---

## 7. Repo + deploy layout

```
parfait/
  Sources/Parfait/...            (unchanged)
  site/                          (marketing one-pager, Workers Static Assets)
    index.html
    legal.html                   (AUP/ToS, see §8)
    wrangler.toml
  workers/
    notes-proxy/                 (the render Worker)
      src/index.ts
      wrangler.toml
      test/index.test.ts
  .github/
    ISSUE_TEMPLATE/
      abuse-report.yml
    workflows/
      deploy-notes-proxy.yml
      deploy-site.yml
```

`workers/notes-proxy/wrangler.toml` sketch:

```toml
name = "parfait-notes-proxy"
main = "src/index.ts"
compatibility_date = "2026-07-09"

routes = [
  { pattern = "notes.parfait.to/*", zone_name = "parfait.to" }
]

# Phase 2: KV namespace for the blocklist, added once populated — the
# binding can exist from day one with an empty namespace at zero cost.
[[kv_namespaces]]
binding = "BLOCKLIST"
id = "<created via wrangler kv namespace create>"

# No GITHUB_PAT secret at launch (see §5/dispositions) — Phase 2 adds one
# only if empirical testing shows it changes observed throttling:
# wrangler secret put GITHUB_PAT --env production
```

`site/wrangler.toml` sketch (same zone, separate Worker/route):

```toml
name = "parfait-site"
compatibility_date = "2026-07-09"
routes = [{ pattern = "parfait.to/*", zone_name = "parfait.to" }]

[assets]
directory = "./"
```

**Deploy:** GitHub Actions using `cloudflare/wrangler-action`, triggered on push to `main` scoped to each `workers/**` / `site/**` path, using a `CLOUDFLARE_API_TOKEN` repo secret (CI-side secret, not an app-side one). Given the solo-maintainer context, a manual `wrangler deploy` is an equally acceptable day-one path.

**Secrets needed:** none at launch. No `GITHUB_PAT` — the Worker fetches `gist.githubusercontent.com` unauthenticated at launch (see §5/dispositions for why this is deliberate, not an oversight). The one CI-side secret is `CLOUDFLARE_API_TOKEN` for automated deploys, which is optional.

---

## 8. Minimal legal/ops

- **AUP/ToS:** a short static page at `parfait.to/legal` (`site/legal.html`), linked from the marketing footer and referenced in the Worker's 403/410 error bodies. States: content must be Parfait-generated (ties to the generator marker), lists prohibited-use categories, explicitly notes that link-based social-engineering content is prohibited even though it isn't technically filtered (ties to the 5c non-goal), and gives the takedown/contact process.
- **Abuse-report route:** `mailto:abuse@parfait.to` (Cloudflare Email Routing, free, forwards to Conrad's real inbox) as the primary contact, plus a `.github/ISSUE_TEMPLATE/abuse-report.yml` for community-flagged links. An informal internal target of **same-day, best-effort** response is set explicitly — response latency, not which statute is cited, is the variable that actually matters for liability exposure given an unstaffed inbox.
- **Legal basis, stated accurately:** DMCA §512 designated-agent registration ($6 one-time, US Copyright Office) covers *copyright* claims only — it does not cover the phishing/fraud/impersonation abuse this design is actually built to resist. **CDA §230** is the relevant US shield for most non-IP third-party-content claims, noted here explicitly (the draft omitted it entirely); its protection weakens once the operator has actual knowledge and fails to act, which is exactly why the same-day response target above matters.
- **Monitoring:** Cloudflare's built-in free Workers Analytics (requests, errors, CPU time, status-code breakdown) plus the Phase-1 Notification policy (§4) is sufficient at launch. Track **both** a Search Console Domain property (apex + all subdomains) and a `parfait.to`-only property separately, since a Domain property surfaces a `notes.parfait.to` flag as "parfait.to has a security issue" on the combined dashboard — subdomain isolation reduces apex blast radius, it does not eliminate the risk that heavy phishing volume on the notes subdomain could still get the bare `parfait.to` eTLD+1 blocked by third-party corporate mail/URL-reputation gateways that score at the registrable-domain level rather than per-host. This is a real residual risk for a brand-new domain (registered 2026-07-09) with no accumulated sender/domain reputation.
- **Before enabling any future Cloudflare bot-management feature** (Bot Fight Mode, managed challenges) on the zone: verify via a live test what `Domain=` attribute Cloudflare sets on its own challenge cookies for that route. Those cookies are a Cloudflare-infrastructure code path outside the Worker's control — the "no cookie-setting code path" claim for subdomain isolation covers only cookies the Worker itself sets, not ones Cloudflare's platform layer might set once a bot-management feature is turned on.

---

## 9. Phased rollout checklist

**Phase 1 — ship this weekend (stateless-first; nothing here depends on a separate human action landing later):**

- [ ] Point `parfait.to` nameservers at Cloudflare (full zone setup); domain stays registered wherever it is today.
- [ ] Build and deploy `site/` (marketing one-pager) to `parfait.to` via Workers Static Assets.
- [ ] Build `workers/notes-proxy`: request validation (incl. query-string rejection) → cache lookup → blocklist check (KV binding present, can start empty) → unauthenticated fetch → negative-cache 4xx/5xx → case-insensitive linter → header stack → cache write, per §3.
- [ ] Deploy `notes-proxy` to `notes.parfait.to`; verify with a real secret gist end-to-end (create → resolve raw URL → hit through the Worker → confirm headers, caching, case-insensitive rejection of a hand-crafted `<SCRIPT>`/`HTTP-EQUIV` variant, and rejection of a non-Parfait gist).
- [ ] Manually test the footer's outbound `<a>` against the shipped CSP header in Chrome/Firefox/Safari (§3 step 6 verification item).
- [ ] Wire one Free-plan WAF rate-limit rule on `notes.parfait.to/*`.
- [ ] Set up a Cloudflare Notification policy for Worker error-rate spikes and daily request count.
- [ ] Add the generator-marker `<meta>` tag to `HTMLExporter.swift`.
- [ ] Add `renderHost` setting to `AppSettings.swift`; update `GitHubGist.swift`'s host swap to read it, defaulting to `notes.parfait.to`.
- [ ] Write `site/legal.html` (AUP/ToS, including the explicit non-goal disclosure) and `.github/ISSUE_TEMPLATE/abuse-report.yml`; set up `abuse@parfait.to` email routing.
- [ ] Ship a small batch of real meetings through the new pipeline; watch Workers Analytics for a few days before calling it stable.

**Phase 2 — fast-follow within 1–2 weeks (once real traffic/report signal exists to size and tune these):**

- [ ] Populate the KV blocklist workflow (currently inert/empty at launch).
- [ ] Build the Durable-Object-backed per-owner/per-IP daily request budget — this, not the WAF rule alone, is the real ceiling on a determined flood.
- [ ] Empirically test whether an authenticated `GITHUB_PAT` origin fetch changes observed GitHub throttling (`curl` with/without a PAT against the raw endpoint under load); add the secret only if the test shows a real effect.
- [ ] Register DMCA designated agent ($6, US Copyright Office).
- [ ] File the Public Suffix List PR for `notes.parfait.to` (private section) — don't gate anything on merge.
- [ ] Once `notes.parfait.to` has proven stable, flip the app default fully and consider whether `.githack` stays a permanent Settings fallback or gets removed (open question #1 below).

---

## Open questions for Conrad (max 3)

1. Keep `.githack` as a permanent, user-facing fallback option in Settings, or treat it as a temporary transition safety valve to be removed once `notes.parfait.to` has proven stable?
2. Should the generator-marker value be versioned per app release (`parfait/2`, `parfait/3`, ...) so future export-format changes can be distinguished at the proxy, or kept as a single static string indefinitely for simplicity?
3. For the DMCA agent and `abuse@parfait.to` inbox — registered under your personal name/address, or should this wait until there's an org/entity to attach it to instead?

---

## Critique dispositions

- Accepted and fixed in §3/§5: case-insensitive linter bypass; query-string cache-key bug; KV-read-before-cache ordering; per-colo Cache API mischaracterization (now documented as residual risk, not implied-global); case-variant blocklist bypass (user lowercased everywhere); missing negative-cache `cache.put()` for upstream errors; missing Phase-1 alerting.
- Accepted and fixed in §1/§8: "two isolated zones" corrected to one zone/two Workers with shared zone-wide budgets; DMCA-vs-CDA-230 scope and same-day response target added; Search Console domain-vs-host property monitoring added; future bot-management cookie-domain verification added as a pre-condition, not assumed away.
- Accepted and fixed in §4/§9: launch checklist split into a stateless Phase 1 and a Phase 2 fast-follow, so KV blocklist/WAF-rule/PAT-experiment/DMCA/PSL are no longer gating "first byte served."
- Accepted and reframed rather than "fixed" in §3/§4/§8 (can't be solved with headers/linting): anchor-only phishing residual risk is now stated as an explicit non-goal in the spec and the AUP, not implied to be covered by CSP/linter.
- **Partially accepted, with an explicit trade-off** — the draft's two PAT-related high findings pull in opposite directions: one says the shared PAT is a single point of failure and needs a Durable-Object budget *moved to launch day*; the other says the PAT's claimed rate-limit benefit is unverified and shouldn't be a launch dependency at all. Resolution: **drop the PAT from launch entirely** (adopting the second finding's fix), which also moots the first finding's specific failure mode (a shared secret bucket). The first finding's underlying concern — "who gets rate-limited during a flood" — is answered honestly in §5 as *everyone, via the shared WAF rule and request ceilings, until the Phase 2 Durable-Object budget ships* — deferred to Phase 2 per the "don't over-engineer launch" finding, rather than shipped day one, since it needs real traffic data to size correctly and the WAF rule + negative caching already cover the stateless-launch bar.
- Rejected: none outright — every confirmed finding is either fixed, reframed as an explicitly documented residual risk, or resolved via the PAT trade-off above rather than dropped.