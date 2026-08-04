// mint_feed_signing_key.mjs — VIRAJ-RUN, ONE TIME. Human-gated prod Vault mutation.
//
// Mints the ed25519 signing keypair for install.kaeva.app/feed/updates.json
// (M2 update channel; custody ruling 2026-07-21: private key lives in the
// EXISTING Supabase Vault, same custody class as deepinfra_api_key /
// api_key_hmac_secret_b64 — no new custody system).
//
//   UNBLOCK_STORAGE_DATABASE_URL=<service-role pooler URL> \
//     node scripts/mint_feed_signing_key.mjs --arm-viraj-run
//
// Without --arm-viraj-run it only prints the plan (ARMED-script discipline:
// a gated mutation script must not fire on a read). It REFUSES if the Vault
// row already exists — key rotation is a separate deliberate act, never an
// accidental overwrite. The PRIVATE KEY IS NEVER PRINTED and never touches
// disk; only the PUBLIC key is printed (pin it in the desktop binary + feed
// tests). After insert it READS THE ROW BACK and proves a sign/verify
// roundtrip with the stored key (per-stage verification, never assume).
//
// Box-local operator script: imports `postgres` from unblock_broker_sidecar's
// node_modules (same proven pattern as the wake bridge on this machine).
import { generateKeyPairSync, createPrivateKey, sign as edSign, verify as edVerify } from 'node:crypto';
import { createRequire } from 'node:module';

const requireFrom = createRequire('C:/Users/12066/unblock_broker_sidecar/package.json');
const postgres = requireFrom('postgres');

const SECRET_NAME = 'update_feed_signing_key';
const ARMED = process.argv.includes('--arm-viraj-run');
const DB = process.env.UNBLOCK_STORAGE_DATABASE_URL;

if (!DB) {
  console.error('UNBLOCK_STORAGE_DATABASE_URL required (service-role pooler URL)');
  process.exit(2);
}
if (!ARMED) {
  console.log('DRY RUN (no --arm-viraj-run). Would do, in order:');
  console.log('  1. SELECT vault.decrypted_secrets WHERE name=' + JSON.stringify(SECRET_NAME) + ' — REFUSE if a row exists');
  console.log('  2. generate ed25519 pair in-process');
  console.log("  3. SELECT vault.create_secret(<private pkcs8 PEM>, '" + SECRET_NAME + "', <description>)");
  console.log('  4. read the row back, sign/verify a probe message with the STORED key');
  console.log('  5. print ONLY the public key (pin in desktop binary + tests)');
  process.exit(0);
}

const sql = postgres(DB, { ssl: 'require', max: 1, connect_timeout: 15 });
try {
  const existing = await sql`SELECT name FROM vault.decrypted_secrets WHERE name = ${SECRET_NAME}`;
  if (existing.length > 0) {
    console.error('REFUSING: Vault row ' + JSON.stringify(SECRET_NAME) + ' already exists. ' +
      'Rotation is a separate deliberate act — never overwrite a signing key by re-running mint.');
    process.exit(1);
  }

  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const privPem = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
  const pubPem = publicKey.export({ type: 'spki', format: 'pem' }).toString();

  await sql`SELECT vault.create_secret(
    ${privPem},
    ${SECRET_NAME},
    ${'ed25519 private key (pkcs8 PEM) signing install.kaeva.app/feed/updates.json — M2 update channel, minted ' + new Date().toISOString()}
  )`;

  // read-back + roundtrip with the STORED bytes — the insert is only proven
  // when the stored key signs and the printed pubkey verifies it.
  const rows = await sql`SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = ${SECRET_NAME}`;
  if (rows.length !== 1) throw new Error('read-back failed: expected 1 row, got ' + rows.length);
  const storedKey = createPrivateKey(rows[0].decrypted_secret);
  const probe = Buffer.from('unblock-update-feed/v1 mint probe');
  const sig = edSign(null, probe, storedKey);
  if (!edVerify(null, probe, publicKey, sig)) throw new Error('roundtrip failed: stored key does not match generated pubkey');

  console.log('MINTED + READ-BACK-VERIFIED. Vault row: ' + SECRET_NAME);
  console.log('PUBLIC KEY (pin in desktop binary; give to unblock_desktop; commit to feed docs):');
  console.log(pubPem);
  // desktop's verifier pins the RAW 32-byte key (SPKI DER = 12-byte prefix + raw key)
  const raw = publicKey.export({ type: 'spki', format: 'der' }).subarray(-32);
  console.log('RAW 32-byte form (base64, for the desktop PINNED_FEED_PUBKEY):');
  console.log(raw.toString('base64'));
} finally {
  await sql.end({ timeout: 5 });
}
