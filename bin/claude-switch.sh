#!/usr/bin/env bash
set -euo pipefail

# Sessionful Claude Code account switch for the VS Code extension.
# Why: Claude Code reads credentials from ~/.claude/.credentials.json. We swap that
# file in-place while leaving ~/.claude/sessions/ and ~/.claude/settings.json
# untouched, so prior session JSONs remain visible after the switch.

DEFAULT_HOME="$HOME/.claude"
ACC2_HOME="${CLAUDE_ACC2_HOME:-$HOME/.claude2}"
DEFAULT_AUTH="$DEFAULT_HOME/.credentials.json"
ACC2_AUTH="$ACC2_HOME/.credentials.json"
SESSIONS_DIR="$DEFAULT_HOME/sessions"
STATE_DIR="$DEFAULT_HOME/app-account-switch"
MODE_FILE="$STATE_DIR/mode"
STAMP_FILE="$STATE_DIR/stamp"
DEFAULT_SAVED_AUTH="$STATE_DIR/default-credentials.json"
ACC2_ACTIVE_LINK_TARGET="$DEFAULT_AUTH"
LOCK_DIR="$STATE_DIR/lock"
LOCK_HELD="no"

# Why: Claude Code reads OAuth credentials from BOTH ~/.claude/.credentials.json
# AND macOS Keychain (service="Claude Code-credentials", account=$USER). A file-only
# swap is insufficient: after VS Code reload Claude may read from Keychain and
# overwrite the swapped file. We swap Keychain in parallel with the file.
KEYCHAIN_SERVICE="Claude Code-credentials"
KEYCHAIN_ACCOUNT="$USER"
ACC2_KEYCHAIN_BLOB="$STATE_DIR/acc2-keychain.blob"
DEFAULT_KEYCHAIN_BLOB="$STATE_DIR/default-keychain.blob"

# Why: locate a usable claude binary. Prefer one on PATH (user-installed CLI);
# fall back to the latest VS Code extension binary so smoke/auth-status still work
# in fresh shells.
discover_claude_bin() {
  local from_path candidates pick
  from_path="$(command -v claude 2>/dev/null || true)"
  if [[ -n "$from_path" && -x "$from_path" ]]; then
    printf '%s\n' "$from_path"
    return 0
  fi
  candidates="$HOME/.vscode/extensions"
  [[ -d "$candidates" ]] || return 1
  pick="$(
    find "$candidates" -maxdepth 3 -type f \
      -path '*anthropic.claude-code-*/resources/native-binary/claude' \
      -perm -u+x 2>/dev/null \
      | sort -V \
      | tail -n 1
  )"
  [[ -n "$pick" && -x "$pick" ]] || return 1
  printf '%s\n' "$pick"
}

CLAUDE_BIN="$(discover_claude_bin 2>/dev/null || true)"

usage() {
  cat <<'USAGE'
Usage:
  claude-switch.sh bootstrap
  claude-switch.sh acc2
  claude-switch.sh fix
  claude-switch.sh smoke
  claude-switch.sh status

Commands:
  bootstrap  One-time: log in as acc#2, capture its credentials + Keychain blob
             for later swaps. Restores the default Keychain at the end.
  acc2       Keep Claude Code on ~/.claude sessions, but run with acc#2
             credentials. Swaps both .credentials.json AND macOS Keychain.
  fix        Restore default ~/.claude credentials and Keychain. Move acc#2
             credentials back to ~/.claude2.
  smoke      Non-destructive: validate acc#2 credentials, session layout, and
             that acc#2 Keychain blob is present.
  status     Show safe metadata only. Does not print token or blob contents.

Notes:
  - Claude Code lives inside VS Code. This script does not quit/restart VS Code.
    After acc2/fix it prints reload instructions; pick one and apply it.
  - ~/.claude/sessions/ stays in place, so prior session files remain visible.
  - Auth files are MOVED (not copied) to avoid duplicating refresh tokens.
  - Claude reads credentials from BOTH ~/.claude/.credentials.json AND macOS
    Keychain (service="Claude Code-credentials"). The swap covers both.
  - While switched, ~/.claude2/.credentials.json is a symlink to
    ~/.claude/.credentials.json.
  - Manual emergency reset if needed:
      ./claude-switch.sh fix
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log_step() {
  printf '[claude-switch] %s\n' "$*"
}

require_claude_bin() {
  [[ -n "${CLAUDE_BIN:-}" && -x "$CLAUDE_BIN" ]] \
    || die "claude binary not found; install Claude Code or set CLAUDE_BIN in env"
}

acquire_lock() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR" 2>/dev/null || true

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_HELD="yes"
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    return 0
  fi

  local owner
  owner="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
    rm -rf "$LOCK_DIR"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      LOCK_HELD="yes"
      printf '%s\n' "$$" > "$LOCK_DIR/pid"
      return 0
    fi
  fi

  die "another switch/fix appears to be running; lock=$LOCK_DIR owner=${owner:-unknown}"
}

