#!/bin/bash
set -euo pipefail

# Release packaging and verification checks. Apple signing, notarization,
# Gatekeeper, disk images, GitHub attestations and downloads are all mocked, so
# no verdict here comes from Apple or GitHub; git, zip, plutil and shasum are real.
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIRECTORY="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/second-wind-release-tooling.XXXXXX")" && pwd)"
trap 'rm -rf "$TEST_DIRECTORY"' EXIT
ROOT="$TEST_DIRECTORY/source checkout"
BIN="$TEST_DIRECTORY/bin"
OUT="$TEST_DIRECTORY/stdout"
ERR="$TEST_DIRECTORY/stderr"
TAG=v0.3.0
TEAM=ABCDE12345
SOURCE_FILE=Second-Wind-0.3.0-source.zip
APP_FILE=Second-Wind-0.3.0.dmg
RELEASE_URL="https://github.com/nicolasdmolina/codex-weekly-reset-guard/releases/download/$TAG"
IDENTITY_HASH=0123456789ABCDEF0123456789ABCDEF01234567
export MOCK_LOG="$TEST_DIRECTORY/commands.log"
export TMPDIR="$TEST_DIRECTORY/tmp"
mkdir -p "$TMPDIR" "$BIN" "$ROOT/scripts" "$ROOT/Resources" "$ROOT/site/src"

for script in package_app.sh package_source.sh release_dmg.sh verify_release.sh install_app.sh; do
  cp "$PROJECT_ROOT/scripts/$script" "$ROOT/scripts/"
done
cp "$PROJECT_ROOT/Resources/Info.plist" "$PROJECT_ROOT/Resources/AppIcon.icns" "$ROOT/Resources/"
cp "$PROJECT_ROOT/LICENSE" "$PROJECT_ROOT/Package.swift" "$ROOT/"
plutil -replace CFBundleShortVersionString -string 0.3.0 "$ROOT/Resources/Info.plist"
NULL_MANIFEST=$'{\n  "release": null\n}'
printf '%s\n' "$NULL_MANIFEST" > "$ROOT/site/src/release.json"

fixture_git() {
  git -C "$ROOT" -c core.hooksPath=/dev/null -c commit.gpgsign=false -c tag.gpgsign=false \
    -c user.name='Synthetic Test' -c user.email=test@example.invalid "$@" >/dev/null
}
fixture_git init --template=
fixture_git add --all
fixture_git commit -m 'Synthetic release fixture'
fixture_git tag "$TAG"
export MOCK_TAG_COMMIT="$(git -C "$ROOT" rev-parse "refs/tags/$TAG^{commit}")"
OTHER_COMMIT=0123456789abcdef0123456789abcdef01234567
export MOCK_REAL_GIT="$(command -v git)"

cat > "$BIN/codesign" <<'SH'
#!/bin/bash
printf 'codesign %s\n' "$*" >> "$MOCK_LOG"
fails() { [[ ",${MOCK_FAIL:-}," == *",$1,"* ]]; }
target="${!#}"
kind=app
[[ "$target" == *.dmg ]] && kind=dmg
case " $* " in
  *" -dv "*)
    printf '%s\n' "${MOCK_CODESIGN_DETAILS:-Identifier=com.nickymolina.second-wind
CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+7 location=embedded
Authority=Developer ID Application: Synthetic Maintainer (ABCDE12345)
Timestamp=Nov 26, 2026 at 9:00:00 AM
TeamIdentifier=ABCDE12345}" >&2
    ;;
  *" --entitlements "*) printf '%s' "${MOCK_ENTITLEMENTS:-}" ;;
  *" --verify "*)
    fails "verify-$kind" && exit 1
    requirement=""
    previous=""
    for argument in "$@"; do
      [[ "$previous" == -R ]] && requirement="$argument"
      previous="$argument"
    done
    if [[ -n "$requirement" ]]; then
      [[ "$requirement" == "=anchor apple generic and "* ]] || exit 3
      [[ "$requirement" == *"subject.OU] = \"${MOCK_SIGNED_TEAM:-ABCDE12345}\""* ]] || exit 3
    fi
    ;;
  *) fails "sign-$kind" && exit 1 ;;
esac
exit 0
SH
cat > "$BIN/spctl" <<'SH'
#!/bin/bash
printf 'spctl %s\n' "$*" >> "$MOCK_LOG"
if [[ "$1" == --status ]]; then
  printf '%s\n' "${MOCK_SPCTL_STATUS:-assessments enabled}"
  exit 0
