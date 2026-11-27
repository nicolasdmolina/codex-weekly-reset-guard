# Native visual QA

Target: 380 × 560 points (760 × 1120 pixels at 2×).

Run `./scripts/native_release_check.sh` to regenerate these synthetic fixtures:

| Fixture | State |
| --- | --- |
| `onboarding.png` | Empty first-run account form |
| `onboarding-error.png` | Invalid-email feedback |
| `connect.png` | One new profile requiring sign-in, Auto-redeem off |
| `paused.png` | One verified account with Auto-redeem off |
| `healthy.png` | Two healthy accounts |
| `near.png` | Weekly-threshold confirmation |
| `redeemed.png` | Synthetic successful reset and recent activity |
| `auth-error.png` | One account requiring reconnection |
| `overview.png`, `claude-low.png`, `claude-signin.png` | Both providers, a low Claude weekly limit, and Claude sign-in |
| `monitor-low.png` | An exhausted five-hour window beside a 75% week, and a 1% week with Auto-redeem off |
| `usage-blocked.png` | Codex blocks usage while percentages remain high |
| `freshness.png` | Current and stale readings, including a window awaiting refill confirmation |
| `inventory.png` | Partial expiry list, a non-expiring reset, and an unknown saved-reset count |
| `used-exact.png` | Used percentages and local clock times |
| `settings.png`, `settings-denied.png` | An enabled test notification and denied permission |
| `rename.png`, `remove.png` | Inline rename and removal confirmation |
| `reveal.png`, `provider-failed.png` | An account highlighted after a notification and a provider that could not load |
| `remote.png`, `remote-stale.png` | Accounts on a synced Mac with a change waiting, and a Mac that stopped updating with a change it did not make |
| `settings-sync.png` | Sync turned on while iCloud Drive is off |

Images are generated under ignored `qa-artifacts/` and contain synthetic data.
The static renderer substitutes styled fields for AppKit-backed controls;
interactive `--preview <state>` uses native controls and scrolling without a
production runtime. Preview actions cannot connect accounts or redeem credits.

Set `SECOND_WIND_NATIVE_QA=1` when running `./scripts/test.sh` on a Mac to
exercise the AppKit rename field and account navigation in a hosted popover
view. The tests measure scrolling when the view opens and reopens.

The 2026-09-20 render review found one medium issue: the fixed preview dates were
formatted relative to the real clock, displaying past reset dates. Previews now
inject one shared reference clock into date formatting. All eight renders were
regenerated at 760 × 1120, and independent re-review found no remaining high/medium
clipping, overlap, readability or state-label issues.

Native interaction QA subsequently passed using a dedicated preview bundle with a
unique executable name and a focusable native window. Verified real text entry,
Tab focus movement, invalid-email feedback, synthetic-only enrollment rejection,
toggle on/off, refresh feedback, Add Profile/Cancel, internal scrolling and fixed
footer access. Screenshots of the actual native controls were inspected.

Live browser sign-in uses a separate isolated diagnostic window whose runtime
cannot redeem resets. See the [release receipt](RELEASE-RECEIPT.md) for the final
live-account and hosted-CI evidence; no account data or live screenshots are published.
