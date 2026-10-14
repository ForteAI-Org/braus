"""Braus vs Cua Driver: the same operations on the same windows, through the same MCP stdio client.

    python3 compare.py --apps Calculator,TextEdit --reps 8 --out results.jsonl --scratch DIR
    python3 compare.py --mode chain --apps TextEdit ...    # steps with 0, 1, 3 and 5 s pauses between them
    python3 compare.py --mode soak --apps TextEdit ...     # 500 steps per driver, footprint every step
    python3 compare.py --phases --drivers braus ...        # a BRAUS_PHASES build, never mixed with timed runs

Every call is one JSONL row: wall time at the client, reply size and tokens (text and image), CPU,
instructions and energy of the driver and of the target application, WindowServer CPU, and what an
independent probe saw around the call (frontmost app, physical cursor, windows and the display each is
on, hashes of the AX values, selection, focus, scroll position and window titles). The first row of a
run is its `kind: "meta"` row: preflight, machine, driver commits. Drivers alternate per app in ABBA
order (braus, cua, cua-overlay, then reversed) with a cooldown between blocks.

Cua is used the way its own docs say (see README, "How Cua is driven"): an action is one
`run_actions` call with `observe:true`, a re-read is a `since:"latest"` diff. `cua-legacy` keeps the
6 October pair (action, then a full `get_window_state`) as the secondary series `step_legacy`.
"""
import argparse, json, math, os, subprocess, sys, threading, time
from mcpclient import MCPClient
import prepare, rusage

HERE = os.path.dirname(os.path.abspath(__file__))
CUA = prepare.CUA
BRAUS = prepare.BRAUS
PROBE = prepare.PROBE
PHASES_BIN = os.environ.get("BRAUS_PHASES_BIN", os.path.join(HERE, ".build-phases/release/braus-mcp-stdio"))
PHASE_TABLE = os.path.join(HERE, "../Phases/phase-table.py")
REST_DELAY_S = 2.5          # ADR 0036: the window stream rests after this long without a use
TEXT_CHARS_PER_TOKEN = 4
# Changed pixels a window shows with nothing done to it: a blinking text caret (about 2 x 20 pt) or a
# terminal's block cursor (about 8 x 18 pt). Above this, the pixels confirm an effect.
PIXEL_NOISE = 200
REPLY_CHARS = 2000          # reply text kept in the row of a failed step, and of the reply before it
PIXEL_DIR = None            # where the probe keeps the gray captures it compares; set by main()

# What an independent oracle looks for after each kind of operation: the probe parts that must change; `oracle()`
# adds the bound window's "pixels" for scrolls and `pixels` scenarios. A fourth element `False` leaves it unverified.
ORACLE = {"click": ["values", "selection", "focus", "windows"], "type": ["values", "selection"],
          "key": ["values", "selection", "focus"], "hotkey": ["values", "selection", "focus"],
          "scroll_down": ["scroll"], "scroll_up": ["scroll"]}


# One operation: a name, then what each driver calls, then optionally its oracle. A cua argument
# {"label": ..} names an element (a run_actions `name`, or the element_token of the latest read for
# cua-legacy); {"at": (fx, fy)} is window-local screenshot pixels. "{rep}" in a string is the repetition.
def scroll(direction, oracle="default"):
    return (f"scroll_{direction}", ("scroll", {"direction": direction, "lines": 3}),
            ("scroll", {"direction": direction, "amount": 3}), oracle)


def menu(op, path, oracle="default"):
    return (op, ("menu", {"path": " > ".join(path)}), ("invoke_menu", {"path": path}), oracle)


