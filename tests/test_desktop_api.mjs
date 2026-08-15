// node tests/test_desktop_api.mjs — pure-function tests for the /api/desktop
// asset matcher. No network, no CF runtime.
import assert from 'node:assert/strict';
import { pickAssets, pickRelease, onRequest, fallbackBody, LAST_KNOWN_GOOD } from '../functions/api/desktop.js';

const A = (name) => ({ name, browser_download_url: 'https://gh/' + name, size: 1 });
let failures = 0;
function t(label, fn) {
  try { fn(); console.log('ok   ' + label); }
  catch (e) { failures++; console.error('FAIL ' + label + ' — ' + e.message); }
}

t('typical tauri v2 release maps every platform', () => {
  const p = pickAssets([
    A('UNBLOCK_0.1.0_x64-setup.exe'),
    A('UNBLOCK_0.1.0_x64_en-US.msi'),
    A('UNBLOCK_0.1.0_aarch64.dmg'),
    A('UNBLOCK_0.1.0_x64.dmg'),
    A('UNBLOCK_0.1.0_amd64.AppImage'),
    A('UNBLOCK_0.1.0_amd64.deb'),
    A('SHA256SUMS'),
  ]);
  assert.equal(p['windows-x64'].name, 'UNBLOCK_0.1.0_x64-setup.exe'); // nsis beats msi
  assert.equal(p['macos-arm64'].name, 'UNBLOCK_0.1.0_aarch64.dmg');
  assert.equal(p['macos-x64'].name, 'UNBLOCK_0.1.0_x64.dmg');
  assert.equal(p['linux-x64'].name, 'UNBLOCK_0.1.0_amd64.AppImage'); // appimage beats deb
  assert.equal(Object.keys(p).length, 4);
});

t('bare CLI exe is NEVER offered as the desktop installer', () => {
  const p = pickAssets([A('unblock-windows-x64.exe'), A('unblock-windows-arm64.exe')]);
  assert.deepEqual(p, {});
});

t('msi is the fallback when no nsis setup exists', () => {
  const p = pickAssets([A('UNBLOCK_0.1.0_x64_en-US.msi')]);
  assert.equal(p['windows-x64'].name, 'UNBLOCK_0.1.0_x64_en-US.msi');
});

t('universal dmg fills both mac slots but arch-specific wins', () => {
  const p = pickAssets([A('UNBLOCK_0.1.0_universal.dmg'), A('UNBLOCK_0.1.0_aarch64.dmg')]);
  assert.equal(p['macos-arm64'].name, 'UNBLOCK_0.1.0_aarch64.dmg');
  assert.equal(p['macos-x64'].name, 'UNBLOCK_0.1.0_universal.dmg');
});

t('arm64 assets route to arm64 slots', () => {
  const p = pickAssets([
    A('UNBLOCK_0.1.0_arm64-setup.exe'),
    A('UNBLOCK_0.1.0_arm64.AppImage'),
  ]);
  assert.equal(p['windows-arm64'].name, 'UNBLOCK_0.1.0_arm64-setup.exe');
  assert.equal(p['linux-arm64'].name, 'UNBLOCK_0.1.0_arm64.AppImage');
  assert.equal(p['windows-x64'], undefined);
});

t('deb preferred over rpm, appimage over both', () => {
  const p = pickAssets([A('unblock.rpm'), A('unblock.deb')]);
  assert.equal(p['linux-x64'].name, 'unblock.deb');
  const p2 = pickAssets([A('unblock.rpm'), A('unblock.deb'), A('unblock.AppImage')]);
  assert.equal(p2['linux-x64'].name, 'unblock.AppImage');
});

t('32-bit builds are skipped, never mis-bucketed as x64', () => {
  const p = pickAssets([
    A('unblock-x86-setup.exe'),
    A('unblock-i686.AppImage'),
    A('unblock-i386.deb'),
    A('unblock-armv7.deb'),
    A('unblock-armhf.AppImage'),
    A('unblock-win32-setup.exe'),
  ]);
  assert.deepEqual(p, {});
});

