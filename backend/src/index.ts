import { createAuth } from './auth';
import {
  DEFAULT_MIN_CHECK_SECONDS,
  configRowMeta,
  etagMatches,
} from './config_meta';
import { RemoteConfigInvalid, loadRemoteConfig, type RemoteConfigDocument } from './remote_config';

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

async function configHeaders(config: ConfigRow) {
  const meta = await configRowMeta(config);
  return {
    'Content-Type': 'application/yaml; charset=utf-8',
    'Cache-Control': 'private, no-store',
    'X-Content-Type-Options': 'nosniff',
    'Last-Modified': new Date(config.updated_at).toUTCString(),
    ETag: meta.etag,
    'X-Config-Version': meta.version,
  };
}

async function resolveProxyConfig(
  db: D1Database,
  userId: string,
  configGroup: string | null,
): Promise<ConfigRow | null> {
  const userRow = await db
    .prepare(
      'SELECT content, updated_at, scope, scope_key FROM proxy_config WHERE scope = ? AND scope_key = ?',
    )
    .bind('user', userId)
    .first<ConfigRow>();
  if (userRow) return userRow;

  if (configGroup) {
    const groupRow = await db
      .prepare(
        'SELECT content, updated_at, scope, scope_key FROM proxy_config WHERE scope = ? AND scope_key = ?',
      )
      .bind('group', configGroup)
      .first<ConfigRow>();
    if (groupRow) return groupRow;
  }

  return db
    .prepare(
      'SELECT content, updated_at, scope, scope_key FROM proxy_config WHERE scope = ? AND scope_key = ?',
    )
    .bind('default', '')
    .first<ConfigRow>();
}

