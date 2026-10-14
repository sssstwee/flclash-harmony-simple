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

export function normalizeEtag(value: string | null): string | null {
  if (!value) return null;
  const trimmed = value.trim();
  if (!trimmed) return null;
  return trimmed.replace(/^W\//, '');
}

export function etagMatches(clientHeader: string | null, etag: string): boolean {
  const normalized = normalizeEtag(clientHeader);
  if (!normalized) return false;
  const candidates = normalized.split(',').map(part => part.trim());
  const target = normalizeEtag(etag);
  return candidates.some(candidate => candidate === target);
}
