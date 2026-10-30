# Privacy and runtime data

Second Wind has no analytics, advertising SDK, crash uploader or project backend.
It talks to Codex and Claude only through their official local tools:

- One official Codex app-server process per Codex account. It communicates with
  OpenAI for sign-in, account information, usage and an eligible reset request.
- The official `claude` executable for each Claude account. It communicates with
  Anthropic for sign-in, account status and plan usage.

OpenAI's and Anthropic's own service policies apply to those calls.

## Local storage

Runtime data lives outside the checkout at:

```text
~/Library/Application Support/SecondWind/
```

- `state.json`: Codex account emails, names, profile UUIDs, preferences, usage
  readings and any durable pending redemption, which can include a credit
  identifier and idempotency key.
- `events.json`: a bounded history of redacted Codex events.
- `claude-state.json`: Claude account emails, names, profile UUIDs, plan name,
  the latest usage reading and which low-limit alerts were already sent.
- `guard.lock`: the single-instance process lock.
- `profiles/<uuid>/`: an isolated `CODEX_HOME` maintained by Codex app-server,
  configured for file-backed authentication. Codex owns the credentials there.
- `claude/<uuid>/`: an isolated `CLAUDE_CONFIG_DIR` maintained by Claude Code.
  Claude Code stores that account's sign-in in your login Keychain under an item
  named for this folder, separate from your everyday Claude Code sign-in.

Second Wind's own directories use mode `0700` and its files `0600`, written
atomically. This is access control, not encryption; other software running as
your user may read them. Second Wind never reads, imports, prints or copies OAuth
tokens or Keychain items. It discards the tools' stderr and redacts sensitive
fields from its event history. That does not make the whole runtime directory
safe to share.

Child processes get a cleaned environment: inherited `OPENAI_*`/Codex credential
variables are removed for Codex, and every `ANTHROPIC_*` and `CLAUDE_*` variable
is removed for Claude, so an API key in your shell can never be picked up.

Version 0.2.0 moves `~/Library/Application Support/CodexWeeklyResetGuard/` to the
new location on first launch and leaves a small note file in its place. It never
merges into an existing `SecondWind` folder.

## User controls

Automatic Codex redemption starts off for each new account, and reconnecting
pauses it until you turn it back on. Launch at login is opt-in. macOS controls
notification permission. Quitting stops all monitoring processes; it does not
revoke account access or delete local data.

To stop using the app, turn off launch at login, quit it and move the app to
Trash. You can then trash its application-support directory to discard all
accounts and recovery state. Do not discard it to retry an uncertain Codex
redemption: it holds the idempotency key needed for safe recovery. A Claude
account's Keychain item is named `Claude Code-credentials-` followed by a short
hash; you can delete it in Keychain Access. Revoke access through OpenAI's or
Anthropic's account settings when appropriate.

Do not attach runtime files to issues, pull requests or release archives. The
repository's publish check excludes runtime paths, local QA output and personal
design-process records; it is a guardrail, not a guarantee against every secret.
