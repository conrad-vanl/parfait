// notes.parfait.to render Worker
//
// Plain modern JavaScript ES module. No TypeScript, no build step, no
// dependencies. See docs/plans/2026-07-09-parfait-to-notes-cdn.md (the
// "Synthesis notes" blockquote at the top overrides the body) for the
// authoritative spec this implements.

const PATH_REGEX =
  /^\/([A-Za-z0-9-]{1,39})\/([0-9a-f]{20,32})\/raw\/([0-9a-f]{40})\/([A-Za-z0-9._-]{1,120}\.html)$/;

const SIZE_CAP_BYTES = 2 * 1024 * 1024; // 2 MiB

const GENERATOR_MARKER = '<meta name="generator" content="parfait/1">';

// Tag-opener substrings that are never legitimate in a Parfait export, since
// HTMLExporter escapes `<` in all user-derived text (transcript, notes).
// Deliberately NOT bare substrings like "javascript:" or "http-equiv" alone
// (see synthesis note: those occur legitimately as plain transcript text,
// e.g. someone dictating a URL scheme or an HTML attribute name out loud).
const FORBIDDEN_TAG_OPENERS = [
  '<script',
  '<iframe',
  '<object',
  '<embed',
  '<link',
  '<base',
  '<form',
];

// Exact header set for a successful 200 response. Bounded TTLs (not
// max-age=31536000/immutable) per the synthesis note: the marketing promise
// "delete the gist and the link dies" requires content to actually expire
// from caches, not serve forever.
export const SECURITY_HEADERS = {
  'Content-Type': 'text/html; charset=utf-8',
  'Content-Security-Policy':
    "default-src 'none'; style-src 'unsafe-inline'; img-src data:; form-action 'none'; base-uri 'none'; sandbox; frame-ancestors 'none'",
  'X-Frame-Options': 'DENY',
  'X-Content-Type-Options': 'nosniff',
  'X-Robots-Tag': 'noindex, nofollow',
  'Referrer-Policy': 'no-referrer',
  'Cache-Control': 'public, max-age=3600, s-maxage=86400',
};

/**
 * Parse and validate a request path against the gist raw-URL shape.
 * Returns { user, gistId, sha, filename } with `user` already lowercased,
 * or null if the path doesn't match.
 */
export function parsePath(pathname) {
  const m = PATH_REGEX.exec(pathname);
  if (!m) return null;
  const [, userRaw, gistId, sha, filename] = m;
  return { user: userRaw.toLowerCase(), gistId, sha, filename };
}

/**
 * Case-insensitive generator-marker gate. `lowerBody` must already be
 * lowercased by the caller (decode once, lowercase once).
 */
export function hasGeneratorMarker(lowerBody) {
  return lowerBody.slice(0, 8192).includes(GENERATOR_MARKER);
}

/**
 * Returns true if any `<meta ...>` tag in the lowercased body carries an
 * `http-equiv` attribute (which enables no-JS redirects like
 * `<meta http-equiv="refresh" content="0;url=…">` that the CSP does not stop).
 *
 * The tag span is delimited by tracking quote state: a `<meta` tag ends at the
 * first `>` that is NOT inside a `"…"`/`'…'` attribute value. Neither `<` nor
 * `>` inside a quoted value can end the tag early, which closes both span-
 * truncation bypasses — `<meta content=">" http-equiv=…>` (early `>`) and
 * `<meta data-x="<" http-equiv=…>` (early `<`). Attribute names are literal in
 * HTML (no entity encoding), so a substring test for `http-equiv` on the
 * correctly-delimited, already-lowercased span is exact. A legitimate Parfait
 * export's four <meta> tags (charset, viewport, color-scheme, generator) never
 * carry http-equiv.
 */
function hasForbiddenMeta(lowerBody) {
  const START = '<meta';
  let idx = lowerBody.indexOf(START);
  while (idx !== -1) {
    let quote = '';
    let end = lowerBody.length;
    for (let i = idx + START.length; i < lowerBody.length; i++) {
      const ch = lowerBody[i];
      if (quote) {
        if (ch === quote) quote = '';
      } else if (ch === '"' || ch === "'") {
        quote = ch;
      } else if (ch === '>') {
        end = i;
        break;
      }
    }
    if (lowerBody.slice(idx, end).includes('http-equiv')) return true;
    idx = lowerBody.indexOf(START, idx + START.length);
  }
  return false;
}

/**
 * Full-body linter. `lowerBody` must already be lowercased by the caller.
 * Returns true if the body should be REJECTED (i.e. contains a forbidden
 * tag-opener context). Tag-opener contexts only, per the synthesis note's
 * amendment — bare substrings like "javascript:" or "srcset=" are legit
 * transcript text and must not be flagged.
 */
export function lintBody(lowerBody) {
  for (const needle of FORBIDDEN_TAG_OPENERS) {
    if (lowerBody.includes(needle)) return true;
  }
  return hasForbiddenMeta(lowerBody);
}

/**
 * Reads a ReadableStream up to `capBytes`. Returns the concatenated bytes
 * as a Uint8Array on success, or null if the stream exceeded the cap
 * (aborting/cancelling the reader rather than buffering further). Never
 * buffers unbounded input.
 */
