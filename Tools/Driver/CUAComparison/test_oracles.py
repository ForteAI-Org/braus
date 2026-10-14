#!/usr/bin/env python3
# Created by Eliomar Alejandro Rodriguez Ferrer on 14/10/2026.
"""Checks the benchmark's oracle decision, the window its pixels are read from, the fields a call row keeps,
the guards of the apps that run on the run's own instance, the undo fallback and the previous-run picker.

Offline: no driver, no application, no probe binary. Run from anywhere: python3 test_oracles.py
"""
import json
import os
import subprocess
import sys
import tempfile
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import compare  # noqa: E402
import report  # noqa: E402
import summarize  # noqa: E402
import tasks  # noqa: E402


def reading(values="a", scroll="s", changed=None, front=1, name="Finder", window=7, width=100, captured=True):
    """A probe reading; its capture has no `changed` count unless one is given, as a first capture has none."""
    return {"parts": {"values": values, "selection": "x", "focus": "f", "windows": "w", "scroll": scroll},
            "digest": values + scroll, "frontmost": front, "frontmostName": name,
            "pixels": {"window": window, "width": width, "height": 50, "changed": changed} if captured else None}


class OracleTests(unittest.TestCase):

    def test_no_operation_of_kitty_or_obsidian_is_left_without_an_oracle(self):
        for app in ("kitty", "Obsidian"):
            scenario = compare.SCENARIOS[app]
            for entry in scenario["ops"]:
                self.assertIn("pixels", compare.oracle(entry[0], entry, scenario), f"{app} {entry[0]}")

    def test_every_scroll_reads_pixels_and_an_explicit_false_stays_unverified(self):
        textedit = compare.SCENARIOS["TextEdit"]
        scroll = next(e for e in textedit["ops"] if e[0] == "scroll_down")
        self.assertEqual(compare.oracle("scroll_down", scroll, textedit), ["scroll", "pixels"])
        photoshop = compare.SCENARIOS["Photoshop"]
        rotate = next(e for e in photoshop["ops"] if e[0] == "menu_rotate")
        self.assertIsNone(compare.oracle("menu_rotate", rotate, photoshop))
        calculator = compare.SCENARIOS["Calculator"]
        click = calculator["ops"][0]
        self.assertEqual(compare.oracle("click", click, calculator), ["values"])

    def test_ax_change_confirms_before_pixels_are_read(self):
        verdict = compare.decide(["values", "pixels"], reading(values="a"), reading(values="b", changed=0))
        self.assertEqual(verdict, (True, "ax"))

    def test_pixels_decide_when_ax_is_blind(self):
        expect = ["values", "pixels"]
        self.assertEqual(compare.decide(expect, reading(), reading(changed=compare.PIXEL_NOISE + 1)), (True, "pixels"))
        self.assertEqual(compare.decide(expect, reading(), reading(changed=0)), (False, "pixels"))
        # A caret blink is not an effect and not a miss.
        self.assertEqual(compare.decide(expect, reading(), reading(changed=compare.PIXEL_NOISE)),
                         (None, "pixels_small"))
        self.assertEqual(compare.decide(expect, reading(), reading()), (None, "pixels_unavailable"))
        self.assertEqual(compare.decide(expect, reading(captured=False), reading(changed=5000)),
                         (None, "pixels_unavailable"))

    def test_captures_of_another_window_or_size_decide_nothing(self):
        expect = ["values", "pixels"]
        # A sheet in front, or a seat window swap: two windows compared would read as a large change.
        self.assertEqual(compare.decide(expect, reading(window=7), reading(window=8, changed=5000)),
                         (None, "pixels_window_changed"))
        self.assertEqual(compare.decide(expect, reading(width=100), reading(width=120, changed=5000)),
                         (None, "pixels_window_changed"))

    def test_without_pixels_an_unchanged_ax_reading_is_a_failure_as_before(self):
        self.assertEqual(compare.decide(["values"], reading(), reading()), (False, "ax"))
        self.assertEqual(compare.decide(None, reading(), reading()), (None, None))


class FakeProcess:
    def poll(self):
        return None


