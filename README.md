# Codex Weekly Reset Guard

A native macOS menu-bar app that watches your Codex weekly allowance and can
automatically redeem an available reset credit when the weekly balance is low.

**Source preview · macOS 14+ · Swift 6+ · MIT**

Independent community software; not affiliated with or endorsed by OpenAI.
Codex and ChatGPT are OpenAI products. This app does not grant or purchase reset
credits, and reset availability depends on your account and Codex version.

## What it does

- Monitor one or more separately authenticated Codex accounts.
- Show weekly capacity, natural reset time, available credits, and recent activity.
- Optionally redeem after two fresh weekly readings at or below **3% remaining**,
  at least five seconds apart, with at least five minutes until the natural reset.
- Preserve a durable idempotency key so an uncertain request can be reconciled.
- Keep automatic redemption and launch at login **off until you enable them**.

The trigger uses the canonical weekly `codex` allowance. Short-window and
model-specific exhaustion cannot trigger redemption. OpenAI determines which
eligible allowance windows the reset actually affects. Enabling automatic
redemption authorizes the app to spend an available reset credit at the threshold;
up to 3% of weekly allowance may remain unused.

## Build and install

You need macOS 14 or later, an active Swift 6+ toolchain (Xcode or Command Line
Tools), and a compatible official Codex CLI or Codex desktop app. Install Codex
using [OpenAI's instructions](https://developers.openai.com/codex/quickstart).
No API key or third-party Swift package is required.

From a checkout or extracted source archive:

```sh
swift --version
./scripts/test.sh
./scripts/package_app.sh
./scripts/install_app.sh
```

The app is installed in `~/Applications/Codex Weekly Reset Guard.app`.
Open it from Finder and look for the shield in the menu bar. The installer does
not launch it unless you pass `--launch`, and retains a backup when replacing an
existing installation. Quit an existing instance before installing an update.

Builds target the host architecture. The generated bundle is **ad-hoc signed and
not notarized**; this repository does not yet provide a Developer ID signed
download. Building locally is the supported installation path for this preview.
Do not disable macOS security protections to run an untrusted download.

## First run

1. Add your expected ChatGPT account email and an optional display label.
2. Use **Connect** to sign in through the browser. Each profile has its own
   app-owned Codex home; existing Codex or CodexBar credentials are not imported.
3. Verify the account and weekly readings. Leave **Auto-redeem** off to monitor
   without redeeming, or enable it for that profile when you want automatic resets.
4. Add further profiles as needed. Use the menu's launch-at-login option if desired.

Existing Guard profiles retain their saved settings. Reconnecting pauses automatic
redemption until you explicitly enable it again. Keep the app running and the Mac
awake and online for monitoring. It cannot guarantee an uninterrupted allowance.

## Compatibility and troubleshooting

Schema compatibility was checked against Codex CLI **0.145.0** and **0.153.4**.
These are tested protocol versions, not a guaranteed minimum or an account
eligibility promise. The app requires the official app-server account, rate-limit,
reset-inventory and consume methods. Missing or ambiguous data prevents redemption.

The first executable found is used, in this order:

1. `~/.local/bin/codex`
2. `/Applications/Codex.app/Contents/Resources/codex`
3. `/usr/local/bin/codex`
4. `/opt/homebrew/bin/codex`

If an old CLI shadows a newer desktop app, update that CLI. A custom-only install
outside these locations is not discovered automatically. Missing inventory or an
ineligible account may show an attention state even when sign-in succeeds.

For an explicit live **no-consume** diagnostic, quit Guard first and run:

```sh
"$HOME/Applications/Codex Weekly Reset Guard.app/Contents/MacOS/CodexWeeklyResetGuard" --doctor
```

This reads already-enrolled accounts and usage. It does not consume a credit or
rewrite Guard policy/history, but Codex may maintain its own session files. It is
not part of the automated release checks. It cannot enroll a new account.

## Development and verification

```sh
./scripts/test.sh
./scripts/test_tooling.sh
./scripts/native_release_check.sh
python3 scripts/test_public_release.py
python3 scripts/check_public_release.py
```

The native release check builds, runs tests and a self-test, renders synthetic UI
states, and verifies the local app bundle. `--skip-previews` supports headless CI.
Tests, previews and packaging do not connect accounts or redeem credits. Python 3
is needed for the publication hygiene check; it is not an app runtime dependency.

For safe native interaction testing, `swift run CodexWeeklyResetGuard --preview onboarding`
opens the real controls in a normal window with synthetic data. Other fixture
names include `paused`, `connect`, `healthy`, `near`, `redeemed` and `auth-error`.
Preview controls cannot enroll accounts or invoke live services.

The code is split into a deterministic core and a native application target. See
[architecture](docs/ARCHITECTURE.md), [contributing](CONTRIBUTING.md),
[privacy](docs/PRIVACY.md), [security reporting](SECURITY.md), and the
[release checklist](docs/RELEASING.md). The [verification receipt](docs/RELEASE-RECEIPT.md)
records what was actually checked for this source preview.

## License

[MIT](LICENSE), copyright 2026 Nicky Molina. Apple system frameworks and your
separately installed Codex software remain subject to their respective terms.