fi
target="${!#}"
kind=app
[[ "$target" == *.dmg ]] && kind=dmg
[[ "$target" == */installed/* ]] && kind=quarantined
if [[ ",${MOCK_FAIL:-}," == *",gatekeeper-$kind,"* ]]; then
  printf '%s: rejected\nsource=Unnotarized Developer ID\n' "$target" >&2
  exit 3
fi
printf '%s: accepted\nsource=%s\norigin=Developer ID Application: Synthetic Maintainer (ABCDE12345)\n' \
  "$target" "${MOCK_SPCTL_SOURCE:-Notarized Developer ID}" >&2
SH
cat > "$BIN/xcrun" <<'SH'
#!/bin/bash
printf 'xcrun %s\n' "$*" >> "$MOCK_LOG"
fails() { [[ ",${MOCK_FAIL:-}," == *",$1,"* ]]; }
target="${!#}"
kind=app
[[ "$target" == *.dmg ]] && kind=dmg
case "$1 $2" in
  "stapler validate")
    if fails "stapled-$kind"; then
      printf '%s does not have a ticket stapled to it.\n' "$target"
      exit 65
    fi
    printf 'Processing: %s\nThe validate action worked!\n' "$target"
    ;;
  "stapler staple") fails staple && exit 65 ;;
  "notarytool submit")
    status="${MOCK_NOTARY_STATUS:-Accepted}"
    [[ "$3" == *.dmg ]] && fails notary-dmg && status=Invalid
    printf '{"id":"2f1c3a4b-0000-4000-8000-000000000001","status":"%s","message":"synthetic"}\n' "$status"
    ;;
  "notarytool log") printf 'synthetic notary log\n' ;;
  *) exit 64 ;;
esac
exit 0
SH
cat > "$BIN/hdiutil" <<'SH'
#!/bin/bash
if [[ "$1" == attach && ",${MOCK_FAIL:-}," == *",attach,"* ]]; then
  printf 'hdiutil failed-attach\n' >> "$MOCK_LOG"
  exit 1
fi
printf 'hdiutil %s\n' "$*" >> "$MOCK_LOG"
option_value() {
  local wanted="$1" previous="" argument
  shift
  for argument in "$@"; do
    [[ "$previous" == "$wanted" ]] && printf '%s\n' "$argument"
    previous="$argument"
  done
}
case "$1" in
  create)
    [[ ",${MOCK_FAIL:-}," == *",hdiutil-create,"* ]] && exit 1
    for argument in "$@"; do [[ "$argument" == *.dmg ]] && output="$argument"; done
    printf 'MOCKDMG\n%s\n' "$(option_value -srcfolder "$@")" > "$output"
    ;;
  attach)
    cp -R "$(sed -n 2p "$2")/." "$(option_value -mountpoint "$@")/"
    ;;
  detach) ;;
  *) exit 64 ;;
esac
SH
cat > "$BIN/lipo" <<'SH'
#!/bin/bash
printf 'lipo %s\n' "$*" >> "$MOCK_LOG"
printf '%s\n' "${MOCK_ARCHS:-x86_64 arm64}"
SH
cat > "$BIN/gh" <<'SH'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$MOCK_LOG"
if [[ ",${MOCK_FAIL:-}," == *",attestation,"* ]]; then
  printf 'no matching attestations found\n' >&2
  exit 1
fi
SH
cat > "$BIN/curl" <<'SH'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$MOCK_LOG"
previous=""
for argument in "$@"; do
  [[ "$previous" == --output ]] && output="$argument"
  previous="$argument"
done
url="${!#}"
[[ -f "$MOCK_RELEASE_SERVER/${url##*/}" ]] || exit 22
cp "$MOCK_RELEASE_SERVER/${url##*/}" "$output"
SH
cat > "$BIN/security" <<'SH'
#!/bin/bash
printf 'security %s\n' "$*" >> "$MOCK_LOG"
[[ -z "${MOCK_IDENTITIES:-}" ]] || printf '%s\n' "$MOCK_IDENTITIES"
SH
cat > "$BIN/swift" <<'SH'
#!/bin/bash
printf 'swift %s\n' "$*" >> "$MOCK_LOG"
if [[ " $* " == *" --show-bin-path "* ]]; then
  printf '%s\n' "$PWD/.build/mock release"
else
  mkdir -p "$PWD/.build/mock release"
  printf '#!/bin/bash\nexit 0\n' > "$PWD/.build/mock release/SecondWind"
  chmod +x "$PWD/.build/mock release/SecondWind"
fi
SH
cat > "$BIN/arch" <<'SH'
#!/bin/bash
printf 'arch %s\n' "$*" >> "$MOCK_LOG"
[[ "${MOCK_NO_ROSETTA:-0}" != 1 ]] || exit 1
shift
exec "$@"
SH
# Real quarantine makes macOS kill the unsigned fixture executable, as it should.
cat > "$BIN/xattr" <<'SH'
#!/bin/bash
printf 'xattr %s\n' "$*" >> "$MOCK_LOG"
SH
# Only the public tag lookup is mocked; every other git command is real.
cat > "$BIN/git" <<'SH'
#!/bin/bash
if [[ "$1" != ls-remote ]]; then
  exec "$MOCK_REAL_GIT" "$@"
fi
printf 'git %s\n' "$*" >> "$MOCK_LOG"
[[ ",${MOCK_FAIL:-}," != *",ls-remote,"* ]] || exit 128
if [[ -n "${MOCK_TAG_OBJECT:-}" ]]; then
  printf '%s\t%s\n%s\t%s^{}\n' "$MOCK_TAG_OBJECT" "$4" "$MOCK_TAG_COMMIT" "$4"
elif [[ -n "${MOCK_TAG_COMMIT:-}" ]]; then
  printf '%s\t%s\n' "$MOCK_TAG_COMMIT" "$4"
fi
SH
cat > "$BIN/sleep" <<'SH'
#!/bin/bash
printf 'sleep %s\n' "$*" >> "$MOCK_LOG"
SH
chmod +x "$BIN/"*
export PATH="$BIN:$PATH"

fail() {
  printf 'Release tooling check failed: %s\n' "$1" >&2
  exit 1
}

reset_log() {
  : > "$MOCK_LOG"
}

check_cleanup() {
  local attaches detaches
  attaches="$(grep -c '^hdiutil attach' "$MOCK_LOG" || true)"
  detaches="$(grep -c '^hdiutil detach' "$MOCK_LOG" || true)"
  [[ "$attaches" == "$detaches" ]] || fail "$1: mounted image was not detached"
  [[ -z "$(ls -A "$TMPDIR")" ]] || fail "$1: temporary verification files were left behind"
}

expect_success() {
  local label="$1"
  shift
  if ! "$@" > "$OUT" 2> "$ERR"; then
    cat "$ERR" >&2
    fail "$label: expected success"
  fi
  check_cleanup "$label"
  printf 'PASS %s\n' "$label"
}

expect_failure() {
  local label="$1" diagnostic="$2"
  shift 2
  if "$@" > "$OUT" 2> "$ERR"; then
    fail "$label: expected a nonzero exit status"
  fi
  if ! grep -qF -- "$diagnostic" "$ERR"; then
    cat "$ERR" >&2
    fail "$label: missing diagnostic '$diagnostic'"
  fi
  check_cleanup "$label"
  printf 'PASS %s\n' "$label"
}

VERIFY="$ROOT/scripts/verify_release.sh"
RELEASE="$ROOT/scripts/release_dmg.sh"
PACKAGE_SOURCE="$ROOT/scripts/package_source.sh"
RELEASE_DIRECTORY="$ROOT/dist/release/$TAG"

reset_log
expect_failure 'source packaging rejects a malformed tag' 'Usage' "$PACKAGE_SOURCE" --tag 0.3.0
expect_failure 'source packaging needs the tag' 'does not exist' "$PACKAGE_SOURCE" --tag v0.3.1
fixture_git tag v0.4.0
expect_failure 'source packaging matches the tag to the app version' 'does not match' "$PACKAGE_SOURCE" --tag v0.4.0
printf 'untracked local change\n' > "$ROOT/local-only.txt"
expect_success 'source packaging archives the tagged commit' "$PACKAGE_SOURCE" --tag "$TAG"
test "$(cat "$OUT")" == "$RELEASE_DIRECTORY/$SOURCE_FILE" || fail "source packaging output is not one path: $(cat "$OUT")"
! unzip -Z1 "$RELEASE_DIRECTORY/$SOURCE_FILE" | grep -q local-only.txt || fail 'untracked file entered the archive'
expect_failure 'source packaging refuses to overwrite' 'already exists' "$PACKAGE_SOURCE" --tag "$TAG"

IMAGE_ROOT="$TEST_DIRECTORY/image"
make_image() {
  rm -rf "$IMAGE_ROOT"
  mkdir -p "$IMAGE_ROOT/Second Wind.app/Contents/MacOS"
  cp "$ROOT/Resources/Info.plist" "$IMAGE_ROOT/Second Wind.app/Contents/Info.plist"
  printf '#!/bin/bash\n[[ "${MOCK_SELF_TEST_FAIL:-0}" != 1 ]]\n' > "$IMAGE_ROOT/Second Wind.app/Contents/MacOS/SecondWind"
  chmod +x "$IMAGE_ROOT/Second Wind.app/Contents/MacOS/SecondWind"
  ln -s /Applications "$IMAGE_ROOT/Applications"
}

ASSETS="$TEST_DIRECTORY/assets"
stage_assets() {
  rm -rf "$ASSETS"
  mkdir -p "$ASSETS"
  cp "$RELEASE_DIRECTORY/$SOURCE_FILE" "$ASSETS/"
  printf 'MOCKDMG\n%s\n' "$IMAGE_ROOT" > "$ASSETS/$APP_FILE"
  (cd "$ASSETS" && shasum -a 256 "$SOURCE_FILE" "$APP_FILE") > "$ASSETS/SHA256SUMS"
}

make_image
stage_assets
reset_log
expect_success 'verifies source and notarized app' "$VERIFY" --tag "$TAG" --dir "$ASSETS" --team-id "$TEAM" --self-test
grep -qx "Verified Second Wind v0.3.0: source, notarized universal app from commit $MOCK_TAG_COMMIT" "$OUT" \
  || fail 'summary is wrong'
grep -qxF "git ls-remote --tags https://github.com/nicolasdmolina/codex-weekly-reset-guard.git refs/tags/$TAG refs/tags/$TAG^{}" "$MOCK_LOG" \
  || fail 'the public tag was not resolved'
for asset in "$SOURCE_FILE" "$APP_FILE"; do
  grep -qF "gh attestation verify $ASSETS/$asset --repo nicolasdmolina/codex-weekly-reset-guard --signer-workflow nicolasdmolina/codex-weekly-reset-guard/.github/workflows/release.yml --source-ref refs/tags/$TAG --source-digest $MOCK_TAG_COMMIT --deny-self-hosted-runners" "$MOCK_LOG" \
    || fail "provenance check for $asset is not strict"
done
grep -q '^hdiutil attach .* -readonly -nobrowse -noautoopen' "$MOCK_LOG" || fail 'image was not mounted read-only'
grep -q '^xattr -w com.apple.quarantine 0081;[0-9a-f]*;Safari; .*/installed/Second Wind.app$' "$MOCK_LOG" || fail 'copy was not quarantined'
grep -q '^spctl --assess --type execute -vv .*/installed/Second Wind.app$' "$MOCK_LOG" || fail 'quarantined copy was not assessed'
if [[ "$(uname -m)" == arm64 ]]; then
  grep -q '^arch -x86_64 .*SecondWind --self-test' "$MOCK_LOG" || fail 'x86_64 self-test did not run'
fi

expect_failure 'app requires an expected team' 'pass the expected Apple team' "$VERIFY" --tag "$TAG" --dir "$ASSETS"
expect_failure 'rejects a malformed team ID' 'ten capital letters' "$VERIFY" --tag "$TAG" --dir "$ASSETS" --team-id abc
expect_failure 'site manifest needs the published release' 'needs --published' \
  "$VERIFY" --tag "$TAG" --dir "$ASSETS" --team-id "$TEAM" --write-site-manifest
expect_failure 'site manifest needs provenance' 'needs --published' \
  "$VERIFY" --tag "$TAG" --published --team-id "$TEAM" --skip-provenance --write-site-manifest

run_case() {
  local label="$1" diagnostic="$2"
  shift 2
  reset_log
  expect_failure "$label" "$diagnostic" env "$@" "$VERIFY" --tag "$TAG" --dir "$ASSETS" --team-id "$TEAM" --self-test
}

run_case 'Gatekeeper disabled proves nothing' 'assessments are disabled' MOCK_SPCTL_STATUS='assessments disabled'
run_case 'invalid image signature' 'invalid code signature' MOCK_FAIL=verify-dmg
run_case 'image signed by another team' 'for team ABCDE12345' MOCK_SIGNED_TEAM=ZZZZZ99999
run_case 'image without stapled ticket' 'Second-Wind-0.3.0.dmg has no valid stapled' MOCK_FAIL=stapled-dmg
run_case 'Gatekeeper rejects the image' 'Gatekeeper rejects Second-Wind-0.3.0.dmg' MOCK_FAIL=gatekeeper-dmg
run_case 'accepted but not notarized' 'as notarized Developer ID' MOCK_SPCTL_SOURCE='Developer ID'
run_case 'image does not mount' 'could not be mounted' MOCK_FAIL=attach
run_case 'invalid app signature' 'Second Wind.app has an invalid code signature' MOCK_FAIL=verify-app
run_case 'no hardened runtime' 'hardened runtime' MOCK_CODESIGN_DETAILS=$'CodeDirectory v=20500 size=1 flags=0x0(none) hashes=1+7\nTimestamp=Nov 26, 2026'
run_case 'no secure timestamp' 'secure signing timestamp' MOCK_CODESIGN_DETAILS='CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+7'
run_case 'debugging entitlement' 'get-task-allow' \
  MOCK_ENTITLEMENTS='<plist><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>'
run_case 'app without stapled ticket' 'Second Wind.app has no valid stapled' MOCK_FAIL=stapled-app
run_case 'Gatekeeper rejects the app' 'Gatekeeper rejects Second Wind.app' MOCK_FAIL=gatekeeper-app
run_case 'Gatekeeper rejects a quarantined copy' 'Gatekeeper rejects a quarantined copy' MOCK_FAIL=gatekeeper-quarantined
run_case 'single-architecture app' 'is not universal' MOCK_ARCHS=arm64
run_case 'failing self-test' 'failed its self-test' MOCK_SELF_TEST_FAIL=1
run_case 'missing provenance' 'no GitHub build provenance' MOCK_FAIL=attestation
run_case 'tag missing from the public repository' 'is not a public tag' MOCK_TAG_COMMIT=
run_case 'public tag cannot be read' 'could not read tag' MOCK_FAIL=ls-remote
run_case 'source archived from another commit' 'was not archived from commit' MOCK_TAG_COMMIT="$OTHER_COMMIT"
reset_log
expect_success 'annotated tags resolve to their commit' env MOCK_TAG_OBJECT="$OTHER_COMMIT" \
  "$VERIFY" --tag "$TAG" --dir "$ASSETS" --team-id "$TEAM"
grep -qF -- "--source-digest $MOCK_TAG_COMMIT" "$MOCK_LOG" || fail 'annotated tag was not peeled to its commit'
reset_log
expect_success 'expected commit agrees with the public tag' \
  "$VERIFY" --tag "$TAG" --dir "$ASSETS" --team-id "$TEAM" --source-commit "$MOCK_TAG_COMMIT"
reset_log
expect_failure 'expected commit disagrees with the public tag' "points to $MOCK_TAG_COMMIT, not $OTHER_COMMIT" \
  "$VERIFY" --tag "$TAG" --dir "$ASSETS" --team-id "$TEAM" --source-commit "$OTHER_COMMIT"
expect_failure 'rejects a malformed source commit' '40 lowercase' \
  "$VERIFY" --tag "$TAG" --dir "$ASSETS" --team-id "$TEAM" --source-commit abc

reset_log
if [[ "$(uname -m)" == arm64 ]]; then
  expect_success 'Rosetta absence is reported, not hidden' env MOCK_NO_ROSETTA=1 \
    "$VERIFY" --tag "$TAG" --dir "$ASSETS" --team-id "$TEAM" --self-test
  grep -q 'SKIP  x86_64 self-test' "$ERR" || fail 'missing Rosetta skip notice'
fi
reset_log
expect_success 'skipped provenance is labelled' "$VERIFY" --tag "$TAG" --dir "$ASSETS" --team-id "$TEAM" --skip-provenance
grep -q 'provenance NOT checked' "$OUT" || fail 'summary hides skipped provenance'
grep -q 'SKIP  the source commit of' "$ERR" || fail 'unpinned source commit was not reported'
! grep -q '^gh \|^git ls-remote' "$MOCK_LOG" || fail 'skipped provenance still contacted GitHub'
reset_log
expect_failure 'skipped provenance still pins a given commit' 'was not archived from commit' \
  "$VERIFY" --tag "$TAG" --dir "$ASSETS" --team-id "$TEAM" --skip-provenance --source-commit "$OTHER_COMMIT"

mutate_image() {
  make_image
  "$@"
  stage_assets
  reset_log
}
mutate_image touch "$IMAGE_ROOT/extra.txt"
expect_failure 'unexpected file in the image' 'should hold only' "$VERIFY" --tag "$TAG" --dir "$ASSETS" --team-id "$TEAM"
mutate_image ln -sfn /tmp "$IMAGE_ROOT/Applications"
expect_failure 'Applications shortcut target' 'does not point to /Applications' "$VERIFY" --tag "$TAG" --dir "$ASSETS" --team-id "$TEAM"
mutate_image plutil -replace CFBundleShortVersionString -string 0.1.9 "$IMAGE_ROOT/Second Wind.app/Contents/Info.plist"
expect_failure 'app version differs from the tag' 'is not version 0.3.0' "$VERIFY" --tag "$TAG" --dir "$ASSETS" --team-id "$TEAM"
mutate_image plutil -insert GuardPreviewKind -string onboarding "$IMAGE_ROOT/Second Wind.app/Contents/Info.plist"
expect_failure 'QA marker in the app' 'QA-only marker' "$VERIFY" --tag "$TAG" --dir "$ASSETS" --team-id "$TEAM"
mutate_image plutil -replace CFBundleIdentifier -string com.example.other "$IMAGE_ROOT/Second Wind.app/Contents/Info.plist"
expect_failure 'wrong bundle identifier' 'wrong bundle identifier' "$VERIFY" --tag "$TAG" --dir "$ASSETS" --team-id "$TEAM"
make_image
stage_assets

sums_case() {
  local label="$1" diagnostic="$2" contents="$3"
  cp "$ASSETS/SHA256SUMS" "$TEST_DIRECTORY/SHA256SUMS.good"
  printf '%s\n' "$contents" > "$ASSETS/SHA256SUMS"
  reset_log
  expect_failure "$label" "$diagnostic" "$VERIFY" --tag "$TAG" --dir "$ASSETS" --team-id "$TEAM"
  mv "$TEST_DIRECTORY/SHA256SUMS.good" "$ASSETS/SHA256SUMS"
}
GOOD_SUMS="$(cat "$ASSETS/SHA256SUMS")"
SOURCE_LINE="$(grep -F "$SOURCE_FILE" <<<"$GOOD_SUMS")"
sums_case 'malformed checksum line' 'malformed line' "$GOOD_SUMS"$'\nnot a checksum'
sums_case 'unexpected listed file' 'not part of the v0.3.0 release' "$GOOD_SUMS"$'\n'"$(printf '%064d' 0)  Second-Wind-0.3.1.dmg"
sums_case 'duplicate listed file' 'twice' "$GOOD_SUMS"$'\n'"$SOURCE_LINE"
sums_case 'empty checksum list' 'lists no release files' ''
printf 'tampered\n' >> "$ASSETS/$APP_FILE"
reset_log
expect_failure 'tampered image' 'does not match its SHA-256' "$VERIFY" --tag "$TAG" --dir "$ASSETS" --team-id "$TEAM"
stage_assets
rm "$ASSETS/$SOURCE_FILE"
reset_log
expect_failure 'listed file missing' 'listed in SHA256SUMS but missing' "$VERIFY" --tag "$TAG" --dir "$ASSETS" --team-id "$TEAM"
stage_assets

ZIP_DIRECTORY="$TEST_DIRECTORY/zips"
source_case() {
  local label="$1" diagnostic="$2" variant="$3"
  rm -rf "$ZIP_DIRECTORY"
  mkdir -p "$ZIP_DIRECTORY"
  python3 -I - "$ZIP_DIRECTORY/$SOURCE_FILE" "$ROOT/Resources/Info.plist" "$variant" "$MOCK_TAG_COMMIT" <<'PY'
import pathlib, sys, zipfile
output, plist, variant, commit = sys.argv[1:5]
folder = "Second-Wind-0.3.0"
entries = {
    f"{folder}/Package.swift": (b"// synthetic\n", 0o100644),
    f"{folder}/LICENSE": (b"synthetic\n", 0o100644),
    f"{folder}/Resources/Info.plist": (pathlib.Path(plist).read_bytes(), 0o100644),
    f"{folder}/scripts/install_app.sh": (b"#!/bin/bash\n", 0o100755),
    f"{folder}/scripts/package_app.sh": (b"#!/bin/bash\n", 0o100755),
}
if variant == "outside":
    entries["elsewhere/file.txt"] = (b"x", 0o100644)
elif variant == "parent":
    entries[f"{folder}/../escape.txt"] = (b"x", 0o100644)
elif variant == "not-executable":
    entries[f"{folder}/scripts/install_app.sh"] = (b"#!/bin/bash\n", 0o100644)
elif variant == "missing":
    del entries[f"{folder}/scripts/install_app.sh"]
elif variant == "symlink":
    entries[f"{folder}/link"] = (b"/etc/passwd", 0o120777)
elif variant == "version":
    entries[f"{folder}/Resources/Info.plist"] = (
        pathlib.Path(plist).read_bytes().replace(b"0.3.0", b"0.1.9"), 0o100644)
with zipfile.ZipFile(output, "w") as archive:
    archive.comment = commit.encode()
    for name, (data, mode) in entries.items():
        info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
        info.create_system = 3
        info.external_attr = mode << 16
        archive.writestr(info, data)
PY
  (cd "$ZIP_DIRECTORY" && shasum -a 256 "$SOURCE_FILE") > "$ZIP_DIRECTORY/SHA256SUMS"
  reset_log
  if [[ -z "$diagnostic" ]]; then
    expect_success "$label" "$VERIFY" --tag "$TAG" --dir "$ZIP_DIRECTORY"
  else
    expect_failure "$label" "$diagnostic" "$VERIFY" --tag "$TAG" --dir "$ZIP_DIRECTORY"
  fi
}
source_case 'well-formed source archive' '' good
grep -qx "Verified Second Wind v0.3.0: source from commit $MOCK_TAG_COMMIT" "$OUT" || fail 'source-only summary is wrong'
source_case 'source entry outside its folder' 'outside Second-Wind-0.3.0/' outside
source_case 'source path escapes its folder' 'leaves its folder' parent
source_case 'install script not executable' 'scripts/install_app.sh executable' not-executable
source_case 'install script missing' 'missing scripts/install_app.sh' missing
source_case 'symbolic link in source' 'symbolic link' symlink
source_case 'source version differs from the tag' 'is not version 0.3.0' version

SERVER="$TEST_DIRECTORY/server"
export MOCK_RELEASE_SERVER="$SERVER"
serve() {
  rm -rf "$SERVER"
  mkdir -p "$SERVER"
  for asset in "$@"; do cp "$ASSETS/$asset" "$SERVER/"; done
  (cd "$SERVER" && shasum -a 256 "$@") > "$SERVER/SHA256SUMS"
  printf '%s\n' "$NULL_MANIFEST" > "$ROOT/site/src/release.json"
  reset_log
}
manifest_unchanged() {
  [[ "$(cat "$ROOT/site/src/release.json")" == "$NULL_MANIFEST" ]] || fail "$1: website manifest changed after a failure"
}
check_manifest() {
  python3 -I - "$ROOT/site/src/release.json" "$ASSETS" "$1" <<'PY'
import hashlib, json, pathlib, sys
manifest, assets, expect_app = sys.argv[1:4]
release = json.loads(pathlib.Path(manifest).read_text())["release"]
digest = lambda name: hashlib.sha256((pathlib.Path(assets) / name).read_bytes()).hexdigest()
assert set(release) == {"repository", "tag", "source", "app"}, release
assert release["repository"] == "nicolasdmolina/codex-weekly-reset-guard"
assert release["tag"] == "v0.3.0"
assert release["source"] == {
    "file": "Second-Wind-0.3.0-source.zip", "folder": "Second-Wind-0.3.0",
    "sha256": digest("Second-Wind-0.3.0-source.zip")}
if expect_app == "app":
    assert release["app"] == {
        "file": "Second-Wind-0.3.0.dmg", "sha256": digest("Second-Wind-0.3.0.dmg"),
        "architectures": ["arm64", "x86_64"], "minimumSystemVersion": "14.0",
        "teamId": "ABCDE12345"}, release["app"]
else:
    assert release["app"] is None
PY
}

serve "$SOURCE_FILE" "$APP_FILE"
expect_success 'published release writes the website manifest' \
  "$VERIFY" --tag "$TAG" --published --team-id "$TEAM" --write-site-manifest
check_manifest app || fail 'website manifest does not match the verified app release'
grep -qF "curl --fail --silent --show-error --location --proto =https --proto-redir =https --tlsv1.2 --retry 3 --output" "$MOCK_LOG" \
  || fail 'downloads are not HTTPS-only'
for asset in SHA256SUMS "$SOURCE_FILE" "$APP_FILE"; do
  grep -q "^curl .* $RELEASE_URL/$asset\$" "$MOCK_LOG" || fail "$asset was not fetched from the public release"
done
serve "$SOURCE_FILE"
expect_success 'source-only release writes a manifest without an app' \
  "$VERIFY" --tag "$TAG" --published --write-site-manifest
check_manifest source || fail 'website manifest does not match the verified source release'
serve "$APP_FILE"
expect_failure 'website needs the source archive' 'needs Second-Wind-0.3.0-source.zip' \
  "$VERIFY" --tag "$TAG" --published --team-id "$TEAM" --write-site-manifest
manifest_unchanged 'app-only release'
serve "$SOURCE_FILE" "$APP_FILE"
rm "$SERVER/$APP_FILE"
expect_failure 'unpublished asset' 'could not download Second-Wind-0.3.0.dmg' \
  "$VERIFY" --tag "$TAG" --published --team-id "$TEAM" --write-site-manifest
manifest_unchanged 'unpublished asset'
serve "$SOURCE_FILE" "$APP_FILE"
expect_failure 'late provenance failure' 'no GitHub build provenance' env MOCK_FAIL=attestation \
  "$VERIFY" --tag "$TAG" --published --team-id "$TEAM" --write-site-manifest
manifest_unchanged 'late provenance failure'
rm -rf "$SERVER"
mkdir -p "$SERVER"
reset_log
expect_failure 'unpublished release' 'could not download SHA256SUMS' "$VERIFY" --tag "$TAG" --published
manifest_unchanged 'unpublished release'

export SECOND_WIND_TEAM_ID="$TEAM"
export SECOND_WIND_NOTARY_KEY_PATH="$TEST_DIRECTORY/synthetic-notary.p8"
export SECOND_WIND_NOTARY_KEY_ID=SYNTHETICKEYID
export SECOND_WIND_NOTARY_ISSUER=SYNTHETIC-ISSUER-SENTINEL
printf 'SYNTHETIC KEY SENTINEL\n' > "$SECOND_WIND_NOTARY_KEY_PATH"
ONE_IDENTITY="  1) $IDENTITY_HASH \"Developer ID Application: Synthetic Maintainer ($TEAM)\""
export MOCK_IDENTITIES="$ONE_IDENTITY"

release_case() {
  local label="$1" diagnostic="$2"
  shift 2
  reset_log
  expect_failure "$label" "$diagnostic" env "$@" "$RELEASE" --tag "$TAG"
  [[ ! -e "$RELEASE_DIRECTORY/$APP_FILE" ]] || fail "$label: left a disk image behind"
  [[ -z "$(find "$ROOT/dist/release" -name '.stage.*')" ]] || fail "$label: left a staging directory behind"
}

reset_log
expect_failure 'release needs a tag' 'Usage' "$RELEASE"
expect_failure 'release tag must match the app version' 'does not match' "$RELEASE" --tag v0.4.0
release_case 'release needs a team ID' 'SECOND_WIND_TEAM_ID' SECOND_WIND_TEAM_ID=
release_case 'release needs notarization credentials' 'Configure notarization' SECOND_WIND_NOTARY_KEY_PATH=
release_case 'release rejects two notarization configurations' 'not both' SECOND_WIND_NOTARY_PROFILE=synthetic-profile
release_case 'release needs a Developer ID identity' 'found 0' MOCK_IDENTITIES=
release_case 'release ignores other teams' 'found 0' \
  MOCK_IDENTITIES="  1) $IDENTITY_HASH \"Developer ID Application: Someone Else (ZZZZZ99999)\""
release_case 'release ignores non-Developer ID identities' 'found 0' \
  MOCK_IDENTITIES="  1) $IDENTITY_HASH \"Apple Development: Synthetic Maintainer ($TEAM)\""
release_case 'release refuses ambiguous identities' 'found 2' \
  MOCK_IDENTITIES="$ONE_IDENTITY"$'\n'"  2) FEDCBA9876543210FEDCBA9876543210FEDCBA98 \"Developer ID Application: Synthetic Maintainer ($TEAM)\""
! grep -q '^swift ' "$MOCK_LOG" || fail 'release built before its signing inputs were checked'
release_case 'release must be universal' 'not universal' MOCK_ARCHS=arm64
release_case 'release signature must be Developer ID for the team' 'not signed with Developer ID' MOCK_SIGNED_TEAM=ZZZZZ99999
release_case 'app notarization must be accepted' 'did not accept the app' MOCK_NOTARY_STATUS=Invalid
grep -q '^xcrun notarytool log 2f1c3a4b-0000-4000-8000-000000000001' "$MOCK_LOG" || fail 'rejected notarization log was not fetched'
release_case 'image notarization must be accepted' 'did not accept the disk image' MOCK_FAIL=notary-dmg
release_case 'stapling failures stop the release' 'Could not staple' MOCK_FAIL=staple
test "$(grep -c '^xcrun stapler staple' "$MOCK_LOG")" -eq 4 || fail 'stapling was not retried a bounded number of times'
release_case 'image creation failures stop the release' 'Could not create the disk image' MOCK_FAIL=hdiutil-create
release_case 'final verification gates the release' 'Gatekeeper rejects' MOCK_FAIL=gatekeeper-app

reset_log
expect_success 'release builds a signed, notarized, stapled image' "$RELEASE" --tag "$TAG"
test "$(cat "$OUT")" == "$RELEASE_DIRECTORY/$APP_FILE" || fail 'release output is not one path'
grep -qx 'Verified Second Wind v0.3.0: notarized universal app (provenance NOT checked)' "$ERR" \
  || fail 'release self-check summary is wrong'
(cd "$RELEASE_DIRECTORY" && shasum -a 256 -c SHA256SUMS >/dev/null) || fail 'SHA256SUMS does not match the release files'
test "$(grep -c . "$RELEASE_DIRECTORY/SHA256SUMS")" -eq 2 || fail 'SHA256SUMS lost the source archive'
grep -q "^codesign --force --options runtime --timestamp --sign $IDENTITY_HASH .*Second Wind.app\$" "$MOCK_LOG" \
  || fail 'app was not signed with hardened runtime and a timestamp'
grep -q "^codesign --force --timestamp --sign $IDENTITY_HASH .*$APP_FILE\$" "$MOCK_LOG" || fail 'image was not signed'
grep -q '^swift build -c release --arch arm64 --arch x86_64 -Xswiftc -warnings-as-errors$' "$MOCK_LOG" \
  || fail 'release was not built universal with warnings as errors'
ORDER="$(grep -E '^(codesign --force|xcrun notarytool submit|xcrun stapler staple|hdiutil create|spctl --status)' "$MOCK_LOG" \
  | sed -E 's/^(codesign --force --options).*/sign app/; s/^(codesign --force --timestamp).*/sign image/; s/^xcrun notarytool submit .*\.zip.*/notarize app/; s/^xcrun notarytool submit .*\.dmg.*/notarize image/; s/^xcrun stapler staple .*\.app$/staple app/; s/^xcrun stapler staple .*\.dmg$/staple image/; s/^hdiutil create.*/create image/; s/^spctl --status.*/verify/' \
  | tr '\n' ',')"
test "$ORDER" == 'sign app,notarize app,staple app,create image,sign image,notarize image,staple image,verify,' \
  || fail "release steps ran out of order: $ORDER"
for sentinel in SYNTHETIC-ISSUER-SENTINEL SYNTHETICKEYID 'SYNTHETIC KEY SENTINEL'; do
  ! grep -qF "$sentinel" "$OUT" "$ERR" || fail 'notarization credentials were printed'
done
expect_failure 'release refuses to overwrite' 'already exists' "$RELEASE" --tag "$TAG"

reset_log
expect_failure 'package keychain needs an identity' 'Usage' "$ROOT/scripts/package_app.sh" --keychain "$TEST_DIRECTORY/k"
expect_success 'local packaging stays ad-hoc' "$ROOT/scripts/package_app.sh"
grep -q '^codesign --force --sign - --timestamp=none ' "$MOCK_LOG" || fail 'default packaging is no longer ad-hoc'
grep -q '^swift build -c release -Xswiftc -warnings-as-errors$' "$MOCK_LOG" || fail 'default packaging is no longer host-only'

printf 'Offline release packaging and verification checks passed.\n'
