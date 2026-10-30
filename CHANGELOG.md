# Changelog

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