class FakeClient:
    """Answers each call with the next reply of a script, as MCPClient.call does: (seconds, bytes, reply)."""

    def __init__(self, replies):
        self.pid, self.proc, self.replies, self.calls = 999_999, FakeProcess(), list(replies), []

    def call(self, name, arguments):
        self.calls.append((name, arguments))
        return 0.01, 10, self.replies.pop(0)


def text_reply(text, error=False):
    return {"result": {"content": [{"type": "text", "text": text}], "isError": error}}


class RowTests(unittest.TestCase):

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.out = os.path.join(self.folder.name, "rows.jsonl")
        self.saved = compare.probe, compare.PIXEL_DIR, compare.window_server
        compare.PIXEL_DIR = self.folder.name
        compare.window_server = lambda: None

    def tearDown(self):
        compare.probe, compare.PIXEL_DIR, compare.window_server = self.saved
        self.folder.cleanup()

    def rows(self):
        with open(self.out) as lines:
            return [json.loads(line) for line in lines]

    def test_a_pixel_confirmed_step_and_a_failed_step_keep_what_the_reader_needs(self):
        sequence = iter([reading(), reading(), reading(), reading(changed=5000, front=2, name="kitty"),
                         reading(), reading(changed=0)])
        calls = []
        compare.probe = lambda pid, pixels=None, against=None, window=None: \
            calls.append((pixels, against, window)) or next(sequence)
        recorder = compare.Recorder(self.out, {"run": "t"}, 5)
        client = FakeClient([text_reply("scene: prompt"), text_reply('{"status": "acted"}'),
                             text_reply("delivered 0 of 10", error=True)])
        recorder.measure(client, "braus", "kitty", "GLFW", "observe", 1, "observe", {}, 1, settle=0, window=42)
        recorder.measure(client, "braus", "kitty", "GLFW", "type", 1, "type_text", {}, 1, settle=0,
                         expect=["values", "pixels"], window=42)
        recorder.measure(client, "braus", "kitty", "GLFW", "key", 1, "press_key", {}, 1, settle=0,
                         expect=["values", "pixels"], window=42)
        recorder.file.close()
        observe, typed, key = self.rows()
        self.assertEqual(calls[0][:2], (None, None))
        self.assertTrue(calls[3][1].endswith("before.gray") and calls[3][0].endswith("after.gray"))
        self.assertEqual([call[2] for call in calls[2:]], [42] * 4)
        self.assertEqual((typed["success"], typed["verified_by"], typed["pixels_changed"]), (True, "pixels", 5000))
        self.assertEqual(typed["frontmost_names"], ["Finder", "kitty"])
        self.assertNotIn("reply_text", typed)
        self.assertEqual((key["success"], key["verified_by"]), (False, "pixels"))
        self.assertEqual(key["reply_text"], "delivered 0 of 10")
        self.assertEqual((key["observe_before_op"], key["observe_before_text"]), ("type", '{"status": "acted"}'))
        self.assertIsNone(observe["verified_by"])

    def test_each_driver_reads_the_pixels_of_the_window_it_is_bound_to(self):
        person = {"id": 5, "title": "Notes.txt", "onscreen": True, "w": 800, "h": 600}
        fixture = {"id": 9, "title": "bench-1.txt", "onscreen": True, "w": 800, "h": 600}
        windows = []
        compare.probe = lambda pid, pixels=None, against=None, window=None: \
            windows.append(window) or dict(reading(changed=0 if against else None), windows=[person, fixture])
        self.assertEqual((compare.bound_window(1), compare.bound_window(1, "bench-1")), (5, 9))
        recorder = compare.Recorder(self.out, {"run": "t"}, 5)
        expect = ["values", "pixels"]
        braus = object.__new__(compare.Braus)
        braus.recorder, braus.client, braus.window = recorder, FakeClient([text_reply('{"session": "s"}'),
                                                                           text_reply('{"status": "acted"}')]), None
        braus.open("TextEdit", "AppKit", 1, (1, "bench-1.txt", "TextEdit"), {})
        windows.clear()
        braus.act("TextEdit", "AppKit", "scroll_down", 1, ("scroll", {"direction": "down"}), (1, None, None), expect)
        self.assertEqual(windows, [9, 9])
        cua = object.__new__(compare.Cua)
        cua.recorder, cua.client, cua.legacy = recorder, FakeClient([text_reply("{}")]), False
        cua.pid, cua.window = 1, 77
        cua.name, windows[:] = "cua", []
        cua.act("TextEdit", "AppKit", "scroll_down", 1, ("scroll", {"direction": "down"}), (1, None, None), expect)
        recorder.file.close()
        self.assertEqual(windows, [77, 77])

    def test_reply_text_is_bounded(self):
        self.assertEqual(len(compare.reply_text(text_reply("x" * 10_000))), compare.REPLY_CHARS)
        self.assertEqual(compare.reply_text({"error": {"message": "gone"}}), '{"message": "gone"}')


