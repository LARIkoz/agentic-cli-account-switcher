# Token Refresh Pitfall — Do NOT run an independent refresher

> Hard-won lesson. Read before adding any "auto-refresh" automation.

## TL;DR

**Never run a background job that refreshes Codex/ChatGPT OAuth tokens independently of the official client.** OpenAI uses **one-time-use rotating refresh tokens**. A second refresher racing the official Codex client guarantees both end up dead.

## What we tried (and why it was wrong)

We added `codex-refresh-tokens.sh` on a 12-hour launchd timer to "keep tokens alive" by refreshing each saved Keychain blob via `https://auth0.openai.com/oauth/token`.

It made things **worse**, not better. Within days both accounts died with `refresh_token_reused` / `invalid_refresh_token`.

## The mechanism

OpenAI's OAuth uses refresh-token **rotation**:

1. Each call to the token endpoint with `grant_type=refresh_token` returns a **new** access token **and a new refresh token**.
2. The **old refresh token is immediately invalidated.**
3. The client must persist the new refresh token and use it next time.

With two independent refreshers (our cron + the official Codex client), the sequence is fatal:

```
auth.json holds RT_1.   blob (our copy) holds RT_1.
  ↓
Our cron refreshes blob: RT_1 → RT_2.  OpenAI kills RT_1.
Blob now has RT_2. auth.json STILL has RT_1 (we never wrote it back to auth.json).
  ↓
Official Codex client refreshes auth.json using RT_1 → "refresh_token_reused" (RT_1 is dead).
Client's refresh fails. auth.json never updates. Session dies.
```

Whoever holds the stale copy of the rotating token loses. There is no way to share a one-time-use rotating refresh token between two independent agents.

## The correct model

- **Exactly one refresher per account: the official Codex client** (CLI, VS Code extension, or desktop app — they coordinate among themselves via file locking on `auth.json`).
- Our tooling must be **passive**: never call the OAuth token endpoint. Only **copy bytes** of `auth.json` for switching/backup.
- `codex-auth-sync.sh` is safe because it only mirrors `auth.json` → Keychain blob (byte copy, no OAuth call). It never consumes a refresh token.

## Symptoms that you've hit this

- `refresh_token_reused` or `invalid_refresh_token` from the token endpoint.
- "Your access token could not be refreshed because your refresh token was already used. Please log out and sign in again."
- Account works for a while, then dies even though you only switched accounts (didn't change passwords).

## Recovery

1. Stop and remove any independent refresher (`launchctl unload` + delete the plist/script).
2. Note: the **access token** is typically valid for ~10 days independent of the refresh token. Check `tokens.access_token` exp before assuming you're locked out — you may still be working.
3. Re-login once (`codex login`, complete in browser). With no competing refresher, the official client keeps the rotation chain alive on its own.
