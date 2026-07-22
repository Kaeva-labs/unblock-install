// node tests/test_waitlist_api.mjs — tests for /api/waitlist (validEmail + handler).
// Uses node's global Request/Response/FormData (node 18+); upstream fetch is mocked.
import assert from 'node:assert/strict';
import { validEmail, onRequestPost } from '../functions/api/waitlist.js';

let failures = 0;
function t(label, fn) {
  return Promise.resolve()
    .then(fn)
    .then(() => console.log('ok   ' + label))
    .catch((e) => { failures++; console.error('FAIL ' + label + ' — ' + e.message); });
}

const realFetch = globalThis.fetch;
function mockFetch(impl) {
  const calls = [];
  globalThis.fetch = (...args) => { calls.push(args); return impl(...args); };
  return calls;
}
function jsonReq(body) {
  return new Request('https://install.kaeva.app/api/waitlist', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}

await t('validEmail accepts normal, rejects junk', () => {
  assert.equal(validEmail('sam@company.com'), true);
  assert.equal(validEmail('  sam@company.com  '), true);
  assert.equal(validEmail('nope'), false);
  assert.equal(validEmail('a@b'), false);
  assert.equal(validEmail('has space@x.com'), false);
  assert.equal(validEmail(''), false);
  assert.equal(validEmail(null), false);
  assert.equal(validEmail('x@y.' + 'z'.repeat(260)), false);
});

await t('bad email -> 400, no upstream call', async () => {
  const calls = mockFetch(() => { throw new Error('must not be called'); });
  const resp = await onRequestPost({ request: jsonReq({ email: 'nope' }), env: { WAITLIST_ENDPOINT: 'https://up/x' } });
  globalThis.fetch = realFetch;
  assert.equal(resp.status, 400);
  assert.equal(calls.length, 0);
});

await t('honeypot filled -> quiet 202, no upstream call', async () => {
  const calls = mockFetch(() => { throw new Error('must not be called'); });
  const resp = await onRequestPost({ request: jsonReq({ email: 'sam@company.com', website: 'spam.biz' }), env: { WAITLIST_ENDPOINT: 'https://up/x' } });
  globalThis.fetch = realFetch;
  assert.equal(resp.status, 202);
  assert.equal(calls.length, 0);
});

await t('no WAITLIST_ENDPOINT -> honest 503, never fake success', async () => {
  const resp = await onRequestPost({ request: jsonReq({ email: 'sam@company.com' }), env: {} });
  const body = await resp.json();
  assert.equal(resp.status, 503);
  assert.equal(body.ok, false);
});

await t('happy path -> 202 and upstream receives email + received_at (issuer contract)', async () => {
  const calls = mockFetch(() => Promise.resolve(new Response('{}', { status: 200 })));
  const resp = await onRequestPost({ request: jsonReq({ email: 'sam@company.com' }), env: { WAITLIST_ENDPOINT: 'https://up/join' } });
  globalThis.fetch = realFetch;
  assert.equal(resp.status, 202);
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], 'https://up/join');
  const sent = JSON.parse(calls[0][1].body);
  assert.equal(sent.email, 'sam@company.com');
  assert.equal(sent.source, 'install.kaeva.app');
  // issuer wants received_at (ISO), not ts — the old key was silently ignored
  assert.ok(sent.received_at && !Number.isNaN(Date.parse(sent.received_at)));
  assert.equal(sent.ts, undefined);
});

await t('upstream failure -> honest 502', async () => {
  mockFetch(() => Promise.resolve(new Response('nope', { status: 500 })));
  const resp = await onRequestPost({ request: jsonReq({ email: 'sam@company.com' }), env: { WAITLIST_ENDPOINT: 'https://up/join' } });
  globalThis.fetch = realFetch;
  assert.equal(resp.status, 502);
  assert.equal((await resp.json()).ok, false);
});

await t('form-encoded body works (no-JS fallback path)', async () => {
  mockFetch(() => Promise.resolve(new Response('{}', { status: 200 })));
  const form = new FormData();
  form.set('email', 'sam@company.com');
  form.set('website', '');
  const req = new Request('https://install.kaeva.app/api/waitlist', { method: 'POST', body: form });
  const resp = await onRequestPost({ request: req, env: { WAITLIST_ENDPOINT: 'https://up/join' } });
  globalThis.fetch = realFetch;
  assert.equal(resp.status, 202);
});

globalThis.fetch = realFetch;
if (failures) { console.error(failures + ' failing'); process.exit(1); }
console.log('all waitlist tests passed');
