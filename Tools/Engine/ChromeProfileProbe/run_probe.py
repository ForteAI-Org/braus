#!/usr/bin/env python3
"""Runs the Braus profile probe, a test fixture, on two TEMPORARY Chrome profiles: never the person's Chrome or data.

What it shows (route B of handoffs/chrome-profile-selection-proposal.md):
- the extension runs as one instance per profile, each with its own random ID in that profile's storage.local;
- each instance is paired only by a confirmation on its own page, under a name given there;
- a page opened through the instance chosen by that pairing reaches its profile's site identity, and only it;
- an instance ID no instance has is refused by the run with nothing sent to Chrome, so nothing opened and no
  profile made by it (a directory listing is only an observation: a profile's files may not be written yet);
- closing closes only the tabs the instance opened; the browser and every other tab stay.

How:
- **Chrome:** one Chrome, given by `--chrome`, on a temporary user data directory with two profiles, `Alfa` and
  `Beta`. The second profile is opened by a second launch that Chrome forwards to the running one
  (`--profile-directory`).
- **The extension:** loaded unpacked with `--load-extension`, with the native host's manifest in the temporary user
  data directory only.
- **The site:** a local one on 127.0.0.1 gives each profile a synthetic identity (carla in Alfa, dario in Beta),
  set by Chrome's own profile routing, not by the extension. These names are site accounts, deliberately different
  from the pairing names ("Fixture Alfa", "Fixture Beta").
- **The harness:** it plays the person (it confirms each pairing page) and checks the tabs at the end, through
  Chrome's DevTools pipe on that temporary profile.

Refusals:
- Chrome's installed browser in /Applications is refused: the personal Chrome stays untouched. Give a test build,
  such as Chrome for Testing.
- A user data directory under ~/Library/Application Support/Google is never used.
- The keychain is mocked (`--use-mock-keychain`).

Exit:
- 0: every check passed;
- 1: a check failed, or an error no check expected ended the run (the report says ERROR);
- 2: blocked: Chrome did not do what the fixture needs (the extension not loaded in both profiles, or a launch not
  forwarded). It is said as such, never worked around.

`--self-check` checks the files, the extension ID and the host's framing with no Chrome at all.
"""

import argparse
import base64
import fcntl
import hashlib
import http.server
import importlib.util
import io
import json
import os
import queue
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import urllib.parse
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
EXTENSION = os.path.join(HERE, "extension")
HOST_SCRIPT = os.path.join(HERE, "profile_probe_host.py")
HOST_NAME = "dev.forte.braus.profile_probe"
PERSONAL_CHROME = "/Applications/Google Chrome.app"
PERSONAL_DATA = os.path.expanduser("~/Library/Application Support/Google")
PROFILES = {"Alfa": ("Fixture Alfa", "carla"), "Beta": ("Fixture Beta", "dario")}


class Blocked(Exception):
    """Chrome did not do what the fixture needs; said as such, never worked around."""


# MARK: The extension and its host


def extension_id(manifest_path):
    """The ID Chrome gives the unpacked extension: the SHA-256 of its public key, first 32 hex digits mapped to a-p."""
    key = json.load(open(manifest_path))["key"]
    digest = hashlib.sha256(base64.b64decode(key)).hexdigest()[:32]
    return "".join(chr(ord("a") + int(digit, 16)) for digit in digest)


def install_host(root, user_data, ext_id):
    """Writes the host's wrapper and manifest inside `root` and `user_data` only, and answers the socket path."""
    channel = os.path.join(root, "ch")
    os.makedirs(channel, mode=0o700)
    socket_path = os.path.join(channel, "run.sock")
    if len(socket_path.encode()) > 100:
        raise OSError(f"the socket path is too long for a Unix socket: {socket_path}")
    wrapper = os.path.join(root, "probe-host")
    with open(wrapper, "w") as script:
        script.write("#!/bin/sh\n")
        script.write(f'exec "{sys.executable}" -I "{HOST_SCRIPT}" --socket "{socket_path}" "$@"\n')
    os.chmod(wrapper, 0o700)
    hosts = os.path.join(user_data, "NativeMessagingHosts")
    os.makedirs(hosts, exist_ok=True)
    manifest = {
        "name": HOST_NAME,
        "description": "Braus profile probe host (test fixture)",
        "path": wrapper,
        "type": "stdio",
        "allowed_origins": [f"chrome-extension://{ext_id}/"],
    }
    with open(os.path.join(hosts, HOST_NAME + ".json"), "w") as file:
        json.dump(manifest, file, indent=2)
    return socket_path


