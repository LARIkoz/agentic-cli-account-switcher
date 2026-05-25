# Keychain Caveat

> Why file-only account switchers leak on macOS, and how this repo solves it.

## Symptom

You've installed a Claude Code / Codex account switcher that swaps `~/.claude/.credentials.json` (or `~/.codex/auth.json`). The first switch works. A few hours later — or right after the CLI refreshes its OAuth token — you're suddenly back on the wrong account. Maybe your second account's tokens leak into your default home. Maybe a session that was supposed to use account A starts billing account B.

This is the **Keychain refresh overwrite** bug.

## Root cause

Claude Code on macOS (verified on 2.1.x) stores OAuth credentials in **two places**:

1. `~/.claude/.credentials.json` — JSON file, what file-only switchers swap.
2. **macOS Keychain** — service entry whose name follows the template:

   ```
   Claude Code${OAUTH_FILE_SUFFIX}${H}${K}
   ```

   where:
   - `OAUTH_FILE_SUFFIX` is `-credentials`
   - `H` is empty
   - `K` is a hash derived from `CLAUDE_CONFIG_DIR` (empty if the env var is unset)
   - **Account** is `process.env.USER || os.userInfo().username`

   In practice, with no `CLAUDE_CONFIG_DIR` override, the entry is:

   ```
   service="Claude Code-credentials"  account=$USER
   ```

Codex CLI behaves similarly with its own Keychain service (`Codex`), and Gemini CLI is expected to follow the same pattern.

### What goes wrong

When the CLI:

- starts a session, OR
- detects an expired access token and triggers a refresh,

it reads the OAuth tokens from the **Keychain**, not the file. After the refresh it writes the new tokens **back to both** the file and the Keychain — overwriting whatever file the switcher just put in place.

If you swapped the file but the Keychain still contains account A's tokens:

1. The CLI reads account A from Keychain.
2. The CLI refreshes account A's access token.
3. The CLI writes account A's refreshed tokens to `~/.claude/.credentials.json` — wiping your file swap.

Result: silent revert, unpredictable timing (depends on token TTL).

## Verification

Check whether your CLI uses Keychain:

```bash
security find-generic-password -s "Claude Code-credentials" -a "$USER"
```

If this prints a Keychain entry (instead of `SecKeychainSearchCopyNext: The specified item could not be found in the keychain.`), then your CLI is using Keychain and **file-only switching is unsafe**.

For Codex:

```bash
security find-generic-password -s "Codex" -a "$USER"
```

## How this repo handles it

In each switch operation, the script:

1. **Reads the current Keychain entry** into a per-account blob:
   ```bash
   security find-generic-password -s "Claude Code-credentials" -a "$USER" -gw 2>/dev/null > "$STATE_DIR/default-keychain.blob"
   ```
2. **Loads the target account's previously saved blob** and writes it back into the Keychain:
   ```bash
   security delete-generic-password -s "Claude Code-credentials" -a "$USER" 2>/dev/null
   security add-generic-password -U -s "Claude Code-credentials" -a "$USER" -w "$(cat "$ACC2_BLOB")"
   ```
3. Wraps the file swap and the Keychain swap inside the **same lock** so they cannot diverge.
4. On any failure, restores both the file AND the Keychain from backup blobs.

This means after `claude-switch.sh acc2`, both the file and the Keychain hold account 2's tokens. The next refresh sees the correct identity and writes back the correct account.

## Alternative: `CLAUDE_CONFIG_DIR` scoping

A more elegant approach that this repo does **not** currently take is to override `CLAUDE_CONFIG_DIR` per account:

```bash
CLAUDE_CONFIG_DIR=~/.claude-acc2 claude
```

Because the Keychain service name includes a hash of `CLAUDE_CONFIG_DIR`, each value gets its **own** Keychain slot, and no swap is needed.

Trade-off: VS Code's Claude Code extension does not currently expose a per-window `CLAUDE_CONFIG_DIR` setting, so this approach only works for terminal usage. The dual-swap approach in this repo covers both terminal and VS Code.

A future v0.x of this repo may add a `--config-dir` mode for users who only use the CLI.

## Smoke test after switch

Always run the bundled smoke test after a switch:

```bash
./bin/claude-switch.sh smoke
```

It asserts that the active credentials file and the Keychain blob match each other and that `claude auth status` reports the expected account identity (not just `loggedIn=true`).
