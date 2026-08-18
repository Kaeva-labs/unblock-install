// Cloudflare Pages Function — GET /api/desktop
//
// Resolves the latest UNBLOCK desktop (Tauri) release into a per-platform
// download map the landing page renders. Release repo is configurable via the
// DESKTOP_REPO env var (Pages project settings); defaults to the desktop repo.
//
// IMPORTANT: desktop artifacts must NOT be published to Kaeva-labs/unblock-install
// releases — install.sh/install.ps1 resolve `releases/latest` of THAT repo for
// the CLI, and a desktop release becoming "latest" would break the CLI installer.
//
// A TRANSPORT ERROR MUST NEVER MASQUERADE AS "NO RELEASE". Live resolution calls
// api.github.com from Cloudflare Pages egress with NO credentials (no GITHUB_TOKEN
// is provisioned, and no appropriately-narrow token exists to provision), so it
// shares that edge IP's 60 req/hr GitHub limit and 403s under normal traffic. The
// pre-v2 resolver answered those 403s with { available: false } AND cached that
// body for 5 minutes — which is why the install.kaeva.app watchdog went red on
// roughly every other run while a public desktop release existed the whole time.
//
// v2 closes that structurally, without any credential:
//   1. LAST_KNOWN_GOOD below is served (available: true, "resolved": "fallback")
//      whenever live resolution fails for ANY reason, so the download door never
//      shuts because GitHub rate-limited an edge IP.
//   2. ONLY a genuine live success is written to the edge cache — a transient
//      403 can no longer be pinned in front of every visitor for 5 minutes.
//   3. Every response carries X-Desktop-Resolver: v2 and X-Desktop-Resolved:
//      live|fallback|none, so which path answered is verifiable from outside.
// The `reason` field is never dropped: a fallback body still says why live
// resolution did not answer.
//
// MAINTENANCE: LAST_KNOWN_GOOD is a hand-checked snapshot of a real published
// release (verified against the GitHub API on the date noted). Refresh it — tag,
// urls, sizes, published_at — whenever a newer desktop release ships, or a
// rate-limited edge will hand users an older build than the live path would.

export const DESKTOP_REPO_DEFAULT = 'Kaeva-labs/unblock';

// Last-known-good desktop release, inline ON PURPOSE: Cloudflare Pages routes
// every file under functions/ as a route, so this manifest cannot live in a
// sibling module without also becoming a public endpoint.
// Verified against api.github.com 2026-08-17 (tag desktop-v0.1.1, draft:false).
export const LAST_KNOWN_GOOD = Object.freeze({
  repo: 'Kaeva-labs/unblock',
  version: 'desktop-v0.1.1',
  prerelease: false,
  published_at: '2026-08-15T23:10:19Z',
  platforms: Object.freeze({
    'macos-arm64': Object.freeze({
      name: 'UNBLOCK-0.1.1-macos-arm64.dmg',
      url: 'https://github.com/Kaeva-labs/unblock/releases/download/desktop-v0.1.1/UNBLOCK-0.1.1-macos-arm64.dmg',
      size: 36616227,
    }),
    'windows-x64': Object.freeze({
      name: 'UNBLOCK_0.1.1_x64-setup.exe',
      url: 'https://github.com/Kaeva-labs/unblock/releases/download/desktop-v0.1.1/UNBLOCK_0.1.1_x64-setup.exe',
      size: 29177059,
    }),
  }),
});

// Body served when live resolution could not answer. The snapshot describes ONE
// specific repo, so a DESKTOP_REPO pointed elsewhere gets an honest unavailable
// rather than another repo's binaries served under its name — the fallback must
// not become a second way to lie.
export function fallbackBody(repo, reason) {
  if (repo !== LAST_KNOWN_GOOD.repo) {
    return { available: false, resolved: 'none', source: 'github.com/' + repo, reason };
  }
  const platforms = {};
  for (const [k, v] of Object.entries(LAST_KNOWN_GOOD.platforms)) {
    platforms[k] = { name: v.name, url: v.url, size: v.size };
  }
  return {
    available: true,
    resolved: 'fallback',
    version: LAST_KNOWN_GOOD.version,
    prerelease: LAST_KNOWN_GOOD.prerelease,
    published_at: LAST_KNOWN_GOOD.published_at,
    source: 'github.com/' + repo,
    reason,
    platforms,
  };
}

// Map GitHub release assets (Tauri v2 bundle outputs) to platform slots.
// Lower rank wins within a slot. Deliberately ignores bare `.exe` files that
// are not NSIS `-setup.exe` installers: a bare exe is the CLI binary shape
// (`unblock-windows-x64.exe`) and must never be offered as the desktop app.
export function pickAssets(assets) {
  const slots = {};
  const put = (key, asset, rank) => {
    if (!slots[key] || slots[key].rank > rank) {
      slots[key] = { name: asset.name, url: asset.browser_download_url, size: asset.size, rank };
    }
  };
  for (const a of assets || []) {
    if (!a || !a.name || !a.browser_download_url) continue;
    const n = a.name.toLowerCase();
    // Skip 32-bit builds entirely — we only offer x64/arm64 slots, and bucketing
    // i686/armv7/x86 into "x64" would hand users a binary that won't run.
    // (Careful: `x86_64`/`x86-64` IS 64-bit and must survive this check.)
    if (/(i[36]86|armv7l?|armhf|ia32|win32)/.test(n)) continue;
    if (/x86/.test(n) && !/x86[_-]?64/.test(n)) continue;
    const arm = /(arm64|aarch64)/.test(n);
    if (n.endsWith('-setup.exe')) {
      put(arm ? 'windows-arm64' : 'windows-x64', a, 0);
    } else if (n.endsWith('.msi')) {
      put(arm ? 'windows-arm64' : 'windows-x64', a, 1);
    } else if (n.endsWith('.dmg')) {
      if (n.includes('universal')) {
        put('macos-arm64', a, 1);
        put('macos-x64', a, 1);
      } else {
        put(arm ? 'macos-arm64' : 'macos-x64', a, 0);
      }
    } else if (n.endsWith('.appimage')) {
      put(arm ? 'linux-arm64' : 'linux-x64', a, 0);
    } else if (n.endsWith('.deb')) {
      put(arm ? 'linux-arm64' : 'linux-x64', a, 1);
    } else if (n.endsWith('.rpm')) {
      put(arm ? 'linux-arm64' : 'linux-x64', a, 2);
    }
  }
  const platforms = {};
  for (const [k, v] of Object.entries(slots)) {
    platforms[k] = { name: v.name, url: v.url, size: v.size };
  }
  return platforms;
}

