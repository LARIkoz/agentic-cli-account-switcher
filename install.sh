#!/usr/bin/env bash
# Installer for agentic-cli-account-switcher.
# Downloads claude-switch and codex-switch from the latest main branch and
# installs them as executables in PREFIX (default: /usr/local/bin if writable,
# otherwise ~/.local/bin).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/LARIkoz/agentic-cli-account-switcher/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/LARIkoz/agentic-cli-account-switcher/main/install.sh | PREFIX=$HOME/bin bash
#   curl -fsSL https://raw.githubusercontent.com/LARIkoz/agentic-cli-account-switcher/main/install.sh | TOOLS="claude" bash
#
# Env:
#   PREFIX  Install directory (default auto-detected).
#   TOOLS   Space-separated subset of: claude codex (default: both).
#   REF     Git ref to install from (default: main).

set -euo pipefail

REPO="LARIkoz/agentic-cli-account-switcher"
REF="${REF:-main}"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/${REF}"
TOOLS="${TOOLS:-claude codex}"

# Detect prefix
if [[ -z "${PREFIX:-}" ]]; then
  if [[ -w /usr/local/bin ]]; then
    PREFIX=/usr/local/bin
  else
    PREFIX="$HOME/.local/bin"
  fi
fi

mkdir -p "$PREFIX"

# OS check
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "warning: this script targets macOS. Other platforms are not supported in v0.x." >&2
fi

# Required CLIs
for cmd in curl chmod; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "error: missing required command: $cmd" >&2
    exit 1
  fi
done

echo "agentic-cli-account-switcher installer"
echo "  repo:   https://github.com/${REPO}"
echo "  ref:    ${REF}"
echo "  prefix: ${PREFIX}"
echo "  tools:  ${TOOLS}"
echo ""

installed=()
for tool in $TOOLS; do
  case "$tool" in
    claude|codex) ;;
    *)
      echo "error: unknown tool '$tool' (expected: claude, codex)" >&2
      exit 1
      ;;
  esac

  src="${RAW_BASE}/bin/${tool}-switch.sh"
  dst="${PREFIX}/${tool}-switch"
  tmp="${dst}.download.$$"

  echo "→ ${tool}-switch.sh -> ${dst}"
  if ! curl -fsSL "$src" -o "$tmp"; then
    echo "error: download failed: $src" >&2
    rm -f "$tmp"
    exit 1
  fi

  # Sanity check: must be a non-empty bash script
  if [[ ! -s "$tmp" ]] || ! head -1 "$tmp" | grep -q '^#!/usr/bin/env bash'; then
    echo "error: downloaded file does not look like a bash script: $tmp" >&2
    rm -f "$tmp"
    exit 1
  fi

  mv "$tmp" "$dst"
  chmod +x "$dst"
  installed+=("$dst")
done

echo ""
echo "installed:"
for path in "${installed[@]}"; do
  echo "  $path"
done

# Friendly PATH hint
case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *)
    echo ""
    echo "note: $PREFIX is not on your PATH."
    echo "Add this to your shell rc (~/.zshrc or ~/.bashrc):"
    echo "  export PATH=\"$PREFIX:\$PATH\""
    ;;
esac

echo ""
echo "next steps:"
echo "  claude-switch bootstrap   # one-time setup for Claude Code"
echo "  claude-switch status      # show active account"
echo "  codex-switch status       # same for Codex"
echo ""
echo "Docs: https://github.com/${REPO}#usage"
