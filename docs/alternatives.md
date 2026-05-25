# Alternatives

How `agentic-cli-account-switcher` compares to other Claude Code / Codex account switchers.

| Tool                                                                              | Stack         | Surface             | Keychain-aware  | Multi-CLI                         | Notes                                                          |
| --------------------------------------------------------------------------------- | ------------- | ------------------- | --------------- | --------------------------------- | -------------------------------------------------------------- |
| **this repo**                                                                     | bash          | CLI                 | yes (dual swap) | Claude + Codex (+ Gemini planned) | Single file each, zero deps, scriptable.                       |
| [Symbioose Claude Switcher](https://github.com/Symbioose/claude-account-switcher) | PyQt          | macOS menu bar GUI  | yes             | Claude + Codex                    | Polished UX, 49 MB Cask, no headless mode.                     |
| [realiti4/claude-swap](https://github.com/realiti4/claude-swap)                   | Python        | CLI                 | partial         | Claude only                       | Good UX, custom Keychain service name.                         |
| [inulute/cux](https://github.com/inulute/cux)                                     | Go            | CLI + live recovery | yes             | Claude only                       | Detects 429/401, swaps mid-session.                            |
| [kaitranntt/ccs](https://github.com/kaitranntt/ccs)                               | TypeScript    | Profile routing     | custom service  | Multi-provider via profiles       | Largest scope; not just account switching.                     |
| [loekj/claude-acct-switcher (VDM)](https://github.com/loekj/claude-acct-switcher) | Node.js proxy | `localhost:3334`    | N/A (proxy)     | Claude only                       | Header rewrite at proxy layer; survives refresh transparently. |

## When to pick which

- **This repo** — you want terminal-first, scriptable into cron/CI, single bash file per CLI, multi-tool from one repo.
- **Symbioose** — you prefer a menu bar GUI, don't mind a heavy Cask, want one-click switch with usage stats.
- **cux** — you want session-continuity across rate-limit hits (auto-swap on 429/401 without breaking the conversation).
- **VDM** — you want a transparent proxy that survives token refresh without touching files or Keychain at all.
- **ccs** — you want a unified config for many providers (Claude, Gemini, Copilot, local), not just account switching.
- **claude-swap** — you want a polished Python CLI, you only need Claude, and your Keychain config matches its expected service name.

## Why we still wrote a new one

1. The bash-only single-file approach (805 + 415 lines) is **auditable in one sitting** — no transitive dependencies to vet.
2. Multi-CLI in a single repo with shared docs (Keychain caveat, alternatives table) — most other tools target one CLI.
3. The Keychain dual-swap pattern documented here is portable to any future AI CLI that adopts the same `~/.<tool>/credentials.json` + macOS Keychain pattern.
4. Sibling positioning to a planned `LARIkoz/codex-macos-account-switcher` was redundant once the dual-CLI design emerged.

## Architecture patterns at a glance

- **File swap** — read live credentials, back up per account, overwrite on switch. Requires Keychain awareness on macOS or you get the [refresh overwrite bug](keychain-caveat.md).
- **Profile routing** — swap entire provider/profile (Claude/Gemini/Copilot). No session continuity, just a fresh profile each time.
- **Proxy layer** — intercept requests at `localhost:PORT`, rewrite `Authorization` header before forwarding. Transparent to the CLI; live session survives token swap.
- **Orchestrator** — not a switcher, but spawns isolated CLI instances per worker via `CLAUDE_CONFIG_DIR` env var (e.g. `multiclaude`).

This repo uses **file swap + Keychain swap** in a single atomic operation with rollback.
