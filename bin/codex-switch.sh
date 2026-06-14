#!/usr/bin/env bash
set -euo pipefail

CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
PRIMARY_AUTH="$CODEX_HOME_DIR/auth.json"
SECONDARY_AUTH="$CODEX_HOME_DIR/auth_account1.json"
LOCK_DIR="$CODEX_HOME_DIR/.auth-switch.lock"
BACKUP_DIR="$CODEX_HOME_DIR/auth-switch-backups"
LATEST_BACKUP_FILE="$BACKUP_DIR/latest"

usage() {
  cat <<'USAGE'
Usage:
  codex-switch.sh switch [--no-app] [--no-vscode] [--allow-running]
  codex-switch.sh restore-last [--no-app] [--no-vscode] [--allow-running]
  codex-switch.sh fix [--no-app] [--no-vscode] [--allow-running]
  codex-switch.sh acc2-status
  codex-switch.sh acc2-smoke
  codex-switch.sh preflight
  codex-switch.sh status

Commands:
  switch    Swap auth.json <-> auth_account1.json across ALL Codex surfaces:
            quit+reopen the Codex App, and restart the VS Code/Cursor Codex
            app-server so the extension re-reads the new account.
            Running it again switches back.
  restore-last
            Restore auth.json and auth_account1.json from the latest backup pair.
  fix       Alias for restore-last.
  acc2-status
            Check approved alternate Codex profile at ~/.codex2.
  acc2-smoke
            Run a tiny read-only codex exec through CODEX_HOME=~/.codex2.
  preflight
            Validate auth files and report whether unmanaged Codex auth-using
            processes are still running. Does not switch anything.
  status    Print safe file metadata only. Does not print token contents.

Options:
  --no-app   Do not quit or reopen the Codex desktop App.
  --no-vscode
             Do not restart the VS Code/Cursor Codex app-server. By default the
             switch kills the editor's `codex app-server` so the extension
             respawns it and re-reads auth.json; the Codex panel reconnects on
             next use. Pass this to leave the editor untouched (file-only swap).
  --allow-running
            Allow switch/fix while UNMANAGED codex auth processes (e.g. a
            `codex exec` in a terminal) are still running. Unsafe; use only for
            emergency manual recovery.

Notes:
  - All three Codex surfaces (CLI, desktop App, VS Code/Cursor extension) share
    ~/.codex/auth.json. Long-running clients cache the token in memory, so the
    switch must restart them to pick up the swap. This script handles the App
    and the editor automatically; the CLI re-reads auth.json on each run.
  - Run from macOS Terminal/iTerm, not from a terminal embedded in Codex App.
  - Does not edit token contents.
  - Creates timestamped backups under ~/.codex/auth-switch-backups.
  - Uses CODEX_HOME if set; otherwise uses ~/.codex.
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

release_lock() {
  rm -f "$LOCK_DIR/pid" 2>/dev/null || true
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

safe_stat() {
  local file="$1"
  if [[ -f "$file" ]]; then
    stat -f '%N size=%z mode=%Sp modified=%Sm' -t '%Y-%m-%d %H:%M:%S' "$file"
  else
    printf '%s missing\n' "$file"
  fi
}

require_auth_files() {
  [[ -d "$CODEX_HOME_DIR" ]] || die "Codex home not found: $CODEX_HOME_DIR"
  [[ -f "$PRIMARY_AUTH" ]] || die "missing $PRIMARY_AUTH"
  [[ -f "$SECONDARY_AUTH" ]] || die "missing $SECONDARY_AUTH"
  [[ ! -L "$PRIMARY_AUTH" ]] || die "$PRIMARY_AUTH is a symlink; refusing to break symlink-managed auth"
  [[ ! -L "$SECONDARY_AUTH" ]] || die "$SECONDARY_AUTH is a symlink; refusing to break symlink-managed auth"
  [[ ! "$PRIMARY_AUTH" -ef "$SECONDARY_AUTH" ]] || die "auth files point to the same file"
}

validate_json_shape() {
  local file="$1"
  node -e '
    const fs = require("fs");
    const file = process.argv[1];
    const j = JSON.parse(fs.readFileSync(file, "utf8"));
    for (const k of ["auth_mode", "tokens"]) {
      if (!(k in j)) throw new Error(`${file}: missing ${k}`);
    }
  ' "$file" >/dev/null
}

acquire_lock() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    local old_pid=""
    [[ -f "$LOCK_DIR/pid" ]] && old_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ "$old_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$old_pid" 2>/dev/null; then
      rm -rf "$LOCK_DIR"
      mkdir "$LOCK_DIR" 2>/dev/null || die "switch lock exists: $LOCK_DIR"
    else
      die "switch lock exists: $LOCK_DIR"
    fi
  fi
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  trap release_lock EXIT
}

quit_codex_app() {
  osascript -e 'quit app "Codex"' >/dev/null 2>&1 || true
  local waited=0
  while codex_auth_processes_running >/dev/null 2>&1; do
    if (( waited >= 20 )); then
      die "Codex App/app-server still running after ${waited}s; close Codex/VS Code manually and retry"
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

open_codex_app() {
  open -a Codex >/dev/null 2>&1 || true
}

# Why: the VS Code / Cursor Codex extension (openai.chatgpt) spawns a long-lived
# `codex app-server` from its bundled binary. That server reads ~/.codex/auth.json
# ONCE at startup and caches the token in memory, so an external auth swap is
# invisible to it until it restarts. We identify those servers by their binary
# path living inside an editor extensions dir.
vscode_codex_pids() {
  local pid command
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$command" in
      */.vscode/extensions/openai.chatgpt-*|\
      */.vscode-insiders/extensions/openai.chatgpt-*|\
      */.cursor/extensions/openai.chatgpt-*|\
      */.windsurf/extensions/openai.chatgpt-*|\
      */.vscode-server/extensions/openai.chatgpt-*)
        printf '%s\n' "$pid" ;;
    esac
  done < <(pgrep -f 'codex app-server' 2>/dev/null || true)
}

# Why: restart the editor's Codex app-server so it re-reads the swapped auth.json.
# The extension host respawns it automatically on next Codex panel use (the panel
# reconnects), reading the new account. We do NOT need to reopen anything.
kill_vscode_codex() {
  local pids
  pids="$(vscode_codex_pids)"
  if [[ -z "$pids" ]]; then
    printf 'VS Code/Cursor Codex: no app-server running\n'
    return 0
  fi
  printf 'VS Code/Cursor Codex: restarting app-server (pids: %s)\n' "$(printf '%s ' $pids)"
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  local waited=0
  while [[ -n "$(vscode_codex_pids)" ]] && (( waited < 6 )); do
    sleep 1
    waited=$((waited + 1))
  done
  # Escalate to SIGKILL if any survived a graceful term.
  local survivors
  survivors="$(vscode_codex_pids)"
  if [[ -n "$survivors" ]]; then
    # shellcheck disable=SC2086
    kill -9 $survivors 2>/dev/null || true
  fi
}

codex_auth_processes_running() {
  local pids=()
  local pid command

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [[ -n "$command" ]] || continue
    [[ "$command" == *chrome_crashpad_handler* ]] && continue
    pids+=("$pid")
  done < <({
    pgrep -f '/Applications/Codex\.app/Contents/(MacOS/Codex|Frameworks/Codex Helper|Resources/codex app-server)' 2>/dev/null || true
    pgrep -f 'codex app-server' 2>/dev/null || true
  } | sort -u)

  if (( ${#pids[@]} > 0 )); then
    printf '%s\n' "${pids[*]}"
    return 0
  fi
  return 1
}

# Why: only processes we do NOT manage should block a swap. App processes are
# managed when manage_app=yes (we quit/reopen). Editor app-servers are managed
# when manage_vscode=yes (we kill/respawn). Anything left (e.g. a `codex exec`
# in a terminal) genuinely holds auth.json and must block unless --allow-running.
blocking_codex_pids() {
  local manage_app="$1"
  local manage_vscode="$2"
  local pid command
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [[ -n "$command" ]] || continue
    [[ "$command" == *chrome_crashpad_handler* ]] && continue
    if [[ "$manage_app" == "yes" && "$command" == */Applications/Codex.app/* ]]; then
      continue
    fi
    if [[ "$manage_vscode" == "yes" ]]; then
      case "$command" in
        */.vscode/extensions/openai.chatgpt-*|\
        */.vscode-insiders/extensions/openai.chatgpt-*|\
        */.cursor/extensions/openai.chatgpt-*|\
        */.windsurf/extensions/openai.chatgpt-*|\
        */.vscode-server/extensions/openai.chatgpt-*)
          continue ;;
      esac
    fi
    printf '%s\n' "$pid"
  done < <({
    pgrep -f '/Applications/Codex\.app/Contents/(MacOS/Codex|Frameworks/Codex Helper|Resources/codex app-server)' 2>/dev/null || true
    pgrep -f 'codex app-server' 2>/dev/null || true
  } | sort -u)
}

ensure_no_codex_auth_processes() {
  local manage_app="$1"
  local manage_vscode="$2"
  local allow_running="$3"
  local pids=""
  pids="$(blocking_codex_pids "$manage_app" "$manage_vscode" | tr '\n' ' ' | sed 's/ *$//')"
  [[ -z "$pids" ]] && return 0

  if [[ "$allow_running" == "yes" ]]; then
    printf 'warning: unmanaged Codex auth process(es) still running: %s\n' "$pids" >&2
    printf 'warning: continuing because --allow-running was provided\n' >&2
    return 0
  fi

  printf 'error: unmanaged Codex auth process(es) still running: %s\n' "$pids" >&2
  printf 'error: these hold auth.json and are not managed by this switch.\n' >&2
  printf 'error: close any `codex` running in a terminal (or pass --allow-running), then retry\n' >&2
  exit 1
}

switch_accounts() {
  local manage_app="$1"
  local manage_vscode="$2"
  local allow_running="$3"
  require_auth_files
  validate_json_shape "$PRIMARY_AUTH"
  validate_json_shape "$SECONDARY_AUTH"
  acquire_lock

  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR" 2>/dev/null || true

  local stamp
  stamp="$(date +%Y%m%d-%H%M%S).$$"

  # Stop every long-running client that caches the token BEFORE the swap, so none
  # can write a stale token back over the file mid-switch.
  if [[ "$manage_app" == "yes" ]]; then
    quit_codex_app
  fi
  if [[ "$manage_vscode" == "yes" ]]; then
    kill_vscode_codex
  fi
  ensure_no_codex_auth_processes "$manage_app" "$manage_vscode" "$allow_running"

  local primary_backup secondary_backup
  primary_backup="$BACKUP_DIR/auth.primary.$stamp.json"
  secondary_backup="$BACKUP_DIR/auth.secondary.$stamp.json"

  cp -p "$PRIMARY_AUTH" "$primary_backup"
  cp -p "$SECONDARY_AUTH" "$secondary_backup"
  printf '%s\n' "$stamp" > "$LATEST_BACKUP_FILE"

  local tmp
  tmp="$CODEX_HOME_DIR/.auth.switch.tmp.$stamp.json"

  local swap_done="no"
  rollback_on_error() {
    local exit_code=$?
    if [[ "$swap_done" != "yes" ]]; then
      printf 'switch failed; restoring latest backup pair\n' >&2
      cp -p "$primary_backup" "$PRIMARY_AUTH" 2>/dev/null || true
      cp -p "$secondary_backup" "$SECONDARY_AUTH" 2>/dev/null || true
      rm -f "$tmp" 2>/dev/null || true
    fi
    exit "$exit_code"
  }

  trap rollback_on_error ERR INT TERM

  cp -p "$SECONDARY_AUTH" "$tmp"
  cp -p "$PRIMARY_AUTH" "$SECONDARY_AUTH"
  mv "$tmp" "$PRIMARY_AUTH"

  validate_json_shape "$PRIMARY_AUTH"
  validate_json_shape "$SECONDARY_AUTH"
  swap_done="yes"
  trap release_lock EXIT

  printf 'switched Codex auth files\n'
  safe_stat "$PRIMARY_AUTH"
  safe_stat "$SECONDARY_AUTH"
  printf 'backup dir: %s\n' "$BACKUP_DIR"

  if command -v codex >/dev/null 2>&1; then
    codex login status || true
  fi

  if [[ "$manage_app" == "yes" ]]; then
    open_codex_app
  fi
  if [[ "$manage_vscode" == "yes" ]]; then
    printf 'VS Code/Cursor Codex: app-server stopped; the Codex panel reconnects on next use (or reload the window).\n'
  fi
}

latest_backup_stamp() {
  if [[ -f "$LATEST_BACKUP_FILE" ]]; then
    local stamp
    stamp="$(cat "$LATEST_BACKUP_FILE" 2>/dev/null || true)"
    if [[ -n "$stamp" \
      && -f "$BACKUP_DIR/auth.primary.$stamp.json" \
      && -f "$BACKUP_DIR/auth.secondary.$stamp.json" ]]; then
      printf '%s\n' "$stamp"
      return 0
    fi
  fi

  find "$BACKUP_DIR" -maxdepth 1 -type f -name 'auth.primary.*.json' 2>/dev/null \
    | sed -E 's/^.*auth\.primary\.(.*)\.json$/\1/' \
    | sort \
    | tail -1
}

restore_last() {
  local manage_app="$1"
  local manage_vscode="$2"
  local allow_running="$3"
  [[ -d "$BACKUP_DIR" ]] || die "backup dir not found: $BACKUP_DIR"
  acquire_lock

  local stamp primary_backup secondary_backup
  stamp="$(latest_backup_stamp)"
  [[ -n "$stamp" ]] || die "no backup pairs found in $BACKUP_DIR"

  primary_backup="$BACKUP_DIR/auth.primary.$stamp.json"
  secondary_backup="$BACKUP_DIR/auth.secondary.$stamp.json"
  [[ -f "$primary_backup" ]] || die "missing $primary_backup"
  [[ -f "$secondary_backup" ]] || die "missing $secondary_backup"
  validate_json_shape "$primary_backup"
  validate_json_shape "$secondary_backup"

  if [[ "$manage_app" == "yes" ]]; then
    quit_codex_app
  fi
  if [[ "$manage_vscode" == "yes" ]]; then
    kill_vscode_codex
  fi
  ensure_no_codex_auth_processes "$manage_app" "$manage_vscode" "$allow_running"

  local tmp_primary tmp_secondary restore_done
  tmp_primary="$CODEX_HOME_DIR/.auth.restore.primary.$stamp.json"
  tmp_secondary="$CODEX_HOME_DIR/.auth.restore.secondary.$stamp.json"
  restore_done="no"

  rollback_restore_on_error() {
    local exit_code=$?
    if [[ "$restore_done" != "yes" ]]; then
      printf 'restore failed; retrying backup copy\n' >&2
      cp -p "$primary_backup" "$PRIMARY_AUTH" 2>/dev/null || true
      cp -p "$secondary_backup" "$SECONDARY_AUTH" 2>/dev/null || true
      rm -f "$tmp_primary" "$tmp_secondary" 2>/dev/null || true
    fi
    exit "$exit_code"
  }

  trap rollback_restore_on_error ERR INT TERM

  cp -p "$primary_backup" "$tmp_primary"
  cp -p "$secondary_backup" "$tmp_secondary"
  mv "$tmp_primary" "$PRIMARY_AUTH"
  mv "$tmp_secondary" "$SECONDARY_AUTH"
  validate_json_shape "$PRIMARY_AUTH"
  validate_json_shape "$SECONDARY_AUTH"
  restore_done="yes"
  trap release_lock EXIT

  printf 'restored latest Codex auth backup pair: %s\n' "$stamp"
  safe_stat "$PRIMARY_AUTH"
  safe_stat "$SECONDARY_AUTH"

  if command -v codex >/dev/null 2>&1; then
    codex login status || true
  fi

  if [[ "$manage_app" == "yes" ]]; then
    open_codex_app
  fi
  if [[ "$manage_vscode" == "yes" ]]; then
    printf 'VS Code/Cursor Codex: app-server stopped; the Codex panel reconnects on next use (or reload the window).\n'
  fi
}

preflight() {
  require_auth_files
  validate_json_shape "$PRIMARY_AUTH"
  validate_json_shape "$SECONDARY_AUTH"

  printf 'auth files OK\n'
  safe_stat "$PRIMARY_AUTH"
  safe_stat "$SECONDARY_AUTH"

  local all_pids blocking
  all_pids="$(codex_auth_processes_running || true)"
  if [[ -n "$all_pids" ]]; then
    printf 'codex auth processes running: %s\n' "$all_pids"
    printf '  (a default switch restarts the Codex App and the VS Code/Cursor app-server automatically)\n'
  fi

  # Only UNMANAGED processes (e.g. a terminal `codex`) block a default switch.
  blocking="$(blocking_codex_pids "yes" "yes" | tr '\n' ' ' | sed 's/ *$//')"
  if [[ -n "$blocking" ]]; then
    printf 'BLOCKED: unmanaged codex auth process(es): %s\n' "$blocking" >&2
    printf 'Close any `codex` running in a terminal (or use --allow-running) before switching.\n' >&2
    return 1
  fi

  printf 'READY: switch will restart managed Codex surfaces; nothing unmanaged is holding auth.json\n'
}

acc2_home() {
  printf '%s/.codex2\n' "$HOME"
}

acc2_status() {
  command -v codex >/dev/null 2>&1 || die "codex CLI not found in PATH"
  local home
  home="$(acc2_home)"
  [[ -d "$home" ]] || die "approved acc#2 CODEX_HOME not found: $home"
  [[ -f "$home/auth.json" ]] || die "missing acc#2 auth file: $home/auth.json"
  validate_json_shape "$home/auth.json"
  CODEX_HOME="$home" codex login status
  safe_stat "$home/auth.json"
}

acc2_smoke() {
  command -v codex >/dev/null 2>&1 || die "codex CLI not found in PATH"
  local home
  home="$(acc2_home)"
  [[ -d "$home" ]] || die "approved acc#2 CODEX_HOME not found: $home"
  [[ -f "$home/auth.json" ]] || die "missing acc#2 auth file: $home/auth.json"
  validate_json_shape "$home/auth.json"
  printf 'Reply exactly: ACC2_CODEX_HOME_OK\n' \
    | CODEX_HOME="$home" codex exec --ephemeral --skip-git-repo-check \
        --sandbox read-only --cd "$PWD" -
}

main() {
  local cmd="${1:-}"
  local manage_app="yes"
  local manage_vscode="yes"
  local allow_running="no"

  case "$cmd" in
    switch)
      shift
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --no-app) manage_app="no" ;;
          --no-vscode) manage_vscode="no" ;;
          --allow-running) allow_running="yes" ;;
          -h|--help) usage; exit 0 ;;
          *) die "unknown option: $1" ;;
        esac
        shift
      done
      switch_accounts "$manage_app" "$manage_vscode" "$allow_running"
      ;;
    restore-last|fix)
      shift
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --no-app) manage_app="no" ;;
          --no-vscode) manage_vscode="no" ;;
          --allow-running) allow_running="yes" ;;
          -h|--help) usage; exit 0 ;;
          *) die "unknown option: $1" ;;
        esac
        shift
      done
      restore_last "$manage_app" "$manage_vscode" "$allow_running"
      ;;
    status)
      require_auth_files
      safe_stat "$PRIMARY_AUTH"
      safe_stat "$SECONDARY_AUTH"
      ;;
    preflight)
      preflight
      ;;
    acc2-status)
      shift
      [[ $# -eq 0 ]] || die "acc2-status does not accept options"
      acc2_status
      ;;
    acc2-smoke)
      shift
      [[ $# -eq 0 ]] || die "acc2-smoke does not accept options"
      acc2_smoke
      ;;
    -h|--help|"")
      usage
      ;;
    *)
      die "unknown command: $cmd"
      ;;
  esac
}

main "$@"
