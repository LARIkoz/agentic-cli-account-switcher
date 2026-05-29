#!/usr/bin/env bash
set -euo pipefail

# Sync ~/.codex/auth.json → codex-switcher:EMAIL keychain blob.
# Triggered by launchd WatchPaths when auth.json changes (on every
# Symbioose switch, Codex login, or token refresh).
#
# Reads the email from the id_token JWT, saves the full auth.json
# as a hex-encoded keychain blob under codex-switcher:EMAIL.

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
AUTH_FILE="$CODEX_HOME/auth.json"
LOG_FILE="$CODEX_HOME/auth-sync.log"

log() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "[$ts] $*" >> "$LOG_FILE"
}

if [[ ! -f "$AUTH_FILE" ]]; then
  log "SKIP: $AUTH_FILE not found"
  exit 0
fi

email="$(python3 -c "
import json, base64
d = json.load(open('$AUTH_FILE'))
idt = d.get('tokens',{}).get('id_token','')
if idt and idt.count('.')==2:
    p = idt.split('.')[1]
    p += '=' * (-len(p) % 4)
    c = json.loads(base64.urlsafe_b64decode(p))
    print(c.get('email',''))
" 2>/dev/null || true)"

if [[ -z "$email" ]]; then
  log "SKIP: cannot extract email from $AUTH_FILE"
  exit 0
fi

service="codex-switcher:$email"
new_hex="$(xxd -p < "$AUTH_FILE" | tr -d '\n')"

if [[ -z "$new_hex" ]]; then
  log "SKIP: empty hex for $email"
  exit 0
fi

security delete-generic-password -s "$service" >/dev/null 2>&1 || true
security add-generic-password -U -s "$service" -a "$(whoami)" -w "$new_hex" >/dev/null 2>&1

log "SYNCED $email: auth.json → keychain blob (${#new_hex} hex chars)"
