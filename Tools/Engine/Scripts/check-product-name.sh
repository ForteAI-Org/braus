#!/bin/bash
#
# The product is Braus everywhere: in code, documents, fixtures and assets. This check refuses a tree in which
# any tracked file, binary assets included, still names the product by its earlier name. The earlier name is
# spelled here in hex, so this file carries no trace of it either. Run by `make test`; run it alone from the
# repository's root. Exit status 1 names the files, 0 means none.
set -eu
cd "$(dirname "$0")/../../.."
earlier=$(printf '\x6d\x65\x63\x75\x6d')
if found=$(git grep -i -l -e "$earlier" -- . ':!.scratch' 2>/dev/null) && [ -n "$found" ]; then
    echo "the product's earlier name is still in these tracked files; the product is Braus everywhere:" >&2
    echo "$found" >&2
    exit 1
fi
echo "OK   product name: no tracked file names the product by its earlier name"
