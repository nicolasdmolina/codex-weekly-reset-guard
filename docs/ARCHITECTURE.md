# Architecture

The Swift package has two targets: a deterministic core library and an AppKit /
SwiftUI menu-bar executable. It has no third-party package dependencies.

```text
SwiftUI popover → GuardAppModel ─┬─ GuardRuntimeController (actor, Codex)
                                 │   ├─ MonitorPersistence → SecureStateStore
                                 │   ├─ RedactedEventLog
                                 │   ├─ ResetPolicyEngine / RateLimitClassifier
                                 │   └─ AppServerClient → isolated codex app-server
                                 └─ ClaudeMonitorController (actor, Claude)
                                     ├─ SecureStateStore (claude-state.json)
                                     ├─ ClaudeAlertPolicy
                                     └─ ClaudeCLI → isolated claude executable
```

The Codex and Claude sides share nothing but the app model and the single-instance
lock. The Codex redemption path is unchanged by Claude support.

Each Codex profile has a UUID-derived application-owned `CODEX_HOME`. A
single-instance lock prevents two Second Wind processes using the same runtime
directory. An expected
email is checked against `account/read` before interpreting a profile's usage and
again before a consume request.

The classifier accepts one unambiguous canonical `codex` weekly window of
10,080 minutes, with a 5% duration tolerance. Short windows, model-specific buckets,
missing values, stale observations and ambiguous classifications fail closed.
The runtime requires authoritative reset inventory as well as weekly usage.

For a new redemption, the policy requires two readings no more than 120 seconds old at or below 3%
remaining, at least five seconds apart, and at least five minutes before the natural reset. It persists
the attempt before the external request. Uncertain responses retain the same key
for reconciliation. OpenAI determines which eligible rate-limit windows are reset;
the request has no parameter that forces a particular allowance window.

New profiles begin disabled. Disabling or reconnecting installs an immediate
in-memory stop before awaiting durable persistence. Previously sent or uncertain
attempts retain recovery state. Actor reentry and stale snapshots are covered by
controller-level regression tests.

## Claude monitoring

Each Claude profile has a UUID-derived `CLAUDE_CONFIG_DIR` under `claude/`.
Claude Code keys its Keychain item by that directory, so profiles never share or
replace the user's everyday sign-in. Children run with every inherited
`ANTHROPIC_*` and `CLAUDE_*` variable removed, a 45-second timeout and a 1 MB
output cap.

`ClaudeUsageParser` accepts only a result whose `local_command` is `usage` with
zero model turns. Anything else stops polling for that profile until the user
reconnects, so a changed CLI cannot spend plan usage in the background. Lines it
does not recognise are ignored; duplicate windows fail closed. Reset times are
read from Claude Code's `Mon d[, yyyy] at h[:mm]am (Zone)` format, inferring the
year nearest to now when it is omitted.

`ClaudeAlertPolicy` notifies when any window is at or below 10% remaining, keyed
by window and reset time so each cycle alerts once. The app never redeems a
Claude reset; it opens `https://claude.ai/settings/usage`.

## Protocol boundary

The app uses the official Codex app-server JSON-RPC interface over stdio:

- `initialize` / `initialized`
- `account/read`
- `account/login/start`
- `account/rateLimits/read`
- `account/rateLimitResetCredit/consume`

The consume method receives an idempotency key and optionally a credit ID. The
app does not call private ChatGPT HTTP endpoints. See the
[official app-server documentation](https://learn.chatgpt.com/docs/app-server).
Protocol support and credit eligibility depend on the installed Codex build and
account; unsupported or missing inventory prevents redemption.

## State migration

`LegacyStateMigration` renames the pre-0.2.0 `CodexWeeklyResetGuard` support
directory to `SecondWind` while holding the old app's instance lock, so a running
old copy blocks the move instead of racing it. It refuses to merge into an
existing directory, ignores symlinks, and leaves a file at the old path so a stale
login item for the old app fails to start rather than creating fresh state.

## Test boundaries

Unit tests exercise classification, policy, protocol decoding, private persistence,
and locking. Controller tests use fake sessions and isolated temporary state to
exercise request ordering, recovery and race conditions. Preview rendering uses
synthetic profiles and does not construct a production runtime. Claude tests use
a fake command runner; `SECOND_WIND_LIVE_CLAUDE=1` adds a check against the real
CLI in a fresh signed-out folder. `--doctor` is an
explicit live account/usage read with a hard no-consume override; it is excluded
from CI and release checks.