SCENARIOS = {
    "Calculator": dict(framework="SwiftUI", process="Calculator", chain=["click", "key"], ops=[
        ("click", ("act", {"target": "7"}), ("click", {"label": "7", "role": "AXButton"}), ["values"]),
        ("key", ("press_key", {"key": "escape"}), ("press_key", {"key": "escape"}), ["values"]),
        menu("menu", ["View", "Basic"]),
    ]),
    "TextEdit": dict(framework="AppKit", process="TextEdit", chain=["key", "hotkey", "scroll_down", "scroll_up"],
                     # Undo not confirmed by its shortcut gets Edit > Undo as a row of its own; both are kept.
                     fallback={"undo": menu("undo_menu", ["Edit", "Undo"], ["values"])},
                     unknown_value="the whole document, around a caret the harness does not read", ops=[
        # The insert opens a new line below line two, so the click's label never changes between reps.
        ("click", ("act", {"target": "Line two."}), ("click", {"at": (0.06, 0.115)}), ["selection"]),
        ("hotkey", ("press_key", {"key": "right", "modifiers": ["cmd"]}), ("hotkey", {"keys": ["cmd", "right"]})),
        ("type", ("insert_text", {"text": "\nbench"}), ("type_text", {"text": "\nbench"}), ["values"]),
        # Undo takes the insert back, so every repetition starts from the same text.
        ("undo", ("press_key", {"key": "z", "modifiers": ["cmd"]}), ("hotkey", {"keys": ["cmd", "z"]}), ["values"]),
        ("key", ("press_key", {"key": "left"}), ("press_key", {"key": "left"})),
        scroll("down"), scroll("up"),
        menu("menu", ["Edit", "Select All"], ["selection"]),
    ]),
    "Google Chrome": dict(framework="Chromium", process="Google Chrome", pixels=True,
                          chain=["key", "hotkey", "scroll_down", "scroll_up"], ops=[
        ("click", ("act", {"target": "Press me"}), ("click", {"label": "Press me", "role": "AXButton"}), ["values"]),
        ("type", ("type_text", {"target": "Name", "text": "hello{rep}"}),
                 ("type_text", {"label": "Name", "role": "AXTextField", "text": "hello{rep}"}), ["values"]),
        ("key", ("press_key", {"key": "tab"}), ("press_key", {"key": "tab"})),
        ("hotkey", ("press_key", {"key": "tab", "modifiers": ["shift"]}), ("hotkey", {"keys": ["shift", "tab"]})),
        scroll("down"), scroll("up"),
        menu("menu", ["View", "Always Show Bookmarks Bar"]),
    ]),
    "Prism Launcher": dict(framework="Qt 6", process="prismlauncher", pixels=True, ops=[
        ("click", ("act", {"target": "Meow"}), ("click", {"label": "Meow", "role": "AXCheckBox"}), ["values"]),
        ("key", ("press_key", {"key": "escape"}), ("press_key", {"key": "escape"})),
    ]),
    "kitty": dict(framework="OpenGL (GLFW)", process="kitty", pixels=True,
                  unknown_value="the terminal's whole text, prompt and scrollback included", ops=[
        # A shell comment: should Ctrl-U not clear it, the Return below still runs no command.
        ("type", ("insert_text", {"text": "# bench {rep}"}), ("type_text", {"text": "# bench {rep}"})),
        ("hotkey", ("press_key", {"key": "u", "modifiers": ["ctrl"]}), ("hotkey", {"keys": ["ctrl", "u"]})),
        # Return on the emptied line prints a new prompt: a visible effect, where Left there moved nothing.
        ("key", ("press_key", {"key": "return"}), ("press_key", {"key": "return"})),
        scroll("up"), scroll("down"),
    ]),
    "Safari": dict(framework="WebKit (Safari)", process="Safari", window="Personal — Bench Page",
                   untitled_session=True, ops=[
        ("click", ("act", {"target": "Press me"}), ("click", {"label": "Press me", "role": "AXButton"}), ["values"]),
        ("type", ("type_text", {"target": "Name", "text": "hello{rep}"}),
                 ("type_text", {"label": "Name", "role": "AXTextField", "text": "hello{rep}"}), ["values"]),
        ("key", ("press_key", {"key": "tab"}), ("press_key", {"key": "tab"})),
        ("hotkey", ("press_key", {"key": "tab", "modifiers": ["shift"]}), ("hotkey", {"keys": ["shift", "tab"]})),
        scroll("down"), scroll("up"),
        # Zoom in, then back to actual size, so each item is enabled when it is pressed.
        menu("menu", ["View", "Zoom In"]), menu("menu_back", ["View", "Actual Size"]),
    ]),
    "Stocks": dict(framework="Mac Catalyst", process="Stocks", window="Stocks", pixels=True, ops=[
        ("key", ("press_key", {"key": "tab"}), ("press_key", {"key": "tab"})),
        scroll("down"), scroll("up"),
    ]),
    "Obsidian": dict(framework="Electron", process="Obsidian", pixels=True, ops=[
        ("click", ("act", {"target": "More options"}), ("click", {"label": "More options", "role": "AXButton"})),
        ("key", ("press_key", {"key": "escape"}), ("press_key", {"key": "escape"})),
        ("hotkey", ("press_key", {"key": "o", "modifiers": ["cmd"]}), ("hotkey", {"keys": ["cmd", "o"]})),
        # Cmd-O opens the quick switcher with an empty query, so the field's whole value is the inserted text.
        ("type", ("insert_text", {"text": "Driver", "expected_value": "Driver"}), ("type_text", {"text": "Driver"})),
        ("key_close", ("press_key", {"key": "escape"}), ("press_key", {"key": "escape"})),
    ]),
    "DaVinci Resolve": dict(framework="Qt + GPU (Resolve)", process="Resolve", pixels=True, ops=[
        ("click", ("act", {"target": "Thumbnail View"}), ("click", {"label": "Thumbnail View", "role": "AXCheckBox"})),
        ("click_back", ("act", {"target": "List View"}), ("click", {"label": "List View", "role": "AXCheckBox"})),
        # No Escape here: it closes the Project Manager, and Resolve quits with no project open.
        scroll("down"), scroll("up"),
    ]),
    # Works in the background and never saves: the document is closed with Don't Save. Known hazards, recorded
    # and not worked around: a "Start Bar" window can make Braus's adoption refuse (moveRefused), and right
    # after a new document Photoshop can be "not ready" for about 2 s.
    "Photoshop": dict(framework="Adobe (proprietary toolkit)", process_prefix="Adobe Photoshop", rebind="front",
                      pixels=True, ops=[
        menu("new_doc", ["File", "New..."], ["windows"]),
        ("new_doc_confirm", ("press_key", {"key": "return"}), ("press_key", {"key": "return"}), ["windows"]),
        # A blank canvas turned 180 degrees and a canvas that fits its window show no change, in AX or in pixels.
        menu("menu_rotate", ["Image", "Image Rotation", "180°"], False),
        menu("menu_rotate_back", ["Image", "Image Rotation", "180°"], False),
        # X swaps the foreground and background swatches of the toolbar: the pixels show it.
        ("key", ("press_key", {"key": "x"}), ("press_key", {"key": "x"})),
        scroll("down", False), scroll("up", False),
        menu("close_doc", ["File", "Close"], ["windows"]),
        ("dont_save", ("press", {"button": "Don't Save"}), ("click", {"label": "Don't Save", "role": "AXButton"}),
         ["windows"]),
    ]),
}
# Rows that are not an operation under test: they carry no success verdict.
NOT_ACTIONS = {"observe", "observe_unchanged", "observe_after", "list_windows", "open_session", "close_session",
               "open_session_untitled", "idle", "baseline", "startup", "soak_mem", "chain_step", "block_aborted",
               "target", "state_reset"}
BAD_STATUS = ("error", "refused", "failed", "honest_miss", "ambiguous")
RUN_TOOLS = {"click", "press_key", "hotkey", "type_text", "scroll"}
ROLES = {"AXButton": "button", "AXCheckBox": "checkbox", "AXTextField": "textfield"}
WINDOW_SERVER = None


class Dead(Exception):
    """The driver process stopped answering or exited: the block ends."""


def target_for(app, scenario, fixtures):
    """(pid, window title or None, app name Braus opens) of the running target; RuntimeError if absent."""
    fixture = fixtures.get(app) or {}
    if "process_prefix" in scenario:
        name = prepare.process_name(scenario["process_prefix"])
        pid = prepare.process_pid(scenario["process_prefix"], prefix=True)
    else:
        name = app
        pid = fixture.get("pid") or prepare.process_pid(scenario["process"])
    if not pid:
        raise RuntimeError(f"{app} is not running")
    title = fixture.get("window") or scenario.get("window")
    # The window list names Chrome's window "<page> - Google Chrome"; both drivers see only "<page>".
    if title and title.endswith(" - Google Chrome"):
        title = title[:-len(" - Google Chrome")]
    if app == "Obsidian":
        # The title names the active note too: bind by the vault's part, as the window is titled now.
        titles = [w.get("title", "") for w in probe(pid).get("windows", [])]
        title = next((t for t in titles if prepare.OBSIDIAN_VAULT in t), prepare.OBSIDIAN_VAULT)
    return pid, title, name


HOME_FRONT = (None, None)


def window_server():
    global WINDOW_SERVER
    WINDOW_SERVER = WINDOW_SERVER or prepare.process_pid("WindowServer")
    return WINDOW_SERVER


def probe(pid, pixels=None, against=None, window=None):
    """The probe's reading; with `pixels`, the gray capture of the window with id `window` is kept in that file
    and, with `against`, compared with an earlier one."""
    argv = [PROBE, str(pid)] + (["--pixels", pixels, "--window", str(window or 0)] if pixels else []) \
        + (["--against", against] if against else [])
    try:
        return json.loads(subprocess.run(argv, capture_output=True, text=True, timeout=10).stdout)
    except Exception as error:
        return {"error": str(error)}


def decide(expect, before, after):
    """(verified, verified_by) of an operation: True/False/None and "ax", "pixels", or, left undecided,
    "pixels_small" (a change no larger than a caret blink), "pixels_window_changed" (the two captures are of
    different windows or sizes, so nothing was compared) or "pixels_unavailable" (no capture to compare)."""
    parts_b, parts_a = before.get("parts"), after.get("parts")
    if not expect or not parts_b or not parts_a:
        return None, None
    if any(parts_b.get(p) != parts_a.get(p) for p in expect if p != "pixels"):
        return True, "ax"
    if "pixels" not in expect:
        return False, "ax"
    shot_b, shot_a = before.get("pixels") or {}, after.get("pixels") or {}
    if not shot_b.get("width") or not shot_a.get("width"):
        return None, "pixels_unavailable"
    frame = lambda shot: (shot.get("window"), shot.get("width"), shot.get("height"))  # noqa: E731
    if frame(shot_b) != frame(shot_a):
        return None, "pixels_window_changed"
    changed = shot_a.get("changed")
    if changed is None:
        return None, "pixels_unavailable"
    if changed > PIXEL_NOISE:
        return True, "pixels"
    return (None, "pixels_small") if changed else (False, "pixels")


