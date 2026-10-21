#!/bin/bash
# Runs a command and, if it fails, turns the compiler's `file:line:col: error: …` lines into
# GitHub annotations — they show up on the run page and in the API without opening the raw log.
# GitHub keeps at most 10 annotations of each level per step, so the first 10 errors go out as
# errors, the next 10 as warnings and the next 10 as notices, all marked as errors in the text.
set -uo pipefail

log="$(mktemp)"
"$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}

if [[ $status -ne 0 ]]; then
    workspace="${GITHUB_WORKSPACE:-$(pwd)}/"
    grep -E '^[^ ]+\.swift:[0-9]+:[0-9]+: error: ' "$log" | sort -u | head -30 | {
        index=0
        while IFS= read -r line; do
            file="${line%%:*}"; rest="${line#*:}"
            row="${rest%%:*}"; rest="${rest#*:}"
            column="${rest%%:*}"; message="${rest#*: error: }"
            file="${file#"$workspace"}"
            level=error
            (( index >= 10 )) && level=warning
            (( index >= 20 )) && level=notice
            echo "::${level} file=${file},line=${row},col=${column}::[error] ${message}"
            index=$((index + 1))
        done
    }
    # Linker and package errors carry no file position.
    grep -E '^error: ' "$log" | sort -u | head -5 | sed 's/^error: /::error::[error] /'
fi
rm -f "$log"
exit "$status"
