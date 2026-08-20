// Cloudflare Pages Function — POST /api/waitlist
//
// Beta waitlist signup for the loud-beta (spec blk_157da46d4752e8dab0c76b0e64061797:
// publicly announced, invite-gated; Viraj mints invites in manual waves).
//
// This function is a thin proxy: the store of record is unblock_storage's
// beta_requests table (mig 054), written via the issuer route
// POST auth.kaeva.app/v1/beta/request. Set WAITLIST_ENDPOINT to that URL. The
// issuer accepts {email (required, RFC5321), received_at?, use_case?,
// agent_count?, country?, cf_turnstile_token?} and STRIPS unknown keys (so
// `source` is dropped today — kept for forward-compat if it's ever accepted).
// Until WAITLIST_ENDPOINT is set, this returns an honest 503 and the page
// shows a "not taking signups yet" state — never a fake success.
//
// Abuse boundary: validEmail rejects whitespace (incl. CRLF) and caps length;
// the email only ever travels in a JSON body, never a header. There is NO
// per-IP rate limit here — that belongs to Cloudflare WAF rules on the Pages
// project plus dedupe-by-email (idempotent upsert) in the upstream store; both
// are part of the deploy/contract checklist, documented in the README.

import { withSecurityHeaders } from '../../lib/http-headers.js';

export function validEmail(s) {
  if (typeof s !== 'string') return false;
  const e = s.trim();
  if (e.length < 6 || e.length > 254) return false;
  // pragmatic shape check, not RFC 5321 — the upstream store revalidates
  return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(e);
}

function json(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: withSecurityHeaders({ 'Content-Type': 'application/json; charset=utf-8' }),
  });
}

export async function onRequestPost(context) {
  const { request, env } = context;

  let data = {};
  try {
    const ct = (request.headers.get('Content-Type') || '').toLowerCase();
    if (ct.includes('application/json')) {
      data = await request.json();
    } else {
      const form = await request.formData();
      data = Object.fromEntries(form.entries());
    }
  } catch {
    return json(400, { ok: false, error: 'unreadable body' });
  }

  // honeypot: real users never fill "website"; bots that do get a quiet 202
  // without touching the upstream store
  if (typeof data.website === 'string' && data.website.trim() !== '') {
    return json(202, { ok: true });
  }

  const email = typeof data.email === 'string' ? data.email.trim() : '';
  if (!validEmail(email)) {
    return json(400, { ok: false, error: 'invalid email' });
  }

  const upstream = env && env.WAITLIST_ENDPOINT;
  if (!upstream) {
    return json(503, { ok: false, error: 'waitlist backend not configured yet' });
  }

  try {
    const resp = await fetch(upstream, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        email,
        source: 'install.kaeva.app',
        received_at: new Date().toISOString(),
      }),
    });
    if (resp.ok) return json(202, { ok: true });
    return json(502, { ok: false, error: 'waitlist backend rejected the signup (HTTP ' + resp.status + ')' });
  } catch {
    return json(502, { ok: false, error: 'waitlist backend unreachable' });
  }
}
