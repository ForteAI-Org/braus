#!/bin/bash
#
# The product is Braus everywhere: in code, documents, fixtures and assets. This check refuses a tree in which
# any tracked file, binary assets included, still names the product by its earlier name. The earlier name is
# spelled here in hex, so this file carries no trace of it either. Run by `make test`; run it alone from the
# repository's root. Exit status 1 names the files, 0 means none outside the reviewed exceptions.
#
# A file may keep the earlier name only when it is listed in product-name-exceptions.txt next to this script,
# one `<path> | <reason>` per line, after a review. An exception that no longer matches a file naming the
# earlier name is refused as well, so the list only ever shrinks with the tree.
#
# The check fails closed: when `git grep` cannot search, outside a repository for example, it says so and
# exits 2 instead of reading the silence as a clean tree.
set -eu
cd "$(dirname "$0")/../../.."
earlier=$(printf '\x6d\x65\x63\x75\x6d')
exceptions=Tools/Engine/Scripts/product-name-exceptions.txt

errors=$(mktemp "${TMPDIR:-/tmp}/check-product-name.XXXXXX")
trap 'rm -f "$errors"' EXIT
status=0
found=$(git -c grep.fallbackToNoIndex=false -c core.quotePath=false \
    grep -i -l -e "$earlier" -- . ':!.scratch' 2>"$errors") || status=$?
if [ "$status" -gt 1 ]; then
    echo "the product name check could not search the tracked files (git grep exited $status):" >&2
    cat "$errors" >&2
    exit 2
fi

listed=""
if [ -f "$exceptions" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        path=${line%% | *}
        reason=${line#* | }
        if [ "$path" = "$line" ] || [ -z "$path" ] || [ -z "${reason// /}" ]; then
            echo "$exceptions: every exception is \`<path> | <reason>\`, and this one is not: $line" >&2
            exit 2
        fi
        listed+="$path"$'\n'
    done < "$exceptions"
fi

unlisted=$(comm -23 <(printf '%s' "$found" | sort -u) <(printf '%s' "$listed" | sort -u))
stale=$(comm -13 <(printf '%s' "$found" | sort -u) <(printf '%s' "$listed" | sort -u))
if [ -n "$unlisted" ]; then
    echo "the product's earlier name is still in these tracked files; the product is Braus everywhere:" >&2
    echo "$unlisted" >&2
fi
if [ -n "$stale" ]; then
    echo "$exceptions lists files that no longer name the product by its earlier name; remove them:" >&2
    echo "$stale" >&2
fi
if [ -n "$unlisted" ] || [ -n "$stale" ]; then
    exit 1
fi
echo "OK   product name: no tracked file names the product by its earlier name outside the reviewed exceptions"