export async function readCapped(body, capBytes) {
  if (!body) return new Uint8Array(0);
  const reader = body.getReader();
  const chunks = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > capBytes) {
      try {
        await reader.cancel();
      } catch {
        // ignore — we're already rejecting this body
      }
      return null;
    }
    chunks.push(value);
  }
  const buf = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    buf.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return buf;
}

/**
 * Blocklist check. Tolerates env.BLOCKLIST being absent/undefined (launch
 * ships it inert) and malformed JSON (fails open with a console warning) —
 * a blocklist outage must never take the whole service down.
 */
export async function isBlocked(env, user, gistId) {
  if (!env || !env.BLOCKLIST || typeof env.BLOCKLIST.get !== 'function') return false;

  let raw;
  try {
    raw = await env.BLOCKLIST.get(user);
  } catch (err) {
    console.warn(`BLOCKLIST.get failed for user "${user}":`, err);
    return false;
  }
  if (!raw) return false;

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    console.warn(`BLOCKLIST value for user "${user}" is malformed JSON:`, err);
    return false;
  }
  if (!parsed || typeof parsed !== 'object') return false;

  if (parsed.blocked === true) return true;
  if (Array.isArray(parsed.blockedGists) && parsed.blockedGists.includes(gistId)) return true;
  return false;
}

function plainResponse(status, body, cacheMaxAge, extraHeaders) {
  const headers = new Headers({ 'Content-Type': 'text/plain; charset=utf-8' });
  if (cacheMaxAge != null) headers.set('Cache-Control', `max-age=${cacheMaxAge}`);
  if (extraHeaders) {
    for (const [key, value] of Object.entries(extraHeaders)) headers.set(key, value);
  }
  return new Response(body, { status, headers });
}

// For HEAD requests, return the same status/headers with a null body.
function finalizeForMethod(response, method) {
  if (method !== 'HEAD') return response;
  return new Response(null, { status: response.status, headers: response.headers });
}

function buildCacheKey(user, gistId, sha, filename) {
  return new Request(`https://notes.parfait.to/${user}/${gistId}/raw/${sha}/${filename}`, {
    method: 'GET',
  });
}

export default {
  async fetch(request, env, ctx) {
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return plainResponse(405, 'Method Not Allowed', null, { Allow: 'GET, HEAD' });
    }

    const url = new URL(request.url);
    if (url.search !== '') {
      // max-age is a client-side hint only; these garbage-path responses are
      // deliberately NOT written to the edge cache (that would let random paths
      // fill it with unbounded-cardinality junk). The WAF rate-limit rule on
      // notes.parfait.to/* is the real scanner-flood brake — see docs/DEPLOY.md.
      return finalizeForMethod(plainResponse(400, 'Bad Request', 60), request.method);
    }

    const parsed = parsePath(url.pathname);
    if (!parsed) {
      return finalizeForMethod(plainResponse(400, 'Bad Request', 60), request.method);
    }
    const { user, gistId, sha, filename } = parsed;

    const cache = caches.default;
    const cacheKey = buildCacheKey(user, gistId, sha, filename);

    const cached = await cache.match(cacheKey);
    if (cached) {
      return finalizeForMethod(cached, request.method);
    }

    const blocked = await isBlocked(env, user, gistId);
    if (blocked) {
      return finalizeForMethod(plainResponse(410, 'Gone', 60), request.method);
    }

    const upstreamUrl = `https://gist.githubusercontent.com/${user}/${gistId}/raw/${sha}/${filename}`;
    let upstream;
    try {
      upstream = await fetch(upstreamUrl, { signal: AbortSignal.timeout(5000) });
    } catch (err) {
      // Timeout or network error — not negative-cached (transient), per spec.
      return finalizeForMethod(plainResponse(502, 'Upstream fetch failed'), request.method);
    }

    if (!upstream.ok) {
      const status = upstream.status === 404 ? 404 : 502;
      const res = plainResponse(status, 'Upstream error', 300);
      ctx.waitUntil(cache.put(cacheKey, res.clone()));
      return finalizeForMethod(res, request.method);
    }

    const bytes = await readCapped(upstream.body, SIZE_CAP_BYTES);
    if (bytes === null) {
      const res = plainResponse(502, 'Response too large', 300);
      ctx.waitUntil(cache.put(cacheKey, res.clone()));
      return finalizeForMethod(res, request.method);
    }

    const text = new TextDecoder('utf-8').decode(bytes);
    const lower = text.toLowerCase();

    if (!hasGeneratorMarker(lower)) {
      const res = plainResponse(403, 'Not a Parfait export', 300);
      ctx.waitUntil(cache.put(cacheKey, res.clone()));
      return finalizeForMethod(res, request.method);
    }

    if (lintBody(lower)) {
      const res = plainResponse(403, 'Rejected content', 300);
      ctx.waitUntil(cache.put(cacheKey, res.clone()));
      return finalizeForMethod(res, request.method);
    }

    const res = new Response(text, { status: 200, headers: new Headers(SECURITY_HEADERS) });
    ctx.waitUntil(cache.put(cacheKey, res.clone()));
    return finalizeForMethod(res, request.method);
  },
};