t('x86_64 and x86-64 still count as 64-bit', () => {
  const p = pickAssets([A('UNBLOCK_0.1.0_x86_64.AppImage'), A('unblock-x86-64-setup.exe')]);
  assert.equal(p['linux-x64'].name, 'UNBLOCK_0.1.0_x86_64.AppImage');
  assert.equal(p['windows-x64'].name, 'unblock-x86-64-setup.exe');
});

t('REAL v0.1.0-beta release shape (Kaeva-labs/unblock) maps windows-x64 only', () => {
  const p = pickAssets([A('UNBLOCK_0.1.0_x64-setup.exe'), A('SHA256SUMS.txt')]);
  assert.equal(p['windows-x64'].name, 'UNBLOCK_0.1.0_x64-setup.exe');
  assert.equal(Object.keys(p).length, 1);
});

t('pickRelease skips drafts AND asset-less releases, takes newest usable', () => {
  const rels = [
    { tag_name: 'v0.3.0', draft: true, assets: [A('UNBLOCK_0.3.0_x64-setup.exe')] },
    { tag_name: 'v0.2.0', draft: false, assets: [A('source.zip')] },
    { tag_name: 'v0.1.0-beta', draft: false, prerelease: true, assets: [A('UNBLOCK_0.1.0_x64-setup.exe'), A('SHA256SUMS.txt')] },
  ];
  const found = pickRelease(rels);
  assert.equal(found.rel.tag_name, 'v0.1.0-beta');
  assert.equal(found.platforms['windows-x64'].name, 'UNBLOCK_0.1.0_x64-setup.exe');
  assert.equal(pickRelease([]), null);
  assert.equal(pickRelease(undefined), null);
});

t('empty / malformed input yields empty map', () => {
  assert.deepEqual(pickAssets(undefined), {});
  assert.deepEqual(pickAssets([]), {});
  assert.deepEqual(pickAssets([{ name: null }, {}]), {});
});

// --- onRequest GitHub-auth header (mocked fetch; no network) ---
async function tAsync(label, fn) {
  try { await fn(); console.log('ok   ' + label); }
  catch (e) { failures++; console.error('FAIL ' + label + ' — ' + e.message); }
}

// fetch stub: releases/latest -> 404 (prerelease-only), releases list -> beta shape.
// Records the Authorization header seen on every GH call.
function mockGH(recorder) {
  return async (url, opts) => {
    recorder.push({ url: String(url), auth: (opts && opts.headers && opts.headers['Authorization']) || null });
    if (String(url).includes('/releases/latest')) return { ok: false, status: 404 };
    return { ok: true, status: 200, json: async () => ([
      { tag_name: 'v0.1.0-beta', draft: false, prerelease: true,
        assets: [{ name: 'UNBLOCK_0.1.0_x64-setup.exe', browser_download_url: 'https://gh/x', size: 1 }] },
    ]) };
  };
}

async function withMockedGH(fn) {
  const origFetch = globalThis.fetch, origCaches = globalThis.caches;
  globalThis.caches = undefined; // skip edge cache in the test
  const rec = [];
  globalThis.fetch = mockGH(rec);
  try { await fn(rec); } finally { globalThis.fetch = origFetch; globalThis.caches = origCaches; }
}

await tAsync('onRequest authenticates to GitHub when GITHUB_TOKEN is set', () => withMockedGH(async (rec) => {
  const resp = await onRequest({ env: { GITHUB_TOKEN: 'tok-123', DESKTOP_REPO: 'o/r' },
    request: { url: 'https://install.kaeva.app/api/desktop' }, waitUntil: () => {} });
  const body = JSON.parse(await resp.text());
  assert.equal(body.available, true);
  assert.equal(body.platforms['windows-x64'].name, 'UNBLOCK_0.1.0_x64-setup.exe');
  assert.ok(rec.length >= 1, 'expected at least one GitHub call');
  for (const c of rec) assert.equal(c.auth, 'Bearer tok-123', 'each GH call must carry the token: ' + c.url);
}));

