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

# Known leaked identifiers (rotate if ever deployed).
FORBIDDEN=(
  'tokenforsell'
  '00000000-0000-0000-0000-000000000000'
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

# Real D1 UUIDs in wrangler (placeholder all-zero and example tokens only).
if rg -n \
  'database_id": "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"' \
  backend/wrangler.jsonc backend/wrangler.local.jsonc.example 2>/dev/null \
  | rg -v '00000000-0000-0000-0000-000000000000' \
  | rg -v 'YOUR-D1-DATABASE-UUID' >/dev/null 2>&1; then
  fail 'non-placeholder database_id in wrangler config'
fi

# Mihomo/Clash subscription-shaped secrets in tests (allow example.org fixtures).
if rg -n \
  -e 'ss://|vmess://|trojan://' \
  --glob '!backend/test/*' \
  --glob '!test/*' \
  . >/dev/null 2>&1; then
  fail 'proxy URI scheme outside test fixtures'
fi

echo 'check-no-secrets: OK'