def bound_window(pid, title=None):
    """The window server id of the target's window titled with `title` (a part of it, as Cua matches), or
    without a title of its front window above 100 px, as Cua binds; None when there is no such window."""
    found = [w for w in probe(pid).get("windows", []) if w.get("w", 0) > 100 and w.get("h", 0) > 100
             and (title is None or title in (w.get("title") or ""))]
    found.sort(key=lambda w: not w.get("onscreen"))  # stable: onscreen first, each group front to back
    return found[0]["id"] if found else None


def reply_text(reply):
    """The text a client forwards to the model, bounded."""
    text = " ".join(item.get("text", "") for item in (reply.get("result") or {}).get("content", [])
                    if item.get("type") == "text")
    if not text and reply.get("error"):
        text = json.dumps(reply["error"])
    return text[:REPLY_CHARS]


def image_tokens(width, height):
    """Anthropic's image estimate: resized to fit 1568 px and 1.15 MP, then w*h/750."""
    scale = min(1.0, 1568 / max(width, height), math.sqrt(1_150_000 / (width * height)))
    return math.ceil((width * scale) * (height * scale) / 750)


def payload(reply):
    """Bytes on the wire, and what a client that forwards `content` puts in the model's context."""
    result = reply.get("result") or {}
    text = sum(len(item.get("text", "")) for item in result.get("content", []) if item.get("type") == "text")
    images = [item for item in result.get("content", []) if item.get("type") == "image"]
    structured = len(json.dumps(result["structuredContent"])) if "structuredContent" in result else 0
    return text, images, structured


def reply_body(reply):
    texts = " ".join(item.get("text", "") for item in (reply.get("result") or {}).get("content", [])
                     if item.get("type") == "text")
    if texts.startswith("{"):
        try:
            return json.loads(texts)
        except ValueError:
            pass
    return None


def self_verdict(reply):
    """What the driver itself claims about the effect: Cua's `effect`, Braus's outcome status."""
    structured = (reply.get("result") or {}).get("structuredContent") or {}
    if "effect" in structured:
        return structured["effect"] if isinstance(structured["effect"], str) else json.dumps(structured["effect"])[:60]
    if "steps" in structured and structured["steps"]:
        step = structured["steps"][0]
        return step.get("effect") or ("ok" if step.get("ok") else "failed")
    body = reply_body(reply) or {}
    return body.get("status") or (body.get("outcome") or {}).get("status")


def failed(reply):
    """Why the call did not do its job, or None. An honest_miss and a failed delivery are failures."""
    result = reply.get("result")
    if result is None:
        return reply.get("error", {}).get("message", "protocol error")
    if result.get("isError"):
        return " ".join(item.get("text", "") for item in result.get("content", []))[:300]
    structured = result.get("structuredContent") or {}
    if structured.get("ok") is False or structured.get("failed_step") is not None:
        bad = next((s for s in structured.get("steps", []) if s.get("ok") is False), {})
        return f"run_actions step {structured.get('failed_step')}: {bad.get('message') or bad.get('error') or 'failed'}"[:300]
    body = reply_body(reply) or {}
    message = body.get("message") or ""
    if body.get("status") in BAD_STATUS:
        return f"{body['status']}: {message}"[:300]
    if body.get("status") == "acted_unverified" and "delivery failed" in message:
        return message[:300]
    if structured.get("effect") in ("refused", "failed"):
        return f"effect {structured['effect']}"
    return None


def moved(a, b, limit=1.0):
    return bool(a and b) and math.dist(a, b) > limit


def user_windows(reading):
    """Substantial onscreen windows of the target on a display that is not the Seat's."""
    return sum(1 for w in reading.get("windows", []) if w.get("onscreen") and not w.get("seat")
               and w.get("display", -1) != -1 and w.get("w", 0) > 100 and w.get("h", 0) > 100)


def sub(a, b, key, scale=1e6):
    return (b[key] - a[key]) / scale if a and b else None


