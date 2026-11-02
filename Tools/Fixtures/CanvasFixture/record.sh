#!/bin/bash
#
#  record.sh
#  Braus
#
#  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
#
# Usage: record.sh <workdir> [Application.app [arguments...]]
# No app records the eight fixture variants in Tests/Perception/Fixtures/Canvas.
# Any supplied app is a real-app recording, written ONLY outside any repository to
# $BRAUS_CANVAS_RECORDINGS (default ~/Downloads/Braus-canvas-recordings), never committed.
# BRAUS_CANVAS_DOCUMENT optionally names a scratch document to open in the new instance.
# Requires Accessibility and Screen Recording grants, an awake display and exclusive desktop use.
set -euo pipefail
if [ "$#" -lt 1 ]; then
    echo 'usage: record.sh <workdir> [Application.app [arguments...]]' >&2
    exit 2
fi
workdir="$1"
shift
mkdir -p "$workdir"
workdir="$(cd "$workdir" && pwd)"
source_dir="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$source_dir/../../.." && pwd)"
if [ "$#" -eq 0 ]; then
    "$source_dir/build.sh" "$workdir/app"
    export BRAUS_CANVAS_RECORD=fixture
    export BRAUS_CANVAS_APP="$workdir/app/CanvasFixture.app"
else
    export BRAUS_CANVAS_RECORD=real
    export BRAUS_CANVAS_APP="$1"
    shift
fi
export BRAUS_CANVAS_ARGS
BRAUS_CANVAS_ARGS="$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1:]))' "$@")"
export BRAUS_CANVAS_WORK="$workdir"
cd "$root"
TMPDIR="$workdir" bash Tools/Driver/Scripts/run-tier.sh canvas-recording 1 \
    /usr/bin/swift test --disable-sandbox --scratch-path "$workdir/swift-build" --filter CanvasRecordingTests

# Recompress PNG streams losslessly. Pixel data, filters and colour metadata are unchanged.
if [ "$BRAUS_CANVAS_RECORD" = fixture ]; then
    python3 - "$root/Tests/Perception/Fixtures/Canvas" <<'PY'
from pathlib import Path
import struct
import sys
import zlib

for path in Path(sys.argv[1]).rglob('*.png'):
    data = path.read_bytes()
    chunks = []
    offset = 8
    while offset < len(data):
        size = struct.unpack('>I', data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + size]
        chunks.append((kind, payload))
        offset += size + 12
    stream = zlib.compress(zlib.decompress(b''.join(p for k, p in chunks if k == b'IDAT')), 9)
    output = bytearray(data[:8])
    wrote_stream = False
    for kind, payload in chunks:
        if kind == b'IDAT':
            if wrote_stream:
                continue
            payload = stream
            wrote_stream = True
        output += struct.pack('>I', len(payload)) + kind + payload
        output += struct.pack('>I', zlib.crc32(kind + payload))
    path.write_bytes(output)
PY
fi