class SafetyTests(unittest.TestCase):

    def setUp(self):
        self.saved = compare.probe

    def tearDown(self):
        compare.probe = self.saved

    def test_obsidian_opens_only_a_scratch_vault_in_its_own_instance(self):
        argv = compare.prepare.open_steps("Obsidian", "/runs/x", 0)[0][1]
        self.assertIn("--user-data-dir=/runs/x/obsidian-profile", argv)
        self.assertEqual(compare.prepare.obsidian_vault("/runs/x"), "/runs/x/" + compare.prepare.OBSIDIAN_VAULT)
        self.assertIn("refused", compare.obsidian_refusal({}))
        foreign = {"Obsidian": {"pid": os.getpid(), "scratch_vault": "/runs/x/v"}}
        self.assertIn("refused", compare.obsidian_refusal(foreign))

    def test_obsidian_binds_by_the_vault_part_of_the_title_as_it_is_now(self):
        fixtures = {"Obsidian": {"pid": 123, "window": "Welcome - bench-vault - Obsidian 1.9"}}
        now = "Driver notes - bench-vault - Obsidian 1.9"
        compare.probe = lambda pid, *args, **kwargs: {"windows": [{"title": "Settings"}, {"title": now}]}
        self.assertEqual(compare.target_for("Obsidian", compare.SCENARIOS["Obsidian"], fixtures)[1], now)
        # No window on the scratch vault: the vault part alone, which no window matches whole.
        compare.probe = lambda pid, *args, **kwargs: {"windows": [{"title": "Notes - my-vault - Obsidian 1.9"}]}
        self.assertEqual(compare.target_for("Obsidian", compare.SCENARIOS["Obsidian"], fixtures)[1],
                         compare.prepare.OBSIDIAN_VAULT)

    def test_kitty_runs_only_on_its_own_instance_and_types_only_comments(self):
        argv = compare.prepare.open_steps("kitty", "/runs/x", 0)[0][1]
        self.assertEqual(argv[:4], ["open", "-g", "-n", "-a"])
        for option, value in (("--config", "/runs/x/kitty.conf"), ("--title", compare.prepare.KITTY_TITLE)):
            self.assertEqual(argv[argv.index(option) + 1], value)
        mine = subprocess.run(["ps", "-o", "args=", "-p", str(os.getpid())], capture_output=True, text=True).stdout
        own = {"launched": True, "pid": os.getpid(), "config": mine.split()[-1]}
        compare.probe = lambda pid, *args, **kwargs: {"axWindows": [{"title": compare.prepare.KITTY_TITLE}]}
        self.assertIsNone(compare.refusal("kitty", {"kitty": own}))
        for fixture in ({}, dict(own, launched=False), dict(own, config="/runs/x/kitty.conf")):
            self.assertIn("refused", compare.refusal("kitty", {"kitty": fixture}))
        compare.probe = lambda pid, *args, **kwargs: {"axWindows": [{"title": "~/work - zsh"}]}
        self.assertIn("refused", compare.refusal("kitty", {"kitty": own}))
        self.assertIsNone(compare.refusal("Calculator", {}))
        for entry in compare.SCENARIOS["kitty"]["ops"]:
            for spec in entry[1:3]:
                self.assertTrue(spec[1].get("text", "#").startswith("#"), entry)

    def test_resets_touch_only_what_the_run_opened(self):
        textedit, photoshop = compare.SCENARIOS["TextEdit"], compare.SCENARIOS["Photoshop"]
        self.assertIn("skipped", compare.reset_state("TextEdit", textedit, {"TextEdit": {"window": "Notes.txt"}}))
        self.assertIn("skipped", compare.reset_state("Photoshop", photoshop, {"Photoshop": {"launched": False}}))
        self.assertIsNone(compare.reset_state("DaVinci Resolve", compare.SCENARIOS["DaVinci Resolve"], {}))