class Recorder:
    def __init__(self, path, meta, call_timeout):
        self.file = open(path, "a")
        self.meta = meta
        self.ctx = {}
        self.timeout = call_timeout
        self.last_end = {}
        self.last = None
        self.last_reply = {}       # per client: (op, text) of its previous reply
        self.pixel_control = False  # reads with no action also compare pixels: the noise floor of the app

    def write(self, row):
        self.file.write(json.dumps(row) + "\n")
        self.file.flush()

    def row(self, **fields):
        return dict(self.meta, **self.ctx, **fields)

    def guarded(self, client, name, arguments):
        """The call, with its stdio server killed (our own child, by handle) when no reply comes."""
        fired = []
        def stop():
            fired.append(True)
            client.proc.kill()
        timer = threading.Timer(self.timeout, stop)
        timer.start()
        try:
            return client.call(name, arguments), False
        finally:
            timer.cancel()
            self.stalled = bool(fired)

    def measure(self, client, driver, app, framework, op, rep, name, arguments, target_pid, settle=0.25,
                light=False, expect=None, window=None, **extra):
        """One call. `light` skips the probes and the settle, for chain and soak steps whose timing counts.
        `window` is the window server id of the window the driver is bound to: the only one the pixels read."""
        pid = getattr(client, "driver_pid", client.pid)
        proxy = client.pid if pid != client.pid else None
        pixels = not light and PIXEL_DIR and ("pixels" in (expect or []) or
                                              (self.pixel_control and op == "observe_unchanged"))
        shots = [os.path.join(PIXEL_DIR, f"{side}.gray") for side in ("before", "after")] if pixels else [None, None]
        before = {} if light else probe(target_pid, shots[0], window=window)
        ws = None if light else window_server()
        cursor0 = rusage.cursor()
        d0, a0, p0 = rusage.sample(pid), rusage.sample(target_pid), rusage.sample(proxy) if proxy else None
        w0 = rusage.ps_cpu_ns(ws) if ws else None
        started = time.perf_counter()
        gap = started - self.last_end[id(client)] if id(client) in self.last_end else None
        try:
            (seconds, size, reply), _ = self.guarded(client, name, arguments)
            error = failed(reply)
        except Exception as exception:
            seconds, size, reply, error = None, 0, {}, f"exception: {exception}"
        timed_out = self.stalled
        self.last_end[id(client)] = time.perf_counter()
        if timed_out:
            error = f"stall: no reply in {self.timeout:.0f} s, driver killed"
        d1, a1, p1 = rusage.sample(pid), rusage.sample(target_pid), rusage.sample(proxy) if proxy else None
        w1 = rusage.ps_cpu_ns(ws) if ws else None
        cursor1 = rusage.cursor()
        if not light:
            time.sleep(settle)
        after = {} if light else probe(target_pid, shots[1], shots[0], window=window)
        text, images, structured = payload(reply)
        sizes = [s for s in image_sizes(reply) if s]
        image_toks = sum(image_tokens(*s) for s in sizes)
        verified, verified_by = decide(expect, before, after)
        success = None
        if op not in NOT_ACTIONS:
            success = False if error is not None or verified is False else (True if verified else None)
        previous = self.last_reply.get(id(client))
        self.last_reply[id(client)] = (op, reply_text(reply))
        # A failed step keeps what the driver answered and what it showed just before, for the reader.
        kept = dict(reply_text=reply_text(reply), observe_before_op=previous and previous[0],
                    observe_before_text=previous and previous[1]) if error is not None or success is False else {}
        shown = lambda reading: (reading.get("pixels") or {})  # noqa: E731
        changed_front = (before.get("frontmost") != after.get("frontmost")) if before and after else None
        observation = ((reply.get("result") or {}).get("structuredContent") or {}).get("observation")
        row = self.row(driver=driver, app=app, framework=framework, op=op, rep=rep, tool=name,
                       ms=None if seconds is None else seconds * 1000, ok=error is None, error=error,
                       self_verdict=self_verdict(reply), reply_bytes=size, text_chars=text,
                       structured_bytes=structured, images=len(images), image_px=[list(s) for s in sizes],
                       image_tokens=image_toks, tokens_text=text / TEXT_CHARS_PER_TOKEN,
                       tokens=text / TEXT_CHARS_PER_TOKEN + image_toks,
                       observe_ok=observation.get("ok") if isinstance(observation, dict) else None,
                       driver_cpu_ms=sub(d0, d1, "cpu_ns"), proxy_cpu_ms=sub(p0, p1, "cpu_ns"),
                       driver_instructions=sub(d0, d1, "instructions", 1),
                       driver_energy_mj=sub(d0, d1, "energy_nj"),
                       driver_footprint_mb=d1["footprint"] / 2**20 if d1 else None,
                       driver_peak_mb=d1["peak_footprint"] / 2**20 if d1 else None,
                       proxy_footprint_mb=p1["footprint"] / 2**20 if p1 else None,
                       app_cpu_ms=sub(a0, a1, "cpu_ns"), app_energy_mj=sub(a0, a1, "energy_nj"),
                       app_footprint_mb=a1["footprint"] / 2**20 if a1 else None,
                       windowserver_cpu_ms=(w1 - w0) / 1e6 if w0 is not None and w1 is not None else None,
                       gap_s=gap,
                       stream_resting=(gap is not None and gap > REST_DELAY_S) if driver == "braus" else None,
                       expect=expect or None, verified=verified, verified_by=verified_by, success=success,
                       pixels_changed=shown(after).get("changed"),
                       pixels_total=shown(after).get("width", 0) * shown(after).get("height", 0) or None,
                       pixel_windows=[shown(before).get("window"), shown(after).get("window")] if pixels else None,
                       frontmost_before=before.get("frontmost"), frontmost_after=after.get("frontmost"),
                       frontmost_changed=changed_front,
                       frontmost_names=[before.get("frontmostName"), after.get("frontmostName")]
                       if changed_front else None,
                       cursor_moved=moved(before.get("cursor"), after.get("cursor")) if before and after else None,
                       cursor_moved_call=moved(cursor0, cursor1),
                       user_windows_before=user_windows(before) if before else None,
                       user_windows_after=user_windows(after) if after else None,
                       window_on_user_display=(user_windows(after) > user_windows(before)) if before and after else None,
                       effect_seen=before.get("digest") != after.get("digest") if before and after else None,
                       digest_before=before.get("digest"), digest_after=after.get("digest"),
                       target_pid=target_pid, **kept, **extra)
        self.write(row)
        self.last = row
        ms = row["ms"]
        print(f"  {'ok ' if row['ok'] else 'ERR'} {driver:11} {app:15} {op:16} r{rep} "
              f"{'   -    ' if ms is None else f'{ms:8.1f}'} ms {size:>8} B"
              + ("" if row["ok"] else f"  {str(error)[:120]}"), flush=True)
        if timed_out or (error and client.proc.poll() is not None):
            raise Dead(error)
        return reply

    def failure(self, driver, app, framework, op, rep, error, **extra):
        """A step the harness could not even send (no element, no window): a failed row with no timing."""
        row = self.row(driver=driver, app=app, framework=framework, op=op, rep=rep, ms=None, ok=False, error=error,
                       success=False if op not in NOT_ACTIONS else None, **extra)
        self.write(row)
        self.last = row
        print(f"  ERR {driver:11} {app:15} {op:16} r{rep}  {error[:120]}", flush=True)


def image_sizes(reply):
    """Each image's pixel size, read from its PNG or JPEG header."""
    import base64, struct
    sizes = []
    for item in (reply.get("result") or {}).get("content", []):
        if item.get("type") != "image":
            continue
        head = base64.b64decode(item["data"][:400] + "=" * (-len(item["data"][:400]) % 4))
        if head[:8] == b"\x89PNG\r\n\x1a\n":
            sizes.append(struct.unpack(">II", head[16:24]))
        else:
            sizes.append(_jpeg_size(base64.b64decode(item["data"])))
    return sizes


def _jpeg_size(data):
    import struct
    i = 2
    while i < len(data):
        marker, length = data[i + 1], struct.unpack(">H", data[i + 2:i + 4])[0]
        if marker in (0xC0, 0xC1, 0xC2):
            height, width = struct.unpack(">HH", data[i + 5:i + 9])
            return width, height
        i += 2 + length
    return None


def fill(arguments, rep):
    return {k: v.format(rep=rep) if isinstance(v, str) and "{rep}" in v else v for k, v in arguments.items()}


def normal(label):
    return label.replace("’", "'").replace("…", "...")


