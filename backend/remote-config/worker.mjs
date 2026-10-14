// Example only: bind CONFIGS (KV) and AUTH_ORIGIN (HTTPS account service).
// CONFIGS key: user:<username>. Keep subscription credentials out of public KV URLs.
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.protocol !== 'https:') return new Response(null, { status: 400 });
    if (!['/v1/config', '/v1/config/version'].includes(url.pathname)) {
      return new Response(null, { status: 404 });
    }
    if (request.method !== 'GET') return new Response(null, { status: 405 });
    const origin = new URL(env.AUTH_ORIGIN);
    if (origin.protocol !== 'https:') return new Response(null, { status: 500 });
    const authorization = request.headers.get('Authorization');
    if (!authorization?.startsWith('Bearer ')) return new Response(null, { status: 401 });
    const auth = await fetch(new URL('/api/auth/get-session', origin), {
      headers: { Authorization: authorization }, redirect: 'error',
    });
    if (!auth.ok) return new Response(null, { status: auth.status === 401 || auth.status === 403 ? 401 : 503 });
    // Adapt this extraction to the account service response; never trust request user IDs.
    const session = await auth.json();
    const username = session.user?.username;
    if (typeof username !== 'string' || !username) return new Response(null, { status: 401 });
    const config = await env.CONFIGS.get(`user:${username}`, 'json');
    if (!config) return new Response(null, { status: 503 });
    const headers = {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'private, no-store',
      'ETag': `"${config.version}-${config.sha256}"`,
      'X-Config-Version': config.version,
    };
    if (url.pathname.endsWith('/version')) {
      return Response.json({ version: config.version, min_check_seconds: 300 }, { headers });
    }
    if (request.headers.get('If-None-Match') === headers.ETag) {
      return new Response(null, { status: 304, headers });
    }
    return Response.json(config, { headers });
  },
};
