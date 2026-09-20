# Source release verification

Date: 2026-09-20 · Version: 0.1.0 source preview

Status: local source-preview checks passed; not published. Files are staged for
the first commit, with no remote configured. Publication, hosted CI, a signed
public binary and real-account redemption are separate gates.

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
| Fresh source archive, `./scripts/native_release_check.sh --skip-previews` | Prior preparation passed 113 tests and a package build without the original build cache; final revision is also checked by hosted CI before release |
| `./scripts/test_tooling.sh` | Passed: mocked build/sign failures, running-app protection, retained backups, launch opt-in, bundled MIT license and QA-marker rejection |
| `python3 scripts/test_public_release.py` | All 20 synthetic publication-safety cases passed, including removed historical content and value withholding |
| `python3 scripts/check_public_release.py` | Passed: 53 staged source files; no existing commit history |
| `git diff --check` and `git diff --cached --check` | Passed |
| Native render review | Eight 760 × 1120 fixtures inspected; misleading preview dates repaired and re-reviewed; no remaining high/medium visual findings |
| Native interaction | Passed: real typing, Tab focus, validation, safe preview isolation, toggle on/off, refresh, Add/Cancel and scrolling |

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
- Hosted GitHub CI and clean-machine sign-in remain unverified until those steps are run.
- Only the local toolchain and architecture are directly tested here; deployment
  target macOS 14 and Swift tools version 6.0 are not a full compatibility matrix.
