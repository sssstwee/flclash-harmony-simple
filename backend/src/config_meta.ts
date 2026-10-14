export const DEFAULT_MIN_CHECK_SECONDS = 300;

export async function sha256Hex(content: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(content),
  );
  return [...new Uint8Array(digest)]
    .map(byte => byte.toString(16).padStart(2, '0'))
    .join('');
}

export async function configContentMeta(content: string) {
  const hex = await sha256Hex(content);
  return {
    etag: `"${hex}"`,
    version: hex.slice(0, 16),
  };
}

export type ConfigRepresentation = {
  scope: string;
  scope_key: string;
  content: string;
};

export async function configRowMeta(config: ConfigRepresentation) {
  const bytes = new TextEncoder().encode(
    JSON.stringify([config.scope, config.scope_key, config.content]),
  );
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  const hex = [...new Uint8Array(digest)]
    .map(byte => byte.toString(16).padStart(2, '0'))
    .join('');
  return {
    etag: `"${hex}"`,
    version: hex.slice(0, 16),
  };
}

export function normalizeEtag(value: string | null): string | null {
  if (!value) return null;
  const trimmed = value.trim();
  if (!trimmed) return null;
  return trimmed.replace(/^W\//, '');
}

export function etagMatches(clientHeader: string | null, etag: string): boolean {
  if (!clientHeader?.trim()) return false;
  const target = normalizeEtag(etag);
  if (!target) return false;
  return clientHeader.split(',').some(part => {
    const candidate = part.trim();
    if (candidate === '*') return true;
    return normalizeEtag(candidate) === target;
  });
}
