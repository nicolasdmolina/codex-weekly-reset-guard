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

Second Wind distributes a universal Mac app ZIP and a source ZIP through GitHub
Releases. GitHub-hosted Actions builds both from the same tag. The app uses an
ad-hoc signature with the hardened runtime. Packaging requires no Apple account,
certificate, notary service or repository signing secrets.

1. Update the version and build number in `Resources/Info.plist` and add the
   version to `CHANGELOG.md`. Merge the tested changes through a pull request.
2. Tag the merged commit and push the tag, for example
   `git tag v0.3.1 <merged-commit> && git push origin refs/tags/v0.3.1`.
3. The release workflow runs the native checks on macOS. It archives the tag,
   builds Apple silicon and Intel slices from an extracted copy of that source,
   checks each signature and runs the app’s synthetic self-test. It records
   GitHub provenance for both ZIPs, then verifies the files against those
   attestations and the public tag.
4. The publish job checks the files again after transfer and creates a draft
   with `Second-Wind-X.Y.Z-mac.zip`, `Second-Wind-X.Y.Z-source.zip` and
   `SHA256SUMS`. Review the draft, then publish it.
5. On a Mac with Git and the GitHub CLI signed in, verify the public files and
   generate the website’s download information:

   ```sh
   ./scripts/verify_release.sh --tag v0.3.1 --published --self-test --write-site-manifest
   ```

6. Open a pull request for `site/src/release.json`. After merge and deployment,
   download the Mac ZIP from the live site and confirm its checksum.
   [Second Wind downloads](https://secondwind.nickymolina.com/#install).

## What verify_release.sh checks

The verifier downloads over anonymous HTTPS. For each ZIP it checks SHA-256
and the GitHub attestation, including the signer workflow, tag, tagged commit
and use of a GitHub-hosted runner. A site link is generated only after these
checks succeed.

- The source ZIP has one versioned root, the expected app metadata, executable
  install scripts and a Git archive comment identifying the commit.
- The Mac ZIP holds one `Second Wind.app`. Before unpacking it, the verifier
  checks the entries, file types, permissions and expected bundle contents.
  It verifies the resource seal, version, bundle identifier and both executable
  slices. Each slice must have an ad-hoc signature, hardened runtime, no extra
  entitlements, and a macOS deployment target matching the app metadata.
- `--self-test` runs the extracted executable without launching account
  monitoring. Apple silicon Macs also test the Intel slice when Rosetta is
  available. A skipped architecture is reported.
- The historical v0.3.0 source-only release remains verifiable. New releases
  must include both ZIPs.

GitHub verifies where the file was built. Apple has not notarized the app, so
macOS may require the user to approve it on first launch. A managed Mac can
restrict this choice. [Apple’s first-open guide](https://support.apple.com/en-us/102445).

## Local packaging

For a dry run, use a local version tag in an isolated checkout and run
`./scripts/package_release.sh --tag vX.Y.Z`. It writes to `dist/release/vX.Y.Z/`
only after both archives pass the prepublication checks. An existing release
directory is preserved. GitHub provenance is created in the hosted workflow.

To inspect local files, use `./scripts/verify_release.sh --tag vX.Y.Z --dir
/absolute/path/to/assets`. The pre-attestation option `--skip-provenance` reports
the skipped check and cannot write website data. For a personal source install,
use `./scripts/install_app.sh`.

`./scripts/test_release_tooling.sh` builds a small universal app and exercises
the ZIP, signatures and rejection paths using macOS tools. Its network fixtures
simulate public tag lookup, GitHub attestations and downloads.
