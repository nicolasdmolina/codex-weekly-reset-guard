# Changelog

## 0.3.2

- Clearer popover: warnings keep their message on its own and show the
  reading's age underneath, every header status has an icon, and the limit
  marker on each meter reads as a notch instead of a stray line.
- Light mode is easier to read: stronger teal, amber and red text, and
  visible off switches, banners and segmented controls.
- Shorter messages for sign-in, low limits, busy accounts and removal.

## 0.3.1

- Download a prebuilt Mac app for Apple silicon and Intel. Unzip it and move
  Second Wind to Applications. The download page explains macOS's first-open
  approval for this unnotarized app.
- Both the Mac app ZIP and the source ZIP have a SHA-256 checksum and a GitHub
  attestation linking the download to the tagged source.

## 0.3.0

- See the five-hour and weekly Codex limits together. Monitor-only accounts
  warn when either limit is low. Each account shows the age of its reading
  and waits for provider confirmation after the displayed reset time passes.
- See saved-reset expiries separately from the next weekly renewal. Choose
  optional expiry and confirmed-refill notifications, test them in Settings,
  and open the affected account directly from a notice.
- Switch between used and remaining percentages, and between countdowns and
  local clock times.
- Rename or remove individual accounts. An unresolved Codex redemption can
  still be reconciled after re-enrolling the same account.
- Copy an account's read-only pre-job command to check session and weekly
  minimums from a terminal or script.
- Versioned release archives carry SHA-256 checksums and GitHub build
  provenance. The release workflow also supports Developer ID signing and
  Apple notarization when configured.

## 0.2.0 — Second Wind

- Renamed from Codex Weekly Reset Guard. Accounts, pending redemptions and
  preferences move to `~/Library/Application Support/SecondWind` on first launch;
  the installer retires the old app bundle.
- Claude support: watch Pro and Max accounts' 5-hour, weekly and per-model limits
  through Claude Code's local `/usage`, get one alert per cycle at 10% remaining,
  and open Claude Settings › Usage to redeem a reset.
- Redesigned popover: grouped Codex and Claude sections, headroom meters with the
  alert line marked, a service picker in onboarding, and a teal brand palette that
  keeps amber and coral for warnings only.
- New app icon and a wind mark in the menu bar showing the lowest headroom.
- Codex redemption policy and safety checks are unchanged.

## 0.1.0 — initial public source preview

- Native menu-bar monitoring with isolated Codex account sessions.
- Independent account enrollment without a CodexBar dependency.
- Explicit opt-in for automatic redemption and launch at login.
- Weekly threshold classification, account verification and durable idempotency.
- Fresh confirmation required after stale observations or a long pause.
- Portable source build, local installer, synthetic UI previews and macOS CI.
- MIT license, contributor guidance, privacy documentation and release checks.

Source preview limitations: no notarized binaries, no live-redemption release
test, and no guarantee of reset eligibility across Codex versions or accounts.
