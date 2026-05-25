# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
