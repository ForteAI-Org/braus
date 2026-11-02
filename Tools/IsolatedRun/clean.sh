#!/bin/sh
# Stop only the recorded child, remove its scratch root, and verify shared storage is unchanged.
# Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
set -eu
: "${SCRATCH:?Set SCRATCH to the same absolute scratch directory used by run.sh}"
case "$SCRATCH" in /*) ;; *) echo 'SCRATCH must be absolute.' >&2; exit 64;; esac
clean_tools=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
clean_repo=$(CDPATH= cd -- "$clean_tools/../.." && pwd -P)
clean_scratch=$(CDPATH= cd -- "$SCRATCH" && pwd -P)
clean_root=$clean_scratch/isolated-run
clean_evidence=$clean_scratch/isolated-audit
[ ! -L "$clean_evidence" ] && [ -f "$clean_evidence/owner" ] \
    && [ ! -L "$clean_evidence/owner" ] && [ "$(cat "$clean_evidence/owner")" = "$clean_repo" ] || {
    echo 'Audit directory is not owned by this runner; refusing cleanup.' >&2; exit 1;
}
for clean_file in "$clean_evidence"/*; do
    [ ! -L "$clean_file" ] || { echo 'Audit files must not be symlinks.' >&2; exit 1; }
done
if [ -e "$clean_root" ] || [ -L "$clean_root" ]; then
    [ ! -L "$clean_root" ] && [ -f "$clean_root/owner" ] && [ ! -L "$clean_root/owner" ] \
        && [ "$(cat "$clean_root/owner")" = "$clean_repo" ] || {
        echo 'Scratch root is not owned by this runner; refusing cleanup.' >&2; exit 1;
    }
fi
if [ -f "$clean_root/runner.pid" ]; then
    clean_runner=$(cat "$clean_root/runner.pid")
    case "$clean_runner" in ''|*[!0-9]*|0|1) echo 'Invalid runner PID.' >&2; exit 1;; esac
    if kill -0 "$clean_runner" 2>/dev/null \
        && [ "$(ps -p "$clean_runner" -o lstart= -o command=)" = "$(cat "$clean_root/runner.identity")" ]; then
        echo 'run.sh is still active; wait for it before cleanup.' >&2
        exit 1
    fi
fi
[ -f "$clean_evidence/before.txt" ] || { echo 'No baseline; refusing unaudited cleanup.' >&2; exit 1; }
if [ -f "$clean_root/app.pid" ]; then
    clean_pid=$(cat "$clean_root/app.pid")
    case "$clean_pid" in ''|*[!0-9]*|0|1) echo 'Invalid recorded PID.' >&2; exit 1;; esac
    if kill -0 "$clean_pid" 2>/dev/null; then
        clean_identity=$(ps -p "$clean_pid" -o lstart= -o command=)
        [ "$clean_identity" = "$(cat "$clean_root/process.identity")" ] || {
            echo 'PID identity changed; refusing to signal another process.' >&2; exit 1;
        }
        kill -TERM "$clean_pid"
        clean_wait=0
        while kill -0 "$clean_pid" 2>/dev/null; do
            clean_wait=$((clean_wait + 1))
            [ "$clean_wait" -lt 20 ] || { echo 'Recorded process did not stop; scratch retained.' >&2; exit 1; }
            sleep 1
        done
    fi
    clean_run=$(cat "$clean_root/current")
    case "$clean_run" in "$clean_root"/run.*) ;; *) echo 'Invalid run directory.' >&2; exit 1;; esac
    clean_receipt=$clean_run/support/scripted-shutdown.json
    [ -f "$clean_receipt" ] && [ ! -L "$clean_receipt" ] || {
        echo 'No shutdown receipt; scratch retained for inspection.' >&2; exit 1;
    }
    clean_completed=$(/usr/bin/plutil -extract completed raw -o - "$clean_receipt") || clean_completed=false
    [ "$clean_completed" = true ] || {
        echo 'Worker cleanup failed; scratch retained for inspection.' >&2; cat "$clean_receipt" >&2; exit 1;
    }
    cp "$clean_receipt" "$clean_evidence/scripted-shutdown.json"
fi
# The fixed leaf is created only by run.sh, never supplied as a deletion argument.
[ ! -L "$clean_root" ] || { echo 'Scratch root is a symlink; refusing cleanup.' >&2; exit 1; }
rm -rf -- "$clean_root"
"$clean_tools/audit.sh" "$clean_evidence/cleaned.txt"
if ! cmp -s "$clean_evidence/before.txt" "$clean_evidence/cleaned.txt"; then
    echo 'TRACE AUDIT FAILED: shared Braus storage differs from the baseline. Nothing personal was removed.' >&2
    diff -u "$clean_evidence/before.txt" "$clean_evidence/cleaned.txt" > "$clean_evidence/trace.diff" || :
    exit 1
fi
[ ! -e "$clean_root" ] || { echo 'Scratch root remains.' >&2; exit 1; }
echo 'No trace in audited shared paths; recorded process stopped and disposable root removed.'
