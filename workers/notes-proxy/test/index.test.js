import { test, describe, beforeEach } from 'node:test';
import assert from 'node:assert/strict';

import worker, {
  parsePath,
  lintBody,
  hasGeneratorMarker,
  SECURITY_HEADERS,
  isBlocked,
} from '../src/index.js';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const USER = 'octocat';
const GIST_32 = 'a'.repeat(32); // real-shape 32-hex gist id
const GIST_20 = 'b'.repeat(20); // legacy-shape 20-hex gist id
const SHA_40 = 'c'.repeat(40);
const FILENAME = 'meeting-notes.html';

function pathFor(user, gist, sha, filename) {
  return `/${user}/${gist}/raw/${sha}/${filename}`;
}

const GENERATOR_META = '<meta name="generator" content="parfait/1">';

function realisticDoc({ generator = GENERATOR_META, extra = '' } = {}) {
  return `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
${generator}
<title>Meeting notes</title>
</head>
<body>
<h1>Meeting notes</h1>
<p>Transcript: &quot;let&#39;s use javascript: in the console and set http-equiv on the meta tag, also srcset= for images.&quot;</p>
${extra}
</body>
</html>`;
}

// ---------------------------------------------------------------------------
// Fake Cache API (Map-backed) + stub ctx/env helpers
// ---------------------------------------------------------------------------

class FakeCache {
  constructor() {
    this.store = new Map();
  }
  async match(req) {
    const key = typeof req === 'string' ? req : req.url;
    const entry = this.store.get(key);
    return entry ? entry.clone() : undefined;
  }
  async put(req, res) {
    const key = typeof req === 'string' ? req : req.url;
    this.store.set(key, res.clone());
  }
}

function installFakeCache() {
  const cache = new FakeCache();
  globalThis.caches = { default: cache };
  return cache;
}

function makeCtx() {
  const tasks = [];
  return {
    ctx: {
      waitUntil(promise) {
        tasks.push(promise);
      },
    },
    async flush() {
      await Promise.all(tasks);
    },
  };
}

// Minimal fake ReadableStream-alike backed by a single Uint8Array, exposing
// just the getReader().read()/cancel() surface readCapped() uses.
function streamFromBytes(bytes) {
  let sent = false;
  return {
    getReader() {
      return {
        async read() {
          if (sent) return { done: true, value: undefined };
          sent = true;
          return { done: false, value: bytes };
        },
        async cancel() {
          sent = true;
        },
      };
    },
  };
}

// Fake stream that reports being larger than `totalBytes`, delivered in
// chunks, without ever allocating the whole thing eagerly.
function streamOfSize(totalBytes, chunkSize = 64 * 1024) {
  let sent = 0;
  return {
    getReader() {
      return {
        async read() {
          if (sent >= totalBytes) return { done: true, value: undefined };
          const size = Math.min(chunkSize, totalBytes - sent);
          sent += size;
          return { done: false, value: new Uint8Array(size) };
        },
        async cancel() {
          sent = totalBytes;
        },
      };
    },
  };
}

function fakeUpstream(status, text) {
  return {
    ok: status >= 200 && status < 300,
    status,
    body: streamFromBytes(new TextEncoder().encode(text ?? '')),
  };
}

function installFetchStub(impl) {
  const orig = globalThis.fetch;
  globalThis.fetch = impl;
  return () => {
    globalThis.fetch = orig;
  };
}

function makeRequest(pathname, { method = 'GET', search = '' } = {}) {
  return new Request(`https://notes.parfait.to${pathname}${search}`, { method });
}

// ---------------------------------------------------------------------------
// Pure helper: parsePath — accept cases
// ---------------------------------------------------------------------------

describe('parsePath — accept', () => {
  test('real 32-hex gist shape', () => {
    const result = parsePath(pathFor(USER, GIST_32, SHA_40, FILENAME));
    assert.deepEqual(result, { user: USER, gistId: GIST_32, sha: SHA_40, filename: FILENAME });
  });

  test('legacy 20-hex gist shape', () => {
    const result = parsePath(pathFor(USER, GIST_20, SHA_40, FILENAME));
    assert.deepEqual(result, { user: USER, gistId: GIST_20, sha: SHA_40, filename: FILENAME });
  });

  test('uppercase user is lowercased', () => {
    const result = parsePath(pathFor('OctoCat', GIST_32, SHA_40, FILENAME));
    assert.equal(result.user, 'octocat');
  });
});