# MARK: The local site


class Site:
    """A site on 127.0.0.1: `/login?as=NAME` sets the synthetic identity cookie, `/whoami?nonce=N` shows it and
    records which identity each nonce saw."""

    def __init__(self):
        self.lock = threading.Lock()
        self.logins = []
        self.seen = {}
        site = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                url = urllib.parse.urlsplit(self.path)
                query = urllib.parse.parse_qs(url.query)
                cookies = dict(part.strip().split("=", 1) for part in (self.headers.get("Cookie") or "").split(";")
                               if "=" in part)
                if url.path == "/login":
                    name = query.get("as", [""])[0]
                    with site.lock:
                        site.logins.append(name)
                    self.answer(f"signed in as {name}", cookie=f"probe_user={name}; Path=/; Max-Age=3600")
                elif url.path == "/whoami":
                    user = cookies.get("probe_user", "")
                    with site.lock:
                        site.seen[query.get("nonce", [""])[0]] = user
                    self.answer(f"user={user}")
                else:
                    self.answer("probe site")

            def answer(self, text, cookie=None):
                body = f"<!doctype html><title>probe</title><body>{text}</body>".encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                if cookie:
                    self.send_header("Set-Cookie", cookie)
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *arguments):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def whoami_count(self):
        with self.lock:
            return len(self.seen)

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


# MARK: The channel to the extension instances


class Channel:
    """The run's end of the restricted channel: a Unix socket in a 0700 directory, one connection per host process,
    that is per extension instance. It knows each instance by the ID its `hello` gave, and each pairing by the name
    confirmed on that instance's own page."""

    def __init__(self, path):
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(path)
        os.chmod(path, 0o600)
        self.listener.listen(8)
        self.messages = queue.Queue()
        self.instances = {}
        self.paired = {}
        self.results = {}
        threading.Thread(target=self.accept, daemon=True).start()

    def accept(self):
        while True:
            try:
                connection, _ = self.listener.accept()
            except OSError:
                return
            writer = connection.makefile("w", encoding="utf-8")
            lock = threading.Lock()

            def send(message, writer=writer, lock=lock):
                with lock:
                    writer.write(json.dumps(message) + "\n")
                    writer.flush()

            def read(connection=connection, send=send):
                for line in connection.makefile("r", encoding="utf-8"):
                    if line.strip():
                        self.messages.put((send, json.loads(line)))

            threading.Thread(target=read, daemon=True).start()

    def pump(self, until, timeout):
        """Handles messages until `until()` is true or `timeout` seconds passed; answers whether it became true."""
        deadline = time.monotonic() + timeout
        while not until():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            try:
                send, message = self.messages.get(timeout=min(remaining, 0.5))
            except queue.Empty:
                continue
            kind = message.get("type")
            if kind == "hello":
                self.instances[message["instanceId"]] = send
            elif kind == "paired":
                self.paired[message["label"]] = message["instanceId"]
            elif kind == "result":
                self.results[message.get("requestId")] = message
        return True

    def request(self, instance_id, message, timeout=30):
        """Sends `message` to the instance `instance_id` and answers its result. An ID no instance has is refused
        here, before anything is sent."""
        send = self.instances.get(instance_id)
        if send is None:
            return {"ok": False, "error": "refused by the run: no instance has this ID", "sent": False}
        request_id = str(uuid.uuid4())
        send({**message, "requestId": request_id})
        if not self.pump(lambda: request_id in self.results, timeout):
            return {"ok": False, "error": "no answer in time", "sent": True}
        return {**self.results.pop(request_id), "sent": True}

    def close(self):
        self.listener.close()


