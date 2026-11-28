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

Each provider owns its sign-in and polling. The menu, notifications and preflight
use account readings from those monitors. Only the Codex controller can request a
saved weekly reset.

Each Codex profile has a UUID-derived application-owned `CODEX_HOME`. A
single-instance lock prevents two Second Wind processes using the same runtime
directory. An expected
email is checked against `account/read` before interpreting a profile's usage and
again before a consume request.

For redemption, the classifier accepts one unambiguous canonical `codex` weekly window of
10,080 minutes, with a 5% duration tolerance. Short windows, model-specific buckets,
missing values, stale observations and ambiguous classifications fail closed.
The runtime requires authoritative reset inventory as well as weekly usage to
redeem. A five-hour reading can warn someone that work will stop even if plenty
of weekly quota remains.

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
by account, window and reset time so each cycle alerts once. The app never redeems a
Claude reset; it opens `https://claude.ai/settings/usage`.

## Sync between Macs

Sync is off until the user turns it on in Settings. While it is off, Second Wind
neither reads nor writes the shared folder. Turning it off removes this Mac's
snapshot. The shared folder is `Second Wind/` in iCloud Drive. Every read and
write goes through `NSFileCoordinator`. A `.name.icloud` placeholder starts its
download and is read on a later pass. Passes run every 30 seconds and whenever
the popover opens. A missing folder or file reads as empty. Reading and
publishing fail separately. A Mac that cannot list the folder still publishes,
with `acceptsCommands` false. Other Macs then show its Auto-redeem switches as
read-only and never send it commands. Settings says which step failed. Each
pass appends one redacted `syncPass` record to `sync-events.json`, with counts,
decision kinds and any error domain and code.

- `devices/<deviceID>.json` is a `DeviceSnapshot`, written only by the Mac it
  describes. It holds each account's name, email, windows, saved-reset count,
  Codex Auto-redeem setting and any attention message, plus up to 50 handled
  command IDs. It holds no tokens, file paths or idempotency keys.
- `commands/<target>/<commandID>.json` is one `RemoteCommand`. The only action
  is `setAutoRedeem(profileID, enabled)`, an absolute state. Each Mac creates its
  own command folder on every pass, so senders write into a folder iCloud Drive
  has already synced.

A host records a command's ID before acting on it, so a command is applied at
most once even across a crash. It refuses commands older than 30 minutes, which
leaves time for iCloud Drive to deliver them, and commands from
the future, for an unknown or Claude profile, and enables for an email that
another Mac's current snapshot already redeems. An accepted command calls the
same function as the local Auto-redeem switch. The policy engine, its fail-closed
rules and idempotency stay the only route to a reset. The host deletes the file
and lists the ID in its next snapshot, which the sender treats as the answer.

The popover lists each account once. Accounts on different Macs are the same
account when provider and normalized email match; accounts with no email never
merge. `syncedAccounts` groups other Macs' copies by account and makes two
separate choices. The reading is the copy with the newest current observation.
The redeemer is a copy with a change in flight, else one with Auto-redeem on,
preferring a live snapshot. A remote-only card names and drives a live redeemer,
else the first Mac that can take a change now, else a quiet redeemer, else the
first Mac, so it does not move as Macs publish.

An account this Mac has is always one card. While its own reading is not
current, the card shows another Mac's current reading; readings are not mixed
window by window, so the card's age stays true. While this Mac's Auto-redeem is
off, the switch drives another Mac through that Mac's guards: a redeemer that is
live or has a change in flight, or, while this Mac is signed out, the first Mac
that can take a change. Otherwise it drives this Mac. A quiet redeemer hands the
switch back, as `AutoRedeemGuard` does. Failures report on this card. The caption
names the other Mac, says when it was last seen or needs attention, and says when
both Macs have Auto-redeem on. The menu bar uses the same cards.

Remote alerts check the low windows of every Mac read this pass, except a Claude
window this Mac read currently at least as recently, since Claude monitoring
alerts for it here; Codex monitoring has no low alert of its own. The alert key
names the provider, a digest of the email (never the email itself) and the window,
so the same low window notifies once even when several Macs report it.

The viewing Mac reads remote windows through `QuotaReadPolicy.remote`. A snapshot
or reading older than 10 minutes is stale: it shows its age and never alerts.
Low remote windows notify through the alert ledger once per account, window and
reset cycle. The double Auto-redeem guard is best effort. Two Macs enabling at
the same moment, or a Mac whose snapshot went stale, can still both be on.

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
