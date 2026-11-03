#!/bin/sh
# Snapshot shared Braus storage without writing, deleting, or reading keychain secrets.
# Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
set -eu
[ "$#" = 1 ] || { echo 'usage: audit.sh <snapshot-file>' >&2; exit 64; }
audit_destination=$1
: "${SCRATCH:?Set SCRATCH to the runner scratch directory}"
audit_scratch=$(CDPATH= cd -- "$SCRATCH" && pwd -P)
audit_parent=$(dirname -- "$audit_destination")
audit_repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
[ "$audit_parent" = "$audit_scratch/isolated-audit" ] && [ ! -L "$audit_parent" ] \
    && [ ! -L "$audit_destination" ] && [ ! -L "$audit_parent/owner" ] \
    && [ -f "$audit_parent/owner" ] && [ "$(cat "$audit_parent/owner")" = "$audit_repo" ] || {
    echo 'Audit destination must be inside the owned scratch evidence directory.' >&2; exit 1;
}
audit_output=$audit_destination
audit_destination=$(mktemp "$audit_parent/snapshot.XXXXXX")
trap 'rm -f -- "$audit_destination"' EXIT HUP INT TERM
audit_home=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory | sed 's/^NFSHomeDirectory: //')
[ -d "$audit_home/Library" ] || { echo 'Cannot locate the personal Library.' >&2; exit 1; }
audit_temp=$(getconf DARWIN_USER_TEMP_DIR)
audit_cache=$(getconf DARWIN_USER_CACHE_DIR)
: > "$audit_destination"
for audit_path in \
        "$audit_home/Library/Preferences/dev.forte.Braus.plist" \
        "$audit_home/Library/Caches/dev.forte.Braus" \
        "$audit_home/Library/Saved Application State/dev.forte.Braus.savedState" \
        "$audit_home/Library/HTTPStorages/"dev.forte.Braus* \
        "$audit_home/Library/WebKit/dev.forte.Braus" \
        "$audit_home/Library/Application Support/Braus" \
        "$audit_temp/dev.forte.Braus.savedState" \
        "$audit_cache/dev.forte.Braus"
    do
        if [ -e "$audit_path" ] || [ -L "$audit_path" ]; then
            find "$audit_path" -exec stat -f '%N|%HT|%p|%z|%m|%c' {} + >> "$audit_destination"
            find "$audit_path" -type f -exec shasum -a 256 {} + >> "$audit_destination"
        else
            printf 'absent|%s\n' "$audit_path" >> "$audit_destination"
        fi
done
LC_ALL=C sort -o "$audit_destination" "$audit_destination"
audit_status=0
audit_defaults=$(defaults read dev.forte.Braus 2>/dev/null) || audit_status=$?
printf 'defaults|%s|%s\n' "$audit_status" "$(printf '%s' "$audit_defaults" | shasum -a 256)" >> "$audit_destination"
# Do not use -g or -w: only the service's item metadata is fingerprinted.
audit_status=0
audit_metadata=$(security find-generic-password -s dev.forte.Braus 2>&1) || audit_status=$?
printf 'keychain|%s|%s\n' "$audit_status" "$(printf '%s' "$audit_metadata" | shasum -a 256)" >> "$audit_destination"
for audit_account in anthropic gemini; do
    audit_status=0
    audit_metadata=$(security find-generic-password -s dev.forte.Braus -a "$audit_account" 2>&1) || audit_status=$?
    printf 'keychain-account|%s|%s|%s\n' "$audit_account" "$audit_status" \
        "$(printf '%s' "$audit_metadata" | shasum -a 256)" >> "$audit_destination"
done
mv -f -- "$audit_destination" "$audit_output"