class ScenarioTests(unittest.TestCase):

    def test_expected_value_only_where_the_whole_field_value_is_known(self):
        inserts = {app: entry[1][1] for app, scenario in compare.SCENARIOS.items() for entry in scenario["ops"]
                   if entry[1][0] == "insert_text"}
        self.assertEqual(sorted(inserts), ["Obsidian", "TextEdit", "kitty"])
        # The quick switcher opens empty: its whole value is the text. A document and a terminal hold more.
        self.assertEqual(inserts["Obsidian"]["expected_value"], "Driver")
        for app in ("TextEdit", "kitty"):
            self.assertNotIn("expected_value", inserts[app])
            self.assertTrue(compare.SCENARIOS[app]["unknown_value"])

    def test_a_braus_row_says_why_its_insert_names_no_expected_value(self):
        saved = compare.probe, compare.window_server
        compare.probe, compare.window_server = (lambda pid, *args, **kwargs: reading()), (lambda: None)
        with tempfile.TemporaryDirectory() as folder:
            try:
                recorder = compare.Recorder(os.path.join(folder, "rows.jsonl"), {"run": "t"}, 5)
                braus = object.__new__(compare.Braus)
                braus.recorder, braus.session, braus.window = recorder, "s", 9
                braus.client = FakeClient([text_reply('{"status": "acted_unverified"}')] * 2)
                for app in ("TextEdit", "Obsidian"):
                    entry = next(e for e in compare.SCENARIOS[app]["ops"] if e[0] == "type")
                    braus.act(app, "f", "type", 1, entry[1], (1, None, None), None)
                recorder.file.close()
                with open(os.path.join(folder, "rows.jsonl")) as lines:
                    textedit, obsidian = [json.loads(line) for line in lines]
            finally:
                compare.probe, compare.window_server = saved
        sent = [arguments for _, arguments in braus.client.calls]
        self.assertNotIn("expected_value", sent[0])
        self.assertEqual(textedit["expected_value_omitted"], compare.SCENARIOS["TextEdit"]["unknown_value"])
        self.assertEqual(sent[1]["expected_value"], "Driver")
        self.assertNotIn("expected_value_omitted", obsidian)

    def test_an_undo_its_shortcut_did_not_confirm_gets_the_menu_as_a_row_of_its_own(self):
        saved = compare.window_server
        compare.window_server = lambda: None
        try:
            for confirmed, expected in ((False, 2), (True, 0)):
                driver = FakeDriver(undo_confirmed=confirmed)
                options = types.SimpleNamespace(idle_windows=0, idle_seconds=0, sessions=0, extra_sessions=False)
                compare.ops_block(driver, "TextEdit", compare.SCENARIOS["TextEdit"], (1, "bench-1.txt", "TextEdit"),
                                  [1], options)
                fallbacks = [act for act in driver.acts if act[2] == "undo"]
                self.assertEqual(len(fallbacks), expected)
                for op, spec, _ in fallbacks:
                    self.assertEqual((op, spec), ("undo_menu", ("menu", {"path": "Edit > Undo"})))
                    self.assertEqual(driver.acts[driver.acts.index((op, spec, "undo")) - 1][0], "undo")
        finally:
            compare.window_server = saved


