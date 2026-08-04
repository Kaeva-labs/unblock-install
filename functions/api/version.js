// Cloudflare Pages Function — GET /api/version
//
// Deploy provenance (prod-bar #5: every served surface exposes its git_sha;
// MERGED != DEPLOYED != RUNNING). CF Pages injects CF_PAGES_COMMIT_SHA and
// CF_PAGES_BRANCH at build time; if absent (local dev, misconfig) we say so
// honestly instead of echoing a default.

export async function onRequest(context) {
  const env = context.env || {};
  return new Response(JSON.stringify({
    surface: 'install.kaeva.app',
    git_sha: env.CF_PAGES_COMMIT_SHA || null,
    branch: env.CF_PAGES_BRANCH || null,
    provenance: env.CF_PAGES_COMMIT_SHA ? 'cf-pages-build-env' : 'unknown (CF_PAGES_* not present)',
  }), {
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'public, max-age=60',
      'X-Served-By': 'unblock-install/functions/api/version.js',
    },
  });
}
