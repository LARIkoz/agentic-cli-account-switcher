#!/usr/bin/env bash
set -euo pipefail

# Refresh OAuth tokens for all saved Codex account blobs in Keychain.
# Prevents "refresh token already used" errors after switching accounts.
#
# Usage:
#   codex-refresh-tokens.sh          # refresh all saved accounts
#   codex-refresh-tokens.sh --quiet  # suppress output except errors
#
# Can be run manually, from cron, or from a launchd plist.
# Does NOT touch the currently active auth.json — only Keychain blobs.
#
# OAuth flow: read blob → call token endpoint with refresh_token →
# save new access_token + refresh_token + id_token back to blob.

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
TOKEN_ENDPOINT="https://auth0.openai.com/oauth/token"
CLIENT_ID="app_EMoamEEZ73f0CkXaXp7hrann"
LOG_FILE="${CODEX_HOME}/token-refresh.log"
QUIET="${1:-}"

log() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "[$ts] $*" >> "$LOG_FILE"
  [[ "$QUIET" == "--quiet" ]] || echo "$*"
}

refresh_blob() {
  local service="$1"
  local email
  email="${service#codex-switcher:}"

  local hex_blob
  # macOS Sequoia dumps entry metadata to stdout before the password for long values.
  # Filter to only the hex line (no spaces, no colons in hex output).
  hex_blob="$(security find-generic-password -s "$service" -w 2>/dev/null | grep -E '^[0-9a-f]+$' || true)"
  if [[ -z "$hex_blob" ]]; then
    log "SKIP $email: no keychain blob"
    return 0
  fi

  local blob
  blob="$(echo "$hex_blob" | xxd -r -p 2>/dev/null || true)"
  if [[ -z "$blob" ]]; then
    log "SKIP $email: cannot decode blob"
    return 0
  fi

  local rt
  rt="$(echo "$blob" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tokens',{}).get('refresh_token',''))" 2>/dev/null || true)"
  if [[ -z "$rt" ]]; then
    log "SKIP $email: no refresh_token in blob"
    return 0
  fi

  local resp http_code
  resp="$(curl -sS -X POST "$TOKEN_ENDPOINT" \
    -H "Content-Type: application/json" \
    -d "{\"grant_type\":\"refresh_token\",\"refresh_token\":\"$rt\",\"client_id\":\"$CLIENT_ID\"}" \
    2>/dev/null || true)"

  # Parse response via env vars to avoid shell-expansion issues with JWTs
  local new_at new_rt new_idt error_code
  new_at="$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null || true)"
  new_rt="$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('refresh_token',''))" 2>/dev/null || true)"
  new_idt="$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id_token',''))" 2>/dev/null || true)"
  error_code="$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); e=d.get('error',{}); print(e.get('code','') if isinstance(e,dict) else '')" 2>/dev/null || true)"

  if [[ -n "$new_at" && -n "$new_rt" ]]; then
    local ts_now
    ts_now="$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)"

    # Update blob via env vars (safe for JWTs with special chars)
    export _REFRESH_AT="$new_at" _REFRESH_RT="$new_rt" _REFRESH_IDT="${new_idt:-}" _REFRESH_TS="$ts_now"
    local updated_blob
    updated_blob="$(python3 -c "
import json, sys, os
d = json.loads(sys.stdin.read())
d['tokens']['access_token'] = os.environ['_REFRESH_AT']
d['tokens']['refresh_token'] = os.environ['_REFRESH_RT']
idt = os.environ.get('_REFRESH_IDT', '')
if idt:
    d['tokens']['id_token'] = idt
d['last_refresh'] = os.environ['_REFRESH_TS']
print(json.dumps(d))
" <<< "$blob" 2>/dev/null || true)"
    unset _REFRESH_AT _REFRESH_RT _REFRESH_IDT _REFRESH_TS

    if [[ -n "$updated_blob" ]]; then
      local new_hex
      new_hex="$(echo -n "$updated_blob" | xxd -p | tr -d '\n')"
      security delete-generic-password -s "$service" >/dev/null 2>&1 || true
      security add-generic-password -U -s "$service" -a "$(whoami)" -w "$new_hex" >/dev/null 2>&1
      log "OK $email: tokens refreshed"
      return 0
    fi
  fi

  if [[ "$error_code" == "refresh_token_reused" || "$error_code" == "refresh_token_invalidated" ]]; then
    log "DEAD $email: refresh token dead ($error_code) — needs re-login"
    return 1
  fi

  log "FAIL $email: unexpected response: ${resp:0:200}"
  return 1
}

main() {
  log "--- refresh cycle start ---"

  local services
  # Enumerate codex-switcher Keychain entries. Pipe stderr to /dev/null
  # to suppress macOS metadata dumps.
  services="$(security dump-keychain 2>/dev/null <<< '' \
    | grep -o '"svce"<blob>="codex-switcher:[^"]*"' \
    | sed 's/.*"codex-switcher:/codex-switcher:/; s/"$//' \
    | sort -u || true)" 2>/dev/null

  if [[ -z "$services" ]]; then
    log "No codex-switcher blobs found in Keychain"
    return 0
  fi

  local total=0 ok=0 dead=0 skip=0
  while IFS= read -r svc; do
    total=$((total + 1))
    if refresh_blob "$svc"; then
      case "$(tail -1 "$LOG_FILE")" in
        *SKIP*) skip=$((skip + 1)) ;;
        *) ok=$((ok + 1)) ;;
      esac
    else
      dead=$((dead + 1))
    fi
  done <<< "$services"

  log "--- refresh cycle done: $ok refreshed, $skip skipped, $dead dead (of $total) ---"
  [[ $dead -eq 0 ]] || return 1
}

main
