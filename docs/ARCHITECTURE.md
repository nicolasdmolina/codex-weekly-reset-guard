# Architecture

The Swift package has two targets: a deterministic core library and an AppKit /
SwiftUI menu-bar executable. It has no third-party package dependencies.

```text
SwiftUI popover → GuardAppModel → GuardRuntimeController (actor)
                                  ├─ MonitorPersistence → SecureStateStore
                                  ├─ RedactedEventLog
                                  ├─ ResetPolicyEngine / RateLimitClassifier
                                  └─ AppServerClient → isolated codex app-server
```

Each profile has a UUID-derived application-owned `CODEX_HOME`. A single-instance
lock prevents two Guard processes using the same runtime directory. An expected
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

## Test boundaries

Unit tests exercise classification, policy, protocol decoding, private persistence,
and locking. Controller tests use fake sessions and isolated temporary state to
exercise request ordering, recovery and race conditions. Preview rendering uses
synthetic profiles and does not construct a production runtime. `--doctor` is an
explicit live account/usage read with a hard no-consume override; it is excluded
from CI and release checks.
