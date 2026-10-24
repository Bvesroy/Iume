#!/bin/bash
# Creates a versioned end-of-day backup of Iume.
#
# Backup versions start at 1.0 and increase by 0.1 on every daily run.
# The version is a backup label only; it does not change the app version or CHANGELOG.
#
# Usage:
#   scripts/daily-backup.sh            Create today's backup (skips if already done)
#   scripts/daily-backup.sh --force    Create another backup even if today's exists
#   scripts/daily-backup.sh --dry-run  Show the next version and exit without writing
set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"

PROJECT_ROOT="${IUME_BACKUP_PROJECT_ROOT:-/Users/bves/projects/Iume}"
BACKUP_ROOT="${IUME_BACKUP_ROOT:-/Users/bves/projects/Iume-backups}"
STATE_FILE="$BACKUP_ROOT/version.json"
LOCK_DIR="$BACKUP_ROOT/.daily-backup.lock"
TODAY="$(date +%F)"
NOW="$(date +%Y-%m-%d-%H%M%S)"

FORCE=0
DRY_RUN=0
case "${1:-}" in
    --force)   FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    "")        ;;
    *)
        echo "Unknown option: $1 (use --force or --dry-run)" >&2
        exit 2
        ;;
esac

mkdir -p "$BACKUP_ROOT"

# Keep one state file that records the last version and the last backup date.
if [ ! -f "$STATE_FILE" ]; then
    printf '{"currentVersion":"1.0","lastBackupDate":null}\n' > "$STATE_FILE"
fi

read_state() {
    /usr/bin/python3 - "$STATE_FILE" "$1" <<'PY'
import json
import sys

path, field = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as handle:
    state = json.load(handle)
value = state.get(field)
print("" if value is None else value)
PY
}

CURRENT_VERSION="$(read_state currentVersion)"
LAST_DATE="$(read_state lastBackupDate)"

if [ -z "$CURRENT_VERSION" ]; then
    echo "ERROR: $STATE_FILE has no currentVersion." >&2
    exit 1
fi

# Increment by exactly one tenth without floating-point drift.
NEW_VERSION="$(/usr/bin/python3 - "$CURRENT_VERSION" <<'PY'
import sys

major, minor = sys.argv[1].split(".")
tenths = int(major) * 10 + int(minor) + 1
print(f"{tenths // 10}.{tenths % 10}")
PY
)"

DEST="$BACKUP_ROOT/v${NEW_VERSION}-${TODAY}"
ARCHIVE="$DEST.zip"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "Current backup version: $CURRENT_VERSION"
    echo "Next backup version:    $NEW_VERSION"
    echo "Archive:                $ARCHIVE"
    exit 0
fi

if [ "$LAST_DATE" = "$TODAY" ] && [ "$FORCE" -eq 0 ]; then
    echo "Backup already created for $TODAY (version $CURRENT_VERSION); skipping."
    exit 0
fi

# Prevent overlapping runs (e.g. manual run while the scheduled one is active).
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Another daily backup is already running; exiting."
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

if [ -e "$DEST" ] || [ -e "$ARCHIVE" ]; then
    DEST="$BACKUP_ROOT/v${NEW_VERSION}-${NOW}"
    ARCHIVE="$DEST.zip"
fi

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/iume-backup.XXXXXX")"
trap 'rm -rf "$STAGING"; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

mkdir -p "$STAGING/project" "$STAGING/app" "$STAGING/user-state"

# Project source, excluding reproducible build output.
/usr/bin/rsync -a \
    --exclude='.build' \
    --exclude='crates/iume_engine/target' \
    --exclude='dist' \
    --exclude='.DS_Store' \
    "$PROJECT_ROOT/" "$STAGING/project/"

# Installed app, so the backup can restore the exact running build.
if [ -d "/Applications/Iume.app" ]; then
    /usr/bin/ditto "/Applications/Iume.app" "$STAGING/app/Iume.app"
fi

# User state: settings memory, saved window layout, and preferences.
for file in \
    "$HOME/Library/Application Support/Iume/settings_memory.json" \
    "$HOME/Library/Application Support/Iume/settings_memory.backup.json" \
    "$HOME/Library/Application Support/Iume/saved_layout.json" \
    "$HOME/Library/Preferences/com.iume.Iume.plist"
do
    if [ -f "$file" ]; then
        /bin/cp -p "$file" "$STAGING/user-state/"
    fi
done

{
    echo "Iume daily backup"
    echo "Backup version: $NEW_VERSION"
    echo "Created: $TODAY $NOW"
    echo "Source: $PROJECT_ROOT"
    if [ -d "$PROJECT_ROOT/.git" ]; then
        echo "Git commit: $(/usr/bin/git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
        echo "Git branch: $(/usr/bin/git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
        if [ -n "$(/usr/bin/git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null)" ]; then
            echo "Git dirty: yes"
        else
            echo "Git dirty: no"
        fi
    fi
    echo "Installed app version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Iume.app/Contents/Info.plist 2>/dev/null || echo none)"
} > "$STAGING/MANIFEST.txt"

# One compressed archive per version, containing the manifest at its root.
/usr/bin/ditto -c -k --sequesterRsrc "$STAGING" "$ARCHIVE"
/bin/cp "$STAGING/MANIFEST.txt" "$DEST.manifest.txt"
rm -rf "$STAGING"
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

# Advance the version only after the archive exists.
printf '{"currentVersion":"%s","lastBackupDate":"%s"}\n' "$NEW_VERSION" "$TODAY" > "$STATE_FILE.tmp"
/bin/mv "$STATE_FILE.tmp" "$STATE_FILE"

echo "Created $ARCHIVE (backup version $NEW_VERSION)"
