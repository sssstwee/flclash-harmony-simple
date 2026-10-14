import { createAuth } from './auth';

const authRoutes = new Map([
  ['/api/auth/sign-in/username', 'POST'],
  ['/api/auth/get-session', 'GET'],
  ['/api/auth/sign-out', 'POST'],
]);

const CONFIG_RATE_WINDOW_SEC = 60;
const CONFIG_RATE_MAX = 30;

type ConfigRow = {
  content: string;
  updated_at: string;
  scope: string;
  scope_key: string;
};

let cachedAuth: { env: Env; auth: ReturnType<typeof createAuth> } | undefined;

function getAuth(env: Env) {
  if (!cachedAuth || cachedAuth.env !== env) {
    cachedAuth = { env, auth: createAuth(env) };
  }
  return cachedAuth.auth;
}

function failure(code: string, status: number) {
  return Response.json({ code }, { status, headers: { 'Cache-Control': 'no-store' } });
}

function configHeaders(updatedAt: string, etag: string) {
  return {
    'Content-Type': 'application/yaml; charset=utf-8',
    'Cache-Control': 'private, no-store',
    'X-Content-Type-Options': 'nosniff',
    ETag: etag,
    'Last-Modified': new Date(updatedAt).toUTCString(),
  };
}

async function resolveProxyConfig(db: D1Database, userId: string): Promise<ConfigRow | null> {
  // Resolve the user's current group and all fallback priorities in one snapshot.
  return db
    .prepare(`
      SELECT config.content, config.updated_at, config.scope, config.scope_key
      FROM user AS account
      JOIN proxy_config AS config ON
        (config.scope = 'user' AND config.scope_key = account.id)
        OR (config.scope = 'group' AND account.config_group <> '' AND config.scope_key = account.config_group)
        OR (config.scope = 'default' AND config.scope_key = '')
      WHERE account.id = ?
      ORDER BY CASE config.scope WHEN 'user' THEN 0 WHEN 'group' THEN 1 ELSE 2 END
      LIMIT 1
    `)
    .bind(userId)
    .first<ConfigRow>();
}

async function allowConfigFetch(db: D1Database, userId: string): Promise<boolean> {
  const now = Math.floor(Date.now() / 1000);
  // Admission and increment must be one atomic statement. Separate reads race
  // both when the row is first inserted and when a limit/window is reached.
  const admitted = await db
    .prepare(`
      INSERT INTO config_api_rate_limit (user_id, window_start, request_count)
      VALUES (?1, ?2, 1)
      ON CONFLICT(user_id) DO UPDATE SET
        window_start = CASE
          WHEN excluded.window_start - config_api_rate_limit.window_start >= ?3
          THEN excluded.window_start ELSE config_api_rate_limit.window_start END,
        request_count = CASE
          WHEN excluded.window_start - config_api_rate_limit.window_start >= ?3
          THEN 1 ELSE config_api_rate_limit.request_count + 1 END
      WHERE excluded.window_start - config_api_rate_limit.window_start >= ?3
        OR config_api_rate_limit.request_count < ?4
      RETURNING request_count
    `)
    .bind(userId, now, CONFIG_RATE_WINDOW_SEC, CONFIG_RATE_MAX)
    .first<{ request_count: number }>();
  return admitted !== null;
}

async function configEtag(config: ConfigRow): Promise<string> {
  // HTTP dates only have second precision and cannot identify scope changes.
  // Include scope identity and the exact bytes so older fallbacks, reassigned
  // groups, and multiple edits in one second never reuse a stale validator.
  const bytes = new TextEncoder().encode(
    JSON.stringify([config.scope, config.scope_key, config.content]),
  );
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  const hash = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('');
  return `"${hash}"`;
}

function matchesEtag(ifNoneMatch: string | null, etag: string): boolean {
  return ifNoneMatch?.split(',').some(value => {
    const tag = value.trim();
    return tag === '*' || tag.replace(/^W\//, '') === etag;
  }) ?? false;
}

function auditConfigFetch(
  ctx: ExecutionContext,
  db: D1Database,
  userId: string,
  scope: string,
  scopeKey: string,
  clientIp: string | null,
) {
  ctx.waitUntil(
    db
      .prepare(
        'INSERT INTO config_fetch_audit (user_id, scope, scope_key, fetched_at, client_ip) VALUES (?, ?, ?, ?, ?)',
      )
      .bind(userId, scope, scopeKey, new Date().toISOString(), clientIp)
      .run()
      .catch(() => undefined),
  );
}

export default {
  async fetch(request, env, ctx) {
    try {
      const path = new URL(request.url).pathname;

      if (path === '/health' && request.method === 'GET') {
        return Response.json({ status: 'ok', app: 'Clash Harmony' });
      }

      if (authRoutes.get(path) === request.method) {
        const auth = getAuth(env);
        let authRequest: Request = request;
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

      const auth = getAuth(env);
      const session = await auth.api.getSession({ headers: request.headers });
      if (!session?.user?.id) return failure('UNAUTHORIZED', 401);

      const allowed = await allowConfigFetch(env.DB, session.user.id);
      if (!allowed) return failure('RATE_LIMITED', 429);

      const config = await resolveProxyConfig(env.DB, session.user.id);
      if (!config) return failure('CONFIG_UNAVAILABLE', 503);

      const etag = await configEtag(config);
      const headers = configHeaders(config.updated_at, etag);
      const clientIp = request.headers.get('cf-connecting-ip');
      auditConfigFetch(ctx, env.DB, session.user.id, config.scope, config.scope_key, clientIp);

      // Date-only clients get a full response: even a later Last-Modified date
      // cannot prove that the previously selected scope/content is unchanged.
      if (matchesEtag(request.headers.get('If-None-Match'), etag)) {
        return new Response(null, { status: 304, headers });
      }

      return new Response(config.content, { headers });
    } catch (error) {
      console.error(
        JSON.stringify({ event: 'request_failed', type: error instanceof Error ? error.name : 'unknown' }),
      );
      return failure('SERVICE_UNAVAILABLE', 503);
    }
  },
} satisfies ExportedHandler<Env>;

async function readLimited(request: Request, max: number): Promise<ArrayBuffer | null> {
  const contentLength = Number(request.headers.get('Content-Length'));
  if (!Number.isNaN(contentLength) && contentLength > max) return null;
  if (!request.body) return new ArrayBuffer(0);
  const reader = request.body.getReader();
  const parts: Uint8Array[] = [];
  let length = 0;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > max) {
      await reader.cancel();
      return null;
    }
    parts.push(value);
  }
  const result = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.byteLength;
  }
  return result.buffer;
}
