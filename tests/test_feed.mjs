// node tests/test_feed.mjs — schema sanity of the shipped feed + sign/verify
// roundtrip with a throwaway key (the same ed25519 detached-sig scheme the
// desktop What's-New pane must implement).
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, rmSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { generateKeyPairSync, sign as edSign, verify as edVerify } from 'node:crypto';

const HERE = dirname(fileURLToPath(import.meta.url));
const FEED = join(HERE, '..', 'feed', 'updates.json');
let failures = 0;
function t(label, fn) {
  try { fn(); console.log('ok   ' + label); }
  catch (e) { failures++; console.error('FAIL ' + label + ' — ' + e.message); }
}

const KINDS = new Set(['feature', 'sop', 'release']);

t('shipped feed parses and matches unblock-update-feed/v1', () => {
  const feed = JSON.parse(readFileSync(FEED, 'utf8'));
  assert.equal(feed.schema, 'unblock-update-feed/v1');
  assert.ok(!Number.isNaN(Date.parse(feed.generated_at)), 'generated_at is a date');
  assert.ok(Array.isArray(feed.items) && feed.items.length > 0, 'has items');
  const ids = new Set();
  for (const it of feed.items) {
    assert.ok(it.id && !ids.has(it.id), 'unique id: ' + it.id);
    ids.add(it.id);
    assert.ok(!Number.isNaN(Date.parse(it.date)), it.id + ' date parses');
    assert.ok(KINDS.has(it.kind), it.id + ' kind in enum');
    assert.ok(typeof it.title === 'string' && it.title.length > 0 && it.title.length <= 120,
      it.id + ' title present, one-sentence-sized');
    assert.ok(typeof it.body === 'string' && it.body.length <= 400, it.id + ' body short');
    if (it.action) {
      assert.ok(it.action.label && it.action.target, it.id + ' action has label+target');
      assert.ok(/^https:\/\//.test(it.action.target) || /^app:/.test(it.action.target),
        it.id + ' action target is https URL or app: route (desktop pane contract)');
    }
    if (it.provision) {
      // interim M1 contract (unblock_cli): feed is the notification, the manifest is
      // the authority — provision carries ONLY the pointer.
      const keys = Object.keys(it.provision).sort().join(',');
      assert.equal(keys, 'manifest_url,min_manifest_version', it.id + ' provision = {manifest_url, min_manifest_version} exactly');
      assert.ok(/^https:\/\//.test(it.provision.manifest_url), it.id + ' manifest_url https');
    }
    if (it.kind === 'sop') {
      assert.ok(it.sop && it.sop.content, it.id + ' sop payload present');
      assert.ok(Number.isInteger(it.sop.sop_version) && it.sop.sop_version >= 1,
        it.id + ' sop.sop_version monotonic int >=1 (SOP-WRITE-CONTRACT v1.1 final naming)');
      assert.ok(!/^\d{4}-\d{2}-\d{2}-/.test(it.id),
        it.id + ' sop id must NOT be date-prefixed (dates change per version, the id must not — it is the supersede join key)');
      const allowed = new Set(['content', 'sop_version', 'tags']);
      for (const k of Object.keys(it.sop)) {
        assert.ok(allowed.has(k), it.id + ' sop field "' + k + '" not in v1.1 contract {content, sop_version, tags?}');
      }
    }
  }
  // HARD GATE (substrate contract): sig-verify is a precondition for brain writes
  // and provisioning — sop/provision items may not ship in an unsigned feed.
  const signed = existsSync(FEED + '.sig');
  if (!signed) {
    for (const it of feed.items) {
      assert.ok(it.kind !== 'sop', it.id + ': kind=sop forbidden while feed is unsigned');
      assert.ok(!it.provision, it.id + ': provision forbidden while feed is unsigned');
    }
  }
});

t('ed25519 detached sign/verify roundtrip + tamper detection', () => {
  const dir = mkdtempSync(join(tmpdir(), 'feed-sig-'));
  try {
    const { privateKey, publicKey } = generateKeyPairSync('ed25519');
    const bytes = readFileSync(FEED);
    const sig = edSign(null, bytes, privateKey);
    assert.equal(edVerify(null, bytes, publicKey, sig), true, 'clean verify');
    const tampered = Buffer.from(bytes);
    tampered[tampered.length - 3] ^= 0xff;
    assert.equal(edVerify(null, tampered, publicKey, sig), false, 'tamper detected');
    // wrong key must fail
    const other = generateKeyPairSync('ed25519');
    assert.equal(edVerify(null, bytes, other.publicKey, sig), false, 'wrong key rejected');
    writeFileSync(join(dir, 'scratch'), 'ok');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

if (failures) { console.error(failures + ' failing'); process.exit(1); }
console.log('all feed tests passed');