// ---------------------------------------------------------------------------
// Pure helper: parsePath — reject cases
// ---------------------------------------------------------------------------

describe('parsePath — reject', () => {
  test('missing /raw/ segment', () => {
    assert.equal(parsePath(`/${USER}/${GIST_32}/${SHA_40}/${FILENAME}`), null);
  });

  test('.htm extension rejected', () => {
    assert.equal(parsePath(pathFor(USER, GIST_32, SHA_40, 'notes.htm')), null);
  });

  test('no extension rejected', () => {
    assert.equal(parsePath(pathFor(USER, GIST_32, SHA_40, 'notes')), null);
  });

  test('39-hex sha rejected (must be exactly 40)', () => {
    assert.equal(parsePath(pathFor(USER, GIST_32, 'c'.repeat(39), FILENAME)), null);
  });

  test('33-hex gist id rejected (cap is 32)', () => {
    assert.equal(parsePath(pathFor(USER, 'a'.repeat(33), SHA_40, FILENAME)), null);
  });

  test('traversal attempt in filename rejected', () => {
    assert.equal(parsePath(pathFor(USER, GIST_32, SHA_40, '../../../etc/passwd.html')), null);
  });

  test('empty filename rejected', () => {
    assert.equal(parsePath(pathFor(USER, GIST_32, SHA_40, '.html')), null);
  });
});

// ---------------------------------------------------------------------------
// Pure helper: hasGeneratorMarker
// ---------------------------------------------------------------------------

describe('hasGeneratorMarker', () => {
  test('present passes', () => {
    assert.equal(hasGeneratorMarker(realisticDoc().toLowerCase()), true);
  });

  test('absent fails', () => {
    assert.equal(hasGeneratorMarker(realisticDoc({ generator: '' }).toLowerCase()), false);
  });

  test('uppercase marker variant passes (case-insensitive)', () => {
    const doc = realisticDoc({ generator: '<META NAME="GENERATOR" CONTENT="PARFAIT/1">' });
    assert.equal(hasGeneratorMarker(doc.toLowerCase()), true);
  });
});

// ---------------------------------------------------------------------------
// Pure helper: lintBody
// ---------------------------------------------------------------------------

describe('lintBody', () => {
  test('realistic transcript with javascript:, http-equiv, srcset= as plain text PASSES', () => {
    assert.equal(lintBody(realisticDoc().toLowerCase()), false);
  });

  test('<SCRIPT> (uppercase) rejects', () => {
    const doc = realisticDoc({ extra: '<SCRIPT>alert(1)</SCRIPT>' });
    assert.equal(lintBody(doc.toLowerCase()), true);
  });

  test('<iFrAmE (mixed case) rejects', () => {
    const doc = realisticDoc({ extra: '<iFrAmE src="https://evil.example"></iFrAmE>' });
    assert.equal(lintBody(doc.toLowerCase()), true);
  });

  test('<meta HTTP-EQUIV="refresh"> rejects', () => {
    const doc = realisticDoc({ extra: '<meta HTTP-EQUIV="refresh" content="0;url=https://evil.example">' });
    assert.equal(lintBody(doc.toLowerCase()), true);
  });

  test('<form rejects', () => {
    const doc = realisticDoc({ extra: '<form action="https://evil.example"></form>' });
    assert.equal(lintBody(doc.toLowerCase()), true);
  });

  // Bypass regressions: neither `>` nor `<` inside a quoted attribute value may
  // truncate the <meta> span before the linter reaches http-equiv.
  test('http-equiv smuggled behind a quoted ">" rejects', () => {
    const doc = realisticDoc({ extra: '<meta content=">" http-equiv="refresh" data-x="0;url=https://evil.example">' });
    assert.equal(lintBody(doc.toLowerCase()), true);
  });

  test('http-equiv smuggled behind a quoted "<" rejects', () => {
    const doc = realisticDoc({ extra: '<meta data-decoy="<" http-equiv="refresh" content="0;url=https://evil.example">' });
    assert.equal(lintBody(doc.toLowerCase()), true);
  });

  test('http-equiv with a single-quoted "<" decoy rejects', () => {
    const doc = realisticDoc({ extra: "<meta data-decoy='<' http-equiv='refresh' content='0;url=https://evil.example'>" });
    assert.equal(lintBody(doc.toLowerCase()), true);
  });

  test('unterminated quote before http-equiv still rejects (fails safe)', () => {
    const doc = realisticDoc({ extra: '<meta data-x="  http-equiv=refresh content=0;url=https://evil.example>' });
    assert.equal(lintBody(doc.toLowerCase()), true);
  });
});