release_lock() {
  if [[ "$LOCK_HELD" == "yes" ]]; then
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    LOCK_HELD="no"
  fi
}

# Why: shape check guards against partially-written or wrong-format files
# slipping into the default slot.
validate_json_shape() {
  local file="$1"
  node -e '
    const fs = require("fs");
    const file = process.argv[1];
    const j = JSON.parse(fs.readFileSync(file, "utf8"));
    for (const k of ["claudeAiOauth", "organizationUuid"]) {
      if (!(k in j)) throw new Error(`${file}: missing ${k}`);
    }
    const oauth = j.claudeAiOauth;
    if (typeof oauth !== "object" || oauth === null) {
      throw new Error(`${file}: claudeAiOauth must be an object`);
    }
    for (const k of ["accessToken", "refreshToken"]) {
      if (typeof oauth[k] !== "string" || oauth[k].length === 0) {
        throw new Error(`${file}: claudeAiOauth.${k} missing or empty`);
      }
    }
  ' "$file" >/dev/null
}

safe_stat() {
  local file="$1"
  if [[ -L "$file" ]]; then
    printf '%s symlink -> %s\n' "$file" "$(readlink "$file")"
  elif [[ -f "$file" ]]; then
    stat -f '%N size=%z mode=%Sp modified=%Sm' -t '%Y-%m-%d %H:%M:%S' "$file"
  else
    printf '%s missing\n' "$file"
  fi
}

# Why: macOS Keychain helpers. We never print blob contents to stdout; all
# transfers happen via chmod 600 files. `security -w` appends a trailing LF to
# its output, which we strip on save so the file holds the exact stored bytes.

keychain_exists() {
  security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1
}

# Why: write current Keychain value to filepath, chmod 600. Strips the trailing
# LF that `security -w` appends so the file matches what's stored in Keychain.
keychain_save_to_file() {
  local filepath="$1"
  local raw stripped
  raw="$(mktemp "${TMPDIR:-/tmp}/claude-kc-raw.XXXXXX")"
  stripped="$(mktemp "${TMPDIR:-/tmp}/claude-kc-strip.XXXXXX")"
  chmod 600 "$raw" "$stripped" 2>/dev/null || true
  if ! security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w > "$raw" 2>/dev/null; then
    rm -f "$raw" "$stripped"
    return 1
  fi
  # Why: drop exactly one trailing LF if present. perl is binary-safe and ships
  # with macOS; awk/sed mangle multi-line or no-newline content.
  perl -e '
    my $f = $ARGV[0];
    open(my $in, "<:raw", $f) or die "open $f: $!";
    local $/; my $b = <$in>; close $in;
    $b =~ s/\n\z//;
    open(my $out, ">:raw", $ARGV[1]) or die "open $ARGV[1]: $!";
    print $out $b; close $out;
  ' "$raw" "$stripped"
  mv "$stripped" "$filepath"
  chmod 600 "$filepath" 2>/dev/null || true
  rm -f "$raw"
}

# Why: write file contents into Keychain. `security -U` upserts the entry.
keychain_restore_from_file() {
  local filepath="$1"
  [[ -f "$filepath" ]] || return 1
  local value
  # Why: read file into variable. OAuth blobs are ASCII JSON; no null bytes.
  value="$(cat "$filepath")"
  security add-generic-password \
    -s "$KEYCHAIN_SERVICE" \
    -a "$KEYCHAIN_ACCOUNT" \
    -w "$value" \
    -U >/dev/null 2>&1
}

keychain_delete() {
  security delete-generic-password \
    -s "$KEYCHAIN_SERVICE" \
    -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1 || true
}

# Why: stable hash of current Keychain value for Murphy round-trip check, without
# printing the value. Returns empty string if Keychain entry is missing.
keychain_hash() {
  if ! keychain_exists; then
    printf ''
    return 0
  fi
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/claude-kc-hash.XXXXXX")"
  chmod 600 "$tmp" 2>/dev/null || true
  if keychain_save_to_file "$tmp" 2>/dev/null; then
    shasum -a 256 "$tmp" | awk '{print $1}'
  else
    printf ''
  fi
  rm -f "$tmp"
}