class KittyTaskTests(unittest.TestCase):
    """The model task runs a command in kitty's shell: only in the run's own kitty, never the person's."""

    def setUp(self):
        self.saved = (dict(vars(tasks.bench_prepare)), tasks.subprocess, tasks.ensure_app,
                      os.environ.get("BENCH_RUN_DIR"))
        self.launched = []
        tasks.subprocess = types.SimpleNamespace(run=lambda argv, **kwargs: self.launched.append(argv))
        os.environ["BENCH_RUN_DIR"] = "/runs/x"
        prepare = tasks.bench_prepare
        prepare.wait_for = lambda find, seconds=12: find()
        self.real_make_kitty_config = prepare.make_kitty_config
        prepare.make_kitty_config = lambda scratch: None
        prepare.window_titles = lambda pid: [prepare.KITTY_TITLE]

        # A regression must fail here, never go on to a live run on the desktop.
        def live(*args, **kwargs):
            raise AssertionError("the test reached a step that acts on the desktop")
        tasks.ensure_app = prepare.home_front = prepare.restore_front = live

    def tearDown(self):
        names, tasks.subprocess, tasks.ensure_app, run_dir = self.saved
        vars(tasks.bench_prepare).update(names)
        if run_dir is None:
            os.environ.pop("BENCH_RUN_DIR", None)
        else:
            os.environ["BENCH_RUN_DIR"] = run_dir

    def own(self, pid, others=()):
        tasks.bench_prepare.target_pid = lambda app, scratch: pid
        tasks.bench_prepare.processes = lambda: [(p, 1, "kitty") for p in ([pid] if pid else []) + list(others)]

    def test_the_run_s_own_kitty_alone_is_used(self):
        self.own(4242)
        self.assertEqual(tasks.kitty_instance(), (4242, None))
        self.assertEqual(self.launched, [])

    def test_the_run_s_kitty_config_starts_a_shell_with_400_lines_of_scrollback(self):
        import shlex
        prepare = tasks.bench_prepare
        with tempfile.TemporaryDirectory() as scratch:
            self.real_make_kitty_config(scratch)
            line = next(l for l in open(prepare.kitty_config(scratch)) if l.startswith("shell "))
        argv = shlex.split(line)[1:]
        out = subprocess.run(argv, capture_output=True, text=True, env={"SHELL": "/usr/bin/true"}).stdout.split()
        self.assertEqual(out, [str(n) for n in range(1, 401)])

    def test_a_missing_own_kitty_is_launched_with_prepare_s_recipe(self):
        pids = iter([None, 4243])
        tasks.bench_prepare.target_pid = lambda app, scratch: next(pids)
        tasks.bench_prepare.processes = lambda: []
        self.assertEqual(tasks.kitty_instance(), (4243, None))
        self.assertEqual(self.launched, [tasks.bench_prepare.open_steps("kitty", "/runs/x", 0)[0][1]])
        self.assertIn("-n", self.launched[0])

    def test_refused_when_it_cannot_be_told_from_the_person_s_kitty(self):
        self.own(4242, others=[71605])
        self.assertIn("another kitty", tasks.kitty_instance()[1])
        self.own(None, others=[71605])
        self.assertIsNone(tasks.kitty_instance()[0])
        self.assertEqual(self.launched, [])
        self.own(4242)
        tasks.bench_prepare.window_titles = lambda pid: ["~ - zsh"]
        self.assertIsNone(tasks.kitty_instance()[0])
        del os.environ["BENCH_RUN_DIR"]
        self.assertIn("BENCH_RUN_DIR", tasks.kitty_instance()[1])

    def test_a_refused_kitty_task_is_recorded_as_skipped_with_the_reason(self):
        self.own(4242, others=[71605])
        task = next(t for t in tasks.CONFIG["tasks"] if t["id"] == "kitty")
        with tempfile.TemporaryDirectory() as folder, open(os.path.join(folder, "tasks.jsonl"), "w") as out:
            row = tasks.run_one(task, "braus", 1, folder, out, None)
        self.assertEqual(row["status"], "skipped")
        self.assertIn("another kitty runs too (pids [71605])", row["reason"])


class FakeDriver:
    """A driver whose undo is confirmed or not, recording each (op, spec, fallback_for) it is asked to act."""
    name = "braus"

    def __init__(self, undo_confirmed):
        self.acts, self.undo_confirmed = [], undo_confirmed
        self.recorder, self.client = types.SimpleNamespace(last_end={}), types.SimpleNamespace(pid=1)

    def open(self, *args, **kwargs):
        return True

    def start_rep(self, *args):
        pass

    def act(self, app, framework, op, rep, spec, target, expect, **extra):
        self.acts.append((op, spec, extra.get("fallback_for")))
        return {"success": self.undo_confirmed if op == "undo" else True}

    def after(self, *args, **kwargs):
        return None

    def release(self, *args):
        pass