// ---------------------------------------------------------------------------
// Handler-level tests (stub globals: caches, fetch, env, ctx)
// ---------------------------------------------------------------------------

describe('handler', () => {
  let restoreFetch;

  beforeEach(() => {
    installFakeCache();
  });

  test('405 for POST, with Allow header', async () => {
    const { ctx } = makeCtx();
    const req = makeRequest(pathFor(USER, GIST_32, SHA_40, FILENAME), { method: 'POST' });
    const res = await worker.fetch(req, {}, ctx);
    assert.equal(res.status, 405);
    assert.equal(res.headers.get('Allow'), 'GET, HEAD');
  });

  test('400 for query string present', async () => {
    const { ctx } = makeCtx();
    const req = makeRequest(pathFor(USER, GIST_32, SHA_40, FILENAME), { search: '?x=1' });
    const res = await worker.fetch(req, {}, ctx);
    assert.equal(res.status, 400);
    assert.equal(res.headers.get('Cache-Control'), 'max-age=60');
  });

  test('400 for malformed path', async () => {
    const { ctx } = makeCtx();
    const req = makeRequest(`/${USER}/not-hex/raw/${SHA_40}/${FILENAME}`);
    const res = await worker.fetch(req, {}, ctx);
    assert.equal(res.status, 400);
  });

  test('HEAD on malformed path returns 400 with a null body', async () => {
    const { ctx } = makeCtx();
    const req = makeRequest(`/${USER}/not-hex/raw/${SHA_40}/${FILENAME}`, { method: 'HEAD' });
    const res = await worker.fetch(req, {}, ctx);
    assert.equal(res.status, 400);
    assert.equal(await res.text(), '');
  });

  test('HEAD on query-string path returns 400 with a null body', async () => {
    const { ctx } = makeCtx();
    const req = makeRequest(pathFor(USER, GIST_32, SHA_40, FILENAME), { method: 'HEAD', search: '?x=1' });
    const res = await worker.fetch(req, {}, ctx);
    assert.equal(res.status, 400);
    assert.equal(await res.text(), '');
  });

  test('uppercase USER path is lowercased in the cache key', async () => {
    const cache = installFakeCache();
    const { ctx, flush } = makeCtx();
    restoreFetch = installFetchStub(async () => fakeUpstream(200, realisticDoc()));

    const req = makeRequest(pathFor('OctoCat', GIST_32, SHA_40, FILENAME));
    const res = await worker.fetch(req, {}, ctx);
    await flush();
    restoreFetch();

    assert.equal(res.status, 200);
    const expectedKey = `https://notes.parfait.to/${USER}/${GIST_32}/raw/${SHA_40}/${FILENAME}`;
    assert.ok(cache.store.has(expectedKey), 'cache key must use the lowercased user segment');
  });

  test('marker gate: present passes (200)', async () => {
    restoreFetch = installFetchStub(async () => fakeUpstream(200, realisticDoc()));
    const { ctx } = makeCtx();
    const req = makeRequest(pathFor(USER, GIST_32, SHA_40, FILENAME));
    const res = await worker.fetch(req, {}, ctx);
    restoreFetch();
    assert.equal(res.status, 200);
  });

  test('marker gate: absent fails (403)', async () => {
    restoreFetch = installFetchStub(async () => fakeUpstream(200, realisticDoc({ generator: '' })));
    const { ctx } = makeCtx();
    const req = makeRequest(pathFor(USER, GIST_32, SHA_40, FILENAME));
    const res = await worker.fetch(req, {}, ctx);
    restoreFetch();
    assert.equal(res.status, 403);
  });

  test('marker gate: UPPERCASE marker variant passes', async () => {
    const doc = realisticDoc({ generator: '<META NAME="GENERATOR" CONTENT="PARFAIT/1">' });
    restoreFetch = installFetchStub(async () => fakeUpstream(200, doc));
    const { ctx } = makeCtx();
    const req = makeRequest(pathFor(USER, GIST_32, SHA_40, FILENAME));
    const res = await worker.fetch(req, {}, ctx);
    restoreFetch();
    assert.equal(res.status, 200);
  });

  test('linter: <SCRIPT> rejects with 403', async () => {
    const doc = realisticDoc({ extra: '<SCRIPT>alert(1)</SCRIPT>' });
    restoreFetch = installFetchStub(async () => fakeUpstream(200, doc));
    const { ctx } = makeCtx();
    const req = makeRequest(pathFor(USER, GIST_32, SHA_40, FILENAME));
    const res = await worker.fetch(req, {}, ctx);
    restoreFetch();
    assert.equal(res.status, 403);
  });

  test('headers: exact CSP string and Cache-Control on a 200', async () => {
    restoreFetch = installFetchStub(async () => fakeUpstream(200, realisticDoc()));
    const { ctx } = makeCtx();
    const req = makeRequest(pathFor(USER, GIST_32, SHA_40, FILENAME));
    const res = await worker.fetch(req, {}, ctx);
    restoreFetch();

    assert.equal(res.status, 200);
    assert.equal(res.headers.get('Content-Type'), 'text/html; charset=utf-8');
    assert.equal(
      res.headers.get('Content-Security-Policy'),
      "default-src 'none'; style-src 'unsafe-inline'; img-src data:; form-action 'none'; base-uri 'none'; sandbox; frame-ancestors 'none'"
    );
    assert.equal(res.headers.get('X-Frame-Options'), 'DENY');
    assert.equal(res.headers.get('X-Content-Type-Options'), 'nosniff');
    assert.equal(res.headers.get('X-Robots-Tag'), 'noindex, nofollow');
    assert.equal(res.headers.get('Referrer-Policy'), 'no-referrer');
    assert.equal(res.headers.get('Cache-Control'), 'public, max-age=3600, s-maxage=86400');
  });

  test('blocklist: blocked user -> 410', async () => {
    const env = {
      BLOCKLIST: { async get() { return JSON.stringify({ blocked: true, blockedGists: [] }); } },
    };
    const { ctx } = makeCtx();
    const req = makeRequest(pathFor(USER, GIST_32, SHA_40, FILENAME));
    const res = await worker.fetch(req, env, ctx);
    assert.equal(res.status, 410);
  });

  test('blocklist: gist in blockedGists -> 410', async () => {
    const env = {
      BLOCKLIST: {
        async get() {
          return JSON.stringify({ blocked: false, blockedGists: [GIST_32] });
        },
      },
    };
    const { ctx } = makeCtx();
    const req = makeRequest(pathFor(USER, GIST_32, SHA_40, FILENAME));
    const res = await worker.fetch(req, env, ctx);
    assert.equal(res.status, 410);
  });

  test('blocklist: absent binding -> serves', async () => {
    restoreFetch = installFetchStub(async () => fakeUpstream(200, realisticDoc()));
    const { ctx } = makeCtx();
    const req = makeRequest(pathFor(USER, GIST_32, SHA_40, FILENAME));
    const res = await worker.fetch(req, {}, ctx); // no BLOCKLIST binding at all
    restoreFetch();
    assert.equal(res.status, 200);
  });

  test('blocklist: malformed JSON fails open (serves)', async () => {
    restoreFetch = installFetchStub(async () => fakeUpstream(200, realisticDoc()));
    const env = { BLOCKLIST: { async get() { return '{not json'; } } };
    const { ctx } = makeCtx();
    const req = makeRequest(pathFor(USER, GIST_32, SHA_40, FILENAME));
    const res = await worker.fetch(req, env, ctx);
    restoreFetch();
    assert.equal(res.status, 200);
  });

  test('size cap: >2 MiB body -> 502', async () => {
    restoreFetch = installFetchStub(async () => ({
      ok: true,
      status: 200,
      body: streamOfSize(3 * 1024 * 1024),
    }));
    const { ctx } = makeCtx();
    const req = makeRequest(pathFor(USER, GIST_32, SHA_40, FILENAME));
    const res = await worker.fetch(req, {}, ctx);
    restoreFetch();
    assert.equal(res.status, 502);
  });

  test('upstream 404 -> 404, negative-cached', async () => {
    restoreFetch = installFetchStub(async () => fakeUpstream(404, 'not found'));
    const { ctx, flush } = makeCtx();
    const req = makeRequest(pathFor(USER, GIST_32, SHA_40, FILENAME));
    const res = await worker.fetch(req, {}, ctx);
    await flush();
    restoreFetch();
    assert.equal(res.status, 404);
    assert.equal(res.headers.get('Cache-Control'), 'max-age=300');
  });

  test('upstream non-404 error -> 502', async () => {
    restoreFetch = installFetchStub(async () => fakeUpstream(500, 'server error'));
    const { ctx } = makeCtx();
    const req = makeRequest(pathFor(USER, GIST_32, SHA_40, FILENAME));
    const res = await worker.fetch(req, {}, ctx);
    restoreFetch();
    assert.equal(res.status, 502);
  });

  test('HEAD request returns same status/headers with null body', async () => {
    restoreFetch = installFetchStub(async () => fakeUpstream(200, realisticDoc()));
    const { ctx } = makeCtx();
    const req = makeRequest(pathFor(USER, GIST_32, SHA_40, FILENAME), { method: 'HEAD' });
    const res = await worker.fetch(req, {}, ctx);
    restoreFetch();
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('Content-Type'), 'text/html; charset=utf-8');
    const body = await res.text();
    assert.equal(body, '');
  });

  test('cache hit returns immediately without invoking fetch again', async () => {
    let fetchCalls = 0;
    restoreFetch = installFetchStub(async () => {
      fetchCalls += 1;
      return fakeUpstream(200, realisticDoc());
    });
    const { ctx, flush } = makeCtx();
    const req = makeRequest(pathFor(USER, GIST_32, SHA_40, FILENAME));

    const first = await worker.fetch(req, {}, ctx);
    await flush();
    assert.equal(first.status, 200);
    assert.equal(fetchCalls, 1);

    const second = await worker.fetch(makeRequest(pathFor(USER, GIST_32, SHA_40, FILENAME)), {}, ctx);
    restoreFetch();
    assert.equal(second.status, 200);
    assert.equal(fetchCalls, 1, 'second request must be served from cache, not upstream');
  });
});