# MARK: Chrome and its DevTools pipe


class Chrome:
    """The fixture's own Chrome, started with `--remote-debugging-pipe` (it reads fd 3, writes fd 4) and ended by
    its own process ID only."""

    def __init__(self, binary, arguments, log_path):
        to_chrome_read, self.to_chrome = self.moved(os.pipe())
        self.from_chrome, from_chrome_write = self.moved(os.pipe())
        (log,) = self.moved((os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600),))
        actions = [
            (os.POSIX_SPAWN_DUP2, to_chrome_read, 3),
            (os.POSIX_SPAWN_DUP2, from_chrome_write, 4),
            (os.POSIX_SPAWN_DUP2, log, 1),
            (os.POSIX_SPAWN_DUP2, log, 2),
        ]
        try:
            self.pid = os.posix_spawn(binary, [binary, *arguments, "--remote-debugging-pipe"], os.environ,
                                      file_actions=actions)
        except OSError:
            for descriptor in (self.to_chrome, self.from_chrome):
                os.close(descriptor)
            raise
        finally:
            for descriptor in (to_chrome_read, from_chrome_write, log):
                os.close(descriptor)
        self.exited = False
        self.next_id = 0
        self.lock = threading.Lock()
        self.replies = {}
        self.arrived = threading.Condition()
        threading.Thread(target=self.read, daemon=True).start()

    @staticmethod
    def moved(descriptors):
        """`descriptors` moved to 10 and above, close-on-exec, the originals closed, as `ChromeProcess.makePipe`
        does: a dup2 onto a descriptor's own number keeps close-on-exec, so one already 3 or 4 would never reach
        Chrome, and one at 1 to 4 could be overwritten by another dup2 of the same spawn."""
        moved = []
        try:
            for descriptor in descriptors:
                moved.append(fcntl.fcntl(descriptor, fcntl.F_DUPFD_CLOEXEC, 10))
        except OSError:
            for descriptor in moved:
                os.close(descriptor)
            raise
        finally:
            for descriptor in descriptors:
                os.close(descriptor)
        return tuple(moved)

    def read(self):
        pending = b""
        while True:
            try:
                chunk = os.read(self.from_chrome, 65536)
            except OSError:
                return
            if not chunk:
                return
            pending += chunk
            while b"\0" in pending:
                frame, pending = pending.split(b"\0", 1)
                message = json.loads(frame)
                if "id" in message:
                    with self.arrived:
                        self.replies[message["id"]] = message
                        self.arrived.notify_all()

    def call(self, method, params=None, session=None, timeout=15):
        with self.lock:
            self.next_id += 1
            call_id = self.next_id
        message = {"id": call_id, "method": method, "params": params or {}}
        if session:
            message["sessionId"] = session
        os.write(self.to_chrome, json.dumps(message).encode() + b"\0")
        with self.arrived:
            if not self.arrived.wait_for(lambda: call_id in self.replies, timeout):
                raise TimeoutError(f"{method}: no answer in {timeout} s")
            answer = self.replies.pop(call_id)
        if "error" in answer:
            raise RuntimeError(f"{method}: {answer['error'].get('message')}")
        return answer.get("result", {})

    def pages(self):
        return [target for target in self.call("Target.getTargets")["targetInfos"] if target["type"] == "page"]

    def is_running(self):
        """Whether Chrome still runs; it is reaped once, the first time it is found ended."""
        if not self.exited and os.waitpid(self.pid, os.WNOHANG) != (0, 0):
            self.exited = True
        return not self.exited

    def answers(self):
        """Whether Chrome runs and answers on its pipe now."""
        try:
            return self.is_running() and bool(self.call("Browser.getVersion", timeout=2))
        except (TimeoutError, RuntimeError, OSError):
            return False

    def end(self):
        """Asks Chrome to close, then ends it by its process ID if it has not within 5 s."""
        try:
            self.call("Browser.close", timeout=3)
        except Exception:
            pass
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if not self.is_running():
                return
            time.sleep(0.1)
        os.kill(self.pid, signal.SIGKILL)
        os.waitpid(self.pid, 0)
        self.exited = True


