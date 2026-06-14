#!/usr/bin/env bash
set -euo pipefail

# Sync ~/.codex/auth.json → codex-switcher:EMAIL keychain blob, AND make the
# VS Code / Cursor Codex extension follow account switches automatically.
#
# Triggered by launchd WatchPaths when auth.json changes (on every Symbioose
# switch, Codex login, or token refresh done BY THE OFFICIAL CLIENT).
#
# Two jobs:
#  1. Mirror auth.json → codex-switcher:EMAIL Keychain blob (backup for switching).
#  2. If the ACCOUNT (email) changed since last run — i.e. a real switch, not a
#     same-account token refresh — restart the editor's `codex app-server` so the
#     Codex panel re-reads the new account. This is what makes a Symbioose (or
#     any) switch take effect in VS Code without a manual window reload.
#
# IMPORTANT: this script is PASSIVE about tokens — it only copies bytes. It NEVER
# calls the OAuth token endpoint. Do NOT add token refreshing here. See
# docs/token-refresh-pitfall.md: OpenAI uses one-time-use rotating refresh
# tokens, so any independent refresher races the official client and kills both.

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
AUTH_FILE="$CODEX_HOME/auth.json"
LOG_FILE="$CODEX_HOME/auth-sync.log"
LAST_EMAIL_FILE="$CODEX_HOME/.auth-sync.last-email"

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

# --- Make VS Code / Cursor Codex follow the switch ---------------------------
# Only act when the ACCOUNT changed (real switch), not on same-account refreshes.
last_email=""
[[ -f "$LAST_EMAIL_FILE" ]] && last_email="$(cat "$LAST_EMAIL_FILE" 2>/dev/null || true)"
printf '%s' "$email" > "$LAST_EMAIL_FILE"

if [[ "$email" == "$last_email" ]]; then
  exit 0
fi

# Account changed → restart the editor's codex app-server so it re-reads auth.json.
# The extension host respawns it on next Codex panel use; the panel reconnects.
vscode_pids=""
while IFS= read -r pid; do
  [[ -n "$pid" ]] || continue
  cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$cmd" in
    */.vscode/extensions/openai.chatgpt-*|\
    */.vscode-insiders/extensions/openai.chatgpt-*|\
    */.cursor/extensions/openai.chatgpt-*|\
    */.windsurf/extensions/openai.chatgpt-*|\
    */.vscode-server/extensions/openai.chatgpt-*)
      vscode_pids+="$pid " ;;
  esac
done < <(pgrep -f 'codex app-server' 2>/dev/null || true)

if [[ -n "$vscode_pids" ]]; then
  # shellcheck disable=SC2086
  kill $vscode_pids 2>/dev/null || true
  log "ACCOUNT CHANGED ${last_email:-<none>} → $email: restarted VS Code/Cursor Codex app-server ($vscode_pids)"
else
  log "ACCOUNT CHANGED ${last_email:-<none>} → $email: no editor Codex app-server running"
fi