async function allowConfigFetch(db: D1Database, userId: string): Promise<boolean> {
  const now = Math.floor(Date.now() / 1000);
  const row = await db
    .prepare('SELECT window_start, request_count FROM config_api_rate_limit WHERE user_id = ?')
    .bind(userId)
    .first<{ window_start: number; request_count: number }>();

  if (!row) {
    await db
      .prepare(
        'INSERT INTO config_api_rate_limit (user_id, window_start, request_count) VALUES (?, ?, 1)',
      )
      .bind(userId, now)
      .run();
    return true;
  }

  if (now - row.window_start >= CONFIG_RATE_WINDOW_SEC) {
    await db
      .prepare(
        'UPDATE config_api_rate_limit SET window_start = ?, request_count = 1 WHERE user_id = ?',
      )
      .bind(now, userId)
      .run();
    return true;
  }

  if (row.request_count >= CONFIG_RATE_MAX) return false;

  await db
    .prepare('UPDATE config_api_rate_limit SET request_count = request_count + 1 WHERE user_id = ?')
    .bind(userId)
    .run();
  return true;
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

type AuthorizedConfig =
  | { ok: true; session: { user: { id: string } }; config: ConfigRow; remote: null }
  | { ok: true; session: { user: { id: string } }; config: null; remote: RemoteConfigDocument }
  | { ok: false; response: Response };

type AuthenticatedUser = { session: { user: { id: string } }; username: string | null; configGroup: string | null };

async function authenticate(request: Request, env: Env): Promise<AuthenticatedUser | null> {
  const auth = getAuth(env);
  const session = await auth.api.getSession({ headers: request.headers });
  if (!session?.user?.id) return null;
  const configGroup = await env.DB.prepare('SELECT config_group FROM user WHERE id = ?')
    .bind(session.user.id)
    .first<{ config_group: string | null }>()
    .then(row => row?.config_group ?? null);
  const username = (session.user as { username?: string | null }).username ?? null;
  return { session, username, configGroup };
}

async function loadConfigFor(user: AuthenticatedUser, env: Env): Promise<AuthorizedConfig> {
  const { session, username, configGroup } = user;
  try {
    const remote = await loadRemoteConfig(env.CONFIGS, username, configGroup);
    if (remote) return { ok: true, session, config: null, remote };
  } catch (error) {
    if (!(error instanceof RemoteConfigInvalid)) throw error;
    console.error(JSON.stringify({ event: 'remote_config_invalid', key: error.key }));
    return { ok: false, response: failure('CONFIG_UNAVAILABLE', 503) };
  }

  const config = await resolveProxyConfig(env.DB, session.user.id, configGroup);
  if (!config) return { ok: false, response: failure('CONFIG_UNAVAILABLE', 503) };

  return { ok: true, session, config, remote: null };
}

export default {
  async fetch(request, env, ctx) {
    try {
      const path = new URL(request.url).pathname;

      if (path === '/health' && request.method === 'GET') {
        return Response.json({ status: 'ok', app: '小猫AI代理' });
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

      if (path === '/v1/config/version' && request.method === 'GET') {
        // The lightweight poll endpoint stays outside the download quota (as before) so
        // clients can keep checking cheaply; it is throttled via min_check_seconds.
        const user = await authenticate(request, env);
        if (!user) return failure('UNAUTHORIZED', 401);
        const loaded = await loadConfigFor(user, env);
        if (!loaded.ok) return loaded.response;
        if (loaded.remote) {
          const { envelope, updatedAt } = loaded.remote;
          return Response.json(
            {
              version: envelope.version,
              ...(updatedAt !== null ? { updated_at: updatedAt } : {}),
              min_check_seconds: DEFAULT_MIN_CHECK_SECONDS,
              minClientVersion: envelope.minClientVersion,
              sha256: envelope.sha256,
            },
            { headers: { 'Cache-Control': 'no-cache', 'X-Content-Type-Options': 'nosniff' } },
          );
        }
        const { config } = loaded;
        const meta = await configRowMeta(config);
        const updatedUnix = Math.floor(new Date(config.updated_at).getTime() / 1000);
        return Response.json(
          {
            version: meta.version,
            updated_at: updatedUnix,
            min_check_seconds: DEFAULT_MIN_CHECK_SECONDS,
          },
          {
            headers: {
              'Cache-Control': 'no-cache',
              'X-Content-Type-Options': 'nosniff',
            },
          },
        );
      }

      if (path !== '/v1/config' || request.method !== 'GET') {
        return failure('NOT_FOUND', 404);
      }

      const user = await authenticate(request, env);
      if (!user) return failure('UNAUTHORIZED', 401);

      // Enforce the download quota before any KV/D1 config read or hashing, including
      // conditional requests, so over-limit accounts cannot consume storage reads or CPU.
      const allowed = await allowConfigFetch(env.DB, user.session.user.id);
      if (!allowed) return failure('RATE_LIMITED', 429);

      const loaded = await loadConfigFor(user, env);
      if (!loaded.ok) return loaded.response;
      const { session } = loaded;

      if (loaded.remote) {
        const { remote } = loaded;
        const headers: Record<string, string> = {
          'Content-Type': 'application/json; charset=utf-8',
          'Cache-Control': 'private, no-store',
          'X-Content-Type-Options': 'nosniff',
          ETag: remote.etag,
          'X-Config-Version': remote.envelope.version,
          ...(remote.updatedAt !== null ? { 'Last-Modified': new Date(remote.updatedAt * 1000).toUTCString() } : {}),
        };
        auditConfigFetch(ctx, env.DB, session.user.id, 'kv', remote.key, request.headers.get('cf-connecting-ip'));
        if (etagMatches(request.headers.get('If-None-Match'), remote.etag)) {
          return new Response(null, { status: 304, headers });
        }
        return new Response(remote.body, { headers });
      }
      const { config } = loaded;

      const meta = await configRowMeta(config);
      const headers = await configHeaders(config);
      const clientIp = request.headers.get('cf-connecting-ip');
      auditConfigFetch(ctx, env.DB, session.user.id, config.scope, config.scope_key, clientIp);

      // Date-only clients get a full response: even a later Last-Modified date
      // cannot prove that the previously selected scope/content is unchanged.
      if (etagMatches(request.headers.get('If-None-Match'), meta.etag)) {
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
