#!/usr/bin/env python3
"""The native messaging host of the Braus profile probe, a test fixture.

Chrome starts one process of it for each extension instance that connects (one per profile), through the host
manifest the probe run writes into its temporary user data directory (`<user-data-dir>/NativeMessagingHosts`); nothing
is registered anywhere else. It relays, unchanged, between two ends:
- Chrome's native messaging on stdin and stdout: each message a 4-byte length in native byte order, then UTF-8 JSON;
- the run's Unix socket, one JSON object per line, given by `--socket`, in a directory only this user can enter
  (0700, checked before connecting).
It interprets nothing: the extension checks every command against its own instance ID and pairing. It ends when
either end closes.
"""

import argparse
import json
import os
import socket
import stat
import struct
import sys
import threading

# Chrome's limit for a message from the host to the extension.
MAX_TO_CHROME = 1024 * 1024


def read_native(stream):
    """The next message from Chrome, or None when Chrome closed the pipe."""
    header = stream.read(4)
    if len(header) < 4:
        return None
    (length,) = struct.unpack("=I", header)
    body = stream.read(length)
    if len(body) < length:
        return None
    return json.loads(body.decode("utf-8"))


def write_native(stream, message):
    """Writes one message to Chrome; refuses one over Chrome's limit."""
    body = json.dumps(message, separators=(",", ":")).encode("utf-8")
    if len(body) > MAX_TO_CHROME:
        raise ValueError("message over Chrome's 1 MB limit")
    stream.write(struct.pack("=I", len(body)) + body)
    stream.flush()


def private_socket(path):
    """Connects to the run's socket after checking that only this user can reach its directory."""
    directory = os.path.dirname(path)
    info = os.stat(directory)
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise PermissionError(f"{directory} is not private to this user (0700)")
    channel = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    channel.connect(path)
    return channel


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    # Chrome adds the caller's origin as a positional argument (and `--parent-window` on Windows).
    arguments, _ = parser.parse_known_args()

    channel = private_socket(arguments.socket)
    from_run = channel.makefile("r", encoding="utf-8")
    to_run = channel.makefile("w", encoding="utf-8")
    from_chrome, to_chrome = sys.stdin.buffer, sys.stdout.buffer
    stop = threading.Event()

    def chrome_to_run():
        try:
            while not stop.is_set():
                message = read_native(from_chrome)
                if message is None:
                    break
                to_run.write(json.dumps(message) + "\n")
                to_run.flush()
        finally:
            stop.set()

    def run_to_chrome():
        try:
            for line in from_run:
                if stop.is_set():
                    break
                if line.strip():
                    write_native(to_chrome, json.loads(line))
        finally:
            stop.set()

    threads = [threading.Thread(target=chrome_to_run, daemon=True), threading.Thread(target=run_to_chrome, daemon=True)]
    for thread in threads:
        thread.start()
    stop.wait()
    channel.close()


if __name__ == "__main__":
    main()
