#!/bin/sh
#
#  stamp-commit.sh
#  Braus
#
#  Created by Eliomar Alejandro Rodriguez Ferrer on 14/10/2026.
#
#  Writes the git commit of the source tree to the phase's declared output,
#  BuildCommit.txt in the app's Resources, so the log export can name the build.
#  Outside a git checkout (a source archive) it writes "unknown"; any other
#  failure stops the build.

set -eu

if git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    commit=$(git -C "$PROJECT_DIR" rev-parse --short=8 HEAD)
else
    commit=unknown
fi

printf '%s\n' "$commit" > "$SCRIPT_OUTPUT_FILE_0"