def forward(binary, user_data, profile, url, extension):
    """A second launch on the same user data directory, which Chrome forwards to the running one: `url` opens in
    `profile`."""
    subprocess.run([binary, f"--user-data-dir={user_data}", f"--profile-directory={profile}",
                    f"--load-extension={extension}", "--no-first-run", "--no-default-browser-check",
                    "--use-mock-keychain", url],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30, check=False)


def top_level_directories(user_data):
    """The directories at the top of the user data directory now. A profile Chrome loads appears here as one, but its
    files (Preferences among them) may not be written yet while Chrome runs, so this says only that no new directory
    appeared, never which profiles exist."""
    return sorted(name for name in os.listdir(user_data) if os.path.isdir(os.path.join(user_data, name)))


def wait(condition, timeout, step=0.2):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(step)
    return condition()


# MARK: The probe


class Report:
    def __init__(self):
        self.lines = []
        self.failed = False

    def check(self, passed, what):
        self.lines.append(("PASS" if passed else "FAIL", what))
        print(("PASS  " if passed else "FAIL  ") + what, flush=True)
        self.failed = self.failed or not passed
        return passed


def probe(binary, root, report, headed):
    user_data = os.path.join(root, "chrome-data")
    os.makedirs(user_data, mode=0o700)
    ext_id = extension_id(os.path.join(EXTENSION, "manifest.json"))
    socket_path = install_host(root, user_data, ext_id)
    arguments = [f"--user-data-dir={user_data}", "--profile-directory=Alfa", f"--load-extension={EXTENSION}",
                 f"--disable-extensions-except={EXTENSION}", "--no-first-run", "--no-default-browser-check",
                 "--use-mock-keychain", "--disable-sync", *([] if headed else ["--headless=new"]), "about:blank"]
    site = channel = chrome = None
    try:
        site = Site()
        channel = Channel(socket_path)
        chrome = Chrome(binary, arguments, os.path.join(root, "chrome.log"))
        if not wait(chrome.answers, 20):
            raise Blocked("Chrome did not start or did not answer on its DevTools pipe")
        print("chrome:", chrome.call("Browser.getVersion").get("product"), "extension id:", ext_id, flush=True)

        # The two profiles and their site identities, by Chrome's own profile routing (not the extension).
        forward(binary, user_data, "Beta", "about:blank", EXTENSION)
        for directory, (_, user) in PROFILES.items():
            forward(binary, user_data, directory, site.url + f"login?as={user}", EXTENSION)
        if not wait(lambda: sorted(site.logins) == ["carla", "dario"], 20):
            raise Blocked(f"the forwarded launches did not open both logins (site saw {site.logins})")
        contexts = {}
        for page in chrome.pages():
            for directory, (_, user) in PROFILES.items():
                if page["url"].endswith(f"/login?as={user}"):
                    contexts[directory] = page.get("browserContextId")
        if not report.check(len(set(contexts.values())) == 2 and None not in contexts.values(),
                            f"fixture: the two logins are in two browser contexts {contexts}"):
            raise Blocked("the forwarded launches did not land in two distinct profiles")
        directories_before = top_level_directories(user_data)
        known_pages = {page["targetId"] for page in chrome.pages()}

        # One extension instance per profile, each saying hello with its own ID.
        if not channel.pump(lambda: len(channel.instances) >= 2, 30):
            raise Blocked(f"{len(channel.instances)} extension instance(s) said hello, 2 needed: --load-extension "
                          "may be ignored by this Chrome, or not applied to a forwarded profile")
        report.check(len(channel.instances) == 2, f"two instances, two distinct IDs: {sorted(channel.instances)}")

        # Pairing: each instance opens its own page; the person (the harness) confirms there, with the profile's name.
        for instance in list(channel.instances):
            answer = channel.request(instance, {"type": "openPairing"})
            report.check(answer.get("ok") is True, f"instance {instance[:8]} opened its pairing page")
        names = {context: PROFILES[directory][0] for directory, context in contexts.items()}
        if not wait(lambda: len([p for p in chrome.pages() if "/pair.html" in p["url"]]) >= 2, 15):
            raise Blocked("the pairing pages did not open")
        for page in [p for p in chrome.pages() if "/pair.html" in p["url"]]:
            name = names.get(page.get("browserContextId"))
            session = chrome.call("Target.attachToTarget", {"targetId": page["targetId"], "flatten": True})["sessionId"]
            chrome.call("Runtime.evaluate", {"expression": (
                f"document.getElementById('label').value = {json.dumps(name)};"
                "document.getElementById('confirm').click(); true")}, session=session)
        channel.pump(lambda: len(channel.paired) >= 2, 15)
        if not report.check(sorted(channel.paired) == ["Fixture Alfa", "Fixture Beta"]
                            and len(set(channel.paired.values())) == 2,
                            f"each profile paired under its own name, to its own instance: {channel.paired}"):
            return

        # The choice, repeated: the identity the site sees follows the instance chosen by its pairing name.
        opened = []
        for name, user in [("Fixture Beta", "dario"), ("Fixture Alfa", "carla"), ("Fixture Beta", "dario")]:
            nonce = uuid.uuid4().hex
            instance = channel.paired.get(name)
            answer = channel.request(instance, {"type": "open", "instanceId": instance,
                                                "url": site.url + f"whoami?nonce={nonce}"})
            if answer.get("ok"):
                opened.append((instance, answer["tabId"]))
            report.check(answer.get("ok") is True and f"user={user}" in answer.get("text", "")
                         and site.seen.get(nonce) == user and user not in name,
                         f"chose '{name}': the page shows user={user}, the site saw {site.seen.get(nonce)!r}")

        # An ID no instance has: refused by the run, nothing opened, no profile made.
        before = site.whoami_count()
        missing = str(uuid.uuid4())
        answer = channel.request(missing, {"type": "open", "instanceId": missing, "url": site.url + "whoami?nonce=x"})
        report.check(answer.get("ok") is False and answer.get("sent") is False and site.whoami_count() == before,
                     "an unknown ID is refused by the run with nothing sent to any instance and nothing opened")
        # Only an observation: the refusal sent nothing to Chrome, so it could not make a profile; the listing cannot
        # attest which profiles exist (see `top_level_directories`).
        directories_after = top_level_directories(user_data)
        report.check(directories_after == directories_before,
                     f"no new top-level directory in the user data dir during that refusal: {directories_after}")

        # An instance asked to act for another one's ID refuses too (the extension's own check).
        alfa, beta = channel.paired["Fixture Alfa"], channel.paired["Fixture Beta"]
        channel.instances[missing] = channel.instances[beta]
        answer = channel.request(missing, {"type": "open", "instanceId": alfa, "url": site.url + "whoami?nonce=y"})
        del channel.instances[missing]
        report.check(answer.get("ok") is False and "another instance" in answer.get("error", "")
                     and site.whoami_count() == before, f"Beta's instance refuses Alfa's ID: {answer.get('error')}")

        # Closing: only the tabs each instance opened; the browser and every other tab stay.
        for instance, tab_id in opened:
            answer = channel.request(instance, {"type": "close", "instanceId": instance, "tabId": tab_id})
            report.check(answer.get("ok") is True, f"instance {instance[:8]} closed its tab {tab_id}")
        wait(lambda: not [p for p in chrome.pages() if "/whoami" in p["url"]], 10)
        remaining = {page["targetId"] for page in chrome.pages()}
        report.check(chrome.is_running() and known_pages <= remaining
                     and not [p for p in chrome.pages() if "/whoami" in p["url"]],
                     "the browser runs, every tab it had before stays, the probe's tabs are gone")
    finally:
        # Each released only if it was acquired, the browser first.
        if chrome is not None:
            chrome.end()
        if channel is not None:
            channel.close()
        if site is not None:
            site.stop()


