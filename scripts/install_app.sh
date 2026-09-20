#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Codex Weekly Reset Guard"
SOURCE_APP="$PROJECT_ROOT/dist/$APP_NAME.app"
INSTALL_DIRECTORY="$HOME/Applications"
SHOULD_LAUNCH=false

usage() {
  printf 'Usage: %s [--launch] [--destination /absolute/directory]\n' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --launch) SHOULD_LAUNCH=true; shift ;;
    --destination)
      if [[ $# -lt 2 || "$2" != /* ]]; then
        usage >&2
        exit 2
      fi
      INSTALL_DIRECTORY="$2"
      shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

INSTALLED_APP="$INSTALL_DIRECTORY/$APP_NAME.app"
if [[ -L "$INSTALLED_APP" || ( -e "$INSTALLED_APP" && ! -d "$INSTALLED_APP" ) ]]; then
  printf 'Refusing to replace a symlink or non-directory: %s\n' "$INSTALLED_APP" >&2
  exit 1
fi

require_stopped_app() {
  if pgrep -f '[/]Codex Weekly Reset Guard[.]app/Contents/MacOS/CodexWeeklyResetGuard([[:space:]]|$)' >/dev/null; then
    printf 'Quit Codex Weekly Reset Guard before installing or updating it.\n' >&2
    exit 1
  fi
}

require_stopped_app
"$PROJECT_ROOT/scripts/package_app.sh" >/dev/null
mkdir -p "$INSTALL_DIRECTORY"
STAGING_DIRECTORY="$(mktemp -d "$INSTALL_DIRECTORY/.weekly-reset-guard-install.XXXXXX")"
trap 'rm -rf "$STAGING_DIRECTORY"' EXIT
STAGED_APP="$STAGING_DIRECTORY/$APP_NAME.app"
ditto "$SOURCE_APP" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP" >&2

# Keep the previous installation intact until the replacement has been verified.
# Backups are retained so updates can be rolled back without rebuilding.
require_stopped_app
PREVIOUS_APP=""
if [[ -e "$INSTALLED_APP" ]]; then
  mkdir -p "$INSTALL_DIRECTORY/.codex-weekly-reset-guard-backups"
  BACKUP_DIRECTORY="$(mktemp -d "$INSTALL_DIRECTORY/.codex-weekly-reset-guard-backups/install.XXXXXX")"
  PREVIOUS_APP="$BACKUP_DIRECTORY/$APP_NAME.app"
  mv "$INSTALLED_APP" "$PREVIOUS_APP"
fi
if ! mv "$STAGED_APP" "$INSTALLED_APP"; then
  if [[ -n "$PREVIOUS_APP" ]]; then
    mv "$PREVIOUS_APP" "$INSTALLED_APP"
  fi
  exit 1
fi

if [[ -n "$PREVIOUS_APP" ]]; then
  printf 'Previous installation retained at: %s\n' "$PREVIOUS_APP" >&2
fi
if [[ "$SHOULD_LAUNCH" == true ]]; then
  open "$INSTALLED_APP"
fi

printf '%s\n' "$INSTALLED_APP"