class SummaryTests(unittest.TestCase):

    def test_former_driver_name_and_confirmations_by_kind(self):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as rows:
            for verified_by, success in (("ax", True), ("pixels", True), ("pixels_small", None), ("pixels", False)):
                rows.write(json.dumps(dict(driver="mecum", app="kitty", op="type", rep=1, ms=10, ok=True, mode="ops",
                                           success=success, verified_by=verified_by)) + "\n")
        try:
            op = summarize.summarize([rows.name])["drivers"]["braus"]["apps"]["kitty"]["ops"]["type"]
        finally:
            os.remove(rows.name)
        self.assertEqual((op["n_confirmed"], op["n_confirmed_ax"], op["n_confirmed_pixels"], op["n_pixels_small"]),
                         (2, 1, 1, 1))

    def test_a_task_summary_that_names_braus_mecum_renders_braus(self):
        cell = {"runs": 1, "skipped": 0, "inconclusive": 0, "tool_errors": 0,
                "success": {"count": 1, "of": 1, "wilson95": [0.2, 1]},
                "intrusion": {"focus_changes": 0, "cursor_moves": 0}}
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "tasks-summary.json")
            with open(path, "w") as tasks:
                json.dump({d: {"tasks": {"calculator": cell}, "within_declared_support": cell, "all_runs": cell}
                           for d in ("mecum", "cua")}, tasks)
            loaded = report.task_summary(path)
        self.assertEqual(sorted(loaded), ["braus", "cua"])
        self.assertIn("**Braus**", report.r_tasks(report.Ctx({"drivers": {}}, {}, loaded, {}, {}, {})))
        self.assertIsNone(report.task_summary(None))

    def test_observe_after_keeps_its_place_ahead_of_the_unlisted_ops(self):
        names = {"front_restored", "observe_after", "undo_menu", "undo", "key"}
        self.assertEqual(sorted(names, key=summarize.order), ["undo", "undo_menu", "key", "observe_after",
                                                              "front_restored"])


class PreviousRunTests(unittest.TestCase):

    def test_the_latest_complete_run_before_this_one(self):
        with tempfile.TemporaryDirectory() as runs:
            for name, done in (("20261009-0017", False), ("20261009-0050", True), ("20261013-1258", True),
                               ("20261014-0900", True)):
                os.makedirs(os.path.join(runs, name))
                if done:
                    with open(os.path.join(runs, name, "summary.json"), "w") as summary:
                        summary.write("{}")
            self.assertEqual(report.previous_run(os.path.join(runs, "20261013-1258"), runs),
                             os.path.join(runs, "20261009-0050"))
            self.assertEqual(report.previous_run("/elsewhere/20261015-1000", runs), os.path.join(runs, "20261014-0900"))
            self.assertIsNone(report.previous_run(os.path.join(runs, "20261009-0050"), runs))
        self.assertEqual(report.run_label("/x/20261009-0050"), "09/10 00:50")

    def test_previous_column_goes_beside_the_6_october_one(self):
        cur = "intro\n\n| Metrica | Braus | Braus vs 6/10 |\n|---|---|---|\n| passo | 1 ms | ▲ -10% |\n\nfine\n"
        prev = "intro\n\n| Metrica | Braus | Braus vs 6/10 |\n|---|---|---|\n| passo | 1 ms | = +2% |\n\nfine\n"
        merged = report.beside(cur, prev, "giro prec.")
        self.assertIn("| Metrica | Braus | Braus vs 6/10 | Braus vs giro prec. |", merged)
        self.assertIn("|---|---|---|---|", merged)
        self.assertIn("| passo | 1 ms | ▲ -10% | = +2% |", merged)
        self.assertTrue(merged.endswith("\n\nfine\n"))
        english = report.beside("| Metric | 6 Oct | Now | Change |\n|---|---|---|---|\n| a | 1 | 2 | ▼ |\n",
                                "| Metric | 6 Oct | Now | Change |\n|---|---|---|---|\n| a | 3 | 2 | ▲ |\n",
                                "previous run")
        self.assertIn("| Metric | 6 Oct | previous run | Now | Change | Change vs previous run |", english)
        self.assertIn("| a | 1 | 3 | 2 | ▼ | ▲ |", english)


if __name__ == "__main__":
    unittest.main()
