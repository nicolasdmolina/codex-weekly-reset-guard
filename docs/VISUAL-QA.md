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

Images are generated under ignored `qa-artifacts/` and contain synthetic data.
The static renderer substitutes styled fields for AppKit-backed controls;
interactive `--preview <state>` uses native controls and scrolling without a
production runtime. Preview actions cannot connect accounts or redeem credits.

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
