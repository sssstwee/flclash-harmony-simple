#!/usr/bin/env bash
set -euo pipefail
# Never enable shell tracing: credentials are passed to curl on stdin.
set +x
: "${SUBSCRIPTION_FILE:?set SUBSCRIPTION_FILE to local YAML path}"
: "${SUBSCRIPTION_PUSH_URL:?set HTTPS endpoint URL (optional scope/key query)}"
[[ "$SUBSCRIPTION_PUSH_URL" == https://* ]] || { echo 'HTTPS required' >&2; exit 1; }
if [[ -n "${SUBSCRIPTION_PUSH_TOKEN_FILE:-}" ]]; then
  [[ -f "$SUBSCRIPTION_PUSH_TOKEN_FILE" && ! -L "$SUBSCRIPTION_PUSH_TOKEN_FILE" &&
     "$(stat -c %a "$SUBSCRIPTION_PUSH_TOKEN_FILE")" == 600 &&
     -O "$SUBSCRIPTION_PUSH_TOKEN_FILE" ]] || { echo 'Token file must be owned by current user with mode 600' >&2; exit 1; }
  SUBSCRIPTION_PUSH_TOKEN=$(cat -- "$SUBSCRIPTION_PUSH_TOKEN_FILE")
fi
: "${SUBSCRIPTION_PUSH_TOKEN:?set token env or SUBSCRIPTION_PUSH_TOKEN_FILE}"
[[ "$SUBSCRIPTION_PUSH_TOKEN" =~ ^[A-Za-z0-9_-]+$ ]] || { echo 'Use a base64url token' >&2; exit 1; }
printf 'header = "Authorization: Bearer %s"\n' "$SUBSCRIPTION_PUSH_TOKEN" |
  curl --config - --silent --show-error --fail-with-body \
    --retry 4 --retry-all-errors --retry-delay 5 --connect-timeout 10 --max-time 45 \
    --proto '=https' --request POST --header 'Content-Type: application/yaml' \
    --data-binary "@$SUBSCRIPTION_FILE" --url "$SUBSCRIPTION_PUSH_URL"