# Why: enumerate processes likely to hold the credentials file open. We can't
# safely move the auth file while a live claude CLI is reading it.
claude_user_pids() {
  local self="$$"
  ps -axo pid=,command= \
    | awk \
      -v self="$self" '
        $1 == self { next }
        /claude-switch\.sh/ { next }
        /\/anthropic\.claude-code-[^\/]+\/resources\/native-binary\/claude/ { print $1 " vscode-extension"; next }
        /(^|\/)claude (auth|setup-token|exec|resume|mcp|--print|-p)( |$)/ { print $1 " claude-cli"; next }
        /(^|\/)claude$/ { print $1 " claude-cli-bare"; next }
      '
}

warn_if_claude_users_running() {
  local users
  users="$(claude_user_pids)"
  if [[ -n "$users" ]]; then
    printf 'warning: live claude processes detected (they will continue using cached tokens until reload):\n%s\n' "$users" >&2
    printf 'proceeding anyway; close VS Code Claude panels or reload window after the swap\n' >&2
  fi
}

session_counts() {
  local default_count acc2_count
  # Why: missing dir makes find exit nonzero, which under pipefail+errexit aborts
  # the substitution. Trailing `|| echo 0` keeps the count usable.
  default_count="$( { find "$DEFAULT_HOME/sessions" -type f 2>/dev/null || true; } | wc -l | tr -d ' ')"
  acc2_count="$( { find "$ACC2_HOME/sessions" -type f 2>/dev/null || true; } | wc -l | tr -d ' ')"
  printf 'default_sessions_files=%s\n' "${default_count:-0}"
  printf 'acc2_sessions_files=%s\n' "${acc2_count:-0}"
}

status() {
  printf 'mode='
  if [[ -f "$MODE_FILE" ]]; then
    cat "$MODE_FILE"
  else
    printf 'default\n'
  fi

  printf '\nAuth files:\n'
  safe_stat "$DEFAULT_AUTH"
  safe_stat "$ACC2_AUTH"
  [[ -f "$DEFAULT_SAVED_AUTH" || -L "$DEFAULT_SAVED_AUTH" ]] && safe_stat "$DEFAULT_SAVED_AUTH"

  printf '\nKeychain:\n'
  if keychain_exists; then
    printf '  entry "%s" account=%s: present\n' "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT"
  else
    printf '  entry "%s" account=%s: absent\n' "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT"
  fi
  if [[ -f "$ACC2_KEYCHAIN_BLOB" ]]; then
    printf '  acc2-keychain.blob: present (%s)\n' "$ACC2_KEYCHAIN_BLOB"
  else
    printf '  acc2-keychain.blob: absent (run "%s bootstrap" to capture)\n' "$0"
  fi
  if [[ -f "$DEFAULT_KEYCHAIN_BLOB" ]]; then
    printf '  default-keychain.blob: present (%s)\n' "$DEFAULT_KEYCHAIN_BLOB"
  else
    printf '  default-keychain.blob: absent\n'
  fi

  printf '\nSession counts:\n'
  session_counts

  printf '\nLive claude processes (extension/CLI):\n'
  local users
  users="$(claude_user_pids 2>/dev/null || true)"
  if [[ -n "$users" ]]; then
    printf '%s\n' "$users"
  else
    printf '(none)\n'
  fi
}

# Why: smoke validates that acc#2 credentials parse and that claude can see them
# when HOME is pointed at a temp dir (Claude honors $HOME for credentials path).
smoke_sessionful_layout() {
  [[ -d "$DEFAULT_HOME" ]] || die "missing default Claude home: $DEFAULT_HOME"
  [[ -d "$ACC2_HOME" ]] || die "missing acc#2 Claude home: $ACC2_HOME"
  [[ -d "$SESSIONS_DIR" ]] || die "missing default sessions dir: $SESSIONS_DIR"
  [[ -f "$ACC2_AUTH" ]] || die "missing acc#2 credentials: $ACC2_AUTH"
  validate_json_shape "$ACC2_AUTH"
  require_claude_bin

  local smoke_home
  smoke_home="$(mktemp -d /tmp/claude-sessionful-smoke.XXXXXX)"
  trap '[[ -n "${smoke_home:-}" ]] && rm -rf "$smoke_home"' EXIT
  chmod 700 "$smoke_home"

  mkdir -p "$smoke_home/.claude"
  ln -s "$ACC2_AUTH" "$smoke_home/.claude/.credentials.json"
  [[ -f "$DEFAULT_HOME/settings.json" ]] && ln -s "$DEFAULT_HOME/settings.json" "$smoke_home/.claude/settings.json"
  ln -s "$SESSIONS_DIR" "$smoke_home/.claude/sessions"

  printf 'smoke_home=%s\n' "$smoke_home"
  printf 'auth_source=%s\n' "$(readlink "$smoke_home/.claude/.credentials.json")"
  printf 'sessions_source=%s\n' "$(readlink "$smoke_home/.claude/sessions")"
  printf 'session_files=%s\n' "$( { find -L "$smoke_home/.claude/sessions" -type f 2>/dev/null || true; } | wc -l | tr -d ' ')"
  # Why: redact email from auth status output; we only care that loggedIn=true.
  printf 'auth_status='
  HOME="$smoke_home" "$CLAUDE_BIN" auth status --text 2>&1 \
    | sed -E 's/[[:alnum:]_.%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}/[redacted-email]/g' \
    | head -5
  # Why: if acc#2 credentials exist on disk, the Keychain blob must also be on
  # disk; otherwise a swap would lose acc#2 Keychain state on Claude reload.
  if [[ -f "$ACC2_AUTH" && ! -L "$ACC2_AUTH" ]]; then
    if [[ -f "$ACC2_KEYCHAIN_BLOB" ]]; then
      printf 'acc2_keychain_blob=present\n'
    else
      printf 'acc2_keychain_blob=missing -- run "%s bootstrap" to capture\n' "$0"
      rm -rf "$smoke_home"
      trap - EXIT
      die "smoke: acc#2 credentials present but acc2-keychain.blob missing"
    fi
  fi
  printf 'smoke=ok\n'
  rm -rf "$smoke_home"
  trap - EXIT
}

