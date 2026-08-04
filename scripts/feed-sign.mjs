// node scripts/feed-sign.mjs <command>
//
//   keygen <name>          write <name>.key (PRIVATE, never commit) + <name>.pub
//   sign   <key> <json>    write <json>.sig (base64 ed25519 over the file's exact bytes)
//   verify <pub> <json>    exit 0 iff <json>.sig verifies — the same check the
//                          desktop What's-New pane must implement
//
// Signature scheme (unblock-update-feed/v1): ed25519 detached signature over the
// EXACT BYTES of updates.json (no canonicalization — the served file IS the
// signed message; never reformat it after signing). The signature is served at
// updates.json.sig (base64, one line). The PUBLIC KEY IS NOT SERVED from
// install.kaeva.app — it is pinned out-of-band in the desktop binary; fetching
// the key from the same origin as the feed would make the signature theater.
// Key custody (who runs `sign` at publish) is an unblock_ci/Viraj decision.
import { generateKeyPairSync, sign as edSign, verify as edVerify, createPrivateKey, createPublicKey } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';

const [cmd, a, b] = process.argv.slice(2);

if (cmd === 'keygen' && a) {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  writeFileSync(a + '.key', privateKey.export({ type: 'pkcs8', format: 'pem' }));
  writeFileSync(a + '.pub', publicKey.export({ type: 'spki', format: 'pem' }));
  console.log('wrote ' + a + '.key (PRIVATE — never commit) and ' + a + '.pub');
} else if (cmd === 'sign' && a && b) {
  const key = createPrivateKey(readFileSync(a));
  const sig = edSign(null, readFileSync(b), key);
  writeFileSync(b + '.sig', sig.toString('base64') + '\n');
  console.log('wrote ' + b + '.sig');
} else if (cmd === 'verify' && a && b) {
  const pub = createPublicKey(readFileSync(a));
  const ok = edVerify(null, readFileSync(b), pub, Buffer.from(readFileSync(b + '.sig', 'utf8').trim(), 'base64'));
  console.log(ok ? 'VERIFIED' : 'SIGNATURE INVALID');
  process.exit(ok ? 0 : 1);
} else {
  console.error('usage: feed-sign.mjs keygen <name> | sign <key> <json> | verify <pub> <json>');
  process.exit(2);
}
