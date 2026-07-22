// notes.parfait.to render Worker
//
// Plain modern JavaScript ES module. No TypeScript, no build step, no
// dependencies. See docs/plans/2026-07-09-parfait-to-notes-cdn.md (the
// "Synthesis notes" blockquote at the top overrides the body) for the
// authoritative spec this implements.
//
// NOTE (2026-07-09): the public URL scheme was changed from the doc's
// /user/gistId/raw/sha/file.html path to a single opaque base64url token
// (see parsePath + Sources/Parfait/Publish/GistLinkToken.swift) so the link
// no longer exposes the GitHub username or gist path. The upstream fetch,
// validation, and caching are otherwise unchanged.

// The public URL is a single opaque base64url token the Parfait app produces
// (Sources/Parfait/Publish/GistLinkToken.swift). It packs the gist coordinates
// so the GitHub username and gist path never appear in the link. We decode it
// back to (user, gist id, commit SHA) and reattach the constant filename before
// fetching upstream. Byte layout: [1B user length][user][gist-id bytes][20B SHA]
// — the SHA is the fixed-length tail, so the gist id needs no length prefix.
const TOKEN_REGEX = /^\/([A-Za-z0-9_-]{1,512})$/;
const FILENAME = 'meeting.html';
const USER_REGEX = /^[a-z0-9-]{1,39}$/; // checked after lowercasing
const GIST_ID_REGEX = /^[0-9a-f]{20,32}$/;
const SHA_REGEX = /^[0-9a-f]{40}$/;

const SIZE_CAP_BYTES = 2 * 1024 * 1024; // 2 MiB

const GENERATOR_MARKER = '<meta name="generator" content="parfait/1">';

// Serve-time page-URL substitution: an export can't know its own public URL at
// render time (the token pins the content hash), so the app bakes this inert
// marker into "Hand to Claude" hrefs and the Worker fills in the real URL when
// serving. The replacement is percent-encoded (letters, digits, '%' only), so
// it can never introduce markup or a forbidden tag opener. Contract with
// Sources/Parfait/Intelligence/ClaudeLink.swift (pageURLMarker).
export const PAGE_URL_MARKER = 'PARFAIT_PAGE_URL';

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
 * Reads a base64url token (no padding) into raw bytes, or null if it isn't
 * valid base64url. Tolerant of missing padding; rejects impossible lengths.
 */
function base64UrlToBytes(token) {
  let b64 = token.replace(/-/g, '+').replace(/_/g, '/');
  const remainder = b64.length % 4;
  if (remainder === 1) return null; // never a valid base64 length
  if (remainder !== 0) b64 += '='.repeat(4 - remainder);
  let binary;
  try {
    binary = atob(b64);
  } catch {
    return null;
  }
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function bytesToHex(bytes) {
  let hex = '';
  for (const b of bytes) hex += b.toString(16).padStart(2, '0');
  return hex;
}

/**
 * Decode and validate the opaque link token. Returns
 * { user, gistId, sha, filename } with `user` lowercased, or null if the token
 * is malformed or decodes to coordinates that fail the strict charset/length
 * checks. Those checks also close any SSRF path: the upstream URL we build only
 * ever contains validated lowercase-hex plus a [a-z0-9-] username.
 */
export function parsePath(pathname) {
  const m = TOKEN_REGEX.exec(pathname);
  if (!m) return null;
  const bytes = base64UrlToBytes(m[1]);
  if (!bytes || bytes.length < 1) return null;
  const userLen = bytes[0];
  // Need: length byte + >=1 user byte + >=1 gist byte + 20 SHA bytes.
  if (userLen < 1 || bytes.length < 1 + userLen + 1 + 20) return null;
  let user;
  try {
    user = new TextDecoder('utf-8', { fatal: true })
      .decode(bytes.subarray(1, 1 + userLen))
      .toLowerCase();
  } catch {
    return null;
  }
  const rest = bytes.subarray(1 + userLen);
  const gistId = bytesToHex(rest.subarray(0, rest.length - 20));
  const sha = bytesToHex(rest.subarray(rest.length - 20));
  if (!USER_REGEX.test(user) || !GIST_ID_REGEX.test(gistId) || !SHA_REGEX.test(sha)) {
    return null;
  }
  return { user, gistId, sha, filename: FILENAME };
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

    // Substituted body is cached as-is: the cache key and the served path both
    // derive from the same (user, gistId, sha) tuple, so the baked-in URL is
    // stable for every request that can hit this entry.
    const pageUrl = encodeURIComponent(`${url.origin}${url.pathname}`);
    const body = text.replaceAll(PAGE_URL_MARKER, pageUrl);
    const res = new Response(body, { status: 200, headers: new Headers(SECURITY_HEADERS) });
    ctx.waitUntil(cache.put(cacheKey, res.clone()));
    return finalizeForMethod(res, request.method);
  },
};
