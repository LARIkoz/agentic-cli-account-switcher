# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] — 2026-06-14

### Added

- **VS Code / Cursor support for account switching.** All Codex surfaces (CLI,
  desktop App, editor extension) share `~/.codex/auth.json`, but long-running
  clients cache the token in memory, so an external swap was invisible to the
  editor until a manual window reload. Now:
  - `codex-switch.sh` restarts the editor's `codex app-server` after a swap
    (kill → the extension host respawns it reading the new account). New
    `--no-vscode` flag opts out. The process guard no longer blocks on the App
    or the editor (both are managed); only truly unmanaged `codex app-server`
    processes (e.g. a terminal `codex`, or a `remodex`/MCP bridge) still block.
  - `codex-auth-sync.sh` now also detects an **account change** (email differs
    from last run, not just a token refresh) and restarts the editor's
    `codex app-server`. This makes a switch done by **Symbioose** — or anything
    that rewrites `auth.json` — take effect in VS Code automatically, no reload.

### Notes

- Detection covers `.vscode`, `.vscode-insiders`, `.cursor`, `.windsurf`, and
  `.vscode-server` extension hosts.
- The editor's Codex panel reconnects on next use after a restart.

## [0.2.0] — 2026-06-14

### Removed (BREAKING)

- **`codex-refresh-tokens.sh` and its launchd plist** — REMOVED. This independent
  token refresher was harmful: OpenAI uses one-time-use rotating refresh tokens,
  so a background refresher races the official Codex client and kills both tokens
  within days (`refresh_token_reused`). See `docs/token-refresh-pitfall.md`.

### Added

- `docs/token-refresh-pitfall.md` — explains why independent OAuth refreshers must
  never be used with rotating one-time-use refresh tokens, and how to recover.

### Changed

- `codex-auth-sync.sh` — clarified that it is strictly passive (byte-copy only,
  never calls the OAuth endpoint). It remains safe and is the only token-related
  automation that should run.

## [0.1.1] — 2026-05-25

### Added

- `install.sh` — one-liner installer for `curl | bash` workflows. Honors `PREFIX`, `TOOLS`, and `REF` env vars.
- README install section now leads with the one-liner; manual clone kept as fallback.

## [0.1.0] — 2026-05-25

Initial public release.

### Added

- `bin/claude-switch.sh` — Claude Code account switcher (file + Keychain dual swap, 805 lines).
  - Commands: `bootstrap`, `acc2`, `default`, `fix`, `status`, `preflight`, `smoke`.
  - Works with both the installed `claude` CLI and the binary shipped inside the VS Code extension.
- `bin/codex-switch.sh` — Codex CLI account switcher (file + Keychain swap with App restart, 415 lines).
  - Commands: `switch`, `restore-last`, `fix`, `status`, `preflight`, `acc2-status`, `acc2-smoke`.
  - Flags: `--no-app` (skip Codex App relaunch), `--allow-running` (force switch despite live processes).
- `docs/keychain-caveat.md` — explanation of the macOS Keychain refresh overwrite bug and the dual-swap solution.
- `docs/alternatives.md` — side-by-side comparison with Symbioose, cux, claude-swap, ccs, and VDM.
- `screenshots/symbioose-menu.png` — sanitized reference image of a GUI alternative.

### Planned

- `bin/gemini-switch.sh` — Gemini CLI module (target v0.2).
- Linux Keychain via `secret-tool` / `libsecret` (target v0.3).
- Homebrew tap (target v0.4).
- CI smoke tests (target v0.5).
