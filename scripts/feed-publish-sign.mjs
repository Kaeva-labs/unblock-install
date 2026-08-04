// feed-publish-sign.mjs — sign feed/updates.json for publish.
//
// Reads the ed25519 private key FROM THE SUPABASE VAULT at publish time
// (row 'update_feed_signing_key' — custody ruling: never a key file in a
// repo), signs the EXACT BYTES of feed/updates.json, writes
// feed/updates.json.sig (base64), then self-verifies and prints the public
// key derived from the signing key so the publisher can eyeball-match the
// one pinned in the desktop binary.
//
//   UNBLOCK_STORAGE_DATABASE_URL=<service-role pooler URL> node scripts/feed-publish-sign.mjs
//
// Dev override (throwaway keys only, never the real one):
//   FEED_SIGNING_KEY_FILE=/path/to/dev.key node scripts/feed-publish-sign.mjs
//
// Fails closed: missing Vault row (or unreadable key) = hard error, never an
// unsigned publish that LOOKS signed.
import { createPrivateKey, createPublicKey, sign as edSign, verify as edVerify } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const HERE = dirname(fileURLToPath(import.meta.url));
const FEED = join(HERE, '..', 'feed', 'updates.json');
const SECRET_NAME = 'update_feed_signing_key';

let privPem;
if (process.env.FEED_SIGNING_KEY_FILE) {
  console.log('DEV MODE: signing with local key file (never use for a real publish)');
  privPem = readFileSync(process.env.FEED_SIGNING_KEY_FILE, 'utf8');
} else {
  const DB = process.env.UNBLOCK_STORAGE_DATABASE_URL;
  if (!DB) {
    console.error('UNBLOCK_STORAGE_DATABASE_URL required (or FEED_SIGNING_KEY_FILE for dev)');
    process.exit(2);
  }
  const requireFrom = createRequire('C:/Users/12066/unblock_broker_sidecar/package.json');
  const postgres = requireFrom('postgres');
  const sql = postgres(DB, { ssl: 'require', max: 1, connect_timeout: 15 });
  try {
    const rows = await sql`SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = ${SECRET_NAME}`;
    if (rows.length !== 1 || !rows[0].decrypted_secret) {
      console.error('Vault row ' + JSON.stringify(SECRET_NAME) + ' missing — run scripts/mint_feed_signing_key.mjs (Viraj-gated) first. Refusing to publish unsigned.');
      process.exit(1);
    }
    privPem = rows[0].decrypted_secret;
  } finally {
    await sql.end({ timeout: 5 });
  }
}

const key = createPrivateKey(privPem);
const pub = createPublicKey(key);
const bytes = readFileSync(FEED);
const sig = edSign(null, bytes, key);
if (!edVerify(null, bytes, pub, sig)) {
  console.error('self-verify failed — refusing to write a bad signature');
  process.exit(1);
}
writeFileSync(FEED + '.sig', sig.toString('base64') + '\n');
console.log('wrote feed/updates.json.sig (self-verified over ' + bytes.length + ' bytes)');
console.log('signing key corresponds to this PUBLIC key (must match the desktop-pinned one):');
console.log(pub.export({ type: 'spki', format: 'pem' }).toString());
console.log('RAW 32-byte form (base64 — the desktop PINNED_FEED_PUBKEY format):');
console.log(pub.export({ type: 'spki', format: 'der' }).subarray(-32).toString('base64'));
