// Cloudflare Pages Function — GET /api/cli-latest
//
// The CLI release pointer, served from our own CF-fronted domain so
// `curl install.kaeva.app | sh` never depends on api.github.com at install
// time. The unauthenticated GitHub API allows 60 req/hr PER IP — shared
// across everyone behind one NAT — and 504-killed live installs 4x in a row
// on 2026-07-28 with the installer's ~4s retry window. A conference room
// installing from one NAT hits that limit in the first minute.
//
// Resolution order (server-side, edge-cached 5 min):
//   1. api.github.com releases/latest — authenticated when GITHUB_TOKEN is
//      set in Pages env (5000 req/hr), best-effort unauthenticated otherwise.
//   2. github.com/<repo>/releases/latest with redirect:'manual' — the WEBSITE
//      endpoint, not the API: it 302s to /releases/tag/<tag> and is not
//      subject to the 60/hr API limit. Parsing the Location header needs no
//      body and no auth.
// Total failure returns 503 (uncached) — the installers then fall back to
// api.github.com client-side, so this endpoint being down never makes an
// install WORSE than the pre-pointer world.
//
// Response shape deliberately matches GitHub's releases/latest for the one
// field the installers parse ({ "tag_name": "vX.Y.Z" }), so install.sh and
// install.ps1 use a single parser for both the pointer and the fallback.

import { withSecurityHeaders } from '../../lib/http-headers.js';

export const CLI_REPO_DEFAULT = 'Kaeva-labs/unblock-install';

// https://github.com/<repo>/releases/tag/v0.1.7 -> "v0.1.7" (null if not a
// tag redirect — e.g. github serving an error page or a login redirect).
export function parseTagFromRedirect(location) {
  if (!location) return null;
  const m = String(location).match(/\/releases\/tag\/([^/?#]+)/);
  return m ? decodeURIComponent(m[1]) : null;
}

// Resolves { tag_name, source } or throws. Exported for tests.
export async function resolveLatestTag(repo, env) {
  const headers = {
    'User-Agent': 'install.kaeva.app cli-release resolver',
    'Accept': 'application/vnd.github+json',
  };
  if (env && env.GITHUB_TOKEN) headers['Authorization'] = 'Bearer ' + env.GITHUB_TOKEN;

  let apiFailure = null;
  try {
    const r = await fetch('https://api.github.com/repos/' + repo + '/releases/latest', { headers });
    if (r.ok) {
      const body = await r.json();
      if (body && body.tag_name) return { tag_name: body.tag_name, source: 'github-api' };
      apiFailure = 'api response had no tag_name';
    } else {
      apiFailure = 'api -> HTTP ' + r.status;
    }
  } catch (e) {
    apiFailure = 'api unreachable: ' + ((e && e.message) || String(e));
  }

  // Website redirect fallback — no API quota involved.
  const r = await fetch('https://github.com/' + repo + '/releases/latest', {
    redirect: 'manual',
    headers: { 'User-Agent': headers['User-Agent'] },
  });
  const tag = parseTagFromRedirect(r.headers.get('Location'));
  if (tag) return { tag_name: tag, source: 'releases-redirect', api_failure: apiFailure };
  throw new Error(
    'both resolvers failed: ' + apiFailure +
    '; redirect -> HTTP ' + r.status + ' Location=' + (r.headers.get('Location') || '(none)'),
  );
}

export async function onRequest(context) {
  const repo = (context.env && context.env.CLI_REPO) || CLI_REPO_DEFAULT;

  // Edge-cache 5 min: install-time traffic never reaches GitHub at all in
  // the common case, and a launch spike costs one origin resolve per colo.
  const cache = globalThis.caches && globalThis.caches.default;
  const cacheKey = new Request(new URL(context.request.url).origin + '/api/cli-latest?repo=' + repo);
  if (cache) {
    const hit = await cache.match(cacheKey);
    if (hit) return hit;
  }

  let resolved;
  try {
    resolved = await resolveLatestTag(repo, context.env);
  } catch (e) {
    // 503, never cached: a transient GitHub outage must not pin a failure
    // into the edge cache for 5 minutes, and the installers treat any
    // non-200 here as "try api.github.com yourself".
    return new Response(JSON.stringify({
      error: 'could not resolve latest release',
      detail: (e && e.message) || String(e),
      source: 'github.com/' + repo,
    }), {
      status: 503,
      headers: withSecurityHeaders({
        'Content-Type': 'application/json; charset=utf-8',
        'Cache-Control': 'no-store',
        'X-Served-By': 'unblock-install/functions/api/cli-latest.js',
      }),
    });
  }

  const resp = new Response(JSON.stringify({
    tag_name: resolved.tag_name,
    source: resolved.source,
    repo,
    resolved_at: new Date().toISOString(),
  }), {
    headers: withSecurityHeaders({
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'public, max-age=300',
      'Access-Control-Allow-Origin': '*',
      'X-Served-By': 'unblock-install/functions/api/cli-latest.js',
    }),
  });
  if (cache && context.waitUntil) context.waitUntil(cache.put(cacheKey, resp.clone()));
  return resp;
}
