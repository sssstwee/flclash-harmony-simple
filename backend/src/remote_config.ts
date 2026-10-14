import { configRowMeta, sha256Hex } from './config_meta';

/** Versioned, data-only remote configuration envelope (schemaVersion 1). */
export type RemoteConfigEnvelope = {
  schemaVersion: 1;
  version: string;
  minClientVersion: string;
  sha256: string;
  payload: string;
};

export type RemoteConfigDocument = {
  envelope: RemoteConfigEnvelope;
  body: string;
  key: string;
  updatedAt: number | null;
  etag: string;
};

const ENVELOPE_KEYS = ['schemaVersion', 'version', 'minClientVersion', 'sha256', 'payload'];
const CLIENT_VERSION = /^\d+\.\d+\.\d+(?:\+\d+)?$/;
export const REMOTE_CONFIG_MAX_BYTES = 1024 * 1024;

export class RemoteConfigInvalid extends Error {
  constructor(public readonly key: string) {
    super('Invalid remote configuration');
    this.name = 'RemoteConfigInvalid';
  }
}

/** KV lookup order mirrors D1: user override, then group, then default. */
export function remoteConfigKeys(username: string | null | undefined, group: string | null): string[] {
  return [
    ...(username ? [`user:${username}`] : []),
    ...(group ? [`group:${group}`] : []),
    'default',
  ];
}

export async function validateEnvelope(raw: string, key: string): Promise<RemoteConfigEnvelope> {
  if (new TextEncoder().encode(raw).byteLength > REMOTE_CONFIG_MAX_BYTES) throw new RemoteConfigInvalid(key);
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new RemoteConfigInvalid(key);
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new RemoteConfigInvalid(key);
  const doc = value as Record<string, unknown>;
  const keys = Object.keys(doc);
  if (keys.length !== ENVELOPE_KEYS.length || !ENVELOPE_KEYS.every(k => keys.includes(k))) {
    throw new RemoteConfigInvalid(key);
  }
  if (
    doc.schemaVersion !== 1 ||
    typeof doc.version !== 'string' || !doc.version ||
    typeof doc.minClientVersion !== 'string' || !CLIENT_VERSION.test(doc.minClientVersion) ||
    typeof doc.payload !== 'string' ||
    typeof doc.sha256 !== 'string'
  ) {
    throw new RemoteConfigInvalid(key);
  }
  if ((await sha256Hex(doc.payload)) !== doc.sha256.toLowerCase()) throw new RemoteConfigInvalid(key);
  try {
    JSON.parse(doc.payload);
  } catch {
    throw new RemoteConfigInvalid(key);
  }
  return doc as unknown as RemoteConfigEnvelope;
}

export async function loadRemoteConfig(
  kv: KVNamespace | undefined,
  username: string | null | undefined,
  group: string | null,
): Promise<RemoteConfigDocument | null> {
  if (!kv) return null;
  for (const key of remoteConfigKeys(username, group)) {
    const { value, metadata } = await kv.getWithMetadata<{ updatedAt?: number }>(key, 'text');
    if (value === null) continue;
    const envelope = await validateEnvelope(value, key);
    const body = JSON.stringify(envelope);
    const meta = await configRowMeta({
      scope: 'kv',
      scope_key: key,
      content: `${envelope.version}\n${envelope.sha256}\n${envelope.minClientVersion}`,
    });
    const updatedAt = typeof metadata?.updatedAt === 'number' ? metadata.updatedAt : null;
    return { envelope, body, key, updatedAt, etag: meta.etag };
  }
  return null;
}
