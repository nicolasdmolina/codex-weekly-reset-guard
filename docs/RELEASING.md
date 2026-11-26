# Releasing

The public repository is
[nicolasdmolina/codex-weekly-reset-guard](https://github.com/nicolasdmolina/codex-weekly-reset-guard).
Preparing a release locally publishes nothing. Pushing a tag, publishing a draft
release and deploying the website each need the maintainer's authorization.

## Local gate

1. Review scoped changes and `Resources/Info.plist` version numbers.
2. Run `./scripts/test.sh`, `./scripts/test_tooling.sh` (which also runs
   `./scripts/test_release_tooling.sh`), `python3 scripts/test_public_release.py`,
   and `./scripts/native_release_check.sh` on macOS.
3. For website changes, run `npm ci`, `node scripts/test-release-manifest.mjs` and
   `npm run build` in `site/`, then the browser QA described in `.github/workflows/site.yml`.
4. Inspect the generated synthetic previews, including first-run onboarding.
5. Stage only intended source files. Local planning, `.scratch/`, QA logs, builds,
   runtime state and account files must stay outside the index.
6. Run `python3 scripts/check_public_release.py`, `git diff --cached --check`,
   and review `git diff --cached --stat` / `git ls-files`.
7. Update `docs/RELEASE-RECEIPT.md` with actual evidence and remaining limitations.

The publication check scans the index and reachable history, rejects unexpected
source paths, symlinks and oversized artifacts, and checks text for personal home
paths and common credential formats. It never reads rejected runtime/credential
files and never prints matching values. It is not a complete secret detector;
review the publish set as well. If historical private material is found, stop and
prepare a clean export with the owner's approval. Do not rewrite shared history
automatically.

## Release flow

`.github/workflows/release.yml` runs when a `vX.Y.Z` tag is pushed. It ends in a
draft GitHub release; nothing becomes public until the maintainer publishes it.

1. Merge the release changes through the pull-request flow and wait for CI.
   `Resources/Info.plist` and `CHANGELOG.md` must name the version.
2. Tag the merged commit with a lightweight tag and push it:
   `git tag v0.3.0 <commit> && git push origin v0.3.0`.
3. The workflow's **source** job checks that the tag matches the app version and
   that `GITHUB_SHA` is the tagged commit, runs the publication checks and
   `native_release_check.sh --skip-previews`, archives the tagged commit with
   `scripts/package_source.sh` as `Second-Wind-X.Y.Z-source.zip`, records GitHub
   build provenance, and verifies the archive against that provenance and commit.
4. The **app** job runs only when the repository variable `SECOND_WIND_SIGNED_DMG`
   is `true`. See [Signed app disk image](#signed-app-disk-image).
5. The **publish** job, which holds no signing secrets, rechecks every file's
   SHA-256 against the digest its build job recorded, writes `SHA256SUMS`, and
   creates the draft release with notes from `CHANGELOG.md`.
6. Review the draft: exactly `Second-Wind-X.Y.Z-source.zip`, `SHA256SUMS`, and the
   `.dmg` only if the app job ran. Then publish it.
7. From a clean checkout of `main`, signed in with `gh auth login`, run:

   ```sh
   ./scripts/verify_release.sh --tag v0.3.0 --published --write-site-manifest
   ```

   Add `--team-id <TEAMID>` when the release has a disk image. This downloads the
   public files without signing in, checks them, and only then writes
   `site/src/release.json`. Open a pull request with that file. The website
   workflow builds and checks the page, and GitHub Pages deploys it after merge.
8. Open [secondwind.nickymolina.com](https://secondwind.nickymolina.com/#install)
   and check that the download link and checksum match the release.

Until step 7 lands, the website keeps offering the source of `main`.

Do not attach `dist/`, QA logs, local planning records, account directories, or an
entire working-directory zip.

## What verify_release.sh checks

`scripts/verify_release.sh` is the same check for maintainers, CI and anyone who
downloads a release. It needs macOS, `git`, and the GitHub CLI signed in.

For every file listed in `SHA256SUMS`:

- the SHA-256 matches, and the list names only this release's files;
- `gh attestation verify` finds provenance from `release.yml`, for this tag and
  repository, on a GitHub-hosted runner, with the source digest pinned to the
  commit the public tag points to (read with `git ls-remote`, annotated tags peeled).

For the source archive: every entry sits under `Second-Wind-X.Y.Z/`, nothing
escapes it or is a symlink, the install scripts are executable, the bundled
`Info.plist` has the release version and no QA markers, and the ZIP comment that
`git archive` writes names the tagged commit.

For the disk image:

- Gatekeeper assessments are enabled on the Mac doing the check;
- the image and the app are signed with a Developer ID Application certificate
  for the expected team, the app as `com.nickymolina.second-wind` with the
  hardened runtime, a secure timestamp and no debugging entitlements;
- both carry stapled notarization tickets, and Gatekeeper reports both as
  `Notarized Developer ID`;
- the image mounts read-only and holds only `Second Wind.app` and an
  `Applications` shortcut;
- the app's version matches the tag and its executable is universal (arm64 and
  x86_64).

`--self-test` additionally copies the app out, quarantines the copy, asks
Gatekeeper again and runs the app's synthetic `--self-test` natively and, when
Rosetta is installed, as x86_64. `--skip-provenance` exists only for the local
pre-attestation check inside `release_dmg.sh`; its summary says
`provenance NOT checked`, and it cannot write the website manifest.

`./scripts/test_release_tooling.sh` exercises these checks and their failure
paths with mocked Apple, GitHub and network tools. It proves the scripts' logic,
not Apple's or GitHub's verdicts.

## Signed app disk image

The app job builds `Second-Wind-X.Y.Z.dmg` with `scripts/release_dmg.sh`: a
universal release build signed with Developer ID, the hardened runtime and a
secure timestamp; the app notarized and stapled; then a signed disk image,
notarized and stapled; then `verify_release.sh` before the file leaves the job.
There is no unsigned or ad-hoc fallback. If anything is missing, the job fails
and no release is drafted.

Prerequisites, all owned by the maintainer:

1. Apple Developer Program membership.
2. A Developer ID Application certificate exported as a password-protected `.p12`.
3. An App Store Connect API key with the Developer role, for `notarytool`.
4. A GitHub environment named `release`, ideally with required reviewers, holding
   the secrets `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`,
   `NOTARY_KEY_P8_BASE64`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`, and the
   variable `SECOND_WIND_TEAM_ID`.
5. The repository variable `SECOND_WIND_SIGNED_DMG` set to `true`.

The job imports the certificate into a temporary keychain and deletes it and the
API key at the end, whatever the outcome. Secret values are never printed.

`release_dmg.sh` also runs locally with `SECOND_WIND_TEAM_ID`, an identity in the
login keychain and `SECOND_WIND_NOTARY_PROFILE` (a `notarytool store-credentials`
profile). A locally built image has no GitHub provenance, so `verify_release.sh`
rejects it for publication; use it only as a dry run.

`scripts/package_app.sh` and `scripts/install_app.sh` stay the local source
install: host architecture and ad-hoc signed.
