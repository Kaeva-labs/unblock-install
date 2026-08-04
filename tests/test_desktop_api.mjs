// node tests/test_desktop_api.mjs — pure-function tests for the /api/desktop
// asset matcher. No network, no CF runtime.
import assert from 'node:assert/strict';
import { pickAssets, pickRelease, onRequest } from '../functions/api/desktop.js';

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

if (failures) { console.error(failures + ' failing'); process.exit(1); }
console.log('all pickAssets tests passed');