class Cua:
    """Launch variants, every other Cua default kept (including its post-action window watch):

    cua          cua-driver mcp --direct: the MCP process owns the runtime, no agent cursor overlay.
    cua-overlay  the daemon-backed path, whose daemon owns the AppKit loop the overlay needs (on by default
                 there). With /Applications/CuaDriver.app installed, a bare `cua-driver mcp` proxies to the
                 daemon the way the README describes. Without it, the harness is the embedding host
                 (Skills/cua-driver/EMBEDDING.md): `serve --embedded` as its own child on a private socket,
                 then `mcp --embedded --socket`. The two cases are recorded in the startup row.
    cua-fast     opt-in floor: CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS=0 drops the post-action watch.
    cua-legacy   as cua, but acting the 6 October way: the action, then a full get_window_state
                 (full_output, element tokens). The secondary series `step_legacy`.

    Telemetry is off in all of them (CUA_DRIVER_RS_TELEMETRY_ENABLED=0). Every call carries a session label."""

    SESSION = "bench"
    APP = "/Applications/CuaDriver.app"

    def __init__(self, recorder, log, variant="cua", scratch=None):
        self.recorder = recorder
        self.name = variant
        self.legacy = variant == "cua-legacy"
        self.daemon = None
        env = dict(os.environ, CUA_DRIVER_RS_TELEMETRY_ENABLED="0")
        if variant == "cua-fast":
            env["CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS"] = "0"
        self.launch = "direct"
        started = time.perf_counter()
        if variant == "cua-overlay" and os.path.isdir(self.APP):
            self.launch, argv = "app-daemon", [CUA, "mcp"]
        elif variant == "cua-overlay":
            self.launch = "embedded-daemon"
            socket_path = os.path.join(scratch, "cua.sock")
            embedded = dict(env, CUA_DRIVER_EMBEDDED="1")
            if os.path.exists(socket_path):
                os.remove(socket_path)
            self.daemon = subprocess.Popen([CUA, "serve", "--embedded", "--socket", socket_path],
                                           stdin=subprocess.PIPE, stdout=log, stderr=log, env=embedded)
            deadline = time.time() + 15
            while not os.path.exists(socket_path):
                if self.daemon.poll() is not None or time.time() > deadline:
                    raise RuntimeError("cua-driver serve --embedded did not open its socket")
                time.sleep(0.1)
            env, argv = embedded, [CUA, "mcp", "--embedded", "--socket", socket_path]
        else:
            argv = [CUA, "mcp", "--direct"]
        self.client = MCPClient(argv, stderr=log, env=env)
        # Resource rows read the process that does the work: the daemon, not its stdio proxy.
        self.client.driver_pid = self.daemon.pid if self.daemon else self.client.pid
        self.startup_ms = (time.perf_counter() - started) * 1000
        self.state = self.shot = None
        self.pid = self.window = None
        self.last_tool = None
        self.client.call("start_session", {"session": self.SESSION})

    def startup_row(self):
        return dict(driver=self.name, op="startup", ms=self.startup_ms, ok=True, launch=self.launch)

    def close(self):
        try:
            self.client.call("end_session", {"session": self.SESSION})
        except Exception:
            pass
        self.client.close()
        if self.daemon:
            # Our own child only: closing its stdin is the documented stop, terminate by PID if it lingers.
            self.daemon.stdin.close()
            try:
                self.daemon.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.daemon.terminate()

    def bind(self, pid, title=None):
        """Binds the top window above 100 px (matching `title` when given); True when the window changed."""
        reply = self.client.call("list_windows", {"pid": pid, "session": self.SESSION})[2]
        windows = [w for w in reply["result"]["structuredContent"]["windows"]
                   if w["bounds"]["width"] > 100 and w["bounds"]["height"] > 100
                   and (title is None or title in (w.get("title") or ""))]
        windows.sort(key=lambda w: w.get("z_index", 0), reverse=True)
        if not windows:
            raise RuntimeError(f"no window above 100 px for pid {pid} (Stage Manager stash or minimized?)")
        changed = (pid, windows[0]["window_id"]) != (self.pid, self.window)
        self.pid, self.window = pid, windows[0]["window_id"]
        return changed

    def open(self, app, framework, rep, target, scenario):
        pid, title, _ = target
        try:
            self.bind(pid, title)
        except RuntimeError as error:
            self.recorder.failure(self.name, app, framework, "open_session", rep, str(error))
            return False
        self.recorder.measure(self.client, self.name, app, framework, "list_windows", 0, "list_windows",
                              {"pid": pid, "session": self.SESSION}, pid)
        return True

    def read(self, app, framework, op, rep, pid, light=False, **extra):
        """A window read. Full: the 6 October payload for cua-legacy, Cua's default read otherwise.
        Diff: `since:"latest"` without a screenshot, the re-read its docs recommend."""
        arguments = {"pid": self.pid, "window_id": self.window, "session": self.SESSION}
        if op == "observe":
            arguments |= {"full_output": True} if self.legacy else {}
        elif not self.legacy:
            arguments |= {"since": "latest", "include_screenshot": False}
        else:
            arguments |= {"full_output": True}
        reply = self.recorder.measure(self.client, self.name, app, framework, op, rep, "get_window_state",
                                      arguments, pid, light=light, window=self.window, **extra)
        structured = (reply.get("result") or {}).get("structuredContent") or {}
        if op != "observe" and not self.legacy:
            return
        self.state = structured
        sizes = image_sizes(reply)
        self.shot = tuple(sizes[0]) if sizes else (structured.get("screenshot_width"), structured.get("screenshot_height"))

    def start_rep(self, app, framework, rep, pid):
        self.read(app, framework, "observe", rep, pid)
        if not self.legacy:
            self.read(app, framework, "observe_unchanged", rep, pid)

    def named(self, arguments):
        """run_actions arguments naming the target by role and name, or by pixels of the last screenshot."""
        arguments = dict(arguments)
        label, role, at = arguments.pop("label", None), arguments.pop("role", None), arguments.pop("at", None)
        if label is not None:
            arguments["name"] = label
            if role:
                arguments["role"] = ROLES.get(role, role.removeprefix("AX").lower())
        if at is not None:
            if not self.shot or None in self.shot:
                raise RuntimeError("no screenshot size for a pixel target")
            arguments["x"], arguments["y"] = round(at[0] * self.shot[0]), round(at[1] * self.shot[1])
        return arguments

    def resolve(self, arguments):
        """cua-legacy: the element_token of the latest full read, as on 6 October."""
        arguments = dict(arguments)
        label, role, at = arguments.pop("label", None), arguments.pop("role", None), arguments.pop("at", None)
        if label is not None:
            matches = [e for e in (self.state or {}).get("elements", [])
                       if normal(e.get("label") or "") == normal(label) and (role is None or e.get("role") == role)]
            if not matches:
                raise RuntimeError(f"no element {label!r} {role}")
            arguments["element_token"] = matches[0]["element_token"]
        if at is not None:
            arguments["x"] = round(at[0] * self.state["screenshot_width"])
            arguments["y"] = round(at[1] * self.state["screenshot_height"])
        return dict(arguments, pid=self.pid, window_id=self.window, session=self.SESSION)

    def act(self, app, framework, op, rep, spec, target, expect, rebind=None, light=False, **extra):
        name, arguments = spec[0], fill(spec[1], rep)
        pid = target[0]
        self.last_tool = name
        try:
            changed = self.bind(pid) if rebind == "front" else False
            if self.legacy and (changed or self.state is None):
                self.state = self.client.call("get_window_state", {
                    "pid": self.pid, "window_id": self.window, "session": self.SESSION,
                    "full_output": True})[2]["result"]["structuredContent"]
            base = {"pid": self.pid, "window_id": self.window, "session": self.SESSION}
            if name == "invoke_menu":
                tool, call = name, dict(arguments, **base)
            elif self.legacy:
                tool, call = name, self.resolve(arguments)
            elif name in RUN_TOOLS:
                tool, call = "run_actions", dict(base, steps=[{"tool": name, "args": self.named(arguments)}],
                                                 observe=True)
            else:
                raise RuntimeError(f"no Cua equivalent of {name}")
        except Dead:
            raise
        except Exception as error:
            self.recorder.failure(self.name, app, framework, op, rep, f"harness: {error}", **extra)
            return self.recorder.last
        self.recorder.measure(self.client, self.name, app, framework, op, rep, tool, call, pid,
                              light=light, expect=expect, window=self.window, **extra)
        return self.recorder.last

    def after(self, app, framework, op, rep, target, rebind=None, light=False, **extra):
        """The observation a step needs after its action: cua-legacy always, others only after a menu
        (run_actions has no menu step), as a diff read."""
        if not self.legacy and self.last_tool != "invoke_menu":
            return None
        try:
            if rebind == "front":
                self.bind(target[0])
            self.read(app, framework, "observe_after", rep, target[0], light=light, after_op=op, **extra)
        except Dead:
            raise
        except Exception as error:
            self.recorder.failure(self.name, app, framework, "observe_after", rep, f"harness: {error}",
                                  after_op=op, **extra)
        return self.recorder.last

    def release(self, app, framework, rep, pid):
        pass