require_normal_default_state() {
  [[ -d "$DEFAULT_HOME" ]] || die "missing default Claude home: $DEFAULT_HOME"
  [[ -d "$ACC2_HOME" ]] || die "missing acc#2 Claude home: $ACC2_HOME (create it and place .credentials.json inside)"
  [[ -f "$DEFAULT_AUTH" && ! -L "$DEFAULT_AUTH" ]] || die "default credentials must be a regular file: $DEFAULT_AUTH"
  [[ -f "$ACC2_AUTH" && ! -L "$ACC2_AUTH" ]] || die "acc#2 credentials must be a regular file before switch: $ACC2_AUTH"
  [[ ! -e "$DEFAULT_SAVED_AUTH" ]] || die "saved default credentials already exist; run fix first or inspect $STATE_DIR"
  validate_json_shape "$DEFAULT_AUTH"
  validate_json_shape "$ACC2_AUTH"
}

require_switched_state_for_fix() {
  [[ -L "$ACC2_AUTH" ]] || die "$ACC2_AUTH is not the expected symlink; refusing to overwrite it"
  local target
  target="$(readlink "$ACC2_AUTH")"
  [[ "$target" == "$ACC2_ACTIVE_LINK_TARGET" ]] || die "$ACC2_AUTH points to $target, expected $ACC2_ACTIVE_LINK_TARGET"
  [[ -f "$DEFAULT_AUTH" && ! -L "$DEFAULT_AUTH" ]] || die "missing active acc#2 credentials in default slot: $DEFAULT_AUTH"
  [[ -f "$DEFAULT_SAVED_AUTH" && ! -L "$DEFAULT_SAVED_AUTH" ]] || die "missing saved default credentials: $DEFAULT_SAVED_AUTH"
  validate_json_shape "$DEFAULT_AUTH"
  validate_json_shape "$DEFAULT_SAVED_AUTH"
}

rollback_auth_moves() {
  if [[ -f "$DEFAULT_SAVED_AUTH" ]]; then
    [[ -L "$ACC2_AUTH" ]] && rm -f "$ACC2_AUTH" 2>/dev/null || true
    if [[ -f "$DEFAULT_AUTH" && ! -e "$ACC2_AUTH" ]]; then
      mv "$DEFAULT_AUTH" "$ACC2_AUTH" 2>/dev/null || true
    fi
    if [[ ! -e "$DEFAULT_AUTH" ]]; then
      mv "$DEFAULT_SAVED_AUTH" "$DEFAULT_AUTH" 2>/dev/null || true
    fi
  fi
}

# Why: VS Code can't be quit safely from a script (would lose user state). We
# emit clear reload instructions and best-effort attempt the URL handler.
print_reload_instructions() {
  local label="$1"
  printf '\n--- Reload VS Code to pick up %s credentials ---\n' "$label"
  printf '  1) In VS Code:  Cmd+Shift+P  ->  "Developer: Reload Window"\n'
  printf '  2) Or close all Claude Code panels and reopen them.\n'
  if command -v code >/dev/null 2>&1; then
    printf '  3) Attempting: code --command workbench.action.reloadWindow\n'
    printf '     (only affects the most recent VS Code window; may be a no-op if no IPC socket)\n'
    code --command workbench.action.reloadWindow >/dev/null 2>&1 || \
      printf '     code CLI returned non-zero; do the manual reload above.\n'
  else
    printf '  3) Optional: install the "code" CLI from VS Code (Shell Command: Install)\n'
    printf '     to enable automated reload next time.\n'
  fi
  printf '\n'
}

