# Deploying parfait.to

A Conrad-facing runbook for standing up `parfait.to` (marketing site) and
`notes.parfait.to` (the rendered-notes proxy) on Cloudflare, plus the ongoing
operations that go with running them.

**Read first:**
- [`docs/plans/2026-07-09-parfait-to-notes-cdn.md`](plans/2026-07-09-parfait-to-notes-cdn.md) —
  authoritative for the Worker spec, URL scheme, security headers, and legal/ops.
- [`docs/plans/2026-07-09-parfait-to-marketing-site.md`](plans/2026-07-09-parfait-to-marketing-site.md) —
  the marketing one-pager's copy, design, and IA.

Repo layout this runbook assumes: `site/` (marketing one-pager, Workers Static
Assets) and `workers/notes-proxy/` (the render Worker) at the repo root.

---

## First deploy

1. **Create the Cloudflare account and zone.** Sign up (or use an existing
   account) at [dash.cloudflare.com](https://dash.cloudflare.com), add
   `parfait.to` as a site, and choose the **Free** plan.

2. **Repoint nameservers at Namecheap.** Cloudflare assigns two nameservers
   when the zone is created. In Namecheap's dashboard for `parfait.to`,
   replace the existing (default parking) nameservers with those two. This is
   the one step that happens outside Cloudflare, and everything else below
   depends on it having propagated (Cloudflare's dashboard shows the zone as
   "Active" once it has).

3. **Authenticate `wrangler`.** From either `site/` or `workers/notes-proxy/`:
   ```bash
   wrangler login
   ```
   This opens a browser to authorize the CLI against the Cloudflare account
   from step 1.

4. **Create the `BLOCKLIST` KV namespace.**
   ```bash
   wrangler kv namespace create BLOCKLIST
   ```
   Copy the `id` it prints and paste it into the `[[kv_namespaces]]` block in
   `workers/notes-proxy/wrangler.toml`. It's fine for this namespace to start
   empty — the Worker's blocklist check (CDN plan §3 step 3) is inert until
   the first entry is written (see **Takedown SOP** below).

5. **Deploy the Worker.**
   ```bash
   cd workers/notes-proxy
   wrangler deploy
   ```
   Both `wrangler.toml` files use **Custom Domain** routes
   (`custom_domain = true`), so this one command provisions the
   `notes.parfait.to` DNS record *and* its TLS certificate for you — there is
   no separate "add a DNS record" or "add a custom domain" dashboard step, and
   nothing to do by hand to avoid `ERR_NAME_NOT_RESOLVED`. First provisioning
   can take a minute or two for the cert to go live.

6. **Deploy the site.**
   ```bash
   cd site
   wrangler deploy
   ```
   Same mechanism (Workers Static Assets), and likewise provisions the
   `parfait.to` **and** `www.parfait.to` DNS records + certs from the
   `custom_domain` routes in `site/wrangler.toml`. Both hostnames serve the
   page; the `<link rel="canonical">` in `index.html` points search engines at
   the apex.

7. **(Optional) www → apex redirect.** If you'd rather `www.parfait.to`
   *redirect* to the apex instead of serving a duplicate page, add a Cloudflare
   Redirect Rule (Rules → Redirect Rules): `www.parfait.to/*` →
   `https://parfait.to/${1}` (301). Not required — the canonical tag already
   handles duplicate-content concerns.

8. **SSL/TLS.** Set the zone's SSL/TLS mode to **Full (strict)** and enable
   **Always Use HTTPS** (SSL/TLS → Edge Certificates).

9. **WAF rate-limiting rule.** Add one Free-plan rate-limiting rule scoped to
    `notes.parfait.to/*` (Security → WAF → Rate limiting rules) — a coarse
    per-IP burst brake shared, on the Free plan, with the rest of the zone's
    rule budget (CDN plan §1, §4).

10. **Notification policies.** Under Notifications, add:
    - a policy on Worker error-rate spikes (5xx rate) for both Workers, and
    - a policy for daily request count approaching the 100,000/day Workers
      Free-plan ceiling.
    Both are cheap dashboard config and catch a request-ceiling breach (a
    full ~24h domain-wide outage per Cloudflare's Error 1027 behavior) before
    a user reports it (CDN plan §4, §8).

11. **(Optional) CI deploys.** Add `CLOUDFLARE_API_TOKEN` as a repo secret
    (Settings → Secrets and variables → Actions) to enable
    `.github/workflows/deploy-site.yml` and
    `.github/workflows/deploy-notes-proxy.yml`. Both skip cleanly (no failed
    run) until this secret exists; a manual `wrangler deploy` from steps 5/7
    is an equally valid path for a solo maintainer.

---

## Operations

### Takedown SOP

Two layers, matching the CDN plan's documented KV-propagation and cache
limits (§3 step 3, §5):

1. **Immediate removal from the edge cache.** Cloudflare dashboard → Caching
   → Configuration → Purge Cache → Custom Purge, and enter the exact
   `notes.parfait.to/...` URL(s). This clears Cloudflare's edge copy right
   away; the next request to that URL is a cache miss and re-runs the full
   validation pipeline (including the blocklist check below) before serving
   anything.

2. **Durable block, so it doesn't just come back.** From
   `workers/notes-proxy`:
   ```bash
   # Block an entire GitHub user:
   wrangler kv key put --binding=BLOCKLIST "<username>" '{"blocked":true}'

   # Block one specific gist, leaving the rest of the user's gists servable:
   wrangler kv key put --binding=BLOCKLIST "<username>" '{"blockedGists":["<gistid>"]}'
   ```
   `<username>` must be lowercase (the Worker lowercases it before every
   lookup — CDN plan §2). KV writes are only eventually consistent (commonly
   cited up to ~60s propagation), and this stops *new* fetches through the
   Worker — it does not retroactively evict a copy a visitor's browser (or
   another Cloudflare colo) already cached before the block landed. Treat it
   as raising the cost of repeat abuse to zero, not as a hard security
   ceiling (CDN plan §3 step 3, §4).

Community-flagged links come in via the
[`abuse-report.yml`](../.github/ISSUE_TEMPLATE/abuse-report.yml) issue
template — that's the canonical intake route (no DMCA agent or `abuse@`
inbox yet, per Conrad's decision).

### Post-deploy verification checklist

Run this after every first deploy, and spot-check the last three items after
any Worker change:

- [ ] **End-to-end publish.** Publish one real meeting from the app; confirm
      the resulting `notes.parfait.to` link renders correctly in both light
      and dark system appearance.
- [ ] **CSP footer-link click test.** Click the rendered page's single
      outbound `<a href="https://github.com/...">` footer link in Chrome,
      Firefox, and Safari and confirm it still navigates under the shipped
      CSP (`sandbox` should block script-driven navigation, not a plain
      user-initiated anchor click — CDN plan §3 step 6).
- [ ] **Malformed paths → 400.** Wrong segment count, non-hex IDs, path
      traversal, missing/incorrect extension, and a non-empty query string
      all return 400 before any upstream fetch.
- [ ] **Forged content → 403.** A hand-crafted gist containing a
      case-varied `<SCRIPT>` or `HTTP-EQUIV` tag (with the generator marker
      present) is rejected by the linter.
- [ ] **Non-Parfait gist → 403.** A gist without the
      `<meta name="generator" content="parfait/1">` marker is rejected.
- [ ] **Deleted gist stops serving within TTL.** Delete a published gist and
      confirm the rendered link stops serving within the bounded cache
      window — up to ~1 day at the edge (`s-maxage=86400`), up to ~1 hour in
      a browser that already cached it (`max-age=3600`); immediate removal
      is always available via the purge-by-URL step above.