class Braus:
    name = "braus"

    def __init__(self, recorder, log, knowledge, binary=None):
        self.recorder = recorder
        env = dict(os.environ, BRAUS_BENCH_UNVALIDATED="1")
        started = time.perf_counter()
        self.client = MCPClient([binary or BRAUS, knowledge], stderr=log, env=env)
        self.startup_ms = (time.perf_counter() - started) * 1000
        self.session = None
        self.window = None
        self.launch = "phases" if binary else "release"

    def startup_row(self):
        return dict(driver="braus", op="startup", ms=self.startup_ms, ok=True, launch=self.launch)

    def open(self, app, framework, rep, target, scenario, op="open_session"):
        pid, window, name = target
        arguments = {"app": name} | ({"window": window} if window else {})
        # Braus names no window id: the one titled as the session asks is the one its pixels are read from.
        self.window = bound_window(pid, window)
        reply = self.recorder.measure(self.client, "braus", app, framework, op, rep,
                                      "open_session", arguments, pid, settle=0.5)
        self.session = (reply_body(reply) or {}).get("session")
        return bool(self.session)

    def release(self, app, framework, rep, pid):
        if self.session:
            self.recorder.measure(self.client, "braus", app, framework, "close_session", rep,
                                  "close_session", {"session": self.session}, pid, settle=0.5)
        self.session = None

    def read(self, app, framework, op, rep, pid, full, light=False, **extra):
        return self.recorder.measure(self.client, "braus", app, framework, op, rep, "observe",
                                     {"session": self.session} | ({"full": True} if full else {}), pid,
                                     light=light, window=self.window, **extra)

    def start_rep(self, app, framework, rep, pid):
        self.read(app, framework, "observe", rep, pid, full=True)
        self.read(app, framework, "observe_unchanged", rep, pid, full=False)

    def act(self, app, framework, op, rep, spec, target, expect, rebind=None, light=False, **extra):
        if rebind == "front":
            self.window = bound_window(target[0])
        # Braus checks expected_value against the field's whole value: where the run cannot know it, the row says why.
        if spec[0] == "insert_text" and "expected_value" not in spec[1]:
            extra["expected_value_omitted"] = SCENARIOS.get(app, {}).get("unknown_value", "whole field value unknown")
        self.recorder.measure(self.client, "braus", app, framework, op, rep, spec[0],
                              dict(fill(spec[1], rep), session=self.session), target[0],
                              light=light, expect=expect, window=self.window, **extra)
        return self.recorder.last

    def after(self, *args, **kwargs):
        """Braus's action reply already carries the scene after it."""
        return None

    def close(self):
        self.client.close()


def new_driver(name, recorder, log, scratch, phases):
    if name.startswith("cua"):
        return Cua(recorder, log, name, scratch)
    knowledge = os.path.join(scratch, f"knowledge-{int(time.time() * 1000)}")
    os.makedirs(knowledge)
    return Braus(recorder, log, knowledge, PHASES_BIN if phases else None)


def oracle(op, entry, scenario=None):
    """The probe parts that confirm this operation, or None when the probe cannot see its effect."""
    given = entry[3] if len(entry) > 3 else "default"
    if given is False:
        return None
    parts = list(ORACLE.get(op) or []) if given == "default" else list(given)
    if (scenario or {}).get("pixels") or op.startswith("scroll"):
        parts.append("pixels")
    return parts or None


def spec_for(driver, entry):
    return entry[1] if driver.name == "braus" else entry[2]


def chain_entries(scenario):
    names = scenario.get("chain")
    return [e for e in scenario["ops"] if names is None or e[0] in names]


def idle_windows(recorder, driver, app, framework, pid, windows, seconds):
    """CPU the driver, the target and WindowServer spend while nothing is asked, in consecutive windows."""
    client, ws = driver.client, window_server()
    d_pid = getattr(client, "driver_pid", client.pid)
    proxy = client.pid if d_pid != client.pid else None
    ended = recorder.last_end.get(id(client), time.perf_counter())
    for index in range(1, windows + 1):
        started = time.perf_counter()
        d0, a0, p0, w0, c0 = rusage.sample(d_pid), rusage.sample(pid), rusage.sample(proxy) if proxy else None, \
            rusage.ps_cpu_ns(ws), rusage.cursor()
        time.sleep(seconds)
        d1, a1, p1, w1, c1 = rusage.sample(d_pid), rusage.sample(pid), rusage.sample(proxy) if proxy else None, \
            rusage.ps_cpu_ns(ws), rusage.cursor()
        row = recorder.row(driver=driver.name, app=app, framework=framework, op="idle", rep=0, tool=None, window=index,
                           since_last_call_s=started - ended, ms=(time.perf_counter() - started) * 1000, ok=True,
                           driver_cpu_ms=sub(d0, d1, "cpu_ns"), proxy_cpu_ms=sub(p0, p1, "cpu_ns"),
                           app_cpu_ms=sub(a0, a1, "cpu_ns"), driver_energy_mj=sub(d0, d1, "energy_nj"),
                           driver_wakeups=d1["wakeups"] - d0["wakeups"], driver_footprint_mb=d1["footprint"] / 2**20,
                           app_footprint_mb=a1["footprint"] / 2**20 if a1 else None,
                           windowserver_cpu_ms=(w1 - w0) / 1e6, cursor_moved_call=moved(c0, c1))
        recorder.write(row)
        print(f"  idle  {driver.name:11} {app:15} w{index} cpu {row['driver_cpu_ms']:.1f} ms  "
              f"app {row['app_cpu_ms'] or 0:.1f} ms  WS {row['windowserver_cpu_ms']:.0f} ms", flush=True)


def baseline(recorder, seconds, where):
    """WindowServer with no driver running, the floor every idle row is read against."""
    ws = window_server()
    w0, c0 = rusage.ps_cpu_ns(ws), rusage.cursor()
    time.sleep(seconds)
    row = recorder.row(driver="none", op="baseline", where=where, ms=seconds * 1000, ok=True,
                       windowserver_cpu_ms=(rusage.ps_cpu_ns(ws) - w0) / 1e6, cursor_moved_call=moved(c0, rusage.cursor()))
    recorder.write(row)
    print(f"  baseline {where} {seconds}s WS {row['windowserver_cpu_ms']:.0f} ms", flush=True)


def ops_block(driver, app, scenario, target, reps, options):
    framework, pid = scenario["framework"], target[0]
    if not driver.open(app, framework, reps[0], target, scenario):
        return
    for rep in [0] + reps:
        driver.start_rep(app, framework, rep, pid)
        for step, entry in enumerate(scenario["ops"]):
            op = entry[0]
            acted = driver.act(app, framework, op, rep, spec_for(driver, entry), target, oracle(op, entry, scenario),
                               rebind=scenario.get("rebind"), step=step)
            driver.after(app, framework, op, rep, target, rebind=scenario.get("rebind"), step=step)
            backup = scenario.get("fallback", {}).get(op)
            if backup and acted.get("success") is not True:
                driver.act(app, framework, backup[0], rep, spec_for(driver, backup), target,
                           oracle(backup[0], backup, scenario), rebind=scenario.get("rebind"), step=step,
                           fallback_for=op)
                driver.after(app, framework, backup[0], rep, target, rebind=scenario.get("rebind"), step=step,
                             fallback_for=op)
    idle_windows(driver.recorder, driver, app, framework, pid, options.idle_windows, options.idle_seconds)
    driver.release(app, framework, 0, pid)
    for rep in range(1, options.sessions + 1) if options.extra_sessions else []:
        if driver.open(app, framework, rep, target, scenario):
            driver.release(app, framework, rep, pid)
    # A session that names no window: for a browser, Braus opens a window of its own (ADR 0038).
    if options.extra_sessions and scenario.get("untitled_session"):
        if driver.open(app, framework, 0, (pid, None, target[2]), scenario, op="open_session_untitled"):
            driver.release(app, framework, 0, pid)