switch_to_acc2_sessionful() {
  acquire_lock
  require_normal_default_state

  local stamp switch_done switch_auth_moves_started keychain_backup keychain_swapped had_keychain
  stamp="$(date +%Y%m%d-%H%M%S).$$"
  switch_done="no"
  switch_auth_moves_started="no"
  keychain_swapped="no"
  had_keychain="no"
  mkdir -p "$STATE_DIR/backups/$stamp"
  chmod 700 "$STATE_DIR" "$STATE_DIR/backups" "$STATE_DIR/backups/$stamp" 2>/dev/null || true
  keychain_backup="$STATE_DIR/backups/$stamp/default-keychain.blob"

  rollback_on_error() {
    local exit_code=$?
    trap - ERR INT TERM EXIT
    if [[ "${switch_done:-no}" != "yes" ]]; then
      if [[ "${keychain_swapped:-no}" == "yes" ]]; then
        printf 'switch failed; attempting Keychain rollback\n' >&2
        if [[ -f "$keychain_backup" ]]; then
          keychain_restore_from_file "$keychain_backup" || \
            printf 'warning: Keychain rollback failed; default-keychain.blob is at %s\n' "$keychain_backup" >&2
        fi
      fi
      if [[ "${switch_auth_moves_started:-no}" == "yes" ]]; then
        printf 'switch failed; attempting local credentials rollback\n' >&2
        rollback_auth_moves
      else
        printf 'switch failed before credentials were moved\n' >&2
      fi
      rm -f "$MODE_FILE" "$STAMP_FILE" 2>/dev/null || true
      printf 'recovery command: %s fix\n' "$0" >&2
    fi
    release_lock
    exit "$exit_code"
  }
  trap rollback_on_error ERR INT TERM EXIT

  cp -p "$DEFAULT_AUTH" "$STATE_DIR/backups/$stamp/default-credentials.before.json"
  cp -p "$ACC2_AUTH" "$STATE_DIR/backups/$stamp/acc2-credentials.before.json"
  chmod 600 "$STATE_DIR/backups/$stamp"/*.json 2>/dev/null || true

  # Why: snapshot default Keychain blob before any swap so we can roll back. If
  # no Keychain entry exists (e.g. --bare mode user, fresh install), skip
  # Keychain operations entirely instead of failing.
  if keychain_exists; then
    had_keychain="yes"
    keychain_save_to_file "$keychain_backup" \
      || die "failed to read default Keychain entry for backup"
    # Why: keep a stable copy outside the timestamped backup dir so `fix` can find
    # it without parsing stamps.
    cp -p "$keychain_backup" "$DEFAULT_KEYCHAIN_BLOB"
    chmod 600 "$DEFAULT_KEYCHAIN_BLOB" 2>/dev/null || true
  else
    printf 'warning: Keychain entry "%s" not found; skipping Keychain swap\n' "$KEYCHAIN_SERVICE" >&2
  fi

  warn_if_claude_users_running

  switch_auth_moves_started="yes"
  mv "$DEFAULT_AUTH" "$DEFAULT_SAVED_AUTH"
  mv "$ACC2_AUTH" "$DEFAULT_AUTH"
  ln -s "$ACC2_ACTIVE_LINK_TARGET" "$ACC2_AUTH"
  chmod 600 "$DEFAULT_AUTH" "$DEFAULT_SAVED_AUTH" 2>/dev/null || true
  validate_json_shape "$DEFAULT_AUTH"
  # Why: symlink target is the moved-in file, so shape check via dereference
  # confirms the link resolves to a valid credentials JSON.
  validate_json_shape "$ACC2_AUTH"

  # Why: swap Keychain to acc#2 AFTER files are in place. If we have a saved
  # acc#2 blob from bootstrap, load it. Otherwise delete the entry so Claude
  # falls back to reading the swapped .credentials.json on next load instead of
  # the stale default-account value still in Keychain.
  if [[ "$had_keychain" == "yes" ]]; then
    if [[ -f "$ACC2_KEYCHAIN_BLOB" ]]; then
      keychain_restore_from_file "$ACC2_KEYCHAIN_BLOB" \
        || die "failed to write acc#2 Keychain entry"
    else
      printf 'warning: no acc#2 Keychain blob saved; deleting Keychain entry so Claude reads from .credentials.json\n' >&2
      printf '         run "%s bootstrap" once to populate acc#2 Keychain for future swaps\n' "$0" >&2
      keychain_delete
    fi
    keychain_swapped="yes"
  fi

  printf 'sessionful-acc2\n' > "$MODE_FILE"
  printf '%s\n' "$stamp" > "$STAMP_FILE"

  switch_done="yes"
  trap - ERR INT TERM EXIT
  release_lock

  printf 'Claude credentials swapped: ~/.claude now uses acc#2; sessions preserved\n'
  print_reload_instructions "acc#2"
  status
}

fix_sessionful() {
  acquire_lock

  local fix_done fix_auth_moves_started keychain_swapped acc2_kc_snapshot had_keychain
  fix_done="no"
  fix_auth_moves_started="no"
  keychain_swapped="no"
  had_keychain="no"
  acc2_kc_snapshot=""
  fix_on_error() {
    local exit_code=$?
    trap - ERR INT TERM EXIT
    if [[ "${keychain_swapped:-no}" == "yes" && -n "${acc2_kc_snapshot:-}" && -f "$acc2_kc_snapshot" ]]; then
      printf 'fix failed; attempting Keychain rollback to acc#2\n' >&2
      keychain_restore_from_file "$acc2_kc_snapshot" || \
        printf 'warning: Keychain rollback failed; acc#2 blob is at %s\n' "$acc2_kc_snapshot" >&2
    fi
    if [[ "${fix_done:-no}" != "yes" && "${fix_auth_moves_started:-no}" == "yes" ]]; then
      if [[ ! -e "$ACC2_AUTH" && -f "$DEFAULT_AUTH" && -f "$DEFAULT_SAVED_AUTH" ]]; then
        mv "$DEFAULT_AUTH" "$ACC2_AUTH" 2>/dev/null || true
      fi
      if [[ -f "$DEFAULT_SAVED_AUTH" && ! -e "$DEFAULT_AUTH" ]]; then
        mv "$DEFAULT_SAVED_AUTH" "$DEFAULT_AUTH" 2>/dev/null || true
      fi
      printf 'fix failed; inspect credentials files, then retry: %s fix\n' "$0" >&2
    fi
    release_lock
    exit "$exit_code"
  }
  trap fix_on_error ERR INT TERM EXIT

  require_switched_state_for_fix

  # Why: capture current (acc#2) Keychain value BEFORE swap so next `acc2` call
  # can restore it. Also keep a temp snapshot for rollback within this fix.
  if keychain_exists; then
    had_keychain="yes"
    acc2_kc_snapshot="$(mktemp "${TMPDIR:-/tmp}/claude-fix-kc.XXXXXX")"
    chmod 600 "$acc2_kc_snapshot" 2>/dev/null || true
    if keychain_save_to_file "$acc2_kc_snapshot"; then
      cp -p "$acc2_kc_snapshot" "$ACC2_KEYCHAIN_BLOB"
      chmod 600 "$ACC2_KEYCHAIN_BLOB" 2>/dev/null || true
    else
      rm -f "$acc2_kc_snapshot"
      acc2_kc_snapshot=""
      printf 'warning: failed to snapshot acc#2 Keychain value before fix\n' >&2
    fi
  fi

  warn_if_claude_users_running

  fix_auth_moves_started="yes"
  rm -f "$ACC2_AUTH"
  mv "$DEFAULT_AUTH" "$ACC2_AUTH"
  mv "$DEFAULT_SAVED_AUTH" "$DEFAULT_AUTH"
  chmod 600 "$DEFAULT_AUTH" "$ACC2_AUTH" 2>/dev/null || true

  validate_json_shape "$DEFAULT_AUTH"
  validate_json_shape "$ACC2_AUTH"

  # Why: restore default Keychain value. Prefer the timestamped backup from the
  # most recent acc2 run; fall back to the stable copy at $DEFAULT_KEYCHAIN_BLOB.
  if [[ "$had_keychain" == "yes" ]]; then
    local restore_source="" latest_stamp_backup=""
    if [[ -f "$STAMP_FILE" ]]; then
      local last_stamp
      last_stamp="$(cat "$STAMP_FILE" 2>/dev/null || true)"
      if [[ -n "$last_stamp" && -f "$STATE_DIR/backups/$last_stamp/default-keychain.blob" ]]; then
        latest_stamp_backup="$STATE_DIR/backups/$last_stamp/default-keychain.blob"
      fi
    fi
    if [[ -n "$latest_stamp_backup" ]]; then
      restore_source="$latest_stamp_backup"
    elif [[ -f "$DEFAULT_KEYCHAIN_BLOB" ]]; then
      restore_source="$DEFAULT_KEYCHAIN_BLOB"
    fi
    if [[ -n "$restore_source" ]]; then
      keychain_restore_from_file "$restore_source" \
        || die "failed to restore default Keychain entry from $restore_source"
      keychain_swapped="yes"
    else
      printf 'warning: no default-keychain.blob backup found; Keychain still holds acc#2 value\n' >&2
      printf '         current .credentials.json (default) will be used by Claude until next login\n' >&2
    fi
  fi

  rm -f "$MODE_FILE" "$STAMP_FILE" 2>/dev/null || true

  fix_done="yes"
  trap - ERR INT TERM EXIT
  [[ -n "$acc2_kc_snapshot" && -f "$acc2_kc_snapshot" ]] && rm -f "$acc2_kc_snapshot"
  release_lock
  printf 'Claude credentials restored: ~/.claude back to default account\n'
  print_reload_instructions "default"
  status
}

# Why: one-time setup to capture the acc#2 Keychain blob. Claude Code writes the
# OAuth blob to Keychain on `auth login`; we need that blob saved so subsequent
# `acc2` swaps can also flip Keychain (not just .credentials.json). Without it,
# Claude on reload would read the stale default-account value from Keychain.
bootstrap_acc2_keychain() {
  acquire_lock

  local boot_done default_kc_temp tmp_home boot_acc2_dir
  boot_done="no"
  default_kc_temp=""
  tmp_home=""
  boot_acc2_dir=""

  bootstrap_on_error() {
    local exit_code=$?
    trap - ERR INT TERM EXIT
    if [[ "${boot_done:-no}" != "yes" ]]; then
      # Why: best-effort restore default Keychain so user isn't left in a worse
      # state than they started. The temp blob holds the pre-bootstrap value.
      if [[ -n "${default_kc_temp:-}" && -f "$default_kc_temp" ]]; then
        printf 'bootstrap failed; attempting to restore default Keychain\n' >&2
        keychain_restore_from_file "$default_kc_temp" || \
          printf 'warning: default Keychain restore failed; blob at %s\n' "$default_kc_temp" >&2
      fi
    fi
    [[ -n "${tmp_home:-}" && -d "$tmp_home" ]] && rm -rf "$tmp_home"
    [[ -n "${default_kc_temp:-}" && -f "$default_kc_temp" ]] && rm -f "$default_kc_temp"
    release_lock
    exit "$exit_code"
  }
  trap bootstrap_on_error ERR INT TERM EXIT

  require_claude_bin

  # Why: idempotency guard. If acc#2 home already has valid credentials AND we
  # already have the Keychain blob saved, there's nothing to bootstrap.
  if [[ -f "$ACC2_AUTH" && ! -L "$ACC2_AUTH" ]] && validate_json_shape "$ACC2_AUTH" 2>/dev/null; then
    if [[ -f "$ACC2_KEYCHAIN_BLOB" ]]; then
      printf 'already bootstrapped: %s exists and is valid; %s present\n' \
        "$ACC2_AUTH" "$ACC2_KEYCHAIN_BLOB"
      boot_done="yes"
      trap - ERR INT TERM EXIT
      release_lock
      status
      return 0
    fi
    printf 'note: %s exists but %s is missing; bootstrap will run to capture Keychain blob\n' \
      "$ACC2_AUTH" "$ACC2_KEYCHAIN_BLOB" >&2
  fi

  if ! keychain_exists; then
    die "default Keychain entry \"$KEYCHAIN_SERVICE\" not found; log in once with the default account before bootstrap"
  fi

  printf '\n--- Bootstrapping acc#2 Keychain ---\n'
  printf 'macOS may prompt for Keychain access during this step (Allow / Always Allow).\n'
  printf 'A browser window will open for acc#2 login. Complete it, then return here.\n\n'

  # Why: snapshot current (default) Keychain BEFORE `claude auth login` overwrites
  # it. We restore from this snapshot at the end.
  default_kc_temp="$(mktemp "${TMPDIR:-/tmp}/claude-boot-default-kc.XXXXXX")"
  chmod 600 "$default_kc_temp" 2>/dev/null || true
  keychain_save_to_file "$default_kc_temp" \
    || die "failed to snapshot default Keychain before bootstrap"

  mkdir -p "$ACC2_HOME"
  chmod 700 "$ACC2_HOME" 2>/dev/null || true

  # Why: `claude auth login` writes credentials under $HOME/.claude/. Point HOME
  # at a private temp dir so we don't disturb the real ~/.claude state, then
  # move the result into $ACC2_HOME afterwards.
  tmp_home="$(mktemp -d "${TMPDIR:-/tmp}/claude-bootstrap-home.XXXXXX")"
  chmod 700 "$tmp_home" 2>/dev/null || true
  mkdir -p "$tmp_home/.claude"

  log_step "running: HOME=$tmp_home $CLAUDE_BIN auth login"
  HOME="$tmp_home" "$CLAUDE_BIN" auth login \
    || die "claude auth login failed; default Keychain will be restored on exit"

  local new_creds="$tmp_home/.claude/.credentials.json"
  [[ -f "$new_creds" ]] || die "claude auth login completed but $new_creds not found"
  validate_json_shape "$new_creds" \
    || die "freshly written credentials at $new_creds failed shape validation"

  # Why: move freshly minted credentials into the acc#2 home. If existing acc#2
  # credentials are present, back them up rather than overwrite blind.
  if [[ -f "$ACC2_AUTH" && ! -L "$ACC2_AUTH" ]]; then
    local backup_acc2="$STATE_DIR/acc2-credentials.pre-bootstrap.$(date +%Y%m%d-%H%M%S).json"
    mkdir -p "$STATE_DIR"
    mv "$ACC2_AUTH" "$backup_acc2"
    chmod 600 "$backup_acc2" 2>/dev/null || true
    printf 'note: pre-existing acc#2 credentials moved to %s\n' "$backup_acc2"
  fi
  mv "$new_creds" "$ACC2_AUTH"
  chmod 600 "$ACC2_AUTH" 2>/dev/null || true
  validate_json_shape "$ACC2_AUTH"

  # Why: capture the acc#2 Keychain value that `claude auth login` just wrote.
  # This is the whole point of bootstrap.
  keychain_save_to_file "$ACC2_KEYCHAIN_BLOB" \
    || die "failed to save acc#2 Keychain blob to $ACC2_KEYCHAIN_BLOB"

  # Why: restore default Keychain so the user is back on acc#1 in Keychain
  # before any reload. The acc#2 blob is preserved on disk for future swaps.
  keychain_restore_from_file "$default_kc_temp" \
    || die "failed to restore default Keychain after bootstrap"

  rm -f "$default_kc_temp"
  default_kc_temp=""
  rm -rf "$tmp_home"
  tmp_home=""

  boot_done="yes"
  trap - ERR INT TERM EXIT
  release_lock
  printf '\nbootstrap=ok\n'
  printf 'acc#2 credentials saved to: %s\n' "$ACC2_AUTH"
  printf 'acc#2 Keychain blob saved to: %s\n' "$ACC2_KEYCHAIN_BLOB"
  printf 'default Keychain restored; ~/.claude still on default account.\n\n'
  status
}

# Why: optional Murphy test mirrors the Codex helper. Builds confidence that the
# default-side files survive a swap+revert round-trip without content drift.
# Enable with CLAUDE_SWITCH_MURPHY=1.
murphy_roundtrip_test() {
  [[ "${CLAUDE_SWITCH_MURPHY:-0}" == "1" ]] || die "set CLAUDE_SWITCH_MURPHY=1 to run the round-trip test"
  require_normal_default_state

  local before_hash after_hash before_kc_hash after_kc_hash
  before_hash="$(shasum -a 256 "$DEFAULT_AUTH" | awk '{print $1}')"
  before_kc_hash="$(keychain_hash)"
  log_step "murphy: default credentials hash before swap = $before_hash"
  log_step "murphy: default Keychain hash before swap = ${before_kc_hash:-<absent>}"

  switch_to_acc2_sessionful >/dev/null
  log_step "murphy: swap to acc#2 succeeded"
  fix_sessionful >/dev/null
  log_step "murphy: fix back to default succeeded"

  after_hash="$(shasum -a 256 "$DEFAULT_AUTH" | awk '{print $1}')"
  after_kc_hash="$(keychain_hash)"
  log_step "murphy: default credentials hash after revert = $after_hash"
  log_step "murphy: default Keychain hash after revert = ${after_kc_hash:-<absent>}"
  [[ "$before_hash" == "$after_hash" ]] || die "murphy: default credentials drifted across round-trip"
  [[ "$before_kc_hash" == "$after_kc_hash" ]] || die "murphy: default Keychain value drifted across round-trip"
  printf 'murphy=ok\n'
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    bootstrap|init-acc2)
      shift
      [[ $# -eq 0 ]] || die "unknown option(s): $*"
      bootstrap_acc2_keychain
      ;;
    acc2|switch|to-acc2)
      shift
      [[ $# -eq 0 ]] || die "unknown option(s): $*"
      switch_to_acc2_sessionful
      ;;
    fix|restore|default)
      shift
      [[ $# -eq 0 ]] || die "unknown option(s): $*"
      fix_sessionful
      ;;
    smoke)
      shift
      [[ $# -eq 0 ]] || die "unknown option(s): $*"
      smoke_sessionful_layout
      ;;
    status)
      shift
      [[ $# -eq 0 ]] || die "unknown option(s): $*"
      status
      ;;
    murphy)
      shift
      [[ $# -eq 0 ]] || die "unknown option(s): $*"
      murphy_roundtrip_test
      ;;
    -h|--help|"")
      usage
      ;;
    *)
      die "unknown command: $cmd"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
