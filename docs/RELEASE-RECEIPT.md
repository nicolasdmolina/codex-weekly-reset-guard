# Release verification

## 0.4.3, November 28, 2026 (UTC)

The macOS check passed on commit `0dcc6bb944d713e834c68690760d98eaf6fc36c5`.
All 420 tests passed locally. GitHub built the Mac and source ZIPs from that
commit. Both public downloads matched their SHA-256 checksums and the build
attestation.
[Mac check](https://github.com/nicolasdmolina/codex-weekly-reset-guard/actions/runs/46126544728) ·
[Release files](https://github.com/nicolasdmolina/codex-weekly-reset-guard/releases/tag/v0.4.3) ·
[Build run](https://github.com/nicolasdmolina/codex-weekly-reset-guard/actions/runs/46126544729).

| File | SHA-256 |
| --- | --- |
| `Second-Wind-0.4.3-mac.zip` | `f511ff767e4bab21010e7d587ce47f123aadaf38f5f1db7311d357dbdb061c91` |
| `Second-Wind-0.4.3-source.zip` | `b850b2e3aef7fd6b14945cfd2a709799f9790cadad67bc35e2c2ff2fbe62f36c` |

The downloaded app's self-test passed on Apple silicon and under Rosetta for
Intel. Removing another Mac's account was tested with synthetic sync folders,
not on a real account.

## 0.4.2, November 28, 2026 (UTC)

The macOS check passed on commit `a6de04e05cdba454ea0dfa65f73afed33e9aeb7c`.
All 408 tests passed locally. GitHub built the Mac and source ZIPs from that
commit. Both public downloads matched their SHA-256 checksums and the build
attestation.
[Mac check](https://github.com/nicolasdmolina/codex-weekly-reset-guard/actions/runs/46113766622) ·
[Release files](https://github.com/nicolasdmolina/codex-weekly-reset-guard/releases/tag/v0.4.2) ·
[Build run](https://github.com/nicolasdmolina/codex-weekly-reset-guard/actions/runs/46113766578).

| File | SHA-256 |
| --- | --- |
| `Second-Wind-0.4.2-mac.zip` | `ec21753f05a4914f506ac0b6cfa3074c62ecd86bcfbe84b2882a5d7e1b1557eb` |
| `Second-Wind-0.4.2-source.zip` | `36a646a575f7ca19f40c21567012bb0cf88f20bba1f2c4ab08acbb430a6adbd6` |

The downloaded app's self-test passed on Apple silicon and under Rosetta for
Intel.

## 0.4.1, November 28, 2026 (UTC)

The macOS check passed on commit `41b74111b949462de983d4ab3dcdb76e08773a05`.
All 394 tests passed locally. GitHub built the Mac and source ZIPs from that
commit. Both public downloads matched their SHA-256 checksums and the build
attestation.
[Mac check](https://github.com/nicolasdmolina/codex-weekly-reset-guard/actions/runs/46095578586) ·
[Release files](https://github.com/nicolasdmolina/codex-weekly-reset-guard/releases/tag/v0.4.1) ·
[Build run](https://github.com/nicolasdmolina/codex-weekly-reset-guard/actions/runs/46095578578).

| File | SHA-256 |
| --- | --- |
| `Second-Wind-0.4.1-mac.zip` | `21c25c62c7633ade53f95c77fec431a3b119d26f9f5236dd2cdfdf7fb5e41f11` |
| `Second-Wind-0.4.1-source.zip` | `7b5fa12587c46dea406ac2de479baae60670f66687c97271d3451144c64e988a` |

The downloaded app's self-test passed on Apple silicon and under Rosetta for
Intel. A live Codex Free account read its monthly limit with no check failure.

## 0.4.0, November 28, 2026 (UTC)

The macOS check passed on commit `cdd9d62a472d0fcf3b4b2eddd0d27ad2cc9e4624`.
All 390 tests passed locally. GitHub built the Mac and source ZIPs from that
commit. Both public downloads matched their SHA-256 checksums and the build
attestation.
[Mac check](https://github.com/nicolasdmolina/codex-weekly-reset-guard/actions/runs/46089995790) ·
[Release files](https://github.com/nicolasdmolina/codex-weekly-reset-guard/releases/tag/v0.4.0) ·
[Build run](https://github.com/nicolasdmolina/codex-weekly-reset-guard/actions/runs/46089995826).

| File | SHA-256 |
| --- | --- |
| `Second-Wind-0.4.0-mac.zip` | `ed3e4288ee1cc844c6bf65b7f56d50755c41104e3ffec3481dfd3d9b1761409d` |
| `Second-Wind-0.4.0-source.zip` | `f79e2a6066c56123f87da3cf3c46d7dd0a4b0fc9928789f178d372d6e5df7f77` |

The downloaded app's self-test passed on Apple silicon and under Rosetta for
Intel. A weekly-only Claude account and a weekly-only Codex account read live
with no 5-hour row and no unknown limit.

## 0.3.3, November 27, 2026 (UTC)

The macOS check that caught the Claude command crash passed on commit
`eea7bbd7e9d8bb2fd45de470d43f2ae3e2b6c5c4`. All 337 tests passed locally.
GitHub built the Mac and source ZIPs from that commit. Both public downloads
matched their SHA-256 checksums and the build attestation.
[Mac check](https://github.com/nicolasdmolina/codex-weekly-reset-guard/actions/runs/45940153073) ·
[Release files](https://github.com/nicolasdmolina/codex-weekly-reset-guard/releases/tag/v0.3.3) ·
[Build run](https://github.com/nicolasdmolina/codex-weekly-reset-guard/actions/runs/45940180099) ·
[Build attestation](https://github.com/nicolasdmolina/codex-weekly-reset-guard/attestations/72941336).

| File | SHA-256 |
| --- | --- |
| `Second-Wind-0.3.3-mac.zip` | `78b7a8eca53a8eae6508336471e0612cf0a0a82a1a52423b66f2d21ef1a8c34a` |
| `Second-Wind-0.3.3-source.zip` | `8aa1ae9b146a833bd6845e2277bc566217661351485924bfb7361a2a3afde437` |

The downloaded app reported version 0.3.3, build 6. Its self-test passed on
Apple silicon and under Rosetta for Intel. The pre-job check returned 0 for
sufficient quota, 10 for low quota, and 11 for a missing reading. All four live
screenshots matched the app’s renders pixel for pixel. Rebuilding the social
preview from its overview also reproduced the live image.

## 0.3.2, November 27, 2026 (UTC)

GitHub built the Mac and source ZIPs from `cd8183cd9984e009e2d49a943057b7a286d18657`.
Both public downloads matched their SHA-256 checksums and the build attestation.
[Release files](https://github.com/nicolasdmolina/codex-weekly-reset-guard/releases/tag/v0.3.2) ·
[Build run](https://github.com/nicolasdmolina/codex-weekly-reset-guard/actions/runs/45937611413) ·
[Build attestation](https://github.com/nicolasdmolina/codex-weekly-reset-guard/attestations/72935089).

| File | SHA-256 |
| --- | --- |
| `Second-Wind-0.3.2-mac.zip` | `1881c470f5ef9c23dff41f08a4663975df20b46a392e78399fa2332db8d897e4` |
| `Second-Wind-0.3.2-source.zip` | `c457ff3505eab90bfd2086ac536a79f7acc3a0fe03f6cea632977b28102fb414` |

All 336 tests passed. The downloaded app reported version 0.3.2, build 5, and
passed its self-test on Apple silicon and under Rosetta for Intel. Its overview,
low Codex quota, low Claude quota, and onboarding screens matched the four live
website screenshots pixel for pixel. Rebuilding the social preview from the
overview also reproduced the image served by the site.

## 0.3.1, November 26, 2026

The release tag points to `3031d7cb54aafc40f853d1736e6c4466a6d322a6`.
All 336 tests passed on an Apple silicon Mac with native UI tests enabled
and the installed Claude CLI using a fresh, signed-out profile.
[Tagged source](https://github.com/nicolasdmolina/codex-weekly-reset-guard/tree/v0.3.1).

GitHub built both ZIPs on a hosted Mac and attested them to the release tag.
Anonymous downloads of both files matched the published SHA-256 checksums
and the attestation. [Release files](https://github.com/nicolasdmolina/codex-weekly-reset-guard/releases/tag/v0.3.1) ·
[Build run](https://github.com/nicolasdmolina/codex-weekly-reset-guard/actions/runs/45913532437) ·
[Build attestation](https://github.com/nicolasdmolina/codex-weekly-reset-guard/attestations/72881640).

| File | SHA-256 |
| --- | --- |
| `Second-Wind-0.3.1-mac.zip` | `12cd6f97eed88ae385d74a207032fe9812afc7b8e1c981edcff6a98e36093e7f` |
| `Second-Wind-0.3.1-source.zip` | `5ef3e187e7e32b8a6da3a211572b754f3e4cda4375c19e63380e33b7b483b33a` |

The downloaded app passed strict signature verification and its self-test on
Apple silicon and under Rosetta for Intel. Both executable slices target
macOS 14. The pre-job check returned `unknown` (exit 11) for a missing snapshot.

The standard Gatekeeper assessment rejected the ad-hoc signed app with system
assessments enabled. Apple has not notarized the app. The interactive first-open
approval was not exercised on this Mac. [Apple’s first-open guide](https://support.apple.com/en-us/102445).

## 0.3.0, November 26, 2026

Local verification ran on Apple silicon with macOS 27.2.1 and Swift 6.2.4.

| Check | Observed result |
| --- | --- |
| Native package | Debug and release builds passed with warnings treated as errors. The bundled executable passed its self-test and the app passed strict local signature verification. |
| Tests with native controls enabled | All 336 tests passed. The run included typing and submitting a rename in an AppKit field, opening and reopening an account from a notification, the settings display, and the installed Claude CLI in a fresh signed-out folder. |
| Quota and recovery | Two monitor-only accounts that previously appeared healthy now warn for the right window. Tests cover partial provider responses, failed sign-in, overdue resets, simultaneous checks and interrupted account removal. Synthetic sessions recorded no reset requests for five-hour exhaustion. |
| Pre-job command | The packaged executable returned 0 for sufficient quota, 10 for exhaustion or an explicit provider block, and 11 for an old, incomplete or ambiguous reading. It left the supplied snapshot untouched. |
| Native menus | Rendered 22 synthetic states, including the two Codex windows, unknown inventory, expired sign-in, recovery targets, settings and clock-time display. |
| Website | Chrome checked desktop and mobile layouts, light and dark appearances, keyboard focus and reduced motion. The eight checks reported no page errors, overflow or accessibility violations. |
| Public source hygiene | The scanner accepted the staged source. All 35 publication fixtures passed, including rejection of unlisted runtime data. |

GitHub's macOS runner built and installed the app from a clean checkout.
The website passed its desktop and mobile checks.
[Mac CI](https://github.com/nicolasdmolina/codex-weekly-reset-guard/actions/runs/45908058142)
and [website checks](https://github.com/nicolasdmolina/codex-weekly-reset-guard/actions/runs/45908058187).

The public source ZIP has SHA-256
`d19c3efd71fba8be10ee6ace9b962bf8294424bf28a7d0a7fbaa5736d6b024af`.
An anonymous download matched the published checksum. Its installer built the
app on a Mac, where it passed its self-test and the pre-job checks. GitHub's
attestation identified the release workflow and tagged commit
`8098991633b3dc07dc468b3a1db66acc3ef55eca`.
[Release files](https://github.com/nicolasdmolina/codex-weekly-reset-guard/releases/tag/v0.3.0)
and [build attestation](https://github.com/nicolasdmolina/codex-weekly-reset-guard/attestations/72870497).

Notification delivery and signed-in provider sessions were simulated. No real
reset was spent. Local builds use an ad-hoc signature. A public app disk image
requires a Developer ID Application identity and a successful Apple notary submission.

## 0.1.0 source preview

Date: 2026-09-20 · Version: 0.1.0 source preview

Status: source published at
[nicolasdmolina/codex-weekly-reset-guard](https://github.com/nicolasdmolina/codex-weekly-reset-guard).
Local and hosted checks passed. The default branch requires pull requests and
the `macos` CI check, blocks force pushes/deletion, and applies those protections
to administrators. Private vulnerability reporting is enabled.

## Scope

- Removed mandatory two-account CodexBar enrollment; new profiles use explicit setup.
- Made automatic redemption and launch at login opt-in, preserving saved settings.
- Required genuine fresh confirmation evidence after sleep/restart for unsent requests.
- Added portable build/install scripts, macOS CI, MIT licensing, contributor and privacy docs.
- Kept personal planning, account state and generated output outside the Git publish set.

## Evidence

Local environment: macOS 26.3, Apple Silicon (arm64), Swift 6.2.4.

| Check | Result |
| --- | --- |
| `./scripts/native_release_check.sh` | Passed: 120 Swift tests, debug/release warnings-as-errors, self-test, eight synthetic renders, plist validation and strict signature verification |
| Fresh source build | Prior local archive passed 113 tests; the published revision passed 120 tests and packaging from a clean GitHub macOS runner |
| `./scripts/test_tooling.sh` | Passed: mocked build/sign failures, running-app protection, retained backups, launch opt-in, bundled MIT license and QA-marker rejection |
| `python3 scripts/test_public_release.py` | All 20 synthetic publication-safety cases passed, including removed historical content and value withholding |
| `python3 scripts/check_public_release.py` | Passed: 53 published source files and reachable history scanned locally and in GitHub CI |
| `git diff --check` and `git diff --cached --check` | Passed |
| Native render review | Eight 760 × 1120 fixtures inspected; misleading preview dates repaired and re-reviewed; no remaining high/medium visual findings |
| Native interaction | Passed: real typing, Tab focus, validation, safe preview isolation, toggle on/off, refresh, Add/Cancel and scrolling |
| Hosted CI | [Initial source revision passed](https://github.com/nicolasdmolina/codex-weekly-reset-guard/actions/runs/35543082817) on GitHub's macOS 15 runner |

Focused independent review covered reset safety, protocol compatibility,
onboarding concurrency, publication hygiene, tooling and documentation. No known
release-blocking findings remain in those reviewed areas. Render evidence and
local logs live in ignored `qa-artifacts/`; they are not part of the source archive.

Stable app-server schemas were inspected for Codex CLI 0.145.0 and 0.153.4 using
isolated temporary Codex homes. Initialization, login, rate-limit inventory and
all four consume outcomes match the client. This is schema evidence, not proof
of eligibility or successful live redemption.

## Limits

- An isolated live browser sign-in test has been started and is awaiting user
  authentication. No real reset credit has been consumed. Controller tests use
  synthetic sessions.
- The installed app and its runtime data were not replaced or modified.
- Packaging is host-architecture and ad-hoc signed, without Developer ID or notarization.
  The release machine reports zero valid code-signing identities; no signed binary
  download is included in this source preview.
- Live browser authentication is still awaiting the operator. The diagnostic UI
  is isolated from installed profiles and writes only its own temporary runtime;
  its read-only policy prevents redemption, not local enrollment/session writes.
- Local Apple Silicon and the GitHub macOS runner were tested; deployment
  target macOS 14 and Swift tools version 6.0 are not a full compatibility matrix.
