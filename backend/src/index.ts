import { createAuth } from './auth';

const authRoutes = new Map([
  ['/api/auth/sign-in/username', 'POST'],
  ['/api/auth/get-session', 'GET'],
  ['/api/auth/sign-out', 'POST'],
]);

function failure(code: string, status: number) {
  return Response.json({ code }, { status, headers: { 'Cache-Control': 'no-store' } });
}

export default {
  async fetch(request, env) {
    try {
      const path = new URL(request.url).pathname;
      if (path === '/health' && request.method === 'GET') {
        return Response.json({ status: 'ok', app: 'Clash Harmony' });
      }
      const auth = createAuth(env);
      if (authRoutes.get(path) === request.method) {
        let authRequest: Request = request;
        // Bound native-client auth input before handing it to the library.
        if (request.method === 'POST') {
          const body = await readLimited(request, 4096);
          if (!body) return failure('INVALID_REQUEST', 413);
          authRequest = new Request(request, { body });
        }
        const response = await auth.handler(authRequest);
        response.headers.set('Cache-Control', 'no-store');
        return response;
      }
      if (path !== '/v1/config' || request.method !== 'GET') {
        return failure('NOT_FOUND', 404);
      }
      const session = await auth.api.getSession({ headers: request.headers });
      if (!session) return failure('UNAUTHORIZED', 401);
      const config = await env.DB.prepare('SELECT content, updated_at FROM proxy_config WHERE id = 1').first<{ content: string; updated_at: string }>();
      if (!config) return failure('CONFIG_UNAVAILABLE', 503);
      return new Response(config.content, {
        headers: {
          'Content-Type': 'application/yaml; charset=utf-8',
          'Cache-Control': 'private, no-store',
          'X-Content-Type-Options': 'nosniff',
          'Last-Modified': new Date(config.updated_at).toUTCString(),
        },
      });
    } catch (error) {
      // Never log bodies, tokens, passwords or upstream URLs.
      console.error(JSON.stringify({ event: 'request_failed', type: error instanceof Error ? error.name : 'unknown' }));
      return failure('SERVICE_UNAVAILABLE', 503);
    }
  },
} satisfies ExportedHandler<Env>;

async function readLimited(request: Request, max: number): Promise<ArrayBuffer | null> {
  if (Number(request.headers.get('Content-Length')) > max) return null;
  if (!request.body) return new ArrayBuffer(0);
  const reader = request.body.getReader();
  const parts: Uint8Array[] = [];
  let length = 0;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > max) { await reader.cancel(); return null; }
    parts.push(value);
  }
  const result = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) { result.set(part, offset); offset += part.byteLength; }
  return result.buffer;
}
