#!/bin/bash
set -euo pipefail

# Build a tiny real universal app. Only the public tag lookup, downloads and
# GitHub attestations are simulated; macOS checks the actual ZIP and signatures.
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/second-wind-release-test.XXXXXX")" && pwd)"
trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/source checkout"
TAG=v0.3.1
VERSION=0.3.1
APP="Second-Wind-$VERSION-mac.zip"
SOURCE="Second-Wind-$VERSION-source.zip"
VERIFY="$ROOT/scripts/verify_release.sh"
OUT="$WORK/out"
ERR="$WORK/err"
mkdir -p "$ROOT/scripts" "$ROOT/Resources" "$ROOT/Sources/SecondWind" "$ROOT/site/src" "$WORK/bin"
cp "$PROJECT_ROOT"/scripts/{package_app.sh,package_release.sh,package_source.sh,verify_release.sh,check_app_zip.py,install_app.sh} "$ROOT/scripts/"
cp "$PROJECT_ROOT"/Resources/{Info.plist,AppIcon.icns} "$ROOT/Resources/"
cp "$PROJECT_ROOT/LICENSE" "$ROOT/"
printf '{"release":null}\n' > "$ROOT/site/src/release.json"

cat > "$ROOT/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SecondWind", platforms: [.macOS(.v14)], targets: [.executableTarget(name: "SecondWind")])
SWIFT
cat > "$ROOT/Sources/SecondWind/main.swift" <<'SWIFT'
import Foundation
guard Array(CommandLine.arguments.dropFirst()) == ["--self-test"] else { exit(70) }
print("Fixture app self-test passed.")
SWIFT

fixture_git() {
  git -C "$ROOT" -c core.hooksPath=/dev/null -c commit.gpgsign=false -c tag.gpgsign=false \
    -c user.name='Release Test' -c user.email='release@example.invalid' "$@" >/dev/null
}
fixture_git init --template=
plutil -replace CFBundleShortVersionString -string 0.3.0 "$ROOT/Resources/Info.plist"
fixture_git add .
fixture_git commit -m 'Previous source-only release'
fixture_git tag v0.3.0
plutil -replace CFBundleShortVersionString -string "$VERSION" "$ROOT/Resources/Info.plist"
fixture_git add Resources/Info.plist
fixture_git commit -m 'Universal app release'
fixture_git tag "$TAG"
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
LEGACY_COMMIT="$(git -C "$ROOT" rev-parse v0.3.0)"
# A build of the working tree would now fail. Both archives must use the tag.
printf 'intentionally invalid Swift\n' > "$ROOT/Sources/SecondWind/main.swift"

ok() {
  local label="$1"; shift
  if ! "$@" > "$OUT" 2> "$ERR"; then cat "$ERR" >&2; exit 1; fi
  printf 'PASS %s\n' "$label"
}
reject() {
  local label="$1" reason="$2"; shift 2
  if "$@" > "$OUT" 2> "$ERR"; then printf 'Unexpected success: %s\n' "$label" >&2; exit 1; fi
  if ! grep -qF -- "$reason" "$ERR"; then cat "$ERR" >&2; exit 1; fi
  printf 'PASS %s\n' "$label"
}

reject 'a release tag is required' 'Usage' "$ROOT/scripts/package_release.sh"
reject 'an unknown tag is refused' 'does not exist' "$ROOT/scripts/package_release.sh" --tag v7.9.9
fixture_git tag v7.9.8
reject 'the tag and app version must agree' 'does not match' "$ROOT/scripts/package_release.sh" --tag v7.9.8
ok 'the tagged source builds a universal app ZIP and synthetic self-test' "$ROOT/scripts/package_release.sh" --tag "$TAG"
ASSETS="$(cat "$OUT")"
test "$ASSETS" = "$ROOT/dist/release/$TAG"
test "$(cd "$ASSETS" && ls -A | sort)" = "$(printf '%s\n' SHA256SUMS "$APP" "$SOURCE" | sort)"
grep -qF 'Fixture app self-test passed.' "$ERR"
(cd "$ASSETS" && shasum -a 256 -c SHA256SUMS)
reject 'existing release files stay intact' 'already exists' "$ROOT/scripts/package_release.sh" --tag "$TAG"

ok 'the previous source ZIP can still be created' "$ROOT/scripts/package_source.sh" --tag v0.3.0
ok 'v0.3.0 can still be verified without an app' "$VERIFY" --tag v0.3.0 --dir "$ROOT/dist/release/v0.3.0" \
  --skip-provenance --source-commit "$LEGACY_COMMIT"
grep -qF "Verified Second Wind v0.3.0: source from commit $LEGACY_COMMIT" "$OUT"

export RELEASE_TEST_REAL_GIT="$(command -v git)"
export RELEASE_TEST_COMMIT="$COMMIT"
export RELEASE_TEST_SERVER="$WORK/server"
export RELEASE_TEST_LOG="$WORK/network.log"
cat > "$WORK/bin/git" <<'SH'
#!/bin/bash
if [[ "$1" == ls-remote ]]; then
  if [[ -n "${RELEASE_TEST_TAG_OBJECT:-}" ]]; then
    printf '%s\t%s\n' "$RELEASE_TEST_TAG_OBJECT" "$4" "$RELEASE_TEST_COMMIT" "$5"
  else
    printf '%s\t%s\n' "$RELEASE_TEST_COMMIT" "$4"
  fi
