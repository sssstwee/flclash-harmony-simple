const SECURITY_HEADERS = {
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Referrer-Policy': 'no-referrer',
  'Permissions-Policy': 'interest-cohort=()',
  'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'",
};

function isAllowedPath(pathname) {
  if (pathname === '/health' || pathname === '/v1/config') return true;
  return pathname.startsWith('/api/auth/');
}

function withSecurityHeaders(response) {
  const headers = new Headers(response.headers);
  for (const [key, value] of Object.entries(SECURITY_HEADERS)) {
    headers.set(key, value);
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (!isAllowedPath(pathname)) {
      return withSecurityHeaders(
        Response.json({ code: 'NOT_FOUND' }, { status: 404, headers: { 'Cache-Control': 'no-store' } }),
      );
    }
    return withSecurityHeaders(await env.API.fetch(request));
  },
};
