// Cloudflare Pages Function — GET /api/desktop
//
// Resolves the latest UNBLOCK desktop (Tauri) release into a per-platform
// download map the landing page renders. Release repo is configurable via the
// DESKTOP_REPO env var (Pages project settings); defaults to the desktop repo.
//
// IMPORTANT: desktop artifacts must NOT be published to Viraj0518/unblock-install
// releases — install.sh/install.ps1 resolve `releases/latest` of THAT repo for
// the CLI, and a desktop release becoming "latest" would break the CLI installer.
//
// Until a public desktop release exists this returns { available: false } and
// the landing page shows an honest "in final assembly" state. The moment a
// public release with Tauri bundle assets lands, this lights up unchanged.

export const DESKTOP_REPO_DEFAULT = 'Viraj0518/unblock_desktop';

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

export async function onRequest(context) {
  const repo = (context.env && context.env.DESKTOP_REPO) || DESKTOP_REPO_DEFAULT;

  // Edge-cache 5 min: dodges the unauthenticated GitHub API 60 req/hr/IP limit
  // and keeps Pages Function invocations off the hot path on a launch spike.
  const cache = globalThis.caches && globalThis.caches.default;
  const cacheKey = new Request(new URL(context.request.url).origin + '/api/desktop?repo=' + repo);
  if (cache) {
    const hit = await cache.match(cacheKey);
    if (hit) return hit;
  }

  let body = { available: false, source: 'github.com/' + repo, reason: 'no public desktop release yet' };
  try {
    const gh = await fetch('https://api.github.com/repos/' + repo + '/releases/latest', {
      headers: {
        'User-Agent': 'install.kaeva.app desktop-release resolver',
        'Accept': 'application/vnd.github+json',
      },
    });
    if (gh.ok) {
      const rel = await gh.json();
      const platforms = pickAssets(rel.assets);
      if (Object.keys(platforms).length > 0) {
        body = {
          available: true,
          version: rel.tag_name,
          published_at: rel.published_at,
          source: 'github.com/' + repo,
          platforms,
        };
      } else {
        body.reason = 'release ' + rel.tag_name + ' has no desktop bundle assets';
      }
    } else {
      // 404 = repo private or no releases — the expected pre-launch state.
      body.reason = 'github releases/latest -> HTTP ' + gh.status;
    }
  } catch (e) {
    body.reason = 'github api unreachable: ' + ((e && e.message) || String(e));
  }

  const resp = new Response(JSON.stringify(body), {
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'public, max-age=300',
      'Access-Control-Allow-Origin': '*',
      'X-Served-By': 'unblock-install/functions/api/desktop.js',
    },
  });
  if (cache && context.waitUntil) context.waitUntil(cache.put(cacheKey, resp.clone()));
  return resp;
}