else
  exec "$RELEASE_TEST_REAL_GIT" "$@"
fi
SH
cat > "$WORK/bin/curl" <<'SH'
#!/bin/bash
set -eu
url="${!#}"
while [[ "$1" != --output ]]; do shift; done
cp "$RELEASE_TEST_SERVER/${url##*/}" "$2"
SH
cat > "$WORK/bin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$RELEASE_TEST_LOG"
[[ "$1 $2" == 'attestation verify' && -f "$3" ]] || exit 1
case "$3" in *-mac.zip) [[ "${RELEASE_TEST_REJECT_APP:-0}" != 1 ]] ;; *) exit 0 ;; esac
SH
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"
mkdir "$RELEASE_TEST_SERVER"
cp "$ASSETS/"* "$RELEASE_TEST_SERVER/"
MANIFEST="$ROOT/site/src/release.json"

ok 'verified public files produce the free app download' "$VERIFY" --tag "$TAG" --published \
  --source-commit "$COMMIT" --self-test --write-site-manifest
python3 -I - "$MANIFEST" "$ASSETS" "$TAG" <<'PY'
from hashlib import sha256
import json
from pathlib import Path
import sys
manifest, directory, tag = sys.argv[1:]
release = json.loads(Path(manifest).read_text())["release"]
assert release["tag"] == tag
version = tag.removeprefix("v")
source = f"Second-Wind-{version}-source.zip"
app = f"Second-Wind-{version}-mac.zip"
def digest(name):
    return sha256((Path(directory) / name).read_bytes()).hexdigest()
assert release["app"] == {"file": app, "sha256": digest(app), "minimumSystemVersion": "14.0",
                          "architectures": ["arm64", "x86_64"], "signing": "ad-hoc"}
assert release["source"] == {"file": source, "folder": f"Second-Wind-{version}", "sha256": digest(source)}
PY
repo=nicolasdmolina/second-wind
for file in "$SOURCE" "$APP"; do
  grep -qF "$file --repo $repo --signer-workflow $repo/.github/workflows/release.yml --source-ref refs/tags/$TAG --source-digest $COMMIT --deny-self-hosted-runners" "$RELEASE_TEST_LOG"
done
cp "$MANIFEST" "$WORK/known-manifest"
reject 'no website updates from a local build' 'needs --published' "$VERIFY" --tag "$TAG" --dir "$ASSETS" \
  --write-site-manifest --skip-provenance
reject 'the public tag pins the exact commit' "tag points to $COMMIT" "$VERIFY" --tag "$TAG" --published --source-commit "$LEGACY_COMMIT"
ok 'an annotated public tag pins the peeled commit' env RELEASE_TEST_TAG_OBJECT="$LEGACY_COMMIT" \
  "$VERIFY" --tag "$TAG" --dir "$ASSETS" --source-commit "$COMMIT"
reject 'the source ZIP must come from the tagged commit' 'was not archived from commit' "$VERIFY" --tag "$TAG" \
  --dir "$ASSETS" --source-commit "$LEGACY_COMMIT" --skip-provenance
reject 'a missing attestation blocks execution and the manifest' 'no GitHub build provenance' \
  env RELEASE_TEST_REJECT_APP=1 "$VERIFY" --tag "$TAG" --published --self-test --write-site-manifest
if grep -qF 'Fixture app self-test passed.' "$ERR"; then exit 1; fi
printf 'changed' >> "$RELEASE_TEST_SERVER/$APP"
reject 'a changed public app is refused' 'does not match its SHA-256' "$VERIFY" --tag "$TAG" --published --write-site-manifest
grep -F "$SOURCE" "$ASSETS/SHA256SUMS" > "$RELEASE_TEST_SERVER/SHA256SUMS"
reject 'a new release requires its app ZIP' "the release needs $APP" "$VERIFY" --tag "$TAG" --published --write-site-manifest
grep -F "$APP" "$ASSETS/SHA256SUMS" > "$RELEASE_TEST_SERVER/SHA256SUMS"
reject 'a new release also requires its source' "the release needs $SOURCE" "$VERIFY" --tag "$TAG" --published --write-site-manifest
cat "$ASSETS/SHA256SUMS" "$ASSETS/SHA256SUMS" > "$RELEASE_TEST_SERVER/SHA256SUMS"
reject 'ambiguous checksum lists are refused' 'twice' "$VERIFY" --tag "$TAG" --published --write-site-manifest
printf 'broken\n' > "$RELEASE_TEST_SERVER/SHA256SUMS"
reject 'malformed checksum lists are refused' 'malformed line' "$VERIFY" --tag "$TAG" --published --write-site-manifest
cmp "$MANIFEST" "$WORK/known-manifest"

