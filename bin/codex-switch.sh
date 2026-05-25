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
  codex-switch.sh switch [--no-app] [--allow-running]
  codex-switch.sh restore-last [--no-app] [--allow-running]
  codex-switch.sh fix [--no-app] [--allow-running]
  codex-switch.sh acc2-status
  codex-switch.sh acc2-smoke
  codex-switch.sh preflight
  codex-switch.sh status

Commands:
  switch    Quit Codex App, swap auth.json <-> auth_account1.json, reopen Codex App.
            Running it again switches back.
  restore-last
            Restore auth.json and auth_account1.json from the latest backup pair.
  fix       Alias for restore-last.
  acc2-status
            Check approved alternate Codex profile at ~/.codex2.
  acc2-smoke
            Run a tiny read-only codex exec through CODEX_HOME=~/.codex2.
  preflight
            Validate auth files and report whether Codex auth-using processes
            are still running. Does not switch anything.
  status    Print safe file metadata only. Does not print token contents.

Options:
  --no-app  Do not quit or reopen Codex App. Only swap files.
  --allow-running
            Allow switch/fix while Codex App or other codex app-server processes
            are still running. Unsafe; use only for emergency manual recovery.

Notes:
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

ensure_no_codex_auth_processes() {
  local allow_running="$1"
  local pids=""
  pids="$(codex_auth_processes_running || true)"
  [[ -z "$pids" ]] && return 0

  if [[ "$allow_running" == "yes" ]]; then
    printf 'warning: Codex auth-using process(es) still running: %s\n' "$pids" >&2
    printf 'warning: continuing because --allow-running was provided\n' >&2
    return 0
  fi

  printf 'error: Codex auth-using process(es) still running: %s\n' "$pids" >&2
  printf 'error: close Codex App, VS Code/Codex extensions, and other codex app-server processes, then retry\n' >&2
  printf 'error: use --allow-running only for emergency manual recovery\n' >&2
  exit 1
}

switch_accounts() {
  local manage_app="$1"
  local allow_running="$2"
  require_auth_files
  validate_json_shape "$PRIMARY_AUTH"
  validate_json_shape "$SECONDARY_AUTH"
  acquire_lock

  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR" 2>/dev/null || true

  local stamp
  stamp="$(date +%Y%m%d-%H%M%S).$$"

  if [[ "$manage_app" == "yes" ]]; then
    quit_codex_app
  fi
  ensure_no_codex_auth_processes "$allow_running"

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
  local allow_running="$2"
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
  ensure_no_codex_auth_processes "$allow_running"

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
}

preflight() {
  require_auth_files
  validate_json_shape "$PRIMARY_AUTH"
  validate_json_shape "$SECONDARY_AUTH"

  printf 'auth files OK\n'
  safe_stat "$PRIMARY_AUTH"
  safe_stat "$SECONDARY_AUTH"

  local pids=""
  pids="$(codex_auth_processes_running || true)"
  if [[ -n "$pids" ]]; then
    printf 'BLOCKED: Codex auth-using process(es) still running: %s\n' "$pids" >&2
    printf 'Close Codex App, VS Code/Codex extensions, and other codex app-server processes before switching.\n' >&2
    return 1
  fi

  printf 'READY: no Codex auth-using processes detected\n'
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
  local allow_running="no"

  case "$cmd" in
    switch)
      shift
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --no-app) manage_app="no" ;;
          --allow-running) allow_running="yes" ;;
          -h|--help) usage; exit 0 ;;
          *) die "unknown option: $1" ;;
        esac
        shift
      done
      switch_accounts "$manage_app" "$allow_running"
      ;;
    restore-last|fix)
      shift
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --no-app) manage_app="no" ;;
          --allow-running) allow_running="yes" ;;
          -h|--help) usage; exit 0 ;;
          *) die "unknown option: $1" ;;
        esac
        shift
      done
      restore_last "$manage_app" "$allow_running"
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