await tAsync('onRequest sends NO Authorization when GITHUB_TOKEN is absent', () => withMockedGH(async (rec) => {
  await onRequest({ env: { DESKTOP_REPO: 'o/r' },
    request: { url: 'https://install.kaeva.app/api/desktop' }, waitUntil: () => {} });
  assert.ok(rec.length >= 1, 'expected at least one GitHub call');
  for (const c of rec) assert.equal(c.auth, null, 'no token -> no Authorization header: ' + c.url);
}));

// --- v2 resolver: a transport error must never masquerade as "no release" ---
//
// The defect these guard: api.github.com is called UNAUTHENTICATED from the
// Cloudflare Pages egress IP, which shares GitHub's 60 req/hr/IP limit and 403s
// under normal traffic. The pre-v2 resolver answered those 403s with
// { available: false } AND cached that body for 5 minutes — so the install
// watchdog (unblock_e2e tests/install.spec.ts) went red on ~every other run
// while a public desktop release existed the whole time.

// Pre-v2 failure funnel, vendored from functions/api/desktop.js @ a1c0766.
// It is here as a POSITIVE CONTROL ON THE MOCK: a reproducer that cannot go red
// proves nothing, so the same 403 stub must first be shown to drive the OLD code
// to available:false before the NEW code is credited with surviving it.
async function legacyResolve(repo) {
  let body = { available: false, source: 'github.com/' + repo, reason: 'no public desktop release yet' };
  try {
    let rel = null;
    const latest = await fetch('https://api.github.com/repos/' + repo + '/releases/latest', { headers: {} });
    if (latest.ok) {
      rel = await latest.json();
    } else {
      const list = await fetch('https://api.github.com/repos/' + repo + '/releases?per_page=10', { headers: {} });
      if (list.ok) {
        const found = pickRelease(await list.json());
        if (found) rel = found.rel;
      } else {
        body.reason = 'github releases -> HTTP ' + list.status;
      }
    }
    if (rel) {
      const platforms = pickAssets(rel.assets);
      if (Object.keys(platforms).length > 0) body = { available: true, version: rel.tag_name, platforms };
    }
  } catch (e) {
    body.reason = 'github api unreachable: ' + ((e && e.message) || String(e));
  }
  return body;
}

// GitHub answering 403 — the exact shared-rate-limit shape CF Pages egress hits.
const ghRateLimited = (rec) => async (url) => {
  rec.push(String(url));
  return { ok: false, status: 403, json: async () => ({ message: 'API rate limit exceeded for <ip>.' }) };
};

// GitHub healthy. Tag/urls/sizes are deliberately NOTHING like LAST_KNOWN_GOOD,
// so "live data was served" and "the fallback was served" cannot be confused —
// a fix that always fails safe would pass its own reproducer with zero
// information, and this is the leg that catches that.
const LIVE_ONLY_URL = 'https://gh-live.example/UNBLOCK-9.9.9-macos-arm64.dmg';
const ghHealthy = (rec) => async (url) => {
  rec.push(String(url));
  return { ok: true, status: 200, json: async () => ({
    tag_name: 'desktop-v9.9.9', draft: false, prerelease: false,
    published_at: '2099-01-01T00:00:00Z',
    assets: [
      { name: 'UNBLOCK-9.9.9-macos-arm64.dmg', browser_download_url: LIVE_ONLY_URL, size: 777 },
      { name: 'UNBLOCK_9.9.9_x64-setup.exe', browser_download_url: 'https://gh-live.example/w.exe', size: 888 },
    ],
  }) };
};

