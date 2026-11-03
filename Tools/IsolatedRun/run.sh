#!/bin/sh
# Build and run a model-free worker in disposable storage; keep evidence under SCRATCH.
# Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
set -eu
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { echo 'usage: run.sh <script.json> [--keep-open]' >&2; exit 64; }
[ "$#" = 1 ] || [ "$2" = --keep-open ] || { echo 'Unknown option.' >&2; exit 64; }
: "${SCRATCH:?Set SCRATCH to an absolute scratch directory}"
case "$SCRATCH" in /*) ;; *) echo 'SCRATCH must be absolute.' >&2; exit 64;; esac
runner_tools=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
runner_repo=$(CDPATH= cd -- "$runner_tools/../.." && pwd -P)
runner_script=$(CDPATH= cd -- "$(dirname -- "$1")" && printf '%s/%s\n' "$(pwd -P)" "$(basename -- "$1")")
[ -f "$runner_script" ] || { echo 'Script is not a file.' >&2; exit 66; }
mkdir -p "$SCRATCH"
runner_scratch=$(CDPATH= cd -- "$SCRATCH" && pwd -P)
runner_root=$runner_scratch/isolated-run
runner_evidence=$runner_scratch/isolated-audit
[ ! -L "$runner_evidence" ] || { echo 'Audit directory must not be a symlink.' >&2; exit 1; }
if [ -e "$runner_evidence" ]; then
    [ -f "$runner_evidence/owner" ] && [ ! -L "$runner_evidence/owner" ] \
        && [ "$(cat "$runner_evidence/owner")" = "$runner_repo" ] || {
        echo 'Audit directory is not owned by this runner.' >&2; exit 1;
    }
    for runner_file in "$runner_evidence"/*; do
        [ ! -L "$runner_file" ] || { echo 'Audit files must not be symlinks.' >&2; exit 1; }
    done
fi
[ ! -e "$runner_root/app.pid" ] || { echo 'Run clean.sh before starting another run.' >&2; exit 1; }
[ ! -L "$runner_root" ] || { echo 'Scratch root must not be a symlink.' >&2; exit 1; }
if [ -e "$runner_root" ]; then
    [ -f "$runner_root/owner" ] && [ ! -L "$runner_root/owner" ] \
        && [ "$(cat "$runner_root/owner")" = "$runner_repo" ] || {
        echo 'Scratch root is not owned by this runner.' >&2; exit 1;
    }
fi
mkdir -p "$runner_root" "$runner_evidence"
printf '%s\n' "$runner_repo" > "$runner_root/owner"
printf '%s\n' "$runner_repo" > "$runner_evidence/owner"
mkdir "$runner_root/active" 2>/dev/null || { echo 'A run already owns this scratch root; use clean.sh.' >&2; exit 1; }
printf '%s\n' "$$" > "$runner_root/runner.pid"
ps -p "$$" -o lstart= -o command= > "$runner_root/runner.identity"
"$runner_tools/audit.sh" "$runner_evidence/before.txt"
runner_run=$(mktemp -d "$runner_root/run.XXXXXX")
mkdir -p "$runner_run/support/home" "$runner_run/support/tmp"
printf '%s\n' "$runner_run" > "$runner_root/current"
runner_app=$runner_root/dd/Build/Products/Debug/Braus.app
if [ ! -x "$runner_app/Contents/MacOS/Braus" ] || [ "${BRAUS_ISOLATED_REBUILD:-0}" = 1 ]; then
    (cd "$runner_repo" && xcodebuild -workspace BrausApp/AgentEnvironment.xcworkspace \
        -scheme Braus -configuration Debug -derivedDataPath "$runner_root/dd" build) \
        > "$runner_evidence/build.log" 2>&1 || { tail -60 "$runner_evidence/build.log" >&2; exit 1; }
fi
cp "$runner_script" "$runner_run/script.json"
runner_quit=1
[ "$#" = 1 ] || runner_quit=0
if [ ! -x "$runner_root/launcher" ] || [ "${BRAUS_ISOLATED_REBUILD:-0}" = 1 ]; then
    /usr/bin/swiftc -parse-as-library -module-cache-path "$runner_root/module-cache" \
        "$runner_tools/IsolatedAppLauncher.swift" -o "$runner_root/launcher" \
        > "$runner_evidence/launcher-build.log" 2>&1 || {
        cat "$runner_evidence/launcher-build.log" >&2; exit 1;
    }
fi
runner_pid=$(BRAUS_ISOLATED_RUN=1 BRAUS_APP_SUPPORT_DIR="$runner_run/support" \
    BRAUS_SCRIPTED_WORKER="$runner_run/script.json" BRAUS_SCRIPTED_CHECK=1 \
    BRAUS_SCRIPTED_CHECK_QUIT="$runner_quit" CFFIXED_USER_HOME="$runner_run/support/home" \
    TMPDIR="$runner_run/support/tmp/" "$runner_root/launcher" "$runner_app" \
    2> "$runner_evidence/launcher.log") || {
    "$runner_tools/audit.sh" "$runner_evidence/after.txt"
    cat "$runner_evidence/launcher.log" >&2
    exit 1
}
case "$runner_pid" in ''|*[!0-9]*|0|1) echo 'Launcher returned an invalid PID.' >&2; exit 1;; esac
printf '%s\n' "$runner_pid" > "$runner_root/app.pid"
ps -p "$runner_pid" -o lstart= -o command= > "$runner_root/process.identity" || :
printf 'PID %s; support %s\n' "$runner_pid" "$runner_run/support"
runner_wait=0
runner_status=0
while [ ! -f "$runner_run/support/scripted-check.json" ]; do
    if ! kill -0 "$runner_pid" 2>/dev/null; then
        echo 'Braus exited before writing scripted-check.json.' >&2
        runner_status=1
        break
    fi
    runner_wait=$((runner_wait + 1))
    if [ "$runner_wait" -ge 120 ]; then
        echo 'Timed out after 120 seconds; run clean.sh.' >&2
        runner_status=1
        break
    fi
    sleep 1
done
if [ -f "$runner_run/support/scripted-check.json" ]; then
    cp "$runner_run/support/scripted-check.json" "$runner_evidence/scripted-check.json"
    cat "$runner_evidence/scripted-check.json"
    runner_passed=$(/usr/bin/plutil -extract passed raw -o - "$runner_evidence/scripted-check.json") || runner_status=1
    [ "$runner_passed" = true ] || runner_status=1
else
    [ ! -f "$runner_run/support/app.log" ] || cat "$runner_run/support/app.log" >&2
fi
[ ! -f "$runner_run/support/scripted-tools.jsonl" ] || cp "$runner_run/support/scripted-tools.jsonl" "$runner_evidence/"
[ ! -f "$runner_run/support/app.log" ] || cp "$runner_run/support/app.log" "$runner_evidence/"
if [ "$runner_quit" = 1 ]; then
    runner_wait=0
    while kill -0 "$runner_pid" 2>/dev/null; do
        runner_wait=$((runner_wait + 1))
        if [ "$runner_wait" -ge 20 ]; then
            echo 'Braus did not quit after its report; run clean.sh.' >&2
            runner_status=1
            break
        fi
        sleep 1
    done
    if [ -f "$runner_run/support/scripted-shutdown.json" ]; then
        cp "$runner_run/support/scripted-shutdown.json" "$runner_evidence/scripted-shutdown.json"
        runner_completed=$(/usr/bin/plutil -extract completed raw -o - "$runner_evidence/scripted-shutdown.json") || runner_status=1
        runner_exit=$(/usr/bin/plutil -extract exitStatus raw -o - "$runner_evidence/scripted-shutdown.json") || runner_status=1
        [ "$runner_completed" = true ] && [ "$runner_exit" = 0 ] || runner_status=1
    else
        echo 'No successful shutdown receipt; termination is unconfirmed. Scratch retained for inspection.' >&2
        runner_status=1
    fi
fi
if ! "$runner_tools/audit.sh" "$runner_evidence/after.txt"; then
    echo 'Post-run trace snapshot failed.' >&2
    runner_status=1
fi
if ! cmp -s "$runner_evidence/before.txt" "$runner_evidence/after.txt"; then
    echo 'Shared Braus storage changed. Personal files were left untouched; inspect isolated-audit.' >&2
    runner_status=1
fi
exit "$runner_status"