def chain_block(driver, app, scenario, target, options):
    """10 consecutive steps with a pause between them, for each pause, from the same resting start."""
    framework, pid = scenario["framework"], target[0]
    entries = chain_entries(scenario)
    if not driver.open(app, framework, 0, target, scenario):
        return
    for pause in options.pauses:
        # A rest longer than Braus's 2.5 s, so every group starts from a resting stream.
        time.sleep(options.group_rest)
        for index in range(options.chain_steps):
            entry = entries[index % len(entries)]
            op = entry[0]
            extra = dict(pause_s=pause, chain_step=index + 1)
            acted = driver.act(app, framework, op, index + 1, spec_for(driver, entry), target, None,
                               light=True, step=index, **extra)
            seen = driver.after(app, framework, op, index + 1, target, light=True, step=index, **extra)
            parts = [r for r in (acted, seen) if r]
            driver.recorder.write(driver.recorder.row(
                driver=driver.name, app=app, framework=framework, op="chain_step", rep=index + 1, **extra,
                tool=acted.get("tool"), step_op=op, gap_s=acted.get("gap_s"),
                stream_resting=acted.get("stream_resting"),
                ms=sum(r["ms"] for r in parts) if all(r.get("ms") is not None for r in parts) else None,
                ok=all(r.get("ok") for r in parts), error=next((r["error"] for r in parts if r.get("error")), None)))
            time.sleep(pause)
    driver.release(app, framework, 0, pid)


def soak_block(driver, app, scenario, target, options):
    """`soak_steps` neutral steps, the driver's and the target's footprint every `soak_every`."""
    framework, pid = scenario["framework"], target[0]
    entries = chain_entries(scenario)
    if not driver.open(app, framework, 0, target, scenario):
        return
    for n in range(1, options.soak_steps + 1):
        entry = entries[(n - 1) % len(entries)]
        driver.act(app, framework, entry[0], n, spec_for(driver, entry), target, None, light=True, soak_step=n)
        driver.after(app, framework, entry[0], n, target, light=True, soak_step=n)
        if n % options.soak_every == 0:
            client = driver.client
            d = rusage.sample(getattr(client, "driver_pid", client.pid))
            a = rusage.sample(pid)
            driver.recorder.write(driver.recorder.row(
                driver=driver.name, app=app, framework=framework, op="soak_mem", rep=0, soak_step=n, ok=True, ms=None,
                driver_footprint_mb=d["footprint"] / 2**20 if d else None,
                driver_peak_mb=d["peak_footprint"] / 2**20 if d else None,
                app_footprint_mb=a["footprint"] / 2**20 if a else None))
    driver.release(app, framework, 0, pid)


def desk(*argv):
    """One `desk` command (our own helper); its JSON answer, or the reason it gave none."""
    try:
        done = subprocess.run([prepare.DESK, *map(str, argv)], capture_output=True, text=True, timeout=15)
        return json.loads(done.stdout)
    except Exception as error:
        return {"ok": False, "error": str(error)}


def reset_state(app, scenario, fixtures):
    """Puts back what a block may have left, before the next one: TextEdit's text and scroll from the fixture,
    Photoshop's documents and dialogs closed without saving. None for every other app. Only on what the run
    opened: the fixture's own TextEdit window, a Photoshop that prepare.py launched (a person's open documents
    are never closed). Never an Escape to DaVinci Resolve: on its only window it quits (ADR 0039)."""
    if app not in ("TextEdit", "Photoshop"):
        return None
    fixture = fixtures.get(app) or {}
    if app == "TextEdit" and not str(fixture.get("window") or "").startswith("bench-"):
        return {"ok": False, "skipped": "no fixture window recorded by prepare.py"}
    if app == "Photoshop" and not fixture.get("launched"):
        return {"ok": False, "skipped": "Photoshop was not launched by prepare.py"}
    pid = target_for(app, scenario, fixtures)[0]
    if app == "TextEdit":
        done = desk("set-text", pid, fixture["window"], os.path.join(prepare.FIXTURES, "bench.txt"))
        return {"ok": done.get("ok"), "set_text": done}
    steps = {"ok": True}
    if any("Dialog" in w.get("role", "") + w.get("subrole", "") for w in probe(pid).get("axWindows", [])):
        steps["escape"] = desk("escape", pid)
        time.sleep(1)
    steps["close_all"] = desk("press", pid, "File", "Close All")
    for index in range(3):
        time.sleep(1.5)
        steps[f"dont_save_{index}"] = desk("button", pid, "Don't Save")
        if not steps[f"dont_save_{index}"].get("ok"):
            break
    steps["windows_after"] = [w.get("title") for w in probe(pid).get("axWindows", [])]
    return steps


def obsidian_refusal(fixtures):
    """Why the Obsidian block must not run, or None: only the run's own instance on its scratch vault, opened by
    prepare.py, may receive input. The 13 October run typed into a note of the person's vault."""
    fixture = fixtures.get("Obsidian") or {}
    pid = fixture.get("pid")
    if not fixture.get("scratch_vault") or not pid:
        return "refused: Obsidian was not opened by prepare.py on a scratch vault"
    profile = subprocess.run(["ps", "-o", "args=", "-p", str(pid)], capture_output=True, text=True).stdout
    if "user-data-dir=" not in profile or os.path.dirname(fixture["scratch_vault"]) not in profile:
        return f"refused: pid {pid} is not the run's own Obsidian"
    titles = [w.get("title", "") for w in probe(pid).get("axWindows", [])]
    if not titles or any(prepare.OBSIDIAN_VAULT not in t for t in titles):
        return f"refused: a window of pid {pid} is not on the scratch vault ({titles})"
    return None


def kitty_refusal(fixtures):
    """Why the kitty block must not run, or None: its Return reaches a shell, so only the kitty that prepare.py
    launched as its own process, on the run's config and with the run's window title, may receive input."""
    fixture = fixtures.get("kitty") or {}
    pid, config = fixture.get("pid"), fixture.get("config")
    if not fixture.get("launched") or not pid or not config:
        return "refused: kitty was not launched by prepare.py as the run's own instance"
    if config not in subprocess.run(["ps", "-o", "args=", "-p", str(pid)], capture_output=True, text=True).stdout:
        return f"refused: pid {pid} is not the run's own kitty"
    titles = [w.get("title", "") for w in probe(pid).get("axWindows", [])]
    if not titles or any(prepare.KITTY_TITLE not in t for t in titles):
        return f"refused: a window of pid {pid} is not the run's kitty window ({titles})"
    return None


def refusal(app, fixtures):
    """Why the app's block must not run, or None: Obsidian and kitty take input only in the run's own instance."""
    return {"Obsidian": obsidian_refusal, "kitty": kitty_refusal}.get(app, lambda _: None)(fixtures)


