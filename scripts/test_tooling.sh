#!/bin/bash
set -euo pipefail

# Exercise replacement and failure behavior in temporary directories. Swift,
# signing, process checks, and app launching are mocked; no real app is started.
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/reset-guard-tooling.XXXXXX")"
trap 'rm -rf "$TEST_DIRECTORY"' EXIT
FIXTURE_ROOT="$TEST_DIRECTORY/source checkout"
INSTALL_DIRECTORY="$TEST_DIRECTORY/custom Applications"
APP_NAME="Codex Weekly Reset Guard.app"
mkdir -p "$FIXTURE_ROOT/scripts" "$FIXTURE_ROOT/Resources" "$TEST_DIRECTORY/bin"
cp "$PROJECT_ROOT/scripts/package_app.sh" "$PROJECT_ROOT/scripts/install_app.sh" "$FIXTURE_ROOT/scripts/"
cp "$PROJECT_ROOT/Resources/Info.plist" "$FIXTURE_ROOT/Resources/"
cp "$PROJECT_ROOT/LICENSE" "$FIXTURE_ROOT/LICENSE"

export GUARD_TOOLING_TEST_LOG="$TEST_DIRECTORY/commands.log"
cat > "$TEST_DIRECTORY/bin/swift" <<'SH'
#!/bin/bash
set -euo pipefail
printf 'swift\n' >> "$GUARD_TOOLING_TEST_LOG"
if [[ "${GUARD_TOOLING_TEST_BUILD_FAIL:-0}" == 1 ]]; then
  printf 'Expected mock build failure\n' >&2
  exit 73
fi
if [[ " $* " == *" --show-bin-path "* ]]; then
  printf '%s\n' "$PWD/.build/mock release"
else
  mkdir -p "$PWD/.build/mock release"
  printf '#!/bin/bash\nexit 0\n' > "$PWD/.build/mock release/CodexWeeklyResetGuard"
  chmod +x "$PWD/.build/mock release/CodexWeeklyResetGuard"
fi
SH
cat > "$TEST_DIRECTORY/bin/codesign" <<'SH'
#!/bin/bash
set -euo pipefail
printf 'codesign\n' >> "$GUARD_TOOLING_TEST_LOG"
[[ "${GUARD_TOOLING_TEST_SIGN_FAIL:-0}" != 1 ]]
SH
cat > "$TEST_DIRECTORY/bin/pgrep" <<'SH'
#!/bin/bash
[[ "${GUARD_TOOLING_TEST_RUNNING:-0}" == 1 ]]
SH
cat > "$TEST_DIRECTORY/bin/open" <<'SH'
#!/bin/bash
printf 'open\n' >> "$GUARD_TOOLING_TEST_LOG"
SH
chmod +x "$TEST_DIRECTORY/bin/"*
export PATH="$TEST_DIRECTORY/bin:$PATH"

fail() {
  printf 'Tooling check failed: %s\n' "$1" >&2
  exit 1
}

expect_failure() {
  if "$@" > "$TEST_DIRECTORY/stdout" 2> "$TEST_DIRECTORY/stderr"; then
    fail 'expected a nonzero exit status'
  fi
}

mkdir -p "$INSTALL_DIRECTORY/$APP_NAME" "$FIXTURE_ROOT/dist/$APP_NAME"
printf 'previous installation\n' > "$INSTALL_DIRECTORY/$APP_NAME/preserved.marker"
printf 'previous build\n' > "$FIXTURE_ROOT/dist/$APP_NAME/preserved.marker"

expect_failure "$FIXTURE_ROOT/scripts/install_app.sh" --unknown
test ! -e "$GUARD_TOOLING_TEST_LOG" || fail 'unknown options invoked tools'
expect_failure "$FIXTURE_ROOT/scripts/install_app.sh" --destination relative/path
test ! -e "$GUARD_TOOLING_TEST_LOG" || fail 'relative destinations invoked tools'

