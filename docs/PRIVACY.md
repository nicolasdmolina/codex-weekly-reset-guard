# Privacy and runtime data

Weekly Reset Guard has no analytics, advertising SDK, crash uploader, or project
backend. It launches an official Codex app-server process per enrolled account.
Those processes communicate with OpenAI for sign-in, account information, usage,
and an eligible reset request. OpenAI's own service policies apply to those calls.

## Local storage

Runtime data lives outside the checkout at:

```text
~/Library/Application Support/CodexWeeklyResetGuard/
```

- `state.json`: expected account email, display label, profile UUID, preferences,
  usage observations, and any durable pending redemption attempt. Pending attempts
  can include a credit identifier and idempotency key.
- `events.json`: a bounded history of redacted operational events.
- `guard.lock`: the single-instance process lock.
- `profiles/<uuid>/`: an isolated `CODEX_HOME` maintained by Codex app-server.
  The app configures file-backed authentication for isolation; Codex owns the
  credentials and session files in that directory.

Guard's state files use private file permissions and atomic, synchronized writes.
Its own directories use mode `0700` and its files use mode `0600`. This is access
control, not encryption. Other software running as your user may access them.
Guard does not read, import, print, or copy OAuth token values. It discards
app-server stderr and redacts sensitive fields from its event history. Redaction
does not make the entire runtime directory safe to share.

New installs do not discover or import CodexBar accounts. Existing Guard profiles
remain usable with their saved preferences. The source retains a tested legacy
CodexBar metadata parser, but onboarding does not call it.

## User controls

Automatic redemption starts off for each new account. Connecting or reconnecting
pauses it until explicitly re-enabled. Launch at login is also opt-in. macOS
controls notification permission. Quitting the app stops its monitoring processes;
it does not revoke the account's authorization or remove its local data.

To stop using the app, disable launch at login from its menu, quit it, and move the
app bundle to Trash. You can then move its application-support directory to Trash
if you intend to discard all profiles and recovery state. Do not discard that
state to retry an uncertain redemption: it contains the idempotency key needed
for safe recovery. Revoke account access through OpenAI's account controls when
appropriate.

Do not submit runtime files in issues, pull requests, or release archives. The
repository's publish check excludes runtime paths, local QA output, and personal
design-process records; it is a guardrail, not a guarantee against every secret.
