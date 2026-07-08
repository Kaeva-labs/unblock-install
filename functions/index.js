// Cloudflare Pages Function — content negotiation for `/`.
//
// curl / wget / PowerShell iwr -useb do NOT send Accept: text/html, so we
// stream install.sh directly. Browsers (Accept: text/html) get landing.html.
// `?ps1=1` or a User-Agent containing "powershell" forces install.ps1.
//
// Why landing.html (not index.html): CF Pages auto-canonicalizes any
// /index.html request to /, which re-enters this function -> infinite
// 308 loop. Using a non-magic filename breaks the cycle. Observed bug
// at install.kaeva.app standup 2026-05-28 17:23 UTC.

export async function onRequest(context) {
  const { request, env } = context;
  const url = new URL(request.url);
  const accept = (request.headers.get('Accept') || '').toLowerCase();
  const ua     = (request.headers.get('User-Agent') || '').toLowerCase();

  const wantsPs1 = url.searchParams.has('ps1') || ua.includes('powershell') || ua.includes('windowspowershell');
  const isBrowser = accept.includes('text/html');

  if (isBrowser && !wantsPs1) {
    // Static asset; non-magic filename avoids CF Pages' /index.html -> /
    // canonical redirect that would loop back through this function.
    return env.ASSETS.fetch(new Request(new URL('/landing.html', url), request));
  }

  const target = wantsPs1 ? '/install.ps1' : '/install.sh';
  const contentType = wantsPs1
    ? 'text/plain; charset=utf-8'   // PowerShell is happy with text/plain
    : 'text/x-shellscript; charset=utf-8';

  const assetReq = new Request(new URL(target, url), request);
  const resp = await env.ASSETS.fetch(assetReq);

  if (!resp.ok) {
    // Don't mask a failed upstream fetch as a 200. `curl | sh` / `iwr | iex`
    // pipes the response body straight into a shell/PowerShell -- if a
    // missing/broken asset were re-wrapped as status 200 here, an error
    // page would get executed as if it were the installer. Propagate the
    // real status (and let it fall out of the success cache/content-type
    // path below) instead.
    return resp;
  }

  // Re-wrap so we control headers cleanly
  return new Response(resp.body, {
    status: 200,
    headers: {
      'Content-Type': contentType,
      'Cache-Control': 'public, max-age=300',
      // The body returned here depends on the Accept/User-Agent request
      // headers (install.sh vs install.ps1 vs landing.html). Without Vary,
      // a shared/intermediary cache keyed only on URL could store one
      // variant and serve it to a different client -- e.g. hand a cached
      // shell script to a browser, or HTML to a curl-to-sh pipe.
      'Vary': 'Accept, User-Agent',
      'X-Served-By': 'unblock-install/functions/index.js',
    },
  });
}