// ---------------------------------------------------------------------------
// isBlocked helper unit tests (already partially covered above, plus a
// missing-binding-tolerance check at the pure-function level)
// ---------------------------------------------------------------------------

describe('isBlocked', () => {
  test('tolerates missing BLOCKLIST binding', async () => {
    assert.equal(await isBlocked({}, USER, GIST_32), false);
    assert.equal(await isBlocked(undefined, USER, GIST_32), false);
  });

  test('tolerates malformed JSON, warns, fails open', async () => {
    const env = { BLOCKLIST: { async get() { return 'not-json{{'; } } };
    assert.equal(await isBlocked(env, USER, GIST_32), false);
  });
});

// Sanity: SECURITY_HEADERS is exported and exact.
test('SECURITY_HEADERS export matches the spec exactly', () => {
  assert.deepEqual(SECURITY_HEADERS, {
    'Content-Type': 'text/html; charset=utf-8',
    'Content-Security-Policy':
      "default-src 'none'; style-src 'unsafe-inline'; img-src data:; form-action 'none'; base-uri 'none'; sandbox; frame-ancestors 'none'",
    'X-Frame-Options': 'DENY',
    'X-Content-Type-Options': 'nosniff',
    'X-Robots-Tag': 'noindex, nofollow',
    'Referrer-Policy': 'no-referrer',
    'Cache-Control': 'public, max-age=3600, s-maxage=86400',
  });
});

// Regression: `>` inside a quoted attribute value must not let http-equiv
// escape the meta-tag span (HTML allows quoted `>` in attribute values).
test('lintBody rejects http-equiv smuggled behind a quoted ">" in a meta tag', () => {
  const body = '<meta content=">" http-equiv="refresh" data-x="0;url=https://evil.example">';
  assert.equal(lintBody(body.toLowerCase()), true);
});

// And the guard must not over-reach: a meta tag followed by escaped user text
// containing the words http-equiv stays clean.
test('lintBody passes when http-equiv appears only as escaped text after a meta tag', () => {
  const body = '<meta charset="utf-8"><title>x</title><p>we discussed http-equiv today</p>';
  assert.equal(lintBody(body.toLowerCase()), false);
});
