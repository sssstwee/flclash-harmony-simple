#!/usr/bin/env bash
# Fail CI if known secret patterns or deploy-specific identifiers are committed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

SCAN_PATHS=(
  .
)

EXCLUDES=(
  --glob '!.github/scripts/check-no-secrets.sh'
  --glob '!**/GEOSITE.dat'
  --glob '!**/GEOIP.dat'
  --glob '!pubspec.lock'
  --glob '!CHANGELOG.md'
)

fail() {
  echo "check-no-secrets: $1" >&2
  exit 1
}

# Substring of a previously leaked workers.dev hostname (not a full URL).
FORBIDDEN=(
  'tokenforsell'
)

for needle in "${FORBIDDEN[@]}"; do
  if rg -F "$needle" "${EXCLUDES[@]}" "${SCAN_PATHS[@]}" >/dev/null 2>&1; then
    rg -n -F "$needle" "${EXCLUDES[@]}" "${SCAN_PATHS[@]}" >&2 || true
    fail "forbidden string: $needle"
  fi
done

# Personal deploy hostnames (allow only placeholders in *.example and docs mentioning the pattern).
if rg -n \
  "${EXCLUDES[@]}" \
  -e 'https://clash-harmony-api\.(workers|pages)\.dev' \
  --glob '!.github/scripts/*' \
  --glob '!*.example' \
  --glob '!backend/wrangler.local.jsonc.example' \
  . >/dev/null 2>&1; then
  rg -n \
    "${EXCLUDES[@]}" \
    -e 'https://clash-harmony-api\.(workers|pages)\.dev' \
    --glob '!.github/scripts/*' \
    --glob '!*.example' \
    . >&2 || true
  fail 'deploy-specific clash-harmony-api *.dev URL in tracked files'
fi

# D1 database_id must stay placeholder-only in wrangler configs.
if rg -n \
  'database_id": "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"' \
  backend/wrangler.jsonc backend/wrangler.local.jsonc.example 2>/dev/null \
  | rg -v '00000000-0000-0000-0000-000000000000' \
  | rg -v 'YOUR-D1-DATABASE-UUID' >/dev/null 2>&1; then
  fail 'non-placeholder database_id in wrangler config'
fi

# Fingerprint of a rotated D1 id: sha256 of the UUID string, literal not stored in git.
LEAKED_D1_SHA256='1c446b78d3d383b101f11be506a5817e398b263157e402093ac02ccc0b198f21'
while IFS= read -r uuid; do
  case "$uuid" in
    00000000-0000-0000-0000-000000000000 | YOUR-D1-DATABASE-UUID) continue ;;
  esac
  hash=$(printf '%s' "$uuid" | sha256sum | awk '{print $1}')
  if [ "$hash" = "$LEAKED_D1_SHA256" ]; then
    fail 'leaked D1 database_id fingerprint detected'
  fi
done < <(
  rg -o --no-filename '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
    "${EXCLUDES[@]}" "${SCAN_PATHS[@]}" 2>/dev/null | sort -u
)

# Mihomo/Clash subscription-shaped secrets in tests (allow example.org fixtures).
if rg -n \
  -e 'ss://|vmess://|trojan://' \
  --glob '!backend/test/*' \
  --glob '!test/*' \
  . >/dev/null 2>&1; then
  fail 'proxy URI scheme outside test fixtures'
fi

echo 'check-no-secrets: OK'
