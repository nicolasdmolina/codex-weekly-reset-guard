# Contributing

Use macOS 14 or later and Swift 6.0 or later. The app uses Apple system
frameworks and has no third-party Swift package dependencies.

1. Make a focused branch from the default branch.
2. Keep policy and protocol code in `CodexWeeklyResetGuardCore` independent of UI.
3. Use synthetic accounts and isolated temporary directories in tests.
4. Run `./scripts/test.sh`, `./scripts/test_tooling.sh`, and
   `python3 scripts/test_public_release.py`.
5. For a release or UI change, run `./scripts/native_release_check.sh` and inspect
   the synthetic previews in `qa-artifacts/`.
6. Stage only intended source files, then run `python3 scripts/check_public_release.py`
   and `git diff --cached --check`.

Describe the problem, behavior after the change, and verification in your pull
request. Include synthetic screenshots for UI changes. CI runs on macOS without
an account or Codex installation. It must never run the production app or `--doctor`.

`swift run CodexWeeklyResetGuard --preview onboarding` opens a focusable native
window for safe keyboard and accessibility testing. Preview mode never creates a
runtime. Dedicated QA bundles can carry a `GuardPreviewKind` marker so reopening
them stays synthetic. A separate `GuardDiagnosticSupportDirectory` marker enables
live sign-in and usage reads in an existing, isolated temporary directory. The
directory must be owned by the current user with mode `0700`, strictly beneath a
system temporary root or the process's explicit `TMPDIR`. An additional `TMPDIR`
root must itself be absolute, existing, user-owned and mode `0700`; an absent or
unsafe value adds no accepted root. Paths are resolved before containment checks,
and production state, its descendants and its ancestors are always excluded.
`TMPDIR` alone never enables diagnostic mode. Diagnostic mode disables reset
redemption, notifications and launch at login, but still writes its isolated
profile/state/session files and must not run in CI.
The two markers are mutually exclusive, fail closed on invalid values, and are
rejected by the public packaging script. Never put either marker in release metadata.

## Reset safety

Changes to classification, identity verification, durable state, and redemption
need regression tests at the controller boundary. Keep these properties:

- Only a fresh, unambiguous canonical weekly limit can trigger a request.
- A short-window or model-specific limit cannot trigger a request.
- New profiles start with automatic redemption disabled.
- Verify the expected account before any redemption request and reject missing inventory.
- Persist an idempotency key before a request; reuse it after uncertainty.
- Disabling or reconnecting must close the redemption boundary immediately.
- A local test, preview, or diagnostic must never consume a real reset.

Do not add private ChatGPT endpoint calls or copy existing credentials. Account
authentication belongs to the official Codex app-server in each isolated home.

## Reports

For bugs, include macOS, Swift and Codex versions, steps to reproduce, and
sanitized error text. Do not attach application-support directories, account
files, sign-in links, raw protocol traces, or screenshots with personal data.
See [SECURITY.md](SECURITY.md) for security reports.

Contributions are made under the repository's [MIT license](LICENSE).