ZIP_DIRECTORY="$WORK/source-variants"
HISTORIC_SOURCE=Second-Wind-0.3.0-source.zip
source_case() {
  local label="$1" diagnostic="$2" variant="$3"
  rm -rf "$ZIP_DIRECTORY"
  mkdir -p "$ZIP_DIRECTORY"
  python3 -I - "$ZIP_DIRECTORY/$HISTORIC_SOURCE" "$WORK/legacy.plist" "$variant" "$LEGACY_COMMIT" <<'PY'
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
  (cd "$ZIP_DIRECTORY" && shasum -a 256 "$HISTORIC_SOURCE") > "$ZIP_DIRECTORY/SHA256SUMS"
  reject "$label" "$diagnostic" "$VERIFY" --tag v0.3.0 --dir "$ZIP_DIRECTORY" \
    --skip-provenance --source-commit "$LEGACY_COMMIT"
}
git -C "$ROOT" show v0.3.0:Resources/Info.plist > "$WORK/legacy.plist"
source_case 'source entry outside its folder' 'outside Second-Wind-0.3.0/' outside
source_case 'source path escapes its folder' 'leaves its folder' parent
source_case 'install script not executable' 'scripts/install_app.sh executable' not-executable
source_case 'install script missing' 'missing scripts/install_app.sh' missing
source_case 'symbolic link in source' 'symbolic link' symlink
source_case 'source version differs from the tag' 'is not version 0.3.0' version

# Exercise signed bundle checks with real Apple tools after recomputing the ZIP checksum.
MUTATIONS="$WORK/mutations"
mkdir -p "$MUTATIONS/unpacked"
cp "$ASSETS/$SOURCE" "$MUTATIONS/"
unpack() {
  rm -rf "$MUTATIONS/unpacked/Second Wind.app"
  ditto -x -k "$ASSETS/$APP" "$MUTATIONS/unpacked"
}
repack() {
  rm -f "$MUTATIONS/$APP"
  (cd "$MUTATIONS/unpacked" && zip -qr "$MUTATIONS/$APP" 'Second Wind.app')
  (cd "$MUTATIONS" && shasum -a 256 "$SOURCE" "$APP" > SHA256SUMS)
}
check_mutation() {
  repack
  reject "$1" "$2" "$VERIFY" --tag "$TAG" --dir "$MUTATIONS" --skip-provenance --source-commit "$COMMIT"
}
app="$MUTATIONS/unpacked/Second Wind.app"
unpack
printf 'changed\n' >> "$app/Contents/Resources/LICENSE"
check_mutation 'modified signed resources are refused' 'invalid app code signature'
unpack
lipo -thin arm64 "$app/Contents/MacOS/SecondWind" -output "$WORK/thin"
cp "$WORK/thin" "$app/Contents/MacOS/SecondWind"
check_mutation 'single-architecture apps are refused' 'expected a universal Mac app'
unpack
plutil -replace CFBundleShortVersionString -string 0.2.9 "$app/Contents/Info.plist"
check_mutation 'a mismatched app version is refused' "is not version $VERSION"
unpack
plutil -insert GuardPreviewKind -string onboarding "$app/Contents/Info.plist"
check_mutation 'a preview app is refused' 'QA-only marker'
unpack
codesign --force --options 0 --sign - --timestamp=none "$app" >/dev/null 2>&1
check_mutation 'a build without hardened runtime is refused' 'missing hardened runtime'
unpack
chmod -x "$app/Contents/MacOS/SecondWind"
check_mutation 'a non-executable Mac download is refused' 'execute permission'

python3 -I - "$ROOT/scripts/check_app_zip.py" "$ASSETS/$APP" "$WORK" <<'PY'
import importlib.util
import pathlib
import stat
import sys
import warnings
import zipfile
module_path, good, work = sys.argv[1:]
spec = importlib.util.spec_from_file_location("layout", module_path)
layout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(layout)
cases = [
    ("extra top-level file", "readme.txt", stat.S_IFREG),
    ("parent path", "Second Wind.app/../outside", stat.S_IFREG),
    ("linked executable", layout.EXECUTABLE, stat.S_IFLNK),
    ("missing executable", layout.EXECUTABLE, None),
    ("duplicate entry", layout.EXECUTABLE, "duplicate"),
]
for label, name, mode in cases:
    destination = pathlib.Path(work) / "malformed.zip"
    with zipfile.ZipFile(good) as source, zipfile.ZipFile(destination, "w") as changed:
        for entry in source.infolist():
            if entry.filename == name and mode != "duplicate":
                continue
            changed.writestr(entry, source.read(entry))
        if mode is not None:
            info = zipfile.ZipInfo(name)
            info.external_attr = ((stat.S_IFREG if mode == "duplicate" else mode) | 0o755) << 16
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                changed.writestr(info, b"synthetic")
    with zipfile.ZipFile(destination) as archive:
        try:
            layout.check(archive)
        except ValueError:
            print(f"PASS {label} is refused")
        else:
            raise SystemExit(f"verification accepted {label}")
PY

printf 'Release checks passed for the free Mac app and the previous source release.\n'