def schedule(drivers, reps, order):
    """[(driver, reps)] blocks: ABBA (forward then reversed), the odd repetition going to the forward pass."""
    first = (reps + 1) // 2
    if order == "forward" or len(drivers) < 2 or reps < 2:
        return [(d, list(range(1, reps + 1))) for d in drivers]
    return [(d, list(range(1, first + 1))) for d in drivers] + \
           [(d, list(range(first + 1, reps + 1))) for d in reversed(drivers)]


def run_app(app, drivers, options, recorder, log, fixtures):
    scenario = SCENARIOS[app]
    try:
        target_for(app, scenario, fixtures)
    except RuntimeError as error:
        recorder.failure("none", app, scenario["framework"], "target", 0, str(error))
        return
    refused = refusal(app, fixtures)
    if refused:
        recorder.failure("none", app, scenario["framework"], "target", 0, refused)
        return
    if options.mode == "ops":
        blocks = schedule(drivers, options.reps, options.order)
    elif options.mode == "chain" and options.order == "abba" and len(drivers) > 1:
        blocks = [(d, []) for d in drivers + drivers[::-1]]
    else:
        blocks = [(d, []) for d in drivers]
    seen = set()
    recorder.pixel_control = bool(scenario.get("pixels"))
    for index, (name, reps) in enumerate(blocks):
        if index:
            print(f"-- cooldown {options.cooldown} s", flush=True)
            time.sleep(options.cooldown)
        try:
            reset = reset_state(app, scenario, fixtures)
        except RuntimeError as error:
            reset = {"ok": False, "error": str(error)}
        if reset is not None:
            recorder.write(dict(recorder.meta, op="state_reset", app=app, block=index, **reset))
        refused = refusal(app, fixtures)
        if refused:
            recorder.write(recorder.row(driver=name, app=app, op="block_aborted", ok=False, error=refused))
            continue
        before = prepare.restore_front(HOME_FRONT)
        if before[0] != HOME_FRONT[0]:
            # Evidence of the previous block leaving another application in front of the person's.
            recorder.write(dict(recorder.meta, op="front_restored", app=app, driver=blocks[index - 1][0] if index else None,
                                block=index, left_in_front=before[1], ok=True))
        series = "step_legacy" if name == "cua-legacy" else "step"
        recorder.ctx = dict(mode=options.mode, block=index, series=series,
                            order_pass="forward" if index < len(drivers) else "reverse")
        print(f"== {app} · {name} · block {index} ({recorder.ctx['order_pass']})", flush=True)
        driver = None
        try:
            driver = new_driver(name, recorder, log, options.scratch, options.phases)
            recorder.write(recorder.row(**driver.startup_row()))
            options.extra_sessions = name == "braus" and name not in seen
            seen.add(name)
            target = target_for(app, scenario, fixtures)
            {"ops": lambda: ops_block(driver, app, scenario, target, reps, options),
             "chain": lambda: chain_block(driver, app, scenario, target, options),
             "soak": lambda: soak_block(driver, app, scenario, target, options)}[options.mode]()
        except Dead as error:
            print(f"  block aborted: {error}", flush=True)
            recorder.write(recorder.row(driver=name, app=app, op="block_aborted", ok=False, error=str(error)))
        except Exception as error:
            print(f"  block failed: {error}", flush=True)
            recorder.write(recorder.row(driver=name, app=app, op="block_aborted", ok=False, error=f"{error}"))
        finally:
            if driver:
                driver.close()
    recorder.ctx = {}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apps", default=",".join(s for s in SCENARIOS if s != "Photoshop"))
    parser.add_argument("--drivers", default="braus,cua,cua-overlay",
                        help="braus, cua, cua-overlay, cua-legacy (6 Oct action + full read), cua-fast")
    parser.add_argument("--mode", choices=["ops", "chain", "soak"], default="ops")
    parser.add_argument("--reps", type=int, default=8, help="measured repetitions per driver, split over ABBA passes")
    parser.add_argument("--order", choices=["abba", "forward"], default="abba")
    parser.add_argument("--cooldown", type=float, default=15, help="seconds between blocks")
    parser.add_argument("--sessions", type=int, default=3, help="extra Braus open/close cycles per app")
    parser.add_argument("--idle-windows", type=int, default=3)
    parser.add_argument("--idle-seconds", type=float, default=10)
    parser.add_argument("--pauses", default="0,1,3,5", help="chain mode: seconds between steps")
    parser.add_argument("--chain-steps", type=int, default=10)
    parser.add_argument("--group-rest", type=float, default=6, help="chain mode: rest before each pause group")
    parser.add_argument("--soak-steps", type=int, default=500)
    parser.add_argument("--soak-every", type=int, default=1, help="soak mode: footprint sample every N steps")
    parser.add_argument("--call-timeout", type=float, default=60, help="a call with no reply by then kills its driver")
    parser.add_argument("--phases", action="store_true", help="Braus from a BRAUS_PHASES build, with signposts")
    parser.add_argument("--out", required=True)
    parser.add_argument("--scratch", required=True)
    options = parser.parse_args()
    options.pauses = [float(p) for p in options.pauses.split(",")]
    apps, drivers = options.apps.split(","), options.drivers.split(",")
    if options.phases and drivers != ["braus"]:
        sys.exit("--phases runs braus alone: a phases build is slower and must never be mixed with timed drivers")
    if options.mode == "soak" and options.apps == parser.get_default("apps"):
        apps = ["TextEdit"]
    os.makedirs(options.scratch, exist_ok=True)
    global HOME_FRONT, PIXEL_DIR
    PIXEL_DIR = os.path.join(options.scratch, "pixels")
    os.makedirs(PIXEL_DIR, exist_ok=True)
    HOME_FRONT = prepare.home_front(list(SCENARIOS) + ["Adobe Photoshop", "DaVinci"])
    fixtures_path = os.path.join(options.scratch, "fixtures.json")
    fixtures = json.load(open(fixtures_path)) if os.path.exists(fixtures_path) else {}
    meta = {"run": time.strftime("%Y-%m-%dT%H:%M:%S"), "reps": options.reps, "phases": options.phases or None}
    recorder = Recorder(options.out, meta, options.call_timeout)
    recorder.write(dict(meta, kind="meta", mode=options.mode, order=options.order, apps=apps, selected=drivers,
                        pauses=options.pauses if options.mode == "chain" else None,
                        soak_steps=options.soak_steps if options.mode == "soak" else None,
                        cooldown=options.cooldown, idle=[options.idle_windows, options.idle_seconds],
                        fixtures=fixtures, **prepare.meta()))
    log = open(os.path.join(options.scratch, "drivers-stderr.log"), "a")
    phase_log = None
    if options.phases:
        phase_log = subprocess.Popen([sys.executable, PHASE_TABLE, "record", "--process", "braus-mcp-stdio",
                                      options.out + ".signposts.ndjson"],
                                     stdout=open(options.out + ".phases.txt", "w"), stderr=log)
        time.sleep(2)
    try:
        if options.mode == "ops":
            baseline(recorder, 10, "start")
        for app in apps:
            run_app(app, drivers, options, recorder, log, fixtures)
        if options.mode == "ops":
            baseline(recorder, 10, "end")
    finally:
        if phase_log:
            phase_log.send_signal(2)
            phase_log.wait(timeout=30)


if __name__ == "__main__":
    main()