def self_check():
    """No Chrome: the files, the extension ID, the host's manifest and the host's framing."""
    manifest = json.load(open(os.path.join(EXTENSION, "manifest.json")))
    for name in ("background.js", "pair.html", "pair.js"):
        assert os.path.isfile(os.path.join(EXTENSION, name)), name
    assert manifest["manifest_version"] == 3 and "nativeMessaging" in manifest["permissions"]
    assert "cookies" not in manifest["permissions"], "the extension must not read cookies"
    ext_id = extension_id(os.path.join(EXTENSION, "manifest.json"))
    assert len(ext_id) == 32 and set(ext_id) <= set("abcdefghijklmnop"), ext_id
    root = tempfile.mkdtemp(prefix="braus-pp-check-")
    try:
        user_data = os.path.join(root, "chrome-data")
        socket_path = install_host(root, user_data, ext_id)
        host_manifest = json.load(open(os.path.join(user_data, "NativeMessagingHosts", HOST_NAME + ".json")))
        assert host_manifest["allowed_origins"] == [f"chrome-extension://{ext_id}/"]
        assert host_manifest["path"].startswith(root) and os.access(host_manifest["path"], os.X_OK)
        assert stat.S_IMODE(os.stat(os.path.dirname(socket_path)).st_mode) == 0o700
        spec = importlib.util.spec_from_file_location("profile_probe_host", HOST_SCRIPT)
        host = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(host)
        stream = io.BytesIO()
        host.write_native(stream, {"type": "hello", "instanceId": "x"})
        stream.seek(0)
        assert host.read_native(stream) == {"type": "hello", "instanceId": "x"}
        assert host.read_native(stream) is None
    finally:
        shutil.rmtree(root, ignore_errors=True)
    print("self-check passed: extension id", ext_id)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--chrome", help="a test build's executable, such as Chrome for Testing")
    parser.add_argument("--headed", action="store_true", help="show the fixture's windows (default: headless)")
    parser.add_argument("--keep", action="store_true", help="keep the temporary directory for inspection")
    parser.add_argument("--self-check", action="store_true", help="check the files only; no Chrome")
    arguments = parser.parse_args()
    if arguments.self_check:
        self_check()
        return 0
    binary = os.path.realpath(arguments.chrome or "")
    if not arguments.chrome or not os.access(binary, os.X_OK):
        print("refused: give --chrome, an executable test build of Chrome", file=sys.stderr)
        return 1
    if binary.startswith(PERSONAL_CHROME):
        print(f"refused: {PERSONAL_CHROME} is the personal Chrome; give a test build", file=sys.stderr)
        return 1
    root = tempfile.mkdtemp(prefix="braus-pp-")
    if os.path.realpath(root).startswith(PERSONAL_DATA):
        print("refused: the temporary directory is under the personal Chrome data", file=sys.stderr)
        return 1
    report = Report()
    status = 0
    try:
        probe(binary, root, report, arguments.headed)
        status = 1 if report.failed else 0
    except Blocked as blocked:
        print(f"BLOCKED  {blocked}", flush=True)
        report.lines.append(("BLOCKED", str(blocked)))
        status = 2
    except Exception as error:
        # An error no check expected, such as a refused bind: the run failed, and the report says so.
        traceback.print_exc()
        report.lines.append(("ERROR", f"{type(error).__name__}: {error}"))
        status = 1
    finally:
        with open(os.path.join(root, "report.json"), "w") as file:
            json.dump({"status": status, "lines": report.lines}, file, indent=2)
        print("report:", os.path.join(root, "report.json") if arguments.keep else "(removed with the directory)")
        if not arguments.keep:
            shutil.rmtree(root, ignore_errors=True)
    return status


if __name__ == "__main__":
    sys.exit(main())