// Recording edge-cache stub: every cache.put is captured so "never cache a
// failure" is asserted on the WRITE, not inferred from the response body.
function makeCache() {
  const puts = [];
  const api = { default: {
    match: async () => null,
    put: async (key, resp) => puts.push({
      key: String(key && key.url ? key.url : key),
      resolved: resp.headers.get('X-Desktop-Resolved'),
      body: JSON.parse(await resp.text()),
    }),
  } };
  return { puts, api };
}

async function runResolver({ fetchImpl, env = {}, cache = null }) {
  const origFetch = globalThis.fetch, origCaches = globalThis.caches;
  globalThis.fetch = fetchImpl;
  globalThis.caches = cache;              // null -> resolver skips the edge cache
  const pending = [];
  try {
    const resp = await onRequest({
      env,
      request: { url: 'https://install.kaeva.app/api/desktop' },
      waitUntil: (p) => pending.push(p),
    });
    await Promise.all(pending);           // cache.put runs before we assert on it
    return { resp, body: JSON.parse(await resp.text()) };
  } finally { globalThis.fetch = origFetch; globalThis.caches = origCaches; }
}

await tAsync('REPRODUCER: under a GitHub 403 the PRE-v2 funnel answers available:false', async () => {
  const rec = [];
  const origFetch = globalThis.fetch;
  globalThis.fetch = ghRateLimited(rec);
  try {
    const old = await legacyResolve('Kaeva-labs/unblock');
    assert.equal(old.available, false, 'pre-v2 code must go red under 403 — otherwise the stub is inert');
    assert.match(old.reason, /HTTP 403/);
    assert.ok(rec.length >= 2, 'both GitHub endpoints must have been attempted');
  } finally { globalThis.fetch = origFetch; }
});

await tAsync('FIX: under that SAME 403 the v2 resolver serves the last-known-good release', async () => {
  const { resp, body } = await runResolver({ fetchImpl: ghRateLimited([]) });
  assert.equal(body.available, true, 'a rate-limited GitHub must never read as "no release"');
  assert.equal(body.resolved, 'fallback', 'the fallback must announce itself honestly');
  assert.equal(body.version, 'desktop-v0.1.0');
  assert.equal(body.prerelease, false);
  assert.equal(body.published_at, '2026-08-15T03:36:35Z');
  assert.match(body.reason, /HTTP 403/, 'why live resolution failed must survive into the body');
  // The two slots unblock_e2e tests/install.spec.ts asserts on, with real bytes.
  assert.equal(body.platforms['macos-arm64'].url, LAST_KNOWN_GOOD.platforms['macos-arm64'].url);
  assert.equal(body.platforms['macos-arm64'].size, 45291128);
  assert.equal(body.platforms['windows-x64'].url, LAST_KNOWN_GOOD.platforms['windows-x64'].url);
  assert.equal(body.platforms['windows-x64'].size, 29206896);
  assert.equal(resp.headers.get('X-Desktop-Resolver'), 'v2');
  assert.equal(resp.headers.get('X-Desktop-Resolved'), 'fallback');
});

await tAsync('POSITIVE CONTROL: healthy GitHub serves LIVE data and does NOT use the fallback', async () => {
  const { resp, body } = await runResolver({ fetchImpl: ghHealthy([]) });
  assert.equal(body.available, true);
  assert.equal(body.resolved, 'live');
  assert.equal(body.version, 'desktop-v9.9.9', 'live tag must win — not the frozen snapshot');
  assert.equal(body.published_at, '2099-01-01T00:00:00Z');
  assert.equal(body.platforms['macos-arm64'].url, LIVE_ONLY_URL);
  assert.equal(body.platforms['macos-arm64'].size, 777);
  assert.equal(body.reason, undefined, 'a live answer has nothing to explain');
  assert.notEqual(body.version, LAST_KNOWN_GOOD.version);
  assert.equal(resp.headers.get('X-Desktop-Resolved'), 'live');
  assert.equal(resp.headers.get('X-Desktop-Resolver'), 'v2');
});