export GUARD_TOOLING_TEST_RUNNING=1
expect_failure "$FIXTURE_ROOT/scripts/install_app.sh" --destination "$INSTALL_DIRECTORY"
test ! -e "$GUARD_TOOLING_TEST_LOG" || fail 'running app did not prevent build/install'
test -f "$INSTALL_DIRECTORY/$APP_NAME/preserved.marker" || fail 'running app was replaced'
unset GUARD_TOOLING_TEST_RUNNING

export GUARD_TOOLING_TEST_BUILD_FAIL=1
expect_failure "$FIXTURE_ROOT/scripts/install_app.sh" --destination "$INSTALL_DIRECTORY"
test -s "$TEST_DIRECTORY/stderr" || fail 'build failure lost its diagnostic'
test -f "$INSTALL_DIRECTORY/$APP_NAME/preserved.marker" || fail 'build failure replaced install'
test -f "$FIXTURE_ROOT/dist/$APP_NAME/preserved.marker" || fail 'build failure replaced package'
unset GUARD_TOOLING_TEST_BUILD_FAIL

export GUARD_TOOLING_TEST_SIGN_FAIL=1
expect_failure "$FIXTURE_ROOT/scripts/install_app.sh" --destination "$INSTALL_DIRECTORY"
test -f "$INSTALL_DIRECTORY/$APP_NAME/preserved.marker" || fail 'signing failure replaced install'
test -f "$FIXTURE_ROOT/dist/$APP_NAME/preserved.marker" || fail 'signing failure replaced package'
unset GUARD_TOOLING_TEST_SIGN_FAIL

for QA_KEY in GuardPreviewKind GuardDiagnosticSupportDirectory; do
  plutil -insert "$QA_KEY" -string onboarding "$FIXTURE_ROOT/Resources/Info.plist"
  expect_failure "$FIXTURE_ROOT/scripts/package_app.sh"
  test -f "$FIXTURE_ROOT/dist/$APP_NAME/preserved.marker" || fail 'QA marker replaced release package'
  plutil -remove "$QA_KEY" "$FIXTURE_ROOT/Resources/Info.plist"
done

"$FIXTURE_ROOT/scripts/install_app.sh" --destination "$INSTALL_DIRECTORY" > "$TEST_DIRECTORY/stdout" 2> "$TEST_DIRECTORY/stderr"
test -x "$INSTALL_DIRECTORY/$APP_NAME/Contents/MacOS/CodexWeeklyResetGuard" || fail 'new app missing'
cmp -s "$PROJECT_ROOT/LICENSE" "$INSTALL_DIRECTORY/$APP_NAME/Contents/Resources/LICENSE" || fail 'license missing from bundle'
test ! -f "$INSTALL_DIRECTORY/$APP_NAME/preserved.marker" || fail 'new install merged with old app'
test "$(cat "$TEST_DIRECTORY/stdout")" == "$INSTALL_DIRECTORY/$APP_NAME" || fail 'installer output is not one path'
INSTALL_BACKUPS=("$INSTALL_DIRECTORY/.codex-weekly-reset-guard-backups/"install.*/"$APP_NAME/preserved.marker")
test "${#INSTALL_BACKUPS[@]}" -eq 1 && test -f "${INSTALL_BACKUPS[0]}" || fail 'previous installation not preserved'
BUILD_BACKUPS=("$FIXTURE_ROOT/dist/previous-builds/"build.*/"$APP_NAME/preserved.marker")
test "${#BUILD_BACKUPS[@]}" -eq 1 && test -f "${BUILD_BACKUPS[0]}" || fail 'previous package not preserved'
while IFS= read -r command_name; do
  [[ "$command_name" != open ]] || fail 'default install launched the app'
done < "$GUARD_TOOLING_TEST_LOG"

"$FIXTURE_ROOT/scripts/install_app.sh" --launch --destination "$INSTALL_DIRECTORY" > "$TEST_DIRECTORY/stdout" 2> "$TEST_DIRECTORY/stderr"
test "$(tail -n 1 "$GUARD_TOOLING_TEST_LOG")" == open || fail '--launch did not request open'
printf 'Offline packaging/installation checks passed.\n'
