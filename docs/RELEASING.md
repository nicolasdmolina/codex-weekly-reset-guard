# Releasing

This checkout is prepared locally. Preparing source does not publish a repository,
create a remote, push commits, enable account features, or produce a notarized app.

## Local gate

1. Review scoped changes and `Resources/Info.plist` version numbers.
2. Run `./scripts/test.sh`, `./scripts/test_tooling.sh`,
   `python3 scripts/test_public_release.py`, and
   `./scripts/native_release_check.sh` on macOS.
3. Inspect the generated synthetic previews, including first-run onboarding.
4. Stage only intended source files. Local planning, `.scratch/`, QA logs, builds,
   runtime state and account files must stay outside the index.
5. Run `python3 scripts/check_public_release.py`, `git diff --cached --check`,
   and review `git diff --cached --stat` / `git ls-files`.
6. Update `docs/RELEASE-RECEIPT.md` with actual evidence and remaining limitations.

The publication check scans the index and reachable history, rejects unexpected
source paths, symlinks and oversized artifacts, and checks text for personal home
paths and common credential formats. It never reads rejected runtime/credential
files and never prints matching values. It is not a complete secret detector;
review the publish set as well. If historical private material is found, stop and
prepare a clean export with the owner's approval. Do not rewrite shared history
automatically.

## GitHub publication — separate owner action

Once the owner approves publication:

1. Create the desired public repository on the owner's GitHub account.
2. Set its description and topics; add a remote and push the reviewed source.
3. Enable private vulnerability reporting under repository security settings.
4. Confirm the macOS workflow passes in GitHub; local success is not hosted CI evidence.
5. Enable appropriate branch protection once the workflow has run.
6. Create a `v0.1.0` prerelease pointing to the reviewed commit. Use the changelog
   and explicitly state the source-preview limits.

Do not attach `dist/`, QA logs, local planning records, account directories, or an
entire working-directory zip. GitHub's source archive contains only committed
files. Locally, `git archive --format=zip HEAD > /tmp/weekly-reset-guard-source.zip`
creates a source-only archive after a reviewed commit exists.

## Binary distribution is a later gate

Ad-hoc signing checks bundle integrity locally; it does not establish publisher
identity or notarization. Before distributing app downloads, choose a signing
identity and supported architectures, sign with Developer ID, notarize and staple,
verify Gatekeeper behavior on a clean Mac, and publish checksums. Those credential
and distribution steps are outside this source-only preparation.