// Newest non-draft release (GitHub lists newest-first) that yields at least
// one platform slot. Prereleases count — during the beta they are all we have.
export function pickRelease(releases) {
  for (const rel of releases || []) {
    if (!rel || rel.draft) continue;
    const platforms = pickAssets(rel.assets);
    if (Object.keys(platforms).length > 0) return { rel, platforms };
  }
  return null;
}

export async function onRequest(context) {
  const repo = (context.env && context.env.DESKTOP_REPO) || DESKTOP_REPO_DEFAULT;

  // Edge-cache 5 min: dodges the unauthenticated GitHub API 60 req/hr/IP limit
  // and keeps Pages Function invocations off the hot path on a launch spike.
  // Only LIVE successes are ever written here — see the cache.put below.
  const cache = globalThis.caches && globalThis.caches.default;
  const cacheKey = new Request(new URL(context.request.url).origin + '/api/desktop?repo=' + repo);
  if (cache) {
    const hit = await cache.match(cacheKey);
    if (hit) return hit;
  }

  const GH_HEADERS = {
    'User-Agent': 'install.kaeva.app desktop-release resolver',
    'Accept': 'application/vnd.github+json',
  };
  // Authenticate to GitHub when a token is present. Unauthenticated calls share
  // the CF edge IP's 60 req/hr GitHub limit and 403 under normal traffic; a
  // read-only token lifts that to 5000/hr and keeps this on the LIVE path. Inert
  // without the env var — none is provisioned today, which is precisely why the
  // fallback above must carry the door. A token is an optimisation here, no
  // longer a correctness dependency.
  const ghToken = context.env && context.env.GITHUB_TOKEN;
  if (ghToken) GH_HEADERS['Authorization'] = 'Bearer ' + ghToken;

  // `live` is set ONLY by a genuine live resolution that yielded platform slots.
  // Everything else — 403, 404, network throw, malformed JSON, asset-less
  // release — leaves it null and funnels to the fallback, with `reason` carrying
  // what actually happened.
  let live = null;
  let reason = 'no public desktop release resolved';
  try {
    // releases/latest EXCLUDES prereleases (404 on a prerelease-only repo, which
    // is exactly the beta state: v0.1.0-beta is prerelease:true). Try it first,
    // then fall back to the releases list and take the newest non-draft entry.
    let rel = null;
    const latest = await fetch('https://api.github.com/repos/' + repo + '/releases/latest', { headers: GH_HEADERS });
    if (latest.ok) {
      rel = await latest.json();
    } else {
      const list = await fetch('https://api.github.com/repos/' + repo + '/releases?per_page=10', { headers: GH_HEADERS });
      if (list.ok) {
        const rels = await list.json();
        const found = pickRelease(Array.isArray(rels) ? rels : []);
        if (found) rel = found.rel;
        else reason = 'no non-draft release with desktop bundle assets on ' + repo;
      } else {
        // 403 = the unauthenticated rate limit this repo's egress IP shares;
        // 404 = repo private or missing. BOTH are statements about the transport,
        // never evidence that no release exists — hence the fallback below.
        reason = 'github releases -> HTTP ' + list.status + ' (releases/latest -> HTTP ' + latest.status + ')';
      }
    }
    if (rel) {
      const platforms = pickAssets(rel.assets);
      if (Object.keys(platforms).length > 0) {
        live = {
          available: true,
          resolved: 'live',
          version: rel.tag_name,
          prerelease: !!rel.prerelease,
          published_at: rel.published_at,
          source: 'github.com/' + repo,
          platforms,
        };
      } else {
        reason = 'release ' + rel.tag_name + ' has no desktop bundle assets';
      }
    }
  } catch (e) {
    reason = 'github api unreachable: ' + ((e && e.message) || String(e));
  }

  const body = live || fallbackBody(repo, reason);
  const resp = new Response(JSON.stringify(body), {
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      // A non-live body is deliberately short-lived downstream: it must not
      // outlive the next successful live resolution by more than a minute.
      'Cache-Control': live ? 'public, max-age=300' : 'public, max-age=60',
      'Access-Control-Allow-Origin': '*',
      'X-Served-By': 'unblock-install/functions/api/desktop.js',
      'X-Desktop-Resolver': 'v2',
      'X-Desktop-Resolved': body.resolved,
    },
  });
  // LIVE SUCCESSES ONLY. Caching a failure body is what turned one rate-limited
  // GitHub call into 5 minutes of "no desktop release" for every visitor.
  if (live && cache && context.waitUntil) context.waitUntil(cache.put(cacheKey, resp.clone()));
  return resp;
}
