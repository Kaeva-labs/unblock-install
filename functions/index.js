// Cloudflare Pages Function — content negotiation for `/`.
//
// curl / wget / PowerShell iwr -useb do NOT send Accept: text/html, so we
// stream install.sh directly. Browsers (Accept: text/html) get index.html.
// `?ps1=1` or a User-Agent containing "powershell" forces install.ps1.

export async function onRequest(context) {
  const { request, env } = context;
  const url = new URL(request.url);
  const accept = (request.headers.get('Accept') || '').toLowerCase();
  const ua     = (request.headers.get('User-Agent') || '').toLowerCase();

  const wantsPs1 = url.searchParams.has('ps1') || ua.includes('powershell') || ua.includes('windowspowershell');
  const isBrowser = accept.includes('text/html');

  if (isBrowser && !wantsPs1) {
    // Let the static asset handler serve /index.html
    return env.ASSETS.fetch(new Request(new URL('/index.html', url), request));
  }

  const target = wantsPs1 ? '/install.ps1' : '/install.sh';
  const contentType = wantsPs1
    ? 'text/plain; charset=utf-8'   // PowerShell is happy with text/plain
    : 'text/x-shellscript; charset=utf-8';

  const assetReq = new Request(new URL(target, url), request);
  const resp = await env.ASSETS.fetch(assetReq);

  // Re-wrap so we control headers cleanly
  return new Response(resp.body, {
    status: 200,
    headers: {
      'Content-Type': contentType,
      'Cache-Control': 'public, max-age=300',
      'X-Served-By': 'unblock-install/functions/index.js',
    },
  });
}