await tAsync('a fallback body is NEVER written to the edge cache', async () => {
  const { puts, api } = makeCache();
  const { body } = await runResolver({ fetchImpl: ghRateLimited([]), cache: api });
  assert.equal(body.resolved, 'fallback');
  assert.deepEqual(puts, [], 'caching a failure/fallback pins it in front of every visitor for minutes');
});

await tAsync('a LIVE success IS written to the edge cache (the cache still works)', async () => {
  const { puts, api } = makeCache();
  await runResolver({ fetchImpl: ghHealthy([]), cache: api });
  assert.equal(puts.length, 1, 'live successes must still be cached — otherwise every hit burns rate limit');
  assert.equal(puts[0].resolved, 'live');
  assert.equal(puts[0].body.version, 'desktop-v9.9.9');
});

await tAsync('a thrown fetch (network unreachable) falls back too, never available:false', async () => {
  const { body } = await runResolver({ fetchImpl: async () => { throw new Error('connect ECONNREFUSED'); } });
  assert.equal(body.available, true);
  assert.equal(body.resolved, 'fallback');
  assert.match(body.reason, /ECONNREFUSED/);
});

await tAsync('a live release with no bundle assets also falls back rather than closing the door', async () => {
  const fetchImpl = async () => ({ ok: true, status: 200, json: async () => ({
    tag_name: 'desktop-v0.2.0', draft: false, assets: [{ name: 'SHA256SUMS.txt', browser_download_url: 'https://gh/s', size: 1 }],
  }) });
  const { body } = await runResolver({ fetchImpl });
  assert.equal(body.available, true);
  assert.equal(body.resolved, 'fallback');
  assert.match(body.reason, /no desktop bundle assets/);
});

await tAsync('the fallback is repo-scoped: a DESKTOP_REPO override gets an honest unavailable', async () => {
  const { resp, body } = await runResolver({ fetchImpl: ghRateLimited([]), env: { DESKTOP_REPO: 'someone/else' } });
  assert.equal(body.available, false, 'never serve one repo\'s binaries under another repo\'s name');
  assert.equal(body.resolved, 'none');
  assert.equal(body.source, 'github.com/someone/else');
  assert.equal(resp.headers.get('X-Desktop-Resolved'), 'none');
});

t('LAST_KNOWN_GOOD matches the published desktop-v0.1.0 release contract', () => {
  // Byte-level pins, checked against api.github.com on 2026-08-15. If a newer
  // desktop release ships, this test is the thing that must be updated with it.
  assert.deepEqual(Object.keys(LAST_KNOWN_GOOD.platforms).sort(), ['macos-arm64', 'windows-x64']);
  for (const [slot, a] of Object.entries(LAST_KNOWN_GOOD.platforms)) {
    assert.ok(a.url.startsWith('https://github.com/Kaeva-labs/unblock/releases/download/desktop-v0.1.0/'), slot + ' url must point at the pinned tag');
    assert.ok(a.url.endsWith(a.name), slot + ' url must end in its asset name');
    assert.ok(Number.isInteger(a.size) && a.size > 1_000_000, slot + ' size must be a real installer size');
  }
  assert.equal(LAST_KNOWN_GOOD.repo, 'Kaeva-labs/unblock');
  // The snapshot must survive being handed out: mutating a served body must not
  // corrupt the constant for the next request on the same isolate.
  const b1 = fallbackBody('Kaeva-labs/unblock', 'x');
  b1.platforms['macos-arm64'].url = 'https://evil/';
  assert.equal(fallbackBody('Kaeva-labs/unblock', 'x').platforms['macos-arm64'].url, LAST_KNOWN_GOOD.platforms['macos-arm64'].url);
});

if (failures) { console.error(failures + ' failing'); process.exit(1); }
console.log('all pickAssets tests passed');
