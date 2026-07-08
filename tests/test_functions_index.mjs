// tests/test_functions_index.mjs -- unit tests for functions/index.js
//
// Regression guards for two 704-audit findings:
//   - functions/index.js:33-43 -- a failed upstream ASSETS.fetch used to be
//     re-wrapped as a hardcoded `status: 200`, so an error body could be
//     piped into `sh`/`iex` as if it were the installer.
//   - functions/index.js:36-43 -- the negotiated response had no `Vary`
//     header, so a shared cache keyed only on URL could serve the wrong
//     variant (e.g. a cached shell script handed to a browser).
//
// No test framework / dependencies -- this repo is intentionally
// dependency-free (static Cloudflare Pages hosting). Run with:
//   node tests/test_functions_index.mjs

import assert from 'node:assert/strict';
import { onRequest } from '../functions/index.js';

let pass = 0;
let fail = 0;

async function test(name, fn) {
  try {
    await fn();
    console.log(`  PASS ${name}`);
    pass++;
  } catch (err) {
    console.log(`  FAIL ${name}`);
    console.log(`    ${err.message}`);
    fail++;
  }
}

// Fake env.ASSETS.fetch -- routes by pathname against a canned table of
// { status, body, ok } responses, mirroring how CF Pages' static asset
// binding behaves (it returns a Response, not a thrown error, on a miss).
function makeEnv(routes) {
  return {
    ASSETS: {
      async fetch(req) {
        const path = new URL(req.url).pathname;
        const route = routes[path];
        if (!route) {
          return new Response('not found', { status: 404 });
        }
        return new Response(route.body, { status: route.status ?? 200 });
      },
    },
  };
}

function makeRequest(url, headers) {
  return new Request(url, { headers });
}

await test('curl (no Accept: text/html) with a healthy upstream -> 200, shell content-type, Vary present', async () => {
  const env = makeEnv({ '/install.sh': { status: 200, body: '#!/bin/sh\necho hi\n' } });
  const req = makeRequest('https://install.kaeva.app/', { 'User-Agent': 'curl/8.4.0' });
  const resp = await onRequest({ request: req, env });
  assert.equal(resp.status, 200);
  assert.equal(resp.headers.get('Content-Type'), 'text/x-shellscript; charset=utf-8');
  assert.equal(resp.headers.get('Vary'), 'Accept, User-Agent');
  assert.equal(await resp.text(), '#!/bin/sh\necho hi\n');
});

await test('powershell UA with a healthy upstream -> 200, text/plain content-type, Vary present', async () => {
  const env = makeEnv({ '/install.ps1': { status: 200, body: '# ps1 content' } });
  const req = makeRequest('https://install.kaeva.app/', { 'User-Agent': 'Mozilla/5.0 WindowsPowerShell/5.1' });
  const resp = await onRequest({ request: req, env });
  assert.equal(resp.status, 200);
  assert.equal(resp.headers.get('Content-Type'), 'text/plain; charset=utf-8');
  assert.equal(resp.headers.get('Vary'), 'Accept, User-Agent');
});

await test('a failed upstream fetch (404) is propagated, NOT masked as 200', async () => {
  // No route registered for /install.sh -> the fake ASSETS binding 404s,
  // exactly like a missing/broken deployed asset would.
  const env = makeEnv({});
  const req = makeRequest('https://install.kaeva.app/', { 'User-Agent': 'curl/8.4.0' });
  const resp = await onRequest({ request: req, env });
  assert.equal(resp.status, 404, 'upstream failure status must propagate, not be forced to 200');
  assert.equal(await resp.text(), 'not found');
});

await test('a failed upstream fetch (500) is propagated with its real status, not silently succeeded', async () => {
  const env = makeEnv({ '/install.sh': { status: 500, body: 'internal error' } });
  const req = makeRequest('https://install.kaeva.app/', { 'User-Agent': 'curl/8.4.0' });
  const resp = await onRequest({ request: req, env });
  assert.equal(resp.status, 500);
  assert.equal(await resp.text(), 'internal error');
});

await test('browser (Accept: text/html) still serves landing.html, unaffected by the fix', async () => {
  const env = makeEnv({ '/landing.html': { status: 200, body: '<html>hi</html>' } });
  const req = makeRequest('https://install.kaeva.app/', {
    'User-Agent': 'Mozilla/5.0 (Macintosh)',
    Accept: 'text/html,application/xhtml+xml',
  });
  const resp = await onRequest({ request: req, env });
  assert.equal(resp.status, 200);
  assert.equal(await resp.text(), '<html>hi</html>');
});

console.log('');
console.log(`PASS=${pass} FAIL=${fail}`);
process.exit(fail === 0 ? 0 : 1);
