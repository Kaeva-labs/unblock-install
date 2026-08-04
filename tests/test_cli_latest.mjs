// node tests/test_cli_latest.mjs — tests for the /api/cli-latest release
// pointer. No network, no CF runtime: fetch is stubbed per-case.
import assert from 'node:assert/strict';
import { parseTagFromRedirect, resolveLatestTag, onRequest, CLI_REPO_DEFAULT } from '../functions/api/cli-latest.js';

let failures = 0;
function t(label, fn) {
  try { fn(); console.log('ok   ' + label); }
  catch (e) { failures++; console.error('FAIL ' + label + ' — ' + e.message); }
}
async function ta(label, fn) {
  try { await fn(); console.log('ok   ' + label); }
  catch (e) { failures++; console.error('FAIL ' + label + ' — ' + e.message); }
}

const realFetch = globalThis.fetch;
function stubFetch(handler) { globalThis.fetch = handler; }
function restoreFetch() { globalThis.fetch = realFetch; }

const apiOk = (tag) => new Response(JSON.stringify({ tag_name: tag }), { status: 200 });
const http = (status) => new Response('', { status });
const redirectTo = (loc) => new Response(null, { status: 302, headers: { Location: loc } });

// ---------- parseTagFromRedirect ----------

t('parses the plain tag redirect', () => {
  assert.equal(
    parseTagFromRedirect('https://github.com/Kaeva-labs/unblock-install/releases/tag/v0.1.7'),
    'v0.1.7',
  );
});

t('tolerates query strings and fragments', () => {
  assert.equal(parseTagFromRedirect('https://github.com/x/y/releases/tag/v1.2.3?foo=1#bar'), 'v1.2.3');
});

t('decodes URL-encoded tags', () => {
  assert.equal(parseTagFromRedirect('https://github.com/x/y/releases/tag/v1.0.0%2Bbuild'), 'v1.0.0+build');
});

t('rejects non-tag locations and empties', () => {
  assert.equal(parseTagFromRedirect('https://github.com/login?return_to=x'), null);
  assert.equal(parseTagFromRedirect(''), null);
  assert.equal(parseTagFromRedirect(null), null);
});

// ---------- resolveLatestTag ----------

await ta('api ok -> github-api source, no redirect call made', async () => {
  const calls = [];
  stubFetch(async (url) => { calls.push(String(url)); return apiOk('v0.1.7'); });
  const r = await resolveLatestTag(CLI_REPO_DEFAULT, {});
  restoreFetch();
  assert.equal(r.tag_name, 'v0.1.7');
  assert.equal(r.source, 'github-api');
  assert.equal(calls.length, 1);
  assert.match(calls[0], /^https:\/\/api\.github\.com\//);
});

await ta('api 403 (the rate-limit case) -> website redirect fallback', async () => {
  stubFetch(async (url) => {
    if (String(url).startsWith('https://api.github.com/')) return http(403);
    return redirectTo('https://github.com/Kaeva-labs/unblock-install/releases/tag/v0.1.8');
  });
  const r = await resolveLatestTag(CLI_REPO_DEFAULT, {});
  restoreFetch();
  assert.equal(r.tag_name, 'v0.1.8');
  assert.equal(r.source, 'releases-redirect');
  assert.match(r.api_failure, /403/);
});

await ta('api network throw -> redirect fallback still resolves', async () => {
  stubFetch(async (url) => {
    if (String(url).startsWith('https://api.github.com/')) throw new Error('ECONNRESET');
    return redirectTo('https://github.com/x/y/releases/tag/v2.0.0');
  });
  const r = await resolveLatestTag('x/y', {});
  restoreFetch();
  assert.equal(r.tag_name, 'v2.0.0');
});

await ta('GITHUB_TOKEN goes to the API and ONLY the API', async () => {
  const authByHost = {};
  stubFetch(async (url, opts) => {
    const h = (opts && opts.headers) || {};
    authByHost[new URL(String(url)).host] = h['Authorization'] || null;
    if (String(url).startsWith('https://api.github.com/')) return http(500);
    return redirectTo('https://github.com/x/y/releases/tag/v1.0.0');
  });
  await resolveLatestTag('x/y', { GITHUB_TOKEN: 'ghp_test' });
  restoreFetch();
  assert.equal(authByHost['api.github.com'], 'Bearer ghp_test');
  assert.equal(authByHost['github.com'], null);
});

await ta('both resolvers down -> throws with both failure details', async () => {
  stubFetch(async (url) => {
    if (String(url).startsWith('https://api.github.com/')) return http(504);
    return http(500); // no Location header
  });
  await assert.rejects(
    () => resolveLatestTag('x/y', {}),
    (e) => /504/.test(e.message) && /500/.test(e.message),
  );
  restoreFetch();
});

// ---------- onRequest ----------

function ctx(env) {
  return {
    request: new Request('https://install.kaeva.app/api/cli-latest'),
    env: env || {},
    waitUntil() {},
  };
}

await ta('success -> 200, tag_name, cacheable 5 min', async () => {
  stubFetch(async () => apiOk('v0.1.7'));
  const resp = await onRequest(ctx());
  restoreFetch();
  assert.equal(resp.status, 200);
  const body = await resp.json();
  assert.equal(body.tag_name, 'v0.1.7');
  assert.equal(resp.headers.get('Cache-Control'), 'public, max-age=300');
});

await ta('total failure -> 503 and NEVER cached', async () => {
  const puts = [];
  globalThis.caches = { default: { match: async () => undefined, put: async (k, v) => puts.push(k) } };
  stubFetch(async () => http(504));
  const resp = await onRequest(ctx());
  restoreFetch();
  delete globalThis.caches;
  assert.equal(resp.status, 503);
  assert.equal(resp.headers.get('Cache-Control'), 'no-store');
  assert.equal(puts.length, 0, 'a failure must not be pinned into the edge cache');
});

await ta('success populates the edge cache; a later hit is served from it', async () => {
  const store = new Map();
  globalThis.caches = {
    default: {
      match: async (k) => store.get(k.url),
      put: async (k, v) => store.set(k.url, v),
    },
  };
  stubFetch(async () => apiOk('v0.3.0'));
  const r1 = await onRequest(ctx());
  assert.equal((await r1.json()).tag_name, 'v0.3.0');
  // Second call: fetch now fails hard — the cache must carry it.
  stubFetch(async () => { throw new Error('github is down'); });
  const r2 = await onRequest(ctx());
  restoreFetch();
  delete globalThis.caches;
  assert.equal((await r2.json()).tag_name, 'v0.3.0');
});

console.log(failures === 0 ? 'ALL PASS' : failures + ' FAILURES');
process.exit(failures === 0 ? 0 : 1);
