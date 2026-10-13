"""SQL checks on the living memory's schema: the one text SQLiteMemory ships, part by part.

They prove the shape of the schema (constraints, triggers, round trips) on the resource included in the
module, through Python's sqlite3: not the Swift store, not the Brain's retention, not the desktop. Schema 1's
checks run first, on part 1, the base with the value change; then parts 2 to 7 run on that populated file in
their order, each with checks of its own, the rows a migration from schema 1 derives
(`SQLiteMemorySchema.derivedRows`) after part 3. The check of a requirement's step, which part 7 writes with one
more case admitted, runs with part 6, whose checks it keeps. The parts are also checked to be the whole text.
`make test` runs them; pass another path to the one text as the argument to check a copy.
The library used is Python's, and it says nothing about the one the Swift binary links.
"""
import re
import sqlite3
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCHEMA = Path(sys.argv[1]) if len(sys.argv) > 1 else \
    ROOT / "Sources/Engine/SQLiteMemory/Resources/brain-living-memory-schema.sql"
# The rows a migration from schema 1 derives that no statement of the text creates, as the store holds them.
DERIVED = re.search(r'derivedRows: \[Int32: String\] = \[1: """\n(.*?)\n\s*"""\]',
                    (ROOT / "Sources/Engine/SQLiteMemory/SQLiteMemorySchema.swift").read_text(), re.S).group(1) + ";"
RULE = "-- " + "=" * 109 + "\n"
segments = SCHEMA.read_text().split(RULE)
assert len(segments) == 15, len(segments)
PARTS = {}
for number in range(1, 8):
    assert segments[2 * number - 1].startswith(f"-- Part {number}. "), segments[2 * number - 1][:40]
    PARTS[number] = segments[2 * number]
REQUIREMENT = re.search(r"CREATE TRIGGER memory_recall_requirements_valid .*?\nEND;\n", PARTS[7], re.S).group(0)
PARTS[6] += "\n" + REQUIREMENT
PARTS[7] = PARTS[7].replace(REQUIREMENT, "")


def objects_of(text):
    scratch = sqlite3.connect(":memory:")
    scratch.executescript(text)
    found = set(scratch.execute("SELECT type, name, sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'"))
    scratch.close()
    return found


db = sqlite3.connect(":memory:")
# The resource carries no PRAGMA of its own: foreign keys are enabled per connection, as the store does.
db.executescript("PRAGMA foreign_keys = ON;\n" + PARTS[1])
passed = []
LIB = db.execute("SELECT sqlite_version(), sqlite_source_id()").fetchone()


def ok(label):
    passed.append(label)


def insert(table, **row):
    keys = list(row)
    db.execute(f"INSERT INTO {table} ({','.join(keys)}) VALUES ({','.join('?' for _ in keys)})",
               [row[k] for k in keys])


def rejects(label, operation):
    db.execute("SAVEPOINT invalid_case")
    try:
        operation()
    except sqlite3.IntegrityError:
        passed.append("rejects: " + label)
    else:
        raise AssertionError(f"Invalid row accepted: {label}")
    finally:
        db.execute("ROLLBACK TO invalid_case")
        db.execute("RELEASE invalid_case")


def event(eid, app=1, kind="action", source="app", **extra):
    insert("memory_events", event_id=eid, source=source, source_stream_id="stream",
           source_key=eid, event_kind=kind, app_id=app, occurred_at_ms=100,
           capture_status="complete", **extra)


def capture(eid, phase="after", ordinal=0, status="complete", surface="window", **extra):
    insert("memory_event_observations", event_id=eid, phase=phase, sample_ordinal=ordinal,
           observation_kind="capture", status=status, surface_kind=surface, **extra)
    return db.execute("SELECT last_insert_rowid()").fetchone()[0]


def argument(name, value, position=0, **owner):
    kind = "boolean" if isinstance(value, bool) else "integer" if isinstance(value, int) else "real" if isinstance(value, float) else "text"
    insert("memory_operation_arguments", argument_name=name, position=position,
           value_kind=kind, **{f"{kind}_value": int(value) if kind == "boolean" else value}, **owner)


# ------------------------------------------------------------------ base fixtures (from v4)
for app in (1, 2):
    insert("brain_apps", app_id=app, bundle_id=f"test.app{app}")
    insert("brain_app_contexts", context_id=app, app_id=app, app_version="1", app_locale="it")
    insert("brain_scenes", scene_id=f"scene{app}", app_id=app, title_bucket="Chat",
           first_seen_ms=0, last_seen_ms=100)
    insert("brain_anchors", anchor_id=f"anchor{app}", app_id=app, insertion_order=0, kind="button", label="Invia",
           first_seen_ms=0, last_seen_ms=100)
    insert("memory_routes", route_id=f"route{app}", name="Invia", status="draft", created_at_ms=0)
    insert("memory_route_steps", step_id=f"step{app}", route_id=f"route{app}", position=0,
           step_kind="goal", goal_text="Messaggio presente", app_id=app)
    insert("memory_route_parameters", parameter_id=f"param{app}", route_id=f"route{app}",
           name="text", direction="input", value_type="text", is_required=1)
    insert("memory_step_operations", operation_id=f"op{app}", route_id=f"route{app}",
           step_id=f"step{app}", app_id=app, position=0, tool_kind="type_text")

insert("brain_scene_elements", scene_element_id="list", app_id=1, scene_id="scene1",
       element_key="conversation_list", element_scope="collection", first_seen_ms=0, last_seen_ms=100)
insert("brain_scene_elements", scene_element_id="row", app_id=1, scene_id="scene1",
       element_key="conversation_row", element_scope="item_template", parent_element_id="list",
       first_seen_ms=0, last_seen_ms=100)
for i, person in enumerate(("Persona A", "Persona B")):
    eid = f"watch{i}"
    event(eid, kind="input", source="watcher", context_id=1)
    insert("memory_input_events", event_id=eid, input_kind="click")
    cap = capture(eid, phase="after")
    insert("memory_event_observations", event_id=eid, phase="after", observation_kind="element",
           status="observed", label=person, parent_observation_id=cap)
    insert("memory_event_scenes", event_id=eid, app_id=1, phase="after", scene_id="scene1",
           match_status="confirmed", matched_by="rules", matcher_version="test")
assert db.execute("SELECT count(*) FROM brain_scenes WHERE app_id=1").fetchone()[0] == 1
ok("two chat observations share one structural scene")

insert("brain_transitions", transition_id="transition1", app_id=1, insertion_order=0, from_scene_id="scene1",
       to_scene_id="scene1", scene_element_id="row", trigger_kind="click", effect_kind="conversation_opened",
       status="candidate", first_seen_ms=0, last_seen_ms=100)
insert("brain_evidence", app_id=1, event_id="watch0", transition_id="transition1", relation="supports",
       assessed_by="rules", assessment_version="test", assessed_at_ms=100)
insert("memory_task_occurrences", task_occurrence_id="task", started_at_ms=0, status="observed")
insert("memory_task_events", task_occurrence_id="task", event_id="watch0", position=0, role="observation")
insert("memory_task_labels", label_id="label", task_occurrence_id="task", label="Apri conversazione",
       assigned_by="test", confidence=0.5, status="candidate", assigned_at_ms=100)
insert("memory_step_occurrences", step_occurrence_id="occurrence", task_occurrence_id="task",
       step_id="step1", started_at_ms=0, status="observed")
insert("memory_step_events", step_occurrence_id="occurrence", event_id="watch0", position=0, role="observation")
insert("memory_step_evidence", step_id="step1", step_occurrence_id="occurrence", relation="supports",
       assessed_by="test", assessed_at_ms=100)
insert("memory_step_checks", check_id="check", route_id="route1", step_id="step1", app_id=1,
       position=0, check_kind="state", expected_anchor_id="anchor1", expected_state="on")
insert("memory_operation_arguments", operation_id="op1", route_id="route1", app_id=1, argument_name="text",
       value_kind="parameter", parameter_id="param1")
ok("one-step Route, Watcher attribution, state check and parameter reference")

fixtures = {
    "status": {}, "windows": {"app": "test.app1"}, "apps": {"query": "chat"},
    "open_session": {"app": "test.app1", "window": "Chat"}, "observe": {},
    "act": {"target": "Invia", "verb": "set_toggle", "value": "on", "section": "Chat"},
    "select": {"control": "Formato", "item": "Mono"},
    "type_text": {"target": "Messaggio", "text": "Ciao\nseconda riga", "replace": False, "section": "Chat"},
    "press_key": {"key": "return", "modifiers": ["shift", "cmd"], "count": 2},
    "scroll": {"direction": "down", "lines": 3, "target": "Conversazioni", "section": "Sidebar"},
    "drag": {"from": "Elemento", "dx": 2.5, "dy": -1.0, "section": "Canvas"},
    "context_menu": {"target": "Messaggio", "item": "Copy", "section": "Chat"},
    "batch": {}, "close_session": {},
}
for tool, args in fixtures.items():
    eid = f"tool_{tool}"
    event(eid, session_id="ephemeral-session", trace_id="trace")
    insert("memory_agent_actions", event_id=eid, app_id=1, tool_kind=tool, execution_status="completed")
    for name, value in args.items():
        for pos, item in enumerate(value if isinstance(value, list) else [value]):
            argument(name, item, pos, event_id=eid, app_id=1)
    rows = db.execute("SELECT argument_name,position,value_kind,text_value,integer_value,real_value,boolean_value FROM memory_operation_arguments WHERE event_id=? ORDER BY argument_name,position", (eid,)).fetchall()
    actual = {}
    for name, pos, kind, *values in rows:
        value = next(v for v in values if v is not None)
        if kind == "boolean": value = bool(value)
        if isinstance(args[name], list): actual.setdefault(name, []).append(value)
        else: actual[name] = value
    assert actual == args, (tool, actual, args)
ok("app tool envelopes and scalar/list argument round-trips")
event("drag_target")
insert("memory_agent_actions", event_id="drag_target", app_id=1, tool_kind="drag", execution_status="planned")
argument("from", "File", event_id="drag_target", app_id=1)
argument("to", "Cartella", event_id="drag_target", app_id=1)
for pos, state in enumerate(("completed", "failed", "skipped")):
    eid = f"batch_{pos}"
    event(eid, parent_event_id="tool_batch", parent_position=pos)
    insert("memory_agent_actions", event_id=eid, app_id=1, tool_kind="act", execution_status=state)
    argument("target", f"Button {pos}", event_id=eid, app_id=1)
assert db.execute("SELECT count(*) FROM memory_events WHERE parent_event_id='tool_batch'").fetchone()[0] == 3
ok("batch preserves executed, failed and unattempted requests")

insert("memory_route_steps", step_id="call", route_id="route1", position=1, step_kind="route_call",
       goal_text="Sottoprocedura", called_route_id="route2")
insert("memory_route_call_bindings", step_id="call", route_id="route1", called_route_id="route2",
       called_parameter_id="param2", source_parameter_id="param1")

rejects("cross-app event context", lambda: event("bad_context", context_id=2))
rejects("source retry duplicate", lambda: db.execute("INSERT INTO memory_events(event_id,source,source_stream_id,source_key,event_kind,occurred_at_ms,capture_status) VALUES ('duplicate','app','stream','tool_act','action',100,'complete')"))
rejects("input detail attached to action", lambda: insert("memory_input_events", event_id="tool_act", input_kind="click"))
rejects("cross-app event scene", lambda: insert("memory_event_scenes", event_id="watch0", app_id=1, phase="before", scene_id="scene2", match_status="confirmed", matched_by="test", matcher_version="test"))
insert("brain_scenes", scene_id="other_scene1", app_id=1, title_bucket="Other", first_seen_ms=0, last_seen_ms=100)
rejects("two confirmed scenes for one sample", lambda: insert("memory_event_scenes", event_id="watch0", app_id=1, phase="after", scene_id="other_scene1", match_status="confirmed", matched_by="test", matcher_version="test"))
ev = dict(app_id=1, event_id="watch1", relation="supports", assessed_by="test", assessment_version="test", assessed_at_ms=100)
rejects("evidence without target", lambda: insert("brain_evidence", **ev))
rejects("evidence with two targets", lambda: insert("brain_evidence", scene_id="scene1", anchor_id="anchor1", **ev))
rejects("evidence cross-app target", lambda: insert("brain_evidence", anchor_id="anchor2", **ev))
rejects("cross-app transition", lambda: insert("brain_transitions", transition_id="bad", app_id=1, insertion_order=9, from_scene_id="scene1", to_scene_id="scene2", trigger_kind="click", effect_kind="changed", status="candidate", first_seen_ms=0, last_seen_ms=100))
rejects("step evidence refers to another step", lambda: insert("memory_step_evidence", step_id="step2", step_occurrence_id="occurrence", relation="supports", assessed_by="test", assessed_at_ms=100))
rejects("operation refers to another Route step", lambda: insert("memory_step_operations", operation_id="bad", route_id="route1", step_id="step2", position=3, tool_kind="act"))
rejects("argument parameter belongs to another Route", lambda: insert("memory_operation_arguments", operation_id="op1", route_id="route1", app_id=1, argument_name="wrong", value_kind="parameter", parameter_id="param2"))
rejects("argument anchor belongs to another app", lambda: insert("memory_operation_arguments", event_id="tool_act", app_id=1, argument_name="wrong", value_kind="anchor", anchor_id="anchor2"))
rejects("argument with two owners", lambda: insert("memory_operation_arguments", operation_id="op1", event_id="tool_act", route_id="route1", app_id=1, argument_name="wrong", value_kind="text", text_value="x"))
rejects("argument wrong typed column", lambda: insert("memory_operation_arguments", event_id="tool_act", app_id=1, argument_name="wrong", value_kind="boolean", text_value="true"))
rejects("argument two values", lambda: insert("memory_operation_arguments", event_id="tool_act", app_id=1, argument_name="wrong", value_kind="text", text_value="x", integer_value=1))
rejects("boolean outside domain", lambda: insert("memory_operation_arguments", event_id="tool_act", app_id=1, argument_name="wrong", value_kind="boolean", boolean_value=2))
rejects("nonconvertible integer rejected by STRICT", lambda: insert("memory_operation_arguments", event_id="tool_act", app_id=1, argument_name="wrong", value_kind="integer", integer_value="abc"))
rejects("duplicate scalar argument", lambda: argument("target", "Again", event_id="tool_act", app_id=1))
rejects("Route call uses wrong callee parameter", lambda: insert("memory_route_call_bindings", step_id="call", route_id="route1", called_route_id="route2", called_parameter_id="param1", literal_text="x"))
rejects("Route call uses wrong caller parameter", lambda: db.execute("UPDATE memory_route_call_bindings SET source_parameter_id='param2' WHERE step_id='call'"))
rejects("check uses another Route parameter", lambda: insert("memory_step_checks", check_id="bad", route_id="route1", step_id="step1", app_id=1, position=1, check_kind="value", expected_parameter_id="param2"))
rejects("batch child crosses steps", lambda: insert("memory_step_operations", operation_id="bad_child", route_id="route1", step_id="step1", app_id=1, parent_operation_id="op2", position=0, tool_kind="act"))
rejects("event parent is itself", lambda: event("self", parent_event_id="self", parent_position=0))

for suffix, mode, payload in [
    ("literal", "literal", {"literal_text": "Input 1"}),
    ("request", "request_slot", {"slot_name": "requested_input"}),
    ("context", "context_slot", {"slot_name": "active_document"}),
]:
    insert("memory_experiences", experience_id=f"experience_{suffix}", phrase="Attiva ingresso",
           route_id="route1", step_id="step1", created_at_ms=0)
    insert("memory_experience_bindings", experience_id=f"experience_{suffix}", route_id="route1",
           parameter_id="param1", value_type="text", binding_kind=mode, **payload)
ok("Experience binds a literal, a request slot or a current context slot")
for kind, value in [("integer", 3), ("real", 0.5), ("boolean", 1)]:
    insert("memory_route_parameters", parameter_id=f"binding_{kind}", route_id="route1",
           name=kind, direction="input", value_type=kind, is_required=1)
    insert("memory_experience_bindings", experience_id="experience_literal", route_id="route1",
           parameter_id=f"binding_{kind}", value_type=kind, binding_kind="literal", **{f"literal_{kind}": value})
ok("Experience literals support text, integer, real and boolean")
binding = dict(experience_id="experience_request", route_id="route1", parameter_id="param1",
               value_type="text", binding_kind="literal", literal_text="Input 2")
rejects("duplicate Experience binding", lambda: insert("memory_experience_bindings", **binding))
rejects("binding references another Route parameter", lambda: insert("memory_experience_bindings", **(binding | {"parameter_id": "param2"})))
rejects("binding references another Route Experience", lambda: insert("memory_experience_bindings", **(binding | {"route_id": "route2", "parameter_id": "param2"})))
rejects("binding type differs from parameter type", lambda: db.execute("UPDATE memory_experience_bindings SET value_type='integer' WHERE experience_id='experience_request'"))
rejects("binding slot cannot be empty", lambda: db.execute("UPDATE memory_experience_bindings SET slot_name='' WHERE experience_id='experience_request'"))
rejects("binding slot is mandatory", lambda: db.execute("UPDATE memory_experience_bindings SET slot_name=NULL WHERE experience_id='experience_context'"))
rejects("slot and literal cannot coexist", lambda: db.execute("UPDATE memory_experience_bindings SET literal_text='stale value' WHERE experience_id='experience_context'"))
rejects("binding literal cannot be empty of values", lambda: db.execute("UPDATE memory_experience_bindings SET literal_text=NULL WHERE experience_id='experience_literal' AND parameter_id='param1'"))
rejects("binding literal rejects wrong value column", lambda: db.execute("UPDATE memory_experience_bindings SET literal_text=NULL,literal_integer=3 WHERE experience_id='experience_literal' AND parameter_id='param1'"))
rejects("binding rejects unknown resolution mode", lambda: db.execute("UPDATE memory_experience_bindings SET binding_kind='anything' WHERE experience_id='experience_request'"))

db.commit()
try:
    with db:
        event("rollback")
        insert("brain_evidence", app_id=1, event_id="rollback", anchor_id="missing", relation="supports",
               assessed_by="test", assessment_version="test", assessed_at_ms=100)
except sqlite3.IntegrityError:
    pass
assert db.execute("SELECT count(*) FROM memory_events WHERE event_id='rollback'").fetchone()[0] == 0
ok("transaction rolls back event and invalid evidence together")

# ------------------------------------------------------------------ D2 retirement (from v4)
insert("brain_app_window_epochs", app_id=1, window_family="Chat", epoch=3)
insert("brain_app_window_epochs", app_id=1, window_family="Settings", epoch=1)
db.execute("INSERT INTO brain_app_window_epochs VALUES (1, 'Chat', 4) "
           "ON CONFLICT(app_id, window_family) DO UPDATE SET epoch=excluded.epoch")
assert db.execute("SELECT window_family,epoch FROM brain_app_window_epochs WHERE app_id=1 ORDER BY window_family").fetchall() == [("Chat", 4), ("Settings", 1)]
ok("window clocks round-trip independently and support an atomic upsert")
rejects("window clock requires an existing app", lambda: insert("brain_app_window_epochs", app_id=99, window_family="Chat", epoch=1))
rejects("window clock cannot be negative", lambda: db.execute("UPDATE brain_app_window_epochs SET epoch=-1 WHERE app_id=1"))
rejects("window clock is unique per app and family", lambda: insert("brain_app_window_epochs", app_id=1, window_family="Chat", epoch=0))

insert("brain_groups", group_id="group1", app_id=1, insertion_order=0, axis="vertical", shared_kind="button", last_seen_ms=100)
insert("brain_group_members", app_id=1, group_id="group1", anchor_id="anchor1", position=0)
# ---- S2 increment 2: ObjectAnchor.groupID is an explicit nullable column, distinct from the ordered membership.
assert "current_group_id" in [column[1] for column in db.execute("PRAGMA table_info(brain_anchors)")]
insert("brain_groups", group_id="group1b", app_id=1, insertion_order=1, axis="horizontal", shared_kind="button", last_seen_ms=100)
insert("brain_groups", group_id="group2", app_id=2, insertion_order=0, axis="vertical", shared_kind="button", last_seen_ms=100)
insert("brain_group_members", app_id=1, group_id="group1b", anchor_id="anchor1", position=0)
db.execute("UPDATE brain_anchors SET current_group_id='group1' WHERE anchor_id='anchor1'")
assert db.execute("SELECT current_group_id FROM brain_anchors WHERE anchor_id='anchor1'").fetchone()[0] == "group1"
assert db.execute("SELECT count(*) FROM brain_group_members WHERE anchor_id='anchor1'").fetchone()[0] == 2
ok("D2: the anchor's current group is an explicit nullable column with a per-app FK, while the anchor stays a member of two groups")
rejects("D2: current group must be an existing group", lambda: db.execute("UPDATE brain_anchors SET current_group_id='nowhere' WHERE anchor_id='anchor1'"))
rejects("D2: current group of another app", lambda: db.execute("UPDATE brain_anchors SET current_group_id='group2' WHERE anchor_id='anchor1'"))
rejects("D2: current group of another app on insert", lambda: insert("brain_anchors", anchor_id="cross", app_id=2, insertion_order=7, kind="button", label="X", first_seen_ms=0, last_seen_ms=0, current_group_id="group1"))
db.execute("UPDATE brain_anchors SET current_group_id=NULL WHERE anchor_id='anchor1'")
db.execute("UPDATE brain_anchors SET current_group_id='group1' WHERE anchor_id='anchor1'")
ok("D2: the current group may be NULL (the algorithm's nil) and be set again")
insert("brain_evidence", app_id=1, event_id="tool_act", anchor_id="anchor1", relation="supports",
       assessed_by="test", assessment_version="test", assessed_at_ms=100)
insert("brain_evidence", app_id=1, event_id="tool_act", group_id="group1", relation="supports",
       assessed_by="test", assessment_version="test", assessed_at_ms=100)
for table, key, value in [("brain_anchors", "anchor_id", "anchor1"),
                          ("brain_groups", "group_id", "group1"),
                          ("brain_transitions", "transition_id", "transition1")]:
    def update_retirement(assignments, parameters=()):
        db.execute(f"UPDATE {table} SET {assignments} WHERE {key}=?", (*parameters, value))
    rejects(f"{table}: retirement requires epoch and cause", lambda: update_retirement("retired_at_ms=200"))
    rejects(f"{table}: epoch alone is not retirement", lambda: update_retirement("retired_epoch=1"))
    rejects(f"{table}: cause alone is not retirement", lambda: update_retirement("retirement_cause='stale'"))
    rejects(f"{table}: negative retirement epoch", lambda: update_retirement("retired_at_ms=200, retired_epoch=-1, retirement_cause='stale'"))
    rejects(f"{table}: retirement before last observation", lambda: update_retirement("retired_at_ms=50, retired_epoch=1, retirement_cause='stale'"))
    rejects(f"{table}: unknown retirement cause", lambda: update_retirement("retired_at_ms=200, retired_epoch=1, retirement_cause='unknown'"))
rejects("anchor label source is a known protection category", lambda: db.execute("UPDATE brain_anchors SET label_source='anything' WHERE anchor_id='anchor1'"))
rejects("transition retirement is independent of confidence status", lambda: db.execute("UPDATE brain_transitions SET status='retired' WHERE transition_id='transition1'"))
db.execute("UPDATE brain_transitions SET status='trusted' WHERE transition_id='transition1'")
for table, key, value in [("brain_anchors", "anchor_id", "anchor1"),
                          ("brain_groups", "group_id", "group1"),
                          ("brain_transitions", "transition_id", "transition1")]:
    db.execute(f"UPDATE {table} SET retired_at_ms=200,retired_epoch=4,retirement_cause='stale' WHERE {key}=?", (value,))
    assert db.execute(f"SELECT count(*) FROM {table} WHERE {key}=? AND retired_at_ms IS NULL", (value,)).fetchone()[0] == 0
    assert db.execute(f"SELECT count(*) FROM {table} WHERE {key}=?", (value,)).fetchone()[0] == 1
assert db.execute("SELECT count(*) FROM brain_evidence WHERE anchor_id='anchor1' OR group_id='group1' OR transition_id='transition1'").fetchone()[0] == 3
assert db.execute("SELECT status FROM brain_transitions WHERE transition_id='transition1'").fetchone()[0] == "trusted"
assert db.execute("SELECT expected_anchor_id FROM memory_step_checks WHERE check_id='check'").fetchone()[0] == "anchor1"
ok("retired knowledge is excluded by active queries while evidence, checks and confidence survive")
assert db.execute("SELECT current_group_id FROM brain_anchors WHERE anchor_id='anchor1'").fetchone()[0] == "group1"
assert db.execute("PRAGMA foreign_key_check").fetchall() == []
ok("D2: retiring a group keeps the anchors' current_group_id references valid")
rejects("referenced retired anchor cannot be physically deleted", lambda: db.execute("DELETE FROM brain_anchors WHERE anchor_id='anchor1'"))
insert("brain_anchors", anchor_id="anchor1_return", app_id=1, insertion_order=1, kind="button", label="Invia",
       label_source="observed", first_seen_ms=300, last_seen_ms=300, last_seen_epoch=5)
insert("brain_anchor_states", anchor_id="anchor1_return", state="on", seen_count=1)
assert db.execute("SELECT anchor_id FROM brain_anchors WHERE app_id=1 AND label='Invia' AND retired_at_ms IS NULL").fetchall() == [("anchor1_return",)]
assert db.execute("SELECT count(*) FROM brain_evidence WHERE anchor_id='anchor1_return'").fetchone()[0] == 0
ok("reappearance can have a new active identity and current state without inherited evidence")

# ================================================================== A. app scope
insert("brain_scenes", scene_id="app_scope1", app_id=1, title_bucket="#app", scene_kind="app",
       first_seen_ms=0, last_seen_ms=0, observation_count=0)
ok("A: one app-scope row per app is representable (scene_kind='app', title_bucket='#app', no structure)")
rejects("A: second app scope for the same app", lambda: insert("brain_scenes", scene_id="app_scope1b", app_id=1, title_bucket="#app", scene_kind="app", first_seen_ms=0, last_seen_ms=0, observation_count=0))
rejects("A: app scope with a structural key", lambda: insert("brain_scenes", scene_id="x", app_id=2, title_bucket="#app", scene_kind="app", structural_key="k", first_seen_ms=0, last_seen_ms=0, observation_count=0))
rejects("A: app scope with observation_count > 0", lambda: insert("brain_scenes", scene_id="x", app_id=2, title_bucket="#app", scene_kind="app", first_seen_ms=0, last_seen_ms=0, observation_count=1))
rejects("A: app scope with a title pattern", lambda: insert("brain_scenes", scene_id="x", app_id=2, title_bucket="#app", scene_kind="app", window_title_pattern="Chat", first_seen_ms=0, last_seen_ms=0, observation_count=0))
rejects("A: app scope without the marker bucket", lambda: insert("brain_scenes", scene_id="x", app_id=2, title_bucket="Chat", scene_kind="app", first_seen_ms=0, last_seen_ms=0, observation_count=0))
rejects("A: structural scene using the marker bucket", lambda: insert("brain_scenes", scene_id="x", app_id=2, title_bucket="#app", scene_kind="window", first_seen_ms=0, last_seen_ms=0))
rejects("A: unknown scene_kind", lambda: insert("brain_scenes", scene_id="x", app_id=2, title_bucket="Chat", scene_kind="unknown", first_seen_ms=0, last_seen_ms=0))
rejects("A: scene_kind is immutable", lambda: db.execute("UPDATE brain_scenes SET scene_kind='window', title_bucket='Chat' WHERE scene_id='app_scope1'"))
rejects("A: structural element on the app scope", lambda: insert("brain_scene_elements", scene_element_id="x", app_id=1, scene_id="app_scope1", element_key="k", first_seen_ms=0, last_seen_ms=0))
rejects("A: element moved onto the app scope", lambda: db.execute("UPDATE brain_scene_elements SET scene_id='app_scope1' WHERE scene_element_id='row'"))
rejects("A: role on the app scope", lambda: insert("brain_scene_roles", scene_id="app_scope1", role="AXButton"))
rejects("A: label on the app scope", lambda: insert("brain_scene_labels", scene_id="app_scope1", label_token="invia"))
rejects("A: observation associated with the app scope", lambda: insert("memory_event_scenes", event_id="watch1", app_id=1, phase="after", scene_id="app_scope1", match_status="candidate", matched_by="structure", matcher_version="v2"))
rejects("A: association moved onto the app scope", lambda: db.execute("UPDATE memory_event_scenes SET scene_id='app_scope1' WHERE event_id='watch0'"))
rejects("A: evidence targeting the app scope", lambda: insert("brain_evidence", app_id=1, event_id="watch1", scene_id="app_scope1", relation="supports", assessed_by="t", assessment_version="t", assessed_at_ms=1))
rejects("A: transition towards the app scope", lambda: insert("brain_transitions", transition_id="x", app_id=1, insertion_order=9, from_scene_id="scene1", to_scene_id="app_scope1", anchor_id="anchor1_return", trigger_kind="click", effect_kind="stateFlip", status="candidate", first_seen_ms=0, last_seen_ms=0))
rejects("A: transition from the app scope with a structural element", lambda: insert("brain_transitions", transition_id="x", app_id=1, insertion_order=9, from_scene_id="app_scope1", scene_element_id="row", trigger_kind="click", effect_kind="stateFlip", status="candidate", first_seen_ms=0, last_seen_ms=0))
insert("brain_transitions", transition_id="scope_transition", app_id=1, insertion_order=1, from_scene_id="app_scope1",
       anchor_id="anchor1_return", trigger_kind="click", effect_kind="stateFlip", effect_text="off>on",
       required_target_state="off", resulting_target_state="on", status="candidate", first_seen_ms=300, last_seen_ms=300)
insert("brain_evidence", app_id=1, event_id="tool_act", transition_id="scope_transition", relation="supports",
       assessed_by="brain", assessment_version="1", assessed_at_ms=300)
rejects("A: the same event cannot support the same transition twice", lambda: insert("brain_evidence", app_id=1, event_id="tool_act", transition_id="scope_transition", relation="supports", assessed_by="brain", assessment_version="1", assessed_at_ms=301))
ok("A: anchor->effect knowledge lives on the app scope with anchor, states and one evidence per event")
db.execute("UPDATE brain_transitions SET to_scene_id=NULL WHERE transition_id='scope_transition'")
rejects("A: destination moved onto the app scope", lambda: db.execute("UPDATE brain_transitions SET to_scene_id='app_scope1' WHERE transition_id='scope_transition'"))

# ================================================================== B. observable orders
insert("brain_anchor_aliases", anchor_id="anchor1_return", alias="Send", position=0)
insert("brain_anchor_aliases", anchor_id="anchor1_return", alias="Invia ora", position=1)
assert [r[0] for r in db.execute("SELECT alias FROM brain_anchor_aliases WHERE anchor_id='anchor1_return' ORDER BY position")] == ["Send", "Invia ora"]
ok("B: alias order is persisted and reproduced (aliases.first, prefix(3))")
rejects("B: two aliases at one position", lambda: insert("brain_anchor_aliases", anchor_id="anchor1_return", alias="Third", position=1))
rejects("B: alias without position", lambda: db.execute("INSERT INTO brain_anchor_aliases(anchor_id, alias) VALUES ('anchor1_return', 'Fourth')"))
rejects("B: duplicate alias text", lambda: insert("brain_anchor_aliases", anchor_id="anchor1_return", alias="Send", position=7))
for order in (2, 3):
    insert("brain_anchors", anchor_id=f"a{order}", app_id=1, insertion_order=order, kind="button", label="X", first_seen_ms=0, last_seen_ms=0)
assert [r[0] for r in db.execute("SELECT anchor_id FROM brain_anchors WHERE app_id=1 AND retired_at_ms IS NULL ORDER BY insertion_order")] == ["anchor1_return", "a2", "a3"]
ok("B: active anchors load in UIBrain.objects order (insertion_order), retired rows excluded")
rejects("B: duplicate anchor insertion_order within an app", lambda: insert("brain_anchors", anchor_id="dup", app_id=1, insertion_order=2, kind="button", label="X", first_seen_ms=0, last_seen_ms=0))
insert("brain_anchors", anchor_id="b2", app_id=2, insertion_order=2, kind="button", label="X", first_seen_ms=0, last_seen_ms=0)
ok("B: insertion_order is scoped per app")
rejects("B: duplicate group insertion_order", lambda: insert("brain_groups", group_id="g", app_id=1, insertion_order=0, axis="vertical", shared_kind="button", last_seen_ms=0))
rejects("B: duplicate transition insertion_order", lambda: insert("brain_transitions", transition_id="t", app_id=1, insertion_order=1, from_scene_id="scene1", anchor_id="a2", trigger_kind="click", effect_kind="x", status="candidate", first_seen_ms=0, last_seen_ms=0))
rejects("B: anchor without insertion_order", lambda: db.execute("INSERT INTO brain_anchors(anchor_id, app_id, kind, label, first_seen_ms, last_seen_ms) VALUES ('noorder', 1, 'button', 'X', 0, 0)"))
insert("brain_group_members", app_id=1, group_id="group1", anchor_id="a3", position=1)
insert("brain_group_members", app_id=1, group_id="group1", anchor_id="a2", position=2)
db.execute("UPDATE brain_group_members SET position = position + 100 WHERE group_id='group1'")
db.execute("UPDATE brain_group_members SET position = 0 WHERE group_id='group1' AND anchor_id='a2'")
db.execute("UPDATE brain_group_members SET position = 1 WHERE group_id='group1' AND anchor_id='a3'")
db.execute("DELETE FROM brain_group_members WHERE group_id='group1' AND anchor_id='anchor1'")
assert [r[0] for r in db.execute("SELECT anchor_id FROM brain_group_members WHERE group_id='group1' ORDER BY position")] == ["a2", "a3"]
ok("B: group membership can be reordered atomically and a departed member is removed (SiblingGroup.memberAnchors)")

# ================================================================== C. null-safe constraints and vocabularies
event("global_call", app=None)
insert("memory_agent_actions", event_id="global_call", app_id=None, tool_kind="status", execution_status="completed")
ok("C: event and action without a single app (both NULL) are accepted")
event("app_call")
rejects("C: event with app A and action with app NULL", lambda: insert("memory_agent_actions", event_id="app_call", app_id=None, tool_kind="act", execution_status="planned"))
rejects("C: event with app A and action with app B", lambda: insert("memory_agent_actions", event_id="app_call", app_id=2, tool_kind="act", execution_status="planned"))
rejects("C: global event with an action claiming app A", lambda: insert("memory_agent_actions", event_id="global_call", app_id=1, tool_kind="act", execution_status="planned"))
rejects("C: event app_id cannot be rewritten afterwards", lambda: db.execute("UPDATE memory_events SET app_id=2 WHERE event_id='app_call'"))
rejects("C: event identity cannot be rewritten afterwards", lambda: db.execute("UPDATE memory_events SET occurred_at_ms=1 WHERE event_id='app_call'"))
db.execute("UPDATE memory_events SET capture_status='partial' WHERE event_id='app_call'")
ok("C: capture_status is the one mutable field of an event")
rejects("C: action identity cannot be rewritten", lambda: db.execute("UPDATE memory_agent_actions SET app_id=NULL WHERE event_id='tool_act'"))
db.execute("UPDATE memory_agent_actions SET execution_status='started' WHERE event_id='drag_target'")
ok("C: execution status has its own updates")
db.execute("UPDATE memory_agent_actions SET started_at_ms=10 WHERE event_id='drag_target'")
rejects("C: a label before the effect is a list", lambda: insert("memory_agent_action_effect_labels", event_id="drag_target", position=0, label="Cartella"))
db.execute("UPDATE memory_agent_actions SET execution_status='completed', completed_at_ms=12, duration_ms=7, result_kind='found_acted', result_message='dragged', observed_effect_kind='elementsAppeared' WHERE event_id='drag_target'")
# S3-d correction: a list effect is rows, in order; a label with a separator stays one label.
for position, label in enumerate(["A|B", "C", ""]):
    insert("memory_agent_action_effect_labels", event_id="drag_target", position=position, label=label)
assert db.execute("SELECT started_at_ms, completed_at_ms, duration_ms FROM memory_agent_actions WHERE event_id='drag_target'").fetchone() == (10, 12, 7)
assert [r[0] for r in db.execute("SELECT label FROM memory_agent_action_effect_labels WHERE event_id='drag_target' ORDER BY position")] == ["A|B", "C", ""]
ok("C: a call keeps the instant it started, its end, its monotonic duration and a list effect as ordered label rows (S3-d)")
event("timed_call")
rejects("C: a planned call has no start", lambda: insert("memory_agent_actions", event_id="timed_call", app_id=1, tool_kind="act", execution_status="planned", started_at_ms=5))
rejects("C: a planned call has no duration", lambda: insert("memory_agent_actions", event_id="timed_call", app_id=1, tool_kind="act", execution_status="planned", duration_ms=5))
rejects("C: a negative duration", lambda: insert("memory_agent_actions", event_id="timed_call", app_id=1, tool_kind="act", execution_status="completed", completed_at_ms=1, duration_ms=-1))
insert("memory_agent_actions", event_id="timed_call", app_id=1, tool_kind="act", execution_status="started", started_at_ms=10)
rejects("C: a title under a list family", lambda: db.execute("UPDATE memory_agent_actions SET execution_status='completed', completed_at_ms=11, observed_effect_kind='menuOpened', observed_effect_text='x' WHERE event_id='timed_call'"))
rejects("C: a flip without its states", lambda: db.execute("UPDATE memory_agent_actions SET execution_status='completed', completed_at_ms=11, observed_effect_kind='stateFlip' WHERE event_id='timed_call'"))
rejects("C: states without a flip", lambda: db.execute("UPDATE memory_agent_actions SET execution_status='completed', completed_at_ms=11, observed_effect_kind='windowTitleChanged', observed_effect_text='Saved', observed_state_before='off', observed_state_after='on' WHERE event_id='timed_call'"))
rejects("C: a title family without its title", lambda: db.execute("UPDATE memory_agent_actions SET execution_status='completed', completed_at_ms=11, observed_effect_kind='windowTitleChanged' WHERE event_id='timed_call'"))
rejects("C: an unknown effect family", lambda: db.execute("UPDATE memory_agent_actions SET execution_status='completed', completed_at_ms=11, observed_effect_kind='rowsMoved' WHERE event_id='timed_call'"))
rejects("C: an observed effect on a failed call", lambda: db.execute("UPDATE memory_agent_actions SET execution_status='failed', completed_at_ms=11, observed_effect_kind='stateFlip', observed_state_before='off', observed_state_after='on' WHERE event_id='timed_call'"))
# The calendar may run backwards between the start and the end: the chronology is kept as it was, the duration is monotone.
db.execute("UPDATE memory_agent_actions SET execution_status='completed', completed_at_ms=9, duration_ms=3, result_kind='found_acted', result_message='set', observed_effect_kind='stateFlip', observed_state_before='off', observed_state_after='on' WHERE event_id='timed_call'")
assert db.execute("SELECT started_at_ms, completed_at_ms, duration_ms, observed_state_before, observed_state_after FROM memory_agent_actions WHERE event_id='timed_call'").fetchone() == (10, 9, 3, "off", "on")
ok("C: an end earlier than the start on the calendar is a valid record with its monotone duration; a flip keeps both states (S3-d)")
rejects("C: a label under a scalar family", lambda: insert("memory_agent_action_effect_labels", event_id="timed_call", position=0, label="x"))
# merge-memory: main's perception reports a selection change, a family with no title, states or labels.
event("selection_call")
insert("memory_agent_actions", event_id="selection_call", app_id=1, tool_kind="insert_text", execution_status="started", started_at_ms=10)
rejects("C: a selection change with a title", lambda: db.execute("UPDATE memory_agent_actions SET execution_status='completed', completed_at_ms=11, observed_effect_kind='textSelectionChanged', observed_effect_text='x' WHERE event_id='selection_call'"))
rejects("C: a selection change with states", lambda: db.execute("UPDATE memory_agent_actions SET execution_status='completed', completed_at_ms=11, observed_effect_kind='textSelectionChanged', observed_state_before='off', observed_state_after='on' WHERE event_id='selection_call'"))
db.execute("UPDATE memory_agent_actions SET execution_status='completed', completed_at_ms=11, duration_ms=1, result_kind='acted_unverified', result_message='inserted', observed_effect_kind='textSelectionChanged' WHERE event_id='selection_call'")
rejects("C: a label under a selection change", lambda: insert("memory_agent_action_effect_labels", event_id="selection_call", position=0, label="x"))
ok("C: a selection change is an observed effect of its family alone (merge-memory)")
# merge of the value change: a text field that now reads another value keeps its label and value, nothing else.
event("value_call")
insert("memory_agent_actions", event_id="value_call", app_id=1, tool_kind="type_text", execution_status="started", started_at_ms=10)
complete = "UPDATE memory_agent_actions SET execution_status='completed', completed_at_ms=11, observed_effect_kind="
rejects("C: a value change without its value", lambda: db.execute(complete + "'valueChanged', observed_effect_label='Name' WHERE event_id='value_call'"))
rejects("C: a value change without its label", lambda: db.execute(complete + "'valueChanged', observed_effect_value='Ada' WHERE event_id='value_call'"))
rejects("C: a value change with a title", lambda: db.execute(complete + "'valueChanged', observed_effect_label='Name', observed_effect_value='Ada', observed_effect_text='x' WHERE event_id='value_call'"))
rejects("C: a value change with states", lambda: db.execute(complete + "'valueChanged', observed_effect_label='Name', observed_effect_value='Ada', observed_state_before='off', observed_state_after='on' WHERE event_id='value_call'"))
rejects("C: a label and value under another family", lambda: db.execute(complete + "'textSelectionChanged', observed_effect_label='Name', observed_effect_value='Ada' WHERE event_id='value_call'"))
rejects("C: a value with no family", lambda: db.execute("UPDATE memory_agent_actions SET observed_effect_value='Ada' WHERE event_id='value_call'"))
db.execute(complete + "'valueChanged', observed_effect_label='', observed_effect_value='' WHERE event_id='value_call'")
assert db.execute("SELECT observed_effect_label, observed_effect_value FROM memory_agent_actions WHERE event_id='value_call'").fetchone() == ("", "")
rejects("C: a label row under a value change", lambda: insert("memory_agent_action_effect_labels", event_id="value_call", position=0, label="x"))
ok("C: a value change is its family with its label and value, the empty text kept (merge of the value change)")
event("mcp_call", source="mcp")
ok("C: an external MCP client is an event source of its own (merge-memory)")
rejects("C: an unknown event source", lambda: event("bridge_call", source="bridge"))
# S3-d correction: the structured results of the listing and scene tools.
event("status_call", app=None)
insert("memory_agent_actions", event_id="status_call", app_id=None, tool_kind="status", execution_status="completed", completed_at_ms=1, result_kind="status")
insert("memory_agent_action_status", event_id="status_call", session_id=None, screen_recording=1, accessibility=0, post_event=1)
rejects("C: a status row for a call that is not status", lambda: insert("memory_agent_action_status", event_id="timed_call", screen_recording=1, accessibility=1, post_event=1))
event("windows_call", app=None)
insert("memory_agent_actions", event_id="windows_call", app_id=None, tool_kind="windows", execution_status="completed", completed_at_ms=1, result_kind="listing")
rejects("C: a listing of another kind than the tool", lambda: insert("memory_agent_action_listings", event_id="windows_call", listing_kind="apps"))
insert("memory_agent_action_listings", event_id="windows_call", listing_kind="windows", hidden_count=0)
insert("memory_agent_action_applications", event_id="windows_call", position=0, name="Mail", bundle_id="com.apple.mail", pid=404)
rejects("C: a windows row without its pid", lambda: insert("memory_agent_action_applications", event_id="windows_call", position=1, name="Notes", bundle_id="com.apple.Notes"))
rejects("C: a windows row carrying apps fields", lambda: insert("memory_agent_action_applications", event_id="windows_call", position=1, name="Notes", bundle_id="com.apple.Notes", pid=5, is_running=1))
rejects("C: a windows row carrying the default browser flag", lambda: insert("memory_agent_action_applications", event_id="windows_call", position=1, name="Safari", bundle_id="com.apple.Safari", pid=6, is_default_browser=1))
insert("memory_agent_action_windows", event_id="windows_call", application_position=0, position=0, window_number=77, title="Inbox")
insert("memory_agent_action_windows", event_id="windows_call", application_position=0, position=1, window_number=78, title=None)
assert [r for r in db.execute("SELECT window_number, title FROM memory_agent_action_windows WHERE event_id='windows_call' ORDER BY position")] == [(77, "Inbox"), (78, None)]
event("apps_call", app=None)
insert("memory_agent_actions", event_id="apps_call", app_id=None, tool_kind="apps", execution_status="completed", completed_at_ms=1, result_kind="listing")
insert("memory_agent_action_listings", event_id="apps_call", listing_kind="apps", hidden_count=3)
insert("memory_agent_action_applications", event_id="apps_call", position=0, name="Pro Tools", bundle_id="com.avid.ProTools", app_version="26.4", is_running=0, location="~/Applications")
rejects("C: an apps row carrying a pid", lambda: insert("memory_agent_action_applications", event_id="apps_call", position=1, name="X", bundle_id="x", pid=1, is_running=1))
rejects("C: an apps row without its running flag", lambda: insert("memory_agent_action_applications", event_id="apps_call", position=1, name="X", bundle_id="x"))
insert("memory_agent_action_applications", event_id="apps_call", position=1, name="Safari", bundle_id="com.apple.Safari", is_running=1, is_default_browser=1)
rejects("C: a default browser flag that is not a boolean", lambda: insert("memory_agent_action_applications", event_id="apps_call", position=2, name="Y", bundle_id="y", is_running=0, is_default_browser=2))
ok("C: an apps row says whether it is the default browser (merge-memory)")
rejects("C: a window under an apps listing", lambda: insert("memory_agent_action_windows", event_id="apps_call", application_position=0, position=0, window_number=1, title="x"))
rejects("C: a negative hidden count", lambda: insert("memory_agent_action_listings", event_id="timed_call", listing_kind="apps", hidden_count=-1))
ok("C: status, windows and apps keep typed rows in order, NULL apart from empty text, with the count left out (S3-d)")
event("observe_call", session_id="ephemeral-session")
insert("memory_agent_actions", event_id="observe_call", app_id=1, tool_kind="observe", execution_status="completed", completed_at_ms=1, result_kind="observation")
rejects("C: an observation result without its sample", lambda: insert("memory_agent_action_observations", event_id="observe_call", session_id="ephemeral-session", session_revision=1, observed_at_ms=1, sample_event_id="observe_call", sample_observation_id=999999))
current = capture("observe_call", phase="current", ordinal=0, status="complete", surface="window", window_title="Chat")
insert("memory_agent_action_observations", event_id="observe_call", session_id="ephemeral-session", session_revision=1, observed_at_ms=1, sample_event_id="observe_call", sample_observation_id=current)
rejects("C: an observation result for a call that is not observe or open_session", lambda: insert("memory_agent_action_observations", event_id="timed_call", session_id="s", session_revision=1, observed_at_ms=1, sample_event_id="observe_call", sample_observation_id=current))
ok("C: an observation result points to its real current sample (S3-d)")
# S3-d correction: the origin of a session's own observation is the call it was taken for.
event("opening_call", app=None, session_id=None)
insert("memory_agent_actions", event_id="opening_call", app_id=None, tool_kind="open_session", execution_status="completed", completed_at_ms=1)
event("opening_observation", kind="observation", session_id="opened", origin_event_id="opening_call")
assert db.execute("SELECT origin_event_id FROM memory_events WHERE event_id='opening_observation'").fetchone() == ("opening_call",)
rejects("C: an origin on an action", lambda: event("origin_action", origin_event_id="opening_call"))
rejects("C: an origin that is the event itself", lambda: event("origin_self", kind="observation", origin_event_id="origin_self"))
rejects("C: an origin the store does not hold", lambda: event("origin_missing", kind="observation", origin_event_id="nowhere"))
rejects("C: the origin is part of the event's identity", lambda: db.execute("UPDATE memory_events SET origin_event_id=NULL WHERE event_id='opening_observation'"))
ok("C: a session's own observation keeps the call it was taken for (S3-d)")
rejects("C: step with app A and operation with app NULL", lambda: insert("memory_step_operations", operation_id="x", route_id="route1", step_id="step1", position=5, tool_kind="act"))
rejects("C: step with app A and operation with app B", lambda: insert("memory_step_operations", operation_id="x", route_id="route1", step_id="step1", app_id=2, position=5, tool_kind="act"))
rejects("C: step with app A and check with app NULL", lambda: insert("memory_step_checks", check_id="x", route_id="route1", step_id="step1", position=5, check_kind="text", expected_text="x"))
insert("memory_route_steps", step_id="step_global", route_id="route1", position=2, step_kind="goal", goal_text="Senza app")
insert("memory_step_operations", operation_id="op_global", route_id="route1", step_id="step_global", position=0, tool_kind="status")
ok("C: a step without app and its operation without app are accepted")
rejects("C: operation claiming an app under a step without app", lambda: insert("memory_step_operations", operation_id="x", route_id="route1", step_id="step_global", app_id=1, position=1, tool_kind="act"))
rejects("C: argument omitting app_id under an app operation", lambda: insert("memory_operation_arguments", operation_id="op1", route_id="route1", argument_name="omit", value_kind="text", text_value="x"))
rejects("C: argument omitting app_id under an app action", lambda: insert("memory_operation_arguments", event_id="tool_act", argument_name="omit", value_kind="text", text_value="x"))
rejects("C: argument claiming an app under a global action", lambda: insert("memory_operation_arguments", event_id="global_call", app_id=1, argument_name="omit", value_kind="text", text_value="x"))
rejects("C: step app is immutable", lambda: db.execute("UPDATE memory_route_steps SET app_id=2 WHERE step_id='step1'"))
db.execute("UPDATE memory_route_steps SET goal_text='Messaggio visibile' WHERE step_id='step1'")
ok("C: a step's goal text may still be edited in a draft")

insert("memory_step_occurrences", step_occurrence_id="occurrence_b", task_occurrence_id="task", step_id="step1", started_at_ms=5, status="observed")
event("verify_a", kind="verification")
insert("memory_verifications", event_id="verify_a", step_occurrence_id="occurrence", scope="step", method="scene", verdict="passed")
rejects("C: verification of A added as verification membership of B", lambda: insert("memory_step_events", step_occurrence_id="occurrence_b", event_id="verify_a", position=9, role="verification"))
insert("memory_step_events", step_occurrence_id="occurrence", event_id="verify_a", position=1, role="verification")
rejects("C: reverse order, verification re-attributed to B while membership says A", lambda: db.execute("UPDATE memory_verifications SET step_occurrence_id='occurrence_b' WHERE event_id='verify_a'"))
rejects("C: an action event cannot play the verification role", lambda: insert("memory_step_events", step_occurrence_id="occurrence", event_id="tool_act", position=9, role="verification"))
event("verify_none", kind="verification")
rejects("C: an unattributed verification cannot be a verification member", lambda: insert("memory_step_events", step_occurrence_id="occurrence", event_id="verify_none", position=9, role="verification"))
insert("memory_step_events", step_occurrence_id="occurrence", event_id="tool_act", position=2, role="action")
ok("C: verification attribution is single and consistent in both write orders")
rejects("C: unknown verdict", lambda: insert("memory_verifications", event_id="verify_none", scope="step", method="scene", verdict="maybe"))
event("cli_act", source="cli")
insert("memory_action_correlations", watcher_event_id="watch1", agent_event_id="cli_act", basis_kind="time")
ok("C: a watcher input correlated with a cli action is accepted")
rejects("C: two agent events are not a Watcher correlation", lambda: insert("memory_action_correlations", watcher_event_id="tool_observe", agent_event_id="tool_act", basis_kind="time"))
event("sys_obs", source="system", kind="observation")
rejects("C: a system observation is not a watcher input", lambda: insert("memory_action_correlations", watcher_event_id="sys_obs", agent_event_id="tool_act", basis_kind="time"))
rejects("C: a watcher input cannot be correlated with a verification", lambda: insert("memory_action_correlations", watcher_event_id="watch0", agent_event_id="verify_a", basis_kind="time"))
rejects("C: direct Route recursion A->A", lambda: insert("memory_route_steps", step_id="x", route_id="route1", position=9, step_kind="route_call", goal_text="x", called_route_id="route1"))
rejects("C: indirect Route recursion A->B->A", lambda: insert("memory_route_steps", step_id="x", route_id="route2", position=9, step_kind="route_call", goal_text="x", called_route_id="route1"))
insert("memory_routes", route_id="route3", name="Terza", status="draft", created_at_ms=0)
insert("memory_route_steps", step_id="step3", route_id="route3", position=0, step_kind="route_call", goal_text="Chiama la seconda", called_route_id="route2")
rejects("C: indirect Route recursion through three Routes", lambda: insert("memory_route_steps", step_id="x", route_id="route2", position=9, step_kind="route_call", goal_text="x", called_route_id="route3"))
ok("C: a non-recursive call chain is accepted")
insert("memory_step_operations", operation_id="op1_child", route_id="route1", step_id="step1", app_id=1, parent_operation_id="op1", position=0, tool_kind="act")
rejects("C: operation parent cycle A->B->A", lambda: db.execute("UPDATE memory_step_operations SET parent_operation_id='op1_child' WHERE operation_id='op1'"))
rejects("C: unknown capture_status", lambda: event("x", capture_status="weird") if False else db.execute("INSERT INTO memory_events(event_id,source,source_stream_id,event_kind,occurred_at_ms,capture_status) VALUES ('x','app','s','action',1,'weird')"))
rejects("C: unknown task status", lambda: insert("memory_task_occurrences", task_occurrence_id="x", started_at_ms=0, status="weird"))
rejects("C: unknown step occurrence status", lambda: insert("memory_step_occurrences", step_occurrence_id="x", started_at_ms=0, status="done"))
rejects("C: unknown Route status", lambda: insert("memory_routes", route_id="x", name="x", status="published", created_at_ms=0))
rejects("C: unknown label status", lambda: insert("memory_task_labels", label_id="x", task_occurrence_id="task", label="x", assigned_by="t", status="maybe", assigned_at_ms=0))
rejects("C: unknown Route evidence relation", lambda: insert("memory_route_evidence", route_id="route1", task_occurrence_id="task", relation="refutes", assessed_by="t", assessed_at_ms=0))
rejects("C: unknown step evidence relation", lambda: insert("memory_step_evidence", step_id="step1", step_occurrence_id="occurrence", relation="refutes", assessed_by="t", assessed_at_ms=0))
rejects("C: unknown membership role", lambda: insert("memory_step_events", step_occurrence_id="occurrence", event_id="watch1", position=9, role="helper"))
rejects("C: unknown task membership role", lambda: insert("memory_task_events", task_occurrence_id="task", event_id="watch1", position=9, role="helper"))
rejects("C: unknown Experience use verdict", lambda: insert("memory_experience_uses", experience_id="experience_literal", event_id="tool_act", verdict="ok"))
rejects("C: unknown observation phase", lambda: insert("memory_event_observations", event_id="tool_act", phase="during", observation_kind="element", status="observed"))

# ================================================================== D. samples with quality
event("act_click")
insert("memory_agent_actions", event_id="act_click", app_id=1, tool_kind="act", execution_status="completed")
before = capture("act_click", phase="before", ordinal=0, status="complete", surface="window", window_title="Chat", session_revision=7)
after = capture("act_click", phase="after", ordinal=0, status="partial", surface="window", window_title="Chat", session_revision=8)
menu = capture("act_click", phase="menu", ordinal=0, status="complete", surface="popup_union")
for name, value in (("walk_completed", 1), ("nodes_visited", 120), ("elements_emitted", 33)):
    insert("memory_event_observations", event_id="act_click", phase="before", observation_kind="capture_field",
           field_name=name, integer_value=value, status="observed", parent_observation_id=before)
insert("memory_event_observations", event_id="act_click", phase="before", observation_kind="capture_field",
       field_name="stopped_by", text_value="deadline", status="observed", parent_observation_id=after)
insert("memory_event_observations", event_id="act_click", phase="before", observation_kind="element",
       status="observed", label="Invia", role="AXButton", label_origin="title", container_path="Composer",
       parent_observation_id=before)
ok("D: a sample is a typed capture row with quality fields and element children")
rejects("D: two captures for one (event, phase, ordinal)", lambda: capture("act_click", phase="before", ordinal=0))
second = capture("act_click", phase="after", ordinal=1, status="complete")
ok("D: a second real capture in the same phase takes the next ordinal")
rejects("D: capture with a non-quality status", lambda: capture("act_click", phase="current", ordinal=0, status="observed"))
rejects("D: capture nested under another observation", lambda: insert("memory_event_observations", event_id="act_click", phase="before", sample_ordinal=3, observation_kind="capture", status="complete", parent_observation_id=before))
rejects("D: unknown label_origin", lambda: insert("memory_event_observations", event_id="act_click", phase="before", observation_kind="element", status="observed", label_origin="guess", parent_observation_id=before))
insert("memory_event_observations", event_id="act_click", phase="before", observation_kind="element",
       status="observed", label="notes-editor", role="AXTextArea", label_origin="identifier", parent_observation_id=before)
ok("D: a label read from the accessibility identifier keeps that origin (merge-memory)")
rejects("D: unknown surface_kind", lambda: capture("act_click", phase="current", ordinal=0, surface="menu"))
rejects("D: association without its capture sample", lambda: insert("memory_event_scenes", event_id="act_click", app_id=1, phase="current", scene_id="scene1", match_status="candidate", matched_by="structure", matcher_version="v2"))
rejects("D: a partial capture cannot confirm a scene", lambda: insert("memory_event_scenes", event_id="act_click", app_id=1, phase="after", sample_ordinal=0, scene_id="scene1", match_status="confirmed", matched_by="structure", matcher_version="v2"))
insert("memory_event_scenes", event_id="act_click", app_id=1, phase="after", sample_ordinal=0, scene_id="scene1", match_status="candidate", matched_by="structure", matcher_version="v2")
insert("memory_event_scenes", event_id="act_click", app_id=1, phase="after", sample_ordinal=0, scene_id="other_scene1", match_status="candidate", matched_by="structure", matcher_version="v2")
ok("D: a partial capture keeps several candidates and confirms none")
rejects("D: promoting a candidate on a partial capture", lambda: db.execute("UPDATE memory_event_scenes SET match_status='confirmed' WHERE event_id='act_click' AND phase='after' AND sample_ordinal=0 AND scene_id='scene1'"))
insert("memory_event_scenes", event_id="act_click", app_id=1, phase="before", sample_ordinal=0, scene_id="scene1", match_status="confirmed", matched_by="structure", matcher_version="v2")
insert("memory_event_scenes", event_id="act_click", app_id=1, phase="after", sample_ordinal=1, scene_id="scene1", match_status="confirmed", matched_by="structure", matcher_version="v2")
ok("D: complete samples confirm at most one scene each; ordinals are distinct samples")
rejects("D: second confirmed scene for the same sample", lambda: insert("memory_event_scenes", event_id="act_click", app_id=1, phase="before", sample_ordinal=0, scene_id="other_scene1", match_status="confirmed", matched_by="structure", matcher_version="v2"))
rejects("D: a confirmed sample cannot be downgraded to partial", lambda: db.execute("UPDATE memory_event_observations SET status='partial' WHERE observation_id=?", (before,)))
rejects("D: a confirmed sample cannot change identity", lambda: db.execute("UPDATE memory_event_observations SET sample_ordinal=5 WHERE observation_id=?", (before,)))
db.execute("UPDATE memory_event_observations SET status='complete' WHERE observation_id=?", (after,))
ok("D: an unconfirmed sample may be corrected")
rejects("D: unknown element scope", lambda: insert("brain_scene_elements", scene_element_id="x", app_id=1, scene_id="scene1", element_key="x", element_scope="panel", first_seen_ms=0, last_seen_ms=0))
insert("brain_scene_roles", scene_id="scene1", role="AXButton")
ok("D: a role may be recorded as presence only (count_bucket NULL)")

# ---- signature round trip: container tree, controls with caption origin, collection, template
insert("brain_scenes", scene_id="sig", app_id=2, title_bucket="Settings", scene_kind="dialog", first_seen_ms=0, last_seen_ms=0)
insert("brain_scene_elements", scene_element_id="c_root", app_id=2, scene_id="sig", element_key="General", element_scope="container", role="AXGroup", first_seen_ms=0, last_seen_ms=0)
insert("brain_scene_elements", scene_element_id="c_sub", app_id=2, scene_id="sig", element_key="General / Privacy", element_scope="container", parent_element_id="c_root", role="AXGroup", first_seen_ms=0, last_seen_ms=0)
insert("brain_scene_elements", scene_element_id="b_ok", app_id=2, scene_id="sig", element_key="AXButton|ok", element_scope="control", parent_element_id="c_root", role="AXButton", label="OK", label_origin="title", first_seen_ms=0, last_seen_ms=0)
insert("brain_scene_elements", scene_element_id="cb_track", app_id=2, scene_id="sig", element_key="AXCheckBox|track", element_scope="control", parent_element_id="c_sub", role="AXCheckBox", label="Track", label_origin="description", first_seen_ms=0, last_seen_ms=0)
insert("brain_scene_elements", scene_element_id="f_name", app_id=2, scene_id="sig", element_key="AXTextField|@0", element_scope="control", parent_element_id="c_sub", role="AXTextField", label="Mario", label_origin="value", first_seen_ms=0, last_seen_ms=0)
insert("brain_scene_elements", scene_element_id="coll", app_id=2, scene_id="sig", element_key="General / People", element_scope="collection", parent_element_id="c_root", role="AXTable", first_seen_ms=0, last_seen_ms=0)
insert("brain_scene_elements", scene_element_id="tpl", app_id=2, scene_id="sig", element_key="AXRow", element_scope="item_template", parent_element_id="coll", role="AXRow", first_seen_ms=0, last_seen_ms=0)


def skeleton(scene_id):
    rows = db.execute("SELECT scene_element_id, parent_element_id, element_scope, role, label, label_origin, element_key "
                      "FROM brain_scene_elements WHERE scene_id=?", (scene_id,)).fetchall()
    by_id = {r[0]: r for r in rows}

    def path(eid):
        chain = []
        while eid is not None:
            r = by_id[eid]
            if r[2] == "container": chain.append(r[6])
            eid = r[1]
        return " / ".join(reversed(chain)) or "<root>"
    roles, captions, collections = {}, {}, set()
    for r in rows:
        if r[2] == "container": continue
        p = path(r[1])
        if r[2] == "collection": collections.add(p); continue
        if r[2] == "item_template": continue
        roles.setdefault(p, set()).add(r[3])
        if r[5] in ("title", "description"): captions.setdefault(p, set()).add((r[3], (r[4] or "").lower()))
    kind, bucket = db.execute("SELECT scene_kind, title_bucket FROM brain_scenes WHERE scene_id=?", (scene_id,)).fetchone()
    # The title bucket is a search hint for people and ordering, never part of the identity (a dialog
    # titled after a file must not become one scene per file).
    return {"surface": kind, "title_hint": bucket,
            "roles": roles, "captions": captions, "collections": collections}


# A nested container's element_key is its own segment; the path is rebuilt from the parent chain.
db.execute("UPDATE brain_scene_elements SET element_key='Privacy' WHERE scene_element_id='c_sub'")
expected = {"surface": "dialog", "title_hint": "Settings",
            "roles": {"General": {"AXButton"}, "General / Privacy": {"AXCheckBox", "AXTextField"}},
            "captions": {"General": {("AXButton", "ok")}, "General / Privacy": {("AXCheckBox", "track")}},
            "collections": {"General"}}
assert skeleton("sig") == expected, skeleton("sig")
ok("D: structure-v2 skeleton (surface, role sets and captions per path, collections; title only a hint) rebuilds from SQL; a value-origin label is not a caption")

# ================================================================== E. brain applications (S2 3a)
def application_argument(app_id, name, position=0, app=1, **value):
    kind, column = next((k, c) for k, c in (("text", "text_value"), ("integer", "integer_value"), ("real", "real_value"), ("boolean", "boolean_value")) if c in value)
    insert("memory_operation_arguments", brain_application_id=app_id, app_id=app, argument_name=name, position=position,
           value_kind=kind, **{column: value[column]})


def application(app_id, event_id, operation="observe", app=1, outcome=None, **extra):
    row = dict(application_id=app_id, app_id=app, event_id=event_id, operation=operation, contract_version=1,
               algorithm_version="brain-updater-1", requested_at_ms=100, effective_at_ms=100)
    if operation == "observe":
        row.update(outcome=outcome or "observed", created_count=0, updated_count=0, skipped_ambiguous_count=0)
    elif operation == "record":
        row.update(outcome=outcome or "no_effect")
    else:
        row.update(outcome=outcome or "not_named")
    row.update(extra)
    insert("brain_applications", **{k: v for k, v in row.items() if v is not None})


act_before = db.execute("SELECT observation_id FROM memory_event_observations WHERE event_id='act_click' AND phase='before' AND sample_ordinal=0 AND observation_kind='capture'").fetchone()[0]
act_after1 = db.execute("SELECT observation_id FROM memory_event_observations WHERE event_id='act_click' AND phase='after' AND sample_ordinal=1 AND observation_kind='capture'").fetchone()[0]
insert("memory_event_observations", event_id="act_click", phase="before", sample_ordinal=0, observation_kind="capture_field",
       field_name="window_role", text_value="AXWindow", status="observed", parent_observation_id=act_before)
act_field = db.execute("SELECT last_insert_rowid()").fetchone()[0]
sample = dict(phase="before", sample_ordinal=0, sample_observation_id=act_before, sample_kind="capture")
application_argument(1, "detection_count", integer_value=0)
application(1, "act_click", **sample)
application_argument(2, "detection_count", integer_value=0)
application(2, "act_click", phase="after", sample_ordinal=1, sample_observation_id=act_after1, sample_kind="capture")
application_argument(3, "verb", text_value="click")
application(3, "tool_act", operation="record")
application_argument(4, "anchor_key", text_value="no-such-anchor")
application_argument(4, "name", text_value="")
application(4, "tool_act", operation="set_name")
assert db.execute("SELECT count(*) FROM brain_applications").fetchone()[0] == 4
assert db.execute("PRAGMA foreign_key_check").fetchall() == []
ok("E: observations of two samples of one event, a record and a failed naming of a literal key are four concluded applications")
rejects("E: the same observation key twice", lambda: (application_argument(9, "detection_count", integer_value=0), application(9, "act_click", **sample)))
rejects("E: the same record key twice, NULL phase and ordinal do not bypass the key", lambda: (application_argument(9, "verb", text_value="click"), application(9, "tool_act", operation="record")))
rejects("E: the same naming key twice", lambda: (application_argument(9, "name", text_value="x"), application(9, "tool_act", operation="set_name")))
rejects("E: an application without its arguments", lambda: application(9, "act_click", phase="after", sample_ordinal=0, sample_observation_id=after, sample_kind="capture"))
rejects("E: an observation's sample must be the capture row of its event, phase and ordinal (a field row)", lambda: (application_argument(9, "detection_count", integer_value=0), application(9, "act_click", phase="before", sample_ordinal=0, sample_observation_id=act_field, sample_kind="capture")))
rejects("E: an observation's sample of another phase", lambda: (application_argument(9, "detection_count", integer_value=0), application(9, "act_click", phase="current", sample_ordinal=0, sample_observation_id=act_before, sample_kind="capture")))
rejects("E: an observation's sample of another event", lambda: (application_argument(9, "detection_count", integer_value=0), application(9, "tool_act", phase="before", sample_ordinal=0, sample_observation_id=act_before, sample_kind="capture")))
rejects("E: an observation without its sample", lambda: (application_argument(9, "detection_count", integer_value=0), application(9, "act_click")))
rejects("E: a record with a phase", lambda: (application_argument(9, "verb", text_value="click"), application(9, "act_click", operation="record", phase="after")))
rejects("E: an application of another application's event", lambda: (application_argument(9, "verb", text_value="click", app=2), application(9, "tool_act", operation="record", app=2)))
rejects("E: a record of an event that is not an action", lambda: (application_argument(9, "verb", text_value="click"), application(9, "watch1", operation="record")))
rejects("E: an operation's outcome must be one of its own", lambda: (application_argument(9, "verb", text_value="click"), application(9, "cli_act", operation="record", outcome="named", anchor_id="anchor1_return")))
rejects("E: a recorded outcome needs its transition and evidence", lambda: (application_argument(9, "verb", text_value="click"), application(9, "cli_act", operation="record", outcome="recorded", anchor_id="anchor1_return")))
rejects("E: an outcome without counts carries none", lambda: (application_argument(9, "verb", text_value="click"), application(9, "cli_act", operation="record", created_count=1)))
rejects("E: an effective instant earlier than the requested one", lambda: (application_argument(9, "verb", text_value="click"), application(9, "cli_act", operation="record", effective_at_ms=99)))
rejects("E: an unknown operation", lambda: (application_argument(9, "verb", text_value="click"), application(9, "cli_act", operation="forget")))
rejects("E: a concluded application is immutable", lambda: db.execute("UPDATE brain_applications SET effective_at_ms = 500 WHERE application_id = 3"))
rejects("E: a concluded application is kept", lambda: db.execute("DELETE FROM brain_applications WHERE application_id = 3"))
rejects("E: a concluded application's input is sealed", lambda: application_argument(3, "target_kind", text_value="control"))
rejects("E: an application's input is immutable", lambda: db.execute("UPDATE memory_operation_arguments SET text_value = 'double_click' WHERE brain_application_id = 3"))
rejects("E: an application's input is kept", lambda: db.execute("DELETE FROM memory_operation_arguments WHERE brain_application_id = 3"))
rejects("E: an argument with an application and an action as owners", lambda: insert("memory_operation_arguments", brain_application_id=3, event_id="tool_act", app_id=1, argument_name="x", value_kind="text", text_value="x"))
rejects("E: an application's argument names no Route", lambda: insert("memory_operation_arguments", brain_application_id=3, route_id="route1", app_id=1, argument_name="x", value_kind="text", text_value="x"))
rejects("E: an application's argument is a plain value, never an anchor reference", lambda: insert("memory_operation_arguments", brain_application_id=3, app_id=1, argument_name="x", value_kind="anchor", anchor_id="anchor1_return"))
rejects("E: an application's argument names its app", lambda: insert("memory_operation_arguments", brain_application_id=3, argument_name="x", value_kind="text", text_value="x"))
rejects("E: a sample an application references keeps its identity", lambda: db.execute("UPDATE memory_event_observations SET phase = 'current' WHERE observation_id = ?", (act_after1,)))
rejects("E: a sample an application references cannot be deleted", lambda: db.execute("DELETE FROM memory_event_observations WHERE observation_id = ?", (act_after1,)))
db.execute("SAVEPOINT deferred_case")
application_argument(77, "verb", text_value="click")
orphans = db.execute("PRAGMA foreign_key_check(memory_operation_arguments)").fetchall()
db.execute("ROLLBACK TO deferred_case")
db.execute("RELEASE deferred_case")
assert len(orphans) == 1 and orphans[0][2] == "brain_applications", orphans
ok("E: an argument whose application never arrives breaks the deferred key to brain_applications")
db.execute("SAVEPOINT deferred_case")
application_argument(78, "verb", text_value="click", app=2)
insert("brain_applications", application_id=78, app_id=1, event_id="cli_act", operation="record", contract_version=1, algorithm_version="v", requested_at_ms=1, effective_at_ms=1, outcome="no_effect")
cross = db.execute("PRAGMA foreign_key_check(memory_operation_arguments)").fetchall()
db.execute("ROLLBACK TO deferred_case")
db.execute("RELEASE deferred_case")
assert len(cross) == 1, cross
ok("E: an argument of another application's app breaks the composite key to its application")
assert db.execute("PRAGMA foreign_key_check").fetchall() == []
assert db.execute("SELECT count(*) FROM memory_operation_arguments WHERE brain_application_id IS NOT NULL").fetchone()[0] == 5

# ================================================================== schema 2 (G76 D1): run on the schema 1 file above
# Schema 2 adds tables, triggers and indexes only: the migration's text runs on an archive of schema 1 with rows.
db.executescript(PARTS[2])
assert db.execute("PRAGMA foreign_key_check").fetchall() == []
ok("schema 2: its text runs on a populated schema 1 file and every foreign key still holds")

event("v2_call")
insert("memory_agent_actions", event_id="v2_call", app_id=1, tool_kind="act", execution_status="completed",
       started_at_ms=100, completed_at_ms=101)
event("v2_open")
insert("memory_agent_actions", event_id="v2_open", app_id=1, tool_kind="act", execution_status="started", started_at_ms=100)
insert("memory_tasks", task_id="t1", contract_version=1, source="app", source_stream_id="worker", opened_at_ms=100,
       status="open", current_revision=1)
insert("memory_task_revisions", task_id="t1", revision=1, recorded_at_ms=100, change_kind="opened", goal="Export")
insert("memory_task_constraints", task_id="t1", revision=1, position=0, constraint_text="same folder")
insert("memory_task_message_refs", task_id="t1", revision=1, position=0, message_ref="m1")
insert("memory_task_values", task_id="t1", revision=1, position=0, name="file", value_kind="file", content="text",
       text_value="a.png", sensitivity="ordinary", source="request")
insert("memory_task_values", task_id="t1", revision=1, position=1, name="password", value_kind="text", content="withheld",
       sensitivity="secret", source="message", source_ref="m1")
insert("memory_task_occurrences", task_occurrence_id="o1", started_at_ms=100, status="in_progress")
insert("memory_task_attempts", task_occurrence_id="o1", task_id="t1", ordinal=1, source="app", source_stream_id="worker",
       opened_at_ms=100, opened_at_revision=1)
insert("memory_task_events", task_occurrence_id="o1", event_id="v2_call", position=0, role="action")
insert("memory_task_call_revisions", event_id="v2_call", task_occurrence_id="o1", task_id="t1", revision=1)
insert("memory_task_checkpoints", task_occurrence_id="o1", sequence=1, checkpoint_kind="checkpoint", task_id="t1",
       revision=1, recorded_at_ms=101, note="half")
insert("memory_task_values", task_id="t1", task_occurrence_id="o1", checkpoint_sequence=1, position=0, name="out",
       value_kind="file", content="text", text_value="b.jpg", sensitivity="ordinary", source="derived")
ok("schema 2: a task with its revision, constraint, message reference, inputs (a secret withheld), attempt, attributed call and checkpoint with an output")
rejects("schema 2: a revision out of order", lambda: insert("memory_task_revisions", task_id="t1", revision=3, recorded_at_ms=1,
                                                        change_kind="revised", goal="g"))
rejects("schema 2: a second revision marked opened", lambda: insert("memory_task_revisions", task_id="t1", revision=2,
                                                                recorded_at_ms=1, change_kind="opened", goal="g"))
rejects("schema 2: a revision is immutable", lambda: db.execute("UPDATE memory_task_revisions SET goal='x' WHERE task_id='t1'"))
rejects("schema 2: a message reference twice in a revision", lambda: insert("memory_task_message_refs", task_id="t1", revision=1,
                                                                        position=1, message_ref="m1"))
rejects("schema 2: a secret with its text", lambda: insert("memory_task_values", task_id="t1", revision=1, position=2, name="pin",
                                                       value_kind="text", content="text", text_value="1234",
                                                       sensitivity="secret", source="request"))
rejects("schema 2: a missing value with a text", lambda: insert("memory_task_values", task_id="t1", revision=1, position=2,
                                                            name="fmt", value_kind="missing", content="text", text_value="x",
                                                            sensitivity="ordinary", source="request"))
rejects("schema 2: a previous output with no reference", lambda: insert("memory_task_values", task_id="t1", revision=1, position=2,
                                                                    name="doc", value_kind="file", content="text",
                                                                    text_value="d", sensitivity="ordinary",
                                                                    source="previous_output"))
rejects("schema 2: an input name twice in a revision", lambda: insert("memory_task_values", task_id="t1", revision=1, position=2,
                                                                  name="file", value_kind="file", content="missing",
                                                                  sensitivity="ordinary", source="request"))
rejects("schema 2: a closed task with no close instant", lambda: db.execute("UPDATE memory_tasks SET status='completed' WHERE task_id='t1'"))
rejects("schema 2: a task's revision moved to one that does not exist", lambda: db.execute("UPDATE memory_tasks SET current_revision=5 WHERE task_id='t1'"))
rejects("schema 2: a task's identity is immutable", lambda: db.execute("UPDATE memory_tasks SET source_stream_id='other' WHERE task_id='t1'"))
rejects("schema 2: a second attempt that resumes nothing", lambda: (
    insert("memory_task_occurrences", task_occurrence_id="o2", started_at_ms=100, status="in_progress"),
    insert("memory_task_attempts", task_occurrence_id="o2", task_id="t1", ordinal=2, source="app", source_stream_id="worker",
           opened_at_ms=100, opened_at_revision=1)))
rejects("schema 2: a checkpoint out of order", lambda: insert("memory_task_checkpoints", task_occurrence_id="o1", sequence=3,
                                                          checkpoint_kind="checkpoint", task_id="t1", revision=1, recorded_at_ms=1))
rejects("schema 2: an end with no declared status", lambda: insert("memory_task_checkpoints", task_occurrence_id="o1", sequence=2,
                                                               checkpoint_kind="end", task_id="t1", revision=1, recorded_at_ms=1))
insert("memory_task_checkpoints", task_occurrence_id="o1", sequence=2, checkpoint_kind="end", task_id="t1", revision=1,
       recorded_at_ms=102, declared_status="completed")
db.execute("UPDATE memory_tasks SET status='completed', closed_at_ms=102 WHERE task_id='t1'")
rejects("schema 2: nothing follows an end", lambda: insert("memory_task_checkpoints", task_occurrence_id="o1", sequence=3,
                                                       checkpoint_kind="checkpoint", task_id="t1", revision=1, recorded_at_ms=1))
rejects("schema 2: a closed task does not move", lambda: db.execute("UPDATE memory_tasks SET status='open', closed_at_ms=NULL WHERE task_id='t1'"))
ok("schema 2: an end closes the attempt and the task once")

insert("memory_call_effects", event_id="v2_call", performed="substitute", substitute="escape", target_element_id="e",
       target_label="Export", checked=1)
rejects("schema 2: an effect of a call not concluded", lambda: insert("memory_call_effects", event_id="v2_open", performed="requested", checked=1))
rejects("schema 2: a substitute without its name", lambda: (event("v2_x"), insert("memory_agent_actions", event_id="v2_x", app_id=1,
        tool_kind="act", execution_status="completed", started_at_ms=1, completed_at_ms=2),
        insert("memory_call_effects", event_id="v2_x", performed="substitute", checked=1)))
event("v2_y")
insert("memory_agent_actions", event_id="v2_y", app_id=1, tool_kind="act", execution_status="completed", started_at_ms=1,
       completed_at_ms=2)
rejects("schema 2: a reason for a gesture that went out", lambda: insert("memory_call_effects", event_id="v2_y",
                                                                     performed="requested", not_sent_reason="miss", checked=1))
insert("memory_call_effects", event_id="v2_y", performed="none", not_sent_reason="honest_miss", checked=1)
rejects("schema 2: an effect is immutable", lambda: db.execute("UPDATE memory_call_effects SET performed='none', substitute=NULL WHERE event_id='v2_call'"))
event("v2_check", kind="verification")
insert("memory_verifications", event_id="v2_check", scope="call", method="scene_difference", verdict="unknown")
insert("memory_operation_verifications", event_id="v2_check", call_event_id="v2_call", contract_version=1,
       condition_kind="recovery_instead_of_request", method_version="engine-oracle-1", performed="substitute", substitute="escape")
insert("memory_operation_verification_limits", event_id="v2_check", position=0, limit_kind="no_expectation")
capture("v2_call", phase="after")
after_id = db.execute("SELECT observation_id FROM memory_event_observations WHERE event_id='v2_call' AND phase='after'").fetchone()[0]
insert("memory_operation_verification_samples", event_id="v2_check", position=0, sample_observation_id=after_id,
       sample_event_id="v2_call", sample_phase="after", sample_ordinal=0)
ok("schema 2: a verification of a call with its condition, method version, limit and sample")
event("v2_step", kind="verification")
insert("memory_verifications", event_id="v2_step", scope="step", method="none", verdict="unknown")
rejects("schema 2: an operation verification whose verdict row is not of scope call", lambda: insert(
    "memory_operation_verifications", event_id="v2_step", call_event_id="v2_call", contract_version=1, condition_kind="none",
    method_version="v", performed="none"))
rejects("schema 2: an unknown condition", lambda: (event("v2_bad", kind="verification"),
        insert("memory_verifications", event_id="v2_bad", scope="call", method="none", verdict="unknown"),
        insert("memory_operation_verifications", event_id="v2_bad", call_event_id="v2_call", contract_version=1,
               condition_kind="goal_reached", method_version="v", performed="requested")))
rejects("schema 2: two verifications of one condition of one call", lambda: (event("v2_twice", kind="verification"),
        insert("memory_verifications", event_id="v2_twice", scope="call", method="none", verdict="unknown"),
        insert("memory_operation_verifications", event_id="v2_twice", call_event_id="v2_call", contract_version=1,
               condition_kind="recovery_instead_of_request", method_version="v", performed="none")))
rejects("schema 2: an unknown limit", lambda: insert("memory_operation_verification_limits", event_id="v2_check", position=1,
                                                 limit_kind="trust_me"))
rejects("schema 2: a verification's sample of another phase", lambda: insert("memory_operation_verification_samples",
        event_id="v2_check", position=1, sample_observation_id=after_id, sample_event_id="v2_call", sample_phase="before",
        sample_ordinal=0))
rejects("schema 2: a verification is immutable", lambda: db.execute("UPDATE memory_operation_verifications SET method_version='w'"))

insert("memory_value_redactions", event_id="v2_call", location_kind="argument", argument_name="text", argument_position=0,
       reason="secret_target")
insert("memory_value_redactions", event_id="v2_call", location_kind="sample_title", sample_phase="after", sample_ordinal=0,
       reason="credential_pattern")
rejects("schema 2: an argument gap with no argument", lambda: insert("memory_value_redactions", event_id="v2_call",
                                                                 location_kind="argument", reason="declared_secret"))
rejects("schema 2: a title gap names no element", lambda: insert("memory_value_redactions", event_id="v2_call",
        location_kind="sample_title", sample_phase="after", sample_ordinal=1, element_position=0, reason="credential_pattern"))
rejects("schema 2: the same gap twice", lambda: insert("memory_value_redactions", event_id="v2_call", location_kind="argument",
                                                   argument_name="text", argument_position=0, reason="declared_secret"))
rejects("schema 2: a declared gap is kept", lambda: db.execute("DELETE FROM memory_value_redactions"))
for kind in ["target_section", "target_element", "observed_effect"]:
    insert("memory_value_redactions", event_id="v2_call", location_kind=kind, reason="declared_secret")
insert("memory_value_redactions", event_id="v2_call", location_kind="listing_entry", element_position=2, reason="credential_pattern")
insert("memory_value_redactions", event_id="v2_call", location_kind="sample_container", sample_phase="after", sample_ordinal=0,
       element_position=0, reason="declared_secret")
rejects("schema 2: a listing gap names no application", lambda: insert("memory_value_redactions", event_id="v2_call",
        location_kind="listing_entry", reason="declared_secret"))
rejects("schema 2: a container gap names no element", lambda: insert("memory_value_redactions", event_id="v2_call",
        location_kind="sample_container", sample_phase="after", sample_ordinal=1, reason="declared_secret"))
rejects("schema 2: an effect gap with a sample", lambda: insert("memory_value_redactions", event_id="v2_call",
        location_kind="observed_effect", sample_phase="after", sample_ordinal=2, reason="declared_secret"))
insert("memory_call_recording_gaps", event_id="v2_y", part="verification", reason="refused", detail="the contract refused it")
insert("memory_call_recording_gaps", event_id="v2_y", part="samples", reason="conflict")
rejects("schema 2: a recording gap of a call not concluded", lambda: insert("memory_call_recording_gaps", event_id="v2_open",
                                                                       part="effect", reason="refused"))
rejects("schema 2: the same part unsaved twice", lambda: insert("memory_call_recording_gaps", event_id="v2_y",
                                                           part="verification", reason="conflict"))
rejects("schema 2: an unknown unsaved part", lambda: insert("memory_call_recording_gaps", event_id="v2_y", part="result",
                                                        reason="refused"))
rejects("schema 2: an empty detail", lambda: insert("memory_call_recording_gaps", event_id="v2_y", part="effect",
                                                reason="refused", detail=""))
rejects("schema 2: a recording gap is immutable", lambda: db.execute("UPDATE memory_call_recording_gaps SET reason='conflict'"))
rejects("schema 2: a recording gap is kept", lambda: db.execute("DELETE FROM memory_call_recording_gaps"))
insert("memory_archive_origins", origin_id="mcp-profile:A", origin_kind="mcp_profile", location="MCP/Knowledge/A",
       status="completed", first_seen_at_ms=1, updated_at_ms=1)
insert("memory_origin_events", origin_id="mcp-profile:A", source_event_id="v2_call", event_id="v2_call", disposition="duplicate")
rejects("schema 2: a renamed fact under its own identity", lambda: insert("memory_origin_events", origin_id="mcp-profile:A",
        source_event_id="v2_open", event_id="v2_open", disposition="renamed"))
rejects("schema 2: the source of a transferred fact is immutable", lambda: db.execute("UPDATE memory_origin_events SET disposition='added'"))
insert("memory_origin_brain_contributions", origin_id="mcp-profile:A", bundle_id="com.x", element_kind="anchor",
       element_key="anchor-1", disposition="added")
insert("memory_origin_brain_contributions", origin_id="mcp-profile:A", bundle_id="com.x", element_kind="group",
       element_key="group-1", disposition="excluded")
rejects("schema 2: an element contributed twice", lambda: insert("memory_origin_brain_contributions", origin_id="mcp-profile:A",
        bundle_id="com.x", element_kind="anchor", element_key="anchor-1", disposition="present"))
rejects("schema 2: an unknown contribution", lambda: insert("memory_origin_brain_contributions", origin_id="mcp-profile:A",
        bundle_id="com.x", element_kind="scene", element_key="s", disposition="added"))
rejects("schema 2: a contribution of an origin never journaled", lambda: insert("memory_origin_brain_contributions",
        origin_id="mcp-profile:Z", bundle_id="com.x", element_kind="anchor", element_key="a", disposition="added"))
rejects("schema 2: what an origin contributed is immutable", lambda: db.execute(
        "UPDATE memory_origin_brain_contributions SET disposition='present'"))
rejects("schema 2: what an origin contributed is kept", lambda: db.execute("DELETE FROM memory_origin_brain_contributions"))
insert("memory_origin_brain_contributions", origin_id="mcp-profile:A", bundle_id="com.x", element_kind="application",
       element_key="e1/record", disposition="excluded", withheld=1)
rejects("schema 2: withheld is a flag", lambda: insert("memory_origin_brain_contributions", origin_id="mcp-profile:A",
        bundle_id="com.x", element_kind="anchor", element_key="anchor-2", disposition="added", withheld=2))
db.execute("UPDATE memory_archive_origins SET status='partial' WHERE origin_id='mcp-profile:A'")
rejects("schema 2: an unknown origin status", lambda: db.execute(
        "UPDATE memory_archive_origins SET status='done' WHERE origin_id='mcp-profile:A'"))
insert("memory_schema_migrations", to_version=2, from_version=1, migrated_at_ms=1, copy_name="memory.sqlite.schema-1-x")
rejects("schema 2: a migration from schema 1 names its copy", lambda: insert("memory_schema_migrations", to_version=3,
                                                                         from_version=1, migrated_at_ms=1))
assert db.execute("PRAGMA foreign_key_check").fetchall() == []
ok("schema 2: gaps, origins and the migration record keep their shapes")

# ================================================================== schema 3 (D2): procedures, parts, qualification, relations
scenes_before = db.execute("SELECT count(*) FROM brain_scenes WHERE scene_kind <> 'app'").fetchone()[0]
db.executescript(PARTS[3] + "\n" + DERIVED)
assert db.execute("SELECT count(*) FROM brain_scene_shapes").fetchone()[0] == scenes_before
assert db.execute("SELECT role_key FROM brain_scene_shapes WHERE scene_id='scene1'").fetchone()[0] == "\x1f".join(sorted(
    r[0] for r in db.execute("SELECT role FROM brain_scene_roles WHERE scene_id='scene1'")))
ok("schema 3: the shape of every structural scene the file held is filled from its roles, none for the app scope")
rejects("schema 3: the app scope has no shape", lambda: insert("brain_scene_shapes", scene_id="app_scope1", app_id=1, role_key=""))
rejects("schema 3: a shape is immutable", lambda: db.execute("UPDATE brain_scene_shapes SET role_key='x' WHERE scene_id='scene1'"))

insert("memory_step_occurrences", step_occurrence_id="occ_v2", task_occurrence_id="o1", started_at_ms=100, status="completed",
       assigned_by="braus-segmentation")
insert("memory_step_events", step_occurrence_id="occ_v2", event_id="v2_call", position=0, role="action")
insert("memory_procedure_candidates", candidate_id="c1", task_id="t1", task_occurrence_id="o1", policy_version="app-blocks-1",
       structure_digest="d1", checkpoint_sequence=1, built_at_ms=100, step_count=1, block_count=1)
insert("memory_candidate_steps", candidate_id="c1", position=0, step_occurrence_id="occ_v2", call_event_id="v2_call",
       block_index=0, app_id=1)
ok("schema 3: a candidate of an attempt with one step, the occurrence of a started operation of that attempt")
insert("memory_step_occurrences", step_occurrence_id="occ_open", task_occurrence_id="o1", started_at_ms=100, status="in_progress",
       assigned_by="braus-segmentation")
insert("memory_step_events", step_occurrence_id="occ_open", event_id="v2_open", position=0, role="action")
rejects("schema 3: a step of a call the attempt was never attributed", lambda: insert("memory_candidate_steps", candidate_id="c1",
        position=1, step_occurrence_id="occ_open", call_event_id="v2_open", block_index=0, app_id=1))
insert("memory_task_events", task_occurrence_id="o1", event_id="v2_open", position=1, role="action")
rejects("schema 3: a step that does not follow the last one", lambda: insert("memory_candidate_steps", candidate_id="c1",
        position=2, step_occurrence_id="occ_open", call_event_id="v2_open", block_index=0, app_id=1))
rejects("schema 3: a new block on the same application", lambda: insert("memory_candidate_steps", candidate_id="c1",
        position=1, step_occurrence_id="occ_open", call_event_id="v2_open", block_index=1, app_id=1))
rejects("schema 3: a step whose occurrence is another call's", lambda: insert("memory_candidate_steps", candidate_id="c1",
        position=1, step_occurrence_id="occ_v2", call_event_id="v2_open", block_index=0, app_id=1))
rejects("schema 3: a step whose application is not its call's", lambda: insert("memory_candidate_steps", candidate_id="c1",
        position=1, step_occurrence_id="occ_open", call_event_id="v2_open", block_index=1, app_id=2))
event("v3_batch")
insert("memory_agent_actions", event_id="v3_batch", app_id=1, tool_kind="batch", execution_status="completed", started_at_ms=1,
       completed_at_ms=2)
insert("memory_task_events", task_occurrence_id="o1", event_id="v3_batch", position=2, role="action")
insert("memory_step_occurrences", step_occurrence_id="occ_batch", started_at_ms=1, status="completed")
insert("memory_step_events", step_occurrence_id="occ_batch", event_id="v3_batch", position=0, role="action")
rejects("schema 3: a batch is a container, never a step", lambda: insert("memory_candidate_steps", candidate_id="c1", position=1,
        step_occurrence_id="occ_batch", call_event_id="v3_batch", block_index=0, app_id=1))
rejects("schema 3: a candidate of no step", lambda: insert("memory_procedure_candidates", candidate_id="c0", task_id="t1",
        task_occurrence_id="o1", policy_version="p", structure_digest="d0", built_at_ms=1, step_count=0, block_count=0))
rejects("schema 3: one structure of an attempt is one candidate", lambda: insert("memory_procedure_candidates", candidate_id="c9",
        task_id="t1", task_occurrence_id="o1", policy_version="app-blocks-1", structure_digest="d1", built_at_ms=1, step_count=1,
        block_count=1))
rejects("schema 3: a candidate is immutable", lambda: db.execute("UPDATE memory_procedure_candidates SET built_at_ms=5"))
rejects("schema 3: a candidate is kept", lambda: db.execute("DELETE FROM memory_candidate_steps"))

insert("memory_procedure_interpretations", interpretation_id="i1", candidate_id="c1", revision=1, contract_version=1,
       payload_digest="12-abc", source="app", source_stream_id="worker", task_revision=1, attempt_state="ended", recorded_at_ms=101)
rejects("schema 3: an interpretation revision out of order", lambda: insert("memory_procedure_interpretations", interpretation_id="i3",
        candidate_id="c1", revision=3, contract_version=1, payload_digest="x", source="app", source_stream_id="worker",
        task_revision=1, attempt_state="ended", recorded_at_ms=1))
rejects("schema 3: an unknown attempt state", lambda: insert("memory_procedure_interpretations", interpretation_id="i2",
        candidate_id="c1", revision=2, contract_version=1, payload_digest="x", source="app", source_stream_id="worker",
        task_revision=1, attempt_state="paused", recorded_at_ms=1))
rejects("schema 3: an interpretation is immutable", lambda: db.execute("UPDATE memory_procedure_interpretations SET payload_digest='y'"))
insert("memory_interpretation_findings", interpretation_id="i1", position=0, finding="use_mismatch", step_position=0,
       argument_name="text", argument_position=0)
rejects("schema 3: an unknown finding", lambda: insert("memory_interpretation_findings", interpretation_id="i1", position=1,
        finding="wrong_intent", step_position=0, argument_name="text", argument_position=0))

insert("memory_routes", route_id="v1", name="Esportare <documento>", status="draft", created_at_ms=101)
insert("memory_route_steps", step_id="v1s0", route_id="v1", position=0, step_kind="goal", goal_text="Impostare il nome", app_id=1)
insert("memory_route_parameters", parameter_id="v1p0", route_id="v1", name="nome_output", direction="input", value_type="text",
       is_required=1)
insert("memory_step_operations", operation_id="v1op0", route_id="v1", step_id="v1s0", app_id=1, position=0, tool_kind="type_text")
insert("memory_operation_argument_segments", route_id="v1", operation_id="v1op0", argument_name="text", argument_position=0,
       argument_index=1, segment_position=0, segment_kind="parameter", parameter_id="v1p0")
insert("memory_operation_argument_segments", route_id="v1", operation_id="v1op0", argument_name="text", argument_position=0,
       argument_index=1, segment_position=1, segment_kind="literal", literal_text=".jpg")
argument("target", "Nome", operation_id="v1op0", route_id="v1", app_id=1)
ok("schema 3: a definition step of one operation whose text is a template of a parameter and a literal")
rejects("schema 3: an argument that is a row and a template", lambda: argument("text", "x", operation_id="v1op0", route_id="v1",
                                                                              app_id=1))
rejects("schema 3: a template segment of an argument that is a row", lambda: insert("memory_operation_argument_segments",
        route_id="v1", operation_id="v1op0", argument_name="target", argument_position=0, argument_index=0, segment_position=0,
        segment_kind="literal", literal_text="x"))
rejects("schema 3: an empty literal segment", lambda: insert("memory_operation_argument_segments", route_id="v1",
        operation_id="v1op0", argument_name="text", argument_position=0, argument_index=1, segment_position=2,
        segment_kind="literal", literal_text=""))
rejects("schema 3: a parameter segment with a literal", lambda: insert("memory_operation_argument_segments", route_id="v1",
        operation_id="v1op0", argument_name="text", argument_position=0, argument_index=1, segment_position=2,
        segment_kind="parameter", parameter_id="v1p0", literal_text="x"))

insert("memory_procedure_versions", route_id="v1", interpretation_id="i1", candidate_id="c1", task_id="t1", task_occurrence_id="o1",
       contract_version=1, built_at_ms=101)
rejects("schema 3: a version is immutable", lambda: db.execute("UPDATE memory_procedure_versions SET built_at_ms=1"))
rejects("schema 3: a variant without its divergence", lambda: (
    insert("memory_routes", route_id="v9", name="n", status="draft", created_at_ms=1),
    insert("memory_procedure_interpretations", interpretation_id="i9", candidate_id="c1", revision=2, contract_version=1,
           payload_digest="z", source="app", source_stream_id="worker", task_revision=1, attempt_state="ended", recorded_at_ms=1),
    insert("memory_procedure_versions", route_id="v9", interpretation_id="i9", candidate_id="c1", task_id="t1",
           task_occurrence_id="o1", contract_version=1, variant_of_route_id="v1", built_at_ms=1)))
rejects("schema 3: a variant diverging past the version it names", lambda: (
    insert("memory_routes", route_id="v9", name="n", status="draft", created_at_ms=1),
    insert("memory_procedure_interpretations", interpretation_id="i9", candidate_id="c1", revision=2, contract_version=1,
           payload_digest="z", source="app", source_stream_id="worker", task_revision=1, attempt_state="ended", recorded_at_ms=1),
    insert("memory_procedure_versions", route_id="v9", interpretation_id="i9", candidate_id="c1", task_id="t1",
           task_occurrence_id="o1", contract_version=1, variant_of_route_id="v1", divergence_position=5, built_at_ms=1)))

insert("memory_procedure_parts", part_id="v1/procedure", route_id="v1", part_kind="procedure", first_position=0, last_position=0,
       app_id=1, label="Esportare <documento>", declared_outcome="completed")
insert("memory_procedure_parts", part_id="v1/step-0", route_id="v1", part_kind="step", parent_part_id="v1/procedure",
       first_position=0, last_position=0, step_id="v1s0", app_id=1, declared_outcome="not_declared")
ok("schema 3: a version's procedure part and its step part, the step unlabelled and kept")
rejects("schema 3: a procedure without a label", lambda: insert("memory_procedure_parts", part_id="x", route_id="v1",
        part_kind="procedure", first_position=0, last_position=0, declared_outcome="completed"))
rejects("schema 3: two procedure parts of one version", lambda: insert("memory_procedure_parts", part_id="x", route_id="v1",
        part_kind="procedure", first_position=0, last_position=1, label="altro", declared_outcome="completed"))
rejects("schema 3: a subprocedure inside a step: containment goes to a finer kind only", lambda: insert("memory_procedure_parts",
        part_id="x", route_id="v1", part_kind="subprocedure", parent_part_id="v1/step-0", first_position=0, last_position=0,
        declared_outcome="not_declared"))
rejects("schema 3: a part outside its parent's interval", lambda: insert("memory_procedure_parts", part_id="x", route_id="v1",
        part_kind="subprocedure", parent_part_id="v1/procedure", first_position=0, last_position=3, declared_outcome="not_declared"))
rejects("schema 3: a step part of another position than its step's", lambda: (
    insert("memory_route_steps", step_id="v1s1", route_id="v1", position=1, step_kind="goal", goal_text="g", app_id=1),
    insert("memory_procedure_parts", part_id="x", route_id="v1", part_kind="step", parent_part_id="v1/procedure",
           first_position=0, last_position=0, step_id="v1s1", declared_outcome="not_declared")))
rejects("schema 3: an unknown declared outcome", lambda: insert("memory_procedure_parts", part_id="x", route_id="v1",
        part_kind="subprocedure", parent_part_id="v1/procedure", first_position=0, last_position=0, declared_outcome="maybe"))
rejects("schema 3: a part is immutable", lambda: db.execute("UPDATE memory_procedure_parts SET label='x'"))
rejects("schema 3: a part is kept", lambda: db.execute("DELETE FROM memory_procedure_parts WHERE part_id='v1/step-0'"))

insert("memory_part_contract_items", part_id="v1/step-0", position=0, route_id="v1", item_kind="input", parameter_id="v1p0")
insert("memory_part_contract_items", part_id="v1/step-0", position=1, route_id="v1", item_kind="application", app_id=1)
insert("memory_part_contract_items", part_id="v1/step-0", position=2, route_id="v1", item_kind="entry_state", app_id=1)
insert("memory_part_contract_items", part_id="v1/procedure", position=0, route_id="v1", item_kind="entry_state", app_id=1,
       scene_id="scene1")
rejects("schema 3: an input that names no parameter", lambda: insert("memory_part_contract_items", part_id="v1/step-0",
        position=3, route_id="v1", item_kind="input"))
rejects("schema 3: an application with a state", lambda: insert("memory_part_contract_items", part_id="v1/procedure",
        position=1, route_id="v1", item_kind="application", app_id=1, scene_id="scene1"))
rejects("schema 3: the same input twice in a contract", lambda: insert("memory_part_contract_items", part_id="v1/step-0",
        position=3, route_id="v1", item_kind="input", parameter_id="v1p0"))
insert("memory_parameter_details", parameter_id="v1p0", route_id="v1", role="nome del file esportato", value_kind="file",
       sensitivity="ordinary", produced_by_part_id=None)
insert("memory_parameter_bindings", parameter_id="v1p0", route_id="v1", task_occurrence_id="o1", content="text",
       text_value="foto_web", source="request")
rejects("schema 3: a binding is immutable", lambda: db.execute("UPDATE memory_parameter_bindings SET text_value='x'"))
rejects("schema 3: a binding's text without content text", lambda: insert("memory_parameter_bindings", parameter_id="v1p0",
        route_id="v1", task_occurrence_id="o2", content="missing", text_value="x", source="request"))
db.execute("INSERT INTO memory_route_parameters (parameter_id, route_id, name, direction, value_type, is_required) VALUES ('v1p1', 'v1', 'pin', 'input', 'text', 1)")
insert("memory_parameter_details", parameter_id="v1p1", route_id="v1", role="codice", value_kind="text", sensitivity="secret")
rejects("schema 3: a secret parameter keeps no text", lambda: insert("memory_parameter_bindings", parameter_id="v1p1", route_id="v1",
        task_occurrence_id="o1", content="text", text_value="1234", source="request"))
insert("memory_parameter_bindings", parameter_id="v1p1", route_id="v1", task_occurrence_id="o1", content="withheld", source="request")
insert("memory_procedure_step_occurrences", route_id="v1", step_id="v1s0", step_occurrence_id="occ_v2")
rejects("schema 3: one occurrence for two steps of a version", lambda: insert("memory_procedure_step_occurrences", route_id="v1",
        step_id="v1s1", step_occurrence_id="occ_v2"))
ok("schema 3: a part's contract, a parameter's role, its episodic bindings (a secret withheld) and the step's occurrence")

insert("memory_qualification_policies", policy_version="qualification-a-1", status="active", changed_at_ms=100)
insert("memory_part_qualifications", part_id="v1/step-0", sequence=1, policy_version="qualification-a-1", verdict="refused",
       evaluated_at_ms=101)
insert("memory_part_qualification_reasons", part_id="v1/step-0", sequence=1, position=0, reason="missing_label")
insert("memory_part_qualification_reasons", part_id="v1/step-0", sequence=1, position=1, reason="verification_not_positive",
       step_position=0, call_event_id="v2_call")
insert("memory_part_qualifications", part_id="v1/procedure", sequence=1, policy_version="qualification-a-1", verdict="admitted",
       evaluated_at_ms=101)
insert("memory_part_qualification_evidence", part_id="v1/procedure", sequence=1, step_position=0, call_event_id="v2_call",
       verification_event_id="v2_check")
rejects("schema 3: an admitted part with a reason against it", lambda: insert("memory_part_qualification_reasons",
        part_id="v1/procedure", sequence=1, position=0, reason="missing_label"))
rejects("schema 3: an unknown reason", lambda: insert("memory_part_qualification_reasons", part_id="v1/step-0", sequence=1,
        position=2, reason="looks_wrong"))
rejects("schema 3: an evaluation out of order", lambda: insert("memory_part_qualifications", part_id="v1/step-0", sequence=3,
        policy_version="qualification-a-1", verdict="refused", evaluated_at_ms=1))
rejects("schema 3: evidence that is another call's verification", lambda: insert("memory_part_qualification_evidence",
        part_id="v1/procedure", sequence=1, step_position=0, call_event_id="v2_y", verification_event_id="v2_check"))
rejects("schema 3: an evaluation is immutable", lambda: db.execute("UPDATE memory_part_qualifications SET verdict='admitted'"))
rejects("schema 3: an evaluation is kept", lambda: db.execute("DELETE FROM memory_part_qualifications"))
rejects("schema 3: a quarantine without its reason", lambda: db.execute(
        "UPDATE memory_qualification_policies SET status='quarantined' WHERE policy_version='qualification-a-1'"))
db.execute("UPDATE memory_qualification_policies SET status='quarantined', reason='wrong rule', changed_at_ms=200")
rejects("schema 3: a policy change back in time", lambda: db.execute("UPDATE memory_qualification_policies SET changed_at_ms=1"))
insert("memory_part_states", part_id="v1/procedure", sequence=1, state="to_reevaluate", reason="policy quarantined",
       recorded_at_ms=200, recorded_by="test")
insert("memory_part_states", part_id="v1/procedure", sequence=2, state="retired", reason="smentita", recorded_at_ms=201,
       recorded_by="test")
rejects("schema 3: nothing follows retirement", lambda: insert("memory_part_states", part_id="v1/procedure", sequence=3,
        state="usable", reason="r", recorded_at_ms=202, recorded_by="test"))
rejects("schema 3: a state is appended, never changed", lambda: db.execute("UPDATE memory_part_states SET state='usable'"))
ok("schema 3: a part's evaluations with reasons and evidence, a policy in quarantine, a state history up to retirement")

insert("brain_relations", relation_id="r1", app_id=1, context_id=1, from_scene_id="scene1", element_key="control||AXButton|invia",
       verb="click", arguments_key="", to_scene_id="scene1", outcome="effect", effect_kind="elementsAppeared",
       first_seen_ms=100, last_seen_ms=100)
insert("brain_relations", relation_id="r2", app_id=1, context_id=1, from_scene_id="scene1", element_key="control||AXButton|invia",
       verb="click", arguments_key="", outcome="effect", effect_kind="windowTitleChanged", first_seen_ms=100, last_seen_ms=100)
insert("brain_relations", relation_id="r3", app_id=1, from_scene_id="scene1", element_key="control||AXCheckBox|attivo",
       verb="set_toggle", arguments_key="value=on", to_scene_id="scene1", outcome="already_satisfied", first_seen_ms=100,
       last_seen_ms=100)
ok("schema 3: alternatives of one group, a self-loop and a verified no-op as relations")
insert("brain_relations", relation_id="r5", app_id=1, context_id=1, from_scene_id="scene1", element_key="control||AXTextField|nome",
       verb="press_key", arguments_key="key=return", to_scene_id="scene1", outcome="effect", effect_kind="valueChanged",
       first_seen_ms=100, last_seen_ms=100)
ok("schema 3: a value change is a relation's effect family, named without its field or its value")
rejects("schema 3: an effect family no call observes", lambda: insert("brain_relations", relation_id="r6", app_id=1,
        from_scene_id="scene1", verb="click", arguments_key="", outcome="effect", effect_kind="valueSet", first_seen_ms=1,
        last_seen_ms=1))
rejects("schema 3: one relation twice under two ids", lambda: insert("brain_relations", relation_id="r4", app_id=1, context_id=1,
        from_scene_id="scene1", element_key="control||AXButton|invia", verb="click", arguments_key="", to_scene_id="scene1",
        outcome="effect", effect_kind="elementsAppeared", first_seen_ms=1, last_seen_ms=1))
rejects("schema 3: an effect without its family", lambda: insert("brain_relations", relation_id="r4", app_id=1,
        from_scene_id="scene1", verb="click", arguments_key="", outcome="effect", first_seen_ms=1, last_seen_ms=1))
rejects("schema 3: a verb fused under click", lambda: insert("brain_relations", relation_id="r4", app_id=1, from_scene_id="scene1",
        verb="hover", arguments_key="", outcome="value_set", first_seen_ms=1, last_seen_ms=1))
rejects("schema 3: a no-op that moves to another state", lambda: insert("brain_relations", relation_id="r4", app_id=1,
        from_scene_id="scene1", verb="set_toggle", arguments_key="value=on", outcome="already_satisfied", first_seen_ms=1,
        last_seen_ms=1))
rejects("schema 3: a relation from the app scope", lambda: insert("brain_relations", relation_id="r4", app_id=1,
        from_scene_id="app_scope1", verb="click", arguments_key="", outcome="value_set", first_seen_ms=1, last_seen_ms=1))
rejects("schema 3: a relation's identity is immutable", lambda: db.execute("UPDATE brain_relations SET verb='double_click' WHERE relation_id='r1'"))
db.execute("UPDATE brain_relations SET last_seen_ms=150 WHERE relation_id='r1'")
insert("brain_relation_proofs", relation_id="r1", call_event_id="v2_call", relation="supports", verification_event_id="v2_check",
       policy_version="brain-relations-1", assessed_at_ms=150)
insert("brain_relation_proofs", relation_id="r2", call_event_id="v2_call", relation="contradicts", verification_event_id="v2_check",
       policy_version="brain-relations-1", assessed_at_ms=150)
rejects("schema 3: one call proves a relation once", lambda: insert("brain_relation_proofs", relation_id="r1",
        call_event_id="v2_call", relation="contradicts", verification_event_id="v2_check", policy_version="p", assessed_at_ms=1))
rejects("schema 3: a proof by another call's verification", lambda: insert("brain_relation_proofs", relation_id="r3",
        call_event_id="v2_y", relation="supports", verification_event_id="v2_check", policy_version="p", assessed_at_ms=1))
rejects("schema 3: a proof is kept", lambda: db.execute("DELETE FROM brain_relation_proofs"))
insert("brain_relation_applications", call_event_id="v2_call", app_id=1, policy_version="brain-relations-1", outcome="supported",
       applied_at_ms=150)
insert("brain_relation_applications", call_event_id="v2_y", app_id=1, policy_version="brain-relations-1", outcome="excluded",
       reason="no_verification", applied_at_ms=150)
rejects("schema 3: an exclusion without its reason", lambda: insert("brain_relation_applications", call_event_id="v2_open",
        policy_version="p", outcome="excluded", applied_at_ms=1))
rejects("schema 3: what a call taught is immutable", lambda: db.execute("UPDATE brain_relation_applications SET outcome='excluded', reason='no_oracle'"))
insert("memory_schema_migrations", to_version=3, from_version=2, migrated_at_ms=1, copy_name="memory.sqlite.schema-2-x")
assert db.execute("PRAGMA foreign_key_check").fetchall() == []
ok("schema 3: proofs once per call and relation, the register of what each call taught, and the migration record")

# ================================================================== schema 4 (D2 after its review): evaluations, evidence, label keys, prefixes
# A variant built under schema 3, before prefixes were checked: schema 4's text states it suggested.
insert("memory_routes", route_id="v8", name="Esportare di nuovo", status="draft", created_at_ms=160)
insert("memory_procedure_interpretations", interpretation_id="i8", candidate_id="c1", revision=2, contract_version=1,
       payload_digest="v8", source="app", source_stream_id="worker", task_revision=1, attempt_state="ended", recorded_at_ms=160)
insert("memory_procedure_versions", route_id="v8", interpretation_id="i8", candidate_id="c1", task_id="t1", task_occurrence_id="o1",
       contract_version=1, variant_of_route_id="v1", divergence_position=1, built_at_ms=160)
db.executescript(PARTS[4])
# A migration comes from schema 1 only, which holds no procedure: part 4 writes no row of its own. The suggested
# prefix of v8, a variant declared before its prefix was checked, is written as a build states it.
assert db.execute("SELECT count(*) FROM memory_variant_prefixes").fetchone()[0] == 0
insert("memory_variant_prefixes", route_id="v8", status="suggested", compared_steps=0, reason="declared_before_verification",
       checked_at_ms=160)
assert db.execute("SELECT count(*) FROM brain_relation_applications").fetchone()[0] == 2
assert db.execute("SELECT count(*) FROM brain_relation_proofs").fetchone()[0] == 2
ok("schema 4: runs on the populated file; a variant declared before its prefix was checked states it suggested; part 3's register is kept")

insert("brain_relation_evaluations", call_event_id="v2_call", sequence=1, app_id=1, policy_version="brain-relations-2",
       cause="acquisition", outcome="excluded", reason="awaiting_state", recoverable=1, evaluated_at_ms=200)
insert("brain_relation_evaluations", call_event_id="v2_call", sequence=2, app_id=1, policy_version="brain-relations-2",
       cause="evidence", outcome="supported", recoverable=0, evaluated_at_ms=210)
insert("brain_relation_evidence", relation_id="r1", call_event_id="v2_call", sequence=2, relation="supports",
       verification_event_id="v2_check", policy_version="brain-relations-2", assessed_at_ms=210)
insert("brain_relation_evaluations", call_event_id="v2_y", sequence=1, app_id=1, policy_version="brain-relations-2",
       cause="recovery", outcome="excluded", reason="nothing_to_contradict", recoverable=1, group_key="group-x",
       expected_effect_kind="menuOpened", evaluated_at_ms=200)
insert("brain_relation_evaluations", call_event_id="v2_y", sequence=2, app_id=1, policy_version="brain-relations-2",
       cause="recovery", outcome="excluded", reason="nothing_to_contradict", recoverable=1, group_key="group-z",
       expected_effect_kind="valueChanged", evaluated_at_ms=201)
ok("schema 4: a call waiting for its state, then supporting; a failure waiting for a relation of its group")
rejects("schema 4: an evaluation out of order", lambda: insert("brain_relation_evaluations", call_event_id="v2_call", sequence=4,
        app_id=1, policy_version="p", cause="policy", outcome="supported", recoverable=0, evaluated_at_ms=1))
rejects("schema 4: an evaluation is immutable", lambda: db.execute("UPDATE brain_relation_evaluations SET outcome='supported'"))
rejects("schema 4: an evaluation is kept", lambda: db.execute("DELETE FROM brain_relation_evaluations"))
rejects("schema 4: an exclusion without its reason", lambda: insert("brain_relation_evaluations", call_event_id="v2_open",
        sequence=1, policy_version="p", cause="recovery", outcome="excluded", recoverable=0, evaluated_at_ms=1))
rejects("schema 4: a support that waits for evidence", lambda: insert("brain_relation_evaluations", call_event_id="v2_call",
        sequence=3, app_id=1, policy_version="p", cause="policy", outcome="supported", recoverable=1, evaluated_at_ms=1))
rejects("schema 4: a group key without a failure waiting for its group", lambda: insert("brain_relation_evaluations",
        call_event_id="v2_call", sequence=3, app_id=1, policy_version="p", cause="policy", outcome="excluded",
        reason="no_oracle", recoverable=0, group_key="g", evaluated_at_ms=1))
rejects("schema 4: an unknown cause", lambda: insert("brain_relation_evaluations", call_event_id="v2_call", sequence=3, app_id=1,
        policy_version="p", cause="guess", outcome="supported", recoverable=0, evaluated_at_ms=1))
rejects("schema 4: an evaluation of another application than its call's", lambda: insert("brain_relation_evaluations",
        call_event_id="v2_call", sequence=3, app_id=2, policy_version="p", cause="policy", outcome="supported", recoverable=0,
        evaluated_at_ms=1))
rejects("schema 4: evidence of an evaluation that excluded", lambda: insert("brain_relation_evidence", relation_id="r1",
        call_event_id="v2_call", sequence=1, relation="supports", verification_event_id="v2_check", policy_version="p",
        assessed_at_ms=1))
rejects("schema 4: a contradiction from an evaluation that supported", lambda: insert("brain_relation_evidence", relation_id="r2",
        call_event_id="v2_call", sequence=2, relation="contradicts", verification_event_id="v2_check", policy_version="p",
        assessed_at_ms=1))
rejects("schema 4: evidence of an evaluation that does not exist", lambda: insert("brain_relation_evidence", relation_id="r1",
        call_event_id="v2_call", sequence=7, relation="supports", verification_event_id="v2_check", policy_version="p",
        assessed_at_ms=1))
rejects("schema 4: evidence by another call's verification", lambda: insert("brain_relation_evidence", relation_id="r3",
        call_event_id="v2_y", sequence=1, relation="supports", verification_event_id="v2_check", policy_version="p",
        assessed_at_ms=1))
rejects("schema 4: evidence is immutable", lambda: db.execute("UPDATE brain_relation_evidence SET relation='contradicts'"))
rejects("schema 4: evidence is kept", lambda: db.execute("DELETE FROM brain_relation_evidence"))

insert("brain_anchor_label_keys", anchor_id="a2", app_id=1, label_key="invia")
ok("schema 4: a label key of an anchor")
rejects("schema 4: a label key of another application than its anchor's", lambda: insert("brain_anchor_label_keys",
        anchor_id="a2", app_id=2, label_key="x"))
rejects("schema 4: an empty label key", lambda: insert("brain_anchor_label_keys", anchor_id="a2", app_id=1, label_key=""))
db.execute("DELETE FROM brain_anchor_label_keys WHERE anchor_id='a2' AND label_key='invia'")
ok("schema 4: a label key is derived and rewritten with its anchor")

insert("memory_routes", route_id="v7", name="Esportare ancora", status="draft", created_at_ms=170)
insert("memory_procedure_interpretations", interpretation_id="i7", candidate_id="c1", revision=3, contract_version=1,
       payload_digest="v7", source="app", source_stream_id="worker", task_revision=1, attempt_state="ended", recorded_at_ms=170)
insert("memory_procedure_versions", route_id="v7", interpretation_id="i7", candidate_id="c1", task_id="t1", task_occurrence_id="o1",
       contract_version=1, variant_of_route_id="v1", divergence_position=1, built_at_ms=170)
rejects("schema 4: a verified prefix with a reason", lambda: insert("memory_variant_prefixes", route_id="v7", status="verified",
        compared_steps=1, reason="withheld_literal", checked_at_ms=170))
rejects("schema 4: a prefix past the divergence", lambda: insert("memory_variant_prefixes", route_id="v7", status="verified",
        compared_steps=2, checked_at_ms=170))
rejects("schema 4: a prefix of a version that varies none", lambda: insert("memory_variant_prefixes", route_id="v1",
        status="verified", compared_steps=0, checked_at_ms=170))
insert("memory_variant_prefixes", route_id="v7", status="verified", compared_steps=1, checked_at_ms=170)
rejects("schema 4: one prefix per variant", lambda: insert("memory_variant_prefixes", route_id="v7", status="suggested",
        compared_steps=1, reason="unreadable_step", checked_at_ms=171))
rejects("schema 4: a prefix check is immutable", lambda: db.execute("UPDATE memory_variant_prefixes SET status='suggested'"))
rejects("schema 4: a prefix check is kept", lambda: db.execute("DELETE FROM memory_variant_prefixes"))
insert("memory_schema_migrations", to_version=4, from_version=3, migrated_at_ms=2, copy_name="memory.sqlite.schema-3-x")
assert db.execute("PRAGMA foreign_key_check").fetchall() == []
ok("schema 4: a verified prefix and the migration record")

# ================================================================== schema 5 (D2 after its second review): prefix checks
# Part 5 writes no row of its own; part 4's rows stay as written, and v8's check is written as a build states it.
db.executescript(PARTS[5])
assert db.execute("SELECT count(*) FROM memory_variant_prefix_checks").fetchone()[0] == 0
assert db.execute("SELECT route_id, status FROM memory_variant_prefixes ORDER BY route_id").fetchall() == \
    [("v7", "verified"), ("v8", "suggested")]
insert("memory_variant_prefix_checks", route_id="v8", status="suggested", compared_steps=0, reason="declared_before_verification",
       checked_at_ms=180)
ok("schema 5: runs on the populated file, keeps part 4's rows as written")
insert("memory_variant_prefix_checks", route_id="v7", status="suggested", compared_steps=1, reason="parameter_correspondence",
       checked_at_ms=180)
ok("schema 5: a prefix whose parameters do not correspond is suggested, and says why")
rejects("schema 5: one check per variant", lambda: insert("memory_variant_prefix_checks", route_id="v7", status="verified",
        compared_steps=1, checked_at_ms=181))
rejects("schema 5: a prefix check is immutable", lambda: db.execute("UPDATE memory_variant_prefix_checks SET status='verified', reason=NULL"))
rejects("schema 5: a prefix check is kept", lambda: db.execute("DELETE FROM memory_variant_prefix_checks"))
rejects("schema 5: a prefix of a version that varies none", lambda: insert("memory_variant_prefix_checks", route_id="v1",
        status="verified", compared_steps=0, checked_at_ms=181))
insert("memory_routes", route_id="v6", name="Esportare in due", status="draft", created_at_ms=190)
insert("memory_procedure_interpretations", interpretation_id="i6", candidate_id="c1", revision=4, contract_version=1,
       payload_digest="v6", source="app", source_stream_id="worker", task_revision=1, attempt_state="ended", recorded_at_ms=190)
insert("memory_procedure_versions", route_id="v6", interpretation_id="i6", candidate_id="c1", task_id="t1", task_occurrence_id="o1",
       contract_version=1, variant_of_route_id="v1", divergence_position=1, built_at_ms=190)
rejects("schema 5: a verified prefix with a reason", lambda: insert("memory_variant_prefix_checks", route_id="v6",
        status="verified", compared_steps=1, reason="parameter_correspondence", checked_at_ms=190))
rejects("schema 5: a suggested prefix without its reason", lambda: insert("memory_variant_prefix_checks", route_id="v6",
        status="suggested", compared_steps=1, checked_at_ms=190))
rejects("schema 5: a reason no check gives", lambda: insert("memory_variant_prefix_checks", route_id="v6", status="suggested",
        compared_steps=1, reason="same_label", checked_at_ms=190))
rejects("schema 5: a prefix past the divergence", lambda: insert("memory_variant_prefix_checks", route_id="v6",
        status="verified", compared_steps=2, checked_at_ms=190))
insert("memory_variant_prefix_checks", route_id="v6", status="verified", compared_steps=1, checked_at_ms=190)
insert("memory_schema_migrations", to_version=5, from_version=4, migrated_at_ms=3, copy_name="memory.sqlite.schema-4-x")
assert db.execute("PRAGMA foreign_key_check").fetchall() == []
ok("schema 5: a verified prefix and the migration record")

# ================================================================== schema 6 (D3): the Recall's index and facts
# The part runs on the populated file and writes nothing: the rebuild a migrated archive needs is queued by the
# store in the migrating transaction, since a text cannot read the time.
db.executescript(PARTS[6])
assert db.execute("SELECT count(*) FROM memory_recall_work").fetchone()[0] == 0
ok("schema 6: runs on the populated schema 5 file; the text itself queues no index work")

D64 = "a" * 64
insert("memory_recall_spaces", space_id="e5@r1", model_id="intfloat/multilingual-e5-small", model_revision="r1",
       weights_digest=D64, tokenizer_digest="b" * 64, dimensions=4, pooling="mean", normalization="l2", precision="float32",
       query_prefix="query: ", document_prefix="passage: ", maximum_tokens=512, recorded_at_ms=300)
rejects("schema 6: a space whose weights digest is not a sha256", lambda: insert("memory_recall_spaces", space_id="x",
        model_id="m", model_revision="r", weights_digest="abc", tokenizer_digest=D64, dimensions=4, pooling="mean",
        normalization="l2", precision="float32", query_prefix="", document_prefix="", maximum_tokens=512, recorded_at_ms=1))
rejects("schema 6: an unknown pooling", lambda: insert("memory_recall_spaces", space_id="x", model_id="m", model_revision="r",
        weights_digest=D64, tokenizer_digest=D64, dimensions=4, pooling="max", normalization="l2", precision="float32",
        query_prefix="", document_prefix="", maximum_tokens=512, recorded_at_ms=1))
rejects("schema 6: a space is immutable", lambda: db.execute("UPDATE memory_recall_spaces SET dimensions=8"))
rejects("schema 6: a space is kept", lambda: db.execute("DELETE FROM memory_recall_spaces"))

insert("memory_recall_generations", generation_id=1, document_format="recall-document-1", space_id="e5@r1", status="building",
       started_at_ms=300)
rejects("schema 6: a generation born ready", lambda: insert("memory_recall_generations", generation_id=2,
        document_format="recall-document-1", status="ready", enumerated=1, started_at_ms=300, ready_at_ms=300))
rejects("schema 6: two generations building", lambda: insert("memory_recall_generations", generation_id=2,
        document_format="recall-document-1", status="building", started_at_ms=300))
rejects("schema 6: a generation ready before it is enumerated", lambda: db.execute(
        "UPDATE memory_recall_generations SET status='ready', ready_at_ms=301 WHERE generation_id=1"))
rejects("schema 6: a generation changes its format", lambda: db.execute(
        "UPDATE memory_recall_generations SET document_format='recall-document-1c' WHERE generation_id=1"))
rejects("schema 6: a generation that failed without its reason", lambda: db.execute(
        "UPDATE memory_recall_generations SET status='failed', ended_at_ms=301 WHERE generation_id=1"))

text = "Esportare <documento>. In Editor."
insert("memory_recall_documents", document_digest=D64, document_format="recall-document-1", text=text, recorded_at_ms=300)
insert("memory_recall_documents", document_digest="c" * 64, document_format="recall-document-1c", text=text, recorded_at_ms=300)
insert("memory_recall_vectors", space_id="e5@r1", document_digest=D64, token_count=9, truncated=0, vector=bytes(16),
       recorded_at_ms=300)
rejects("schema 6: a vector of another length than its space's dimensions", lambda: insert("memory_recall_vectors",
        space_id="e5@r1", document_digest="c" * 64, token_count=9, truncated=0, vector=bytes(12), recorded_at_ms=300))
rejects("schema 6: one vector per document and space", lambda: insert("memory_recall_vectors", space_id="e5@r1",
        document_digest=D64, token_count=9, truncated=0, vector=bytes(16), recorded_at_ms=300))
rejects("schema 6: a vector is immutable", lambda: db.execute("UPDATE memory_recall_vectors SET truncated=1"))
rejects("schema 6: a document is immutable", lambda: db.execute("UPDATE memory_recall_documents SET text='x'"))

insert("memory_recall_entries", generation_id=1, part_id="v1/procedure", route_id="v1", part_kind="procedure",
       document_digest=D64, qualification_sequence=1, state_sequence=0, entered_at_ms=300)
assert db.execute("SELECT revision FROM memory_recall_generations WHERE generation_id=1").fetchone()[0] == 1
ok("schema 6: a space, a generation being built, a document with its vector, an entry counted in the generation's revision")
rejects("schema 6: an entry of another kind than its part's", lambda: insert("memory_recall_entries", generation_id=1,
        part_id="v1/step-0", route_id="v1", part_kind="procedure", document_digest=D64, qualification_sequence=1,
        state_sequence=0, entered_at_ms=300))
rejects("schema 6: an entry whose document is in another format", lambda: insert("memory_recall_entries", generation_id=1,
        part_id="v1/step-0", route_id="v1", part_kind="step", document_digest="c" * 64, qualification_sequence=1,
        state_sequence=0, entered_at_ms=300))
rejects("schema 6: an entry is replaced, never changed", lambda: db.execute("UPDATE memory_recall_entries SET state_sequence=1"))
db.execute("UPDATE memory_recall_generations SET enumerated=1, cursor_route_id='v1' WHERE generation_id=1")
db.execute("UPDATE memory_recall_generations SET status='ready', ready_at_ms=301 WHERE generation_id=1")
rejects("schema 6: a ready generation goes back to building", lambda: db.execute(
        "UPDATE memory_recall_generations SET status='building', ready_at_ms=NULL WHERE generation_id=1"))
rejects("schema 6: an enumerated generation forgets it", lambda: db.execute(
        "UPDATE memory_recall_generations SET enumerated=0 WHERE generation_id=1"))
rejects("schema 6: a generation's revision goes back", lambda: db.execute(
        "UPDATE memory_recall_generations SET revision=0 WHERE generation_id=1"))
rejects("schema 6: a generation is kept", lambda: db.execute("DELETE FROM memory_recall_generations"))
insert("memory_recall_generations", generation_id=2, document_format="recall-document-1c", status="building", started_at_ms=302)
rejects("schema 6: two generations ready", lambda: db.execute(
        "UPDATE memory_recall_generations SET status='ready', enumerated=1, ready_at_ms=303 WHERE generation_id=2"))
db.execute("UPDATE memory_recall_generations SET status='failed', ended_at_ms=303, reason='stopped' WHERE generation_id=2")
rejects("schema 6: a failed generation is final", lambda: db.execute(
        "UPDATE memory_recall_generations SET status='retired' WHERE generation_id=2"))
rejects("schema 6: an entry in a generation that failed", lambda: insert("memory_recall_entries", generation_id=2,
        part_id="v1/procedure", route_id="v1", part_kind="procedure", document_digest="c" * 64, qualification_sequence=1,
        state_sequence=0, entered_at_ms=303))
db.execute("DELETE FROM memory_recall_entries WHERE generation_id=1 AND part_id='v1/procedure'")
assert db.execute("SELECT revision FROM memory_recall_generations WHERE generation_id=1").fetchone()[0] == 2
ok("schema 6: a generation made ready once enumerated, another that failed is final, a removed entry counts in the revision")

# Index work recorded with the writes that change what the catalogue may offer, one pending row per route.
insert("memory_part_qualifications", part_id="v1/step-0", sequence=2, policy_version="qualification-a-1", verdict="admitted",
       evaluated_at_ms=310)
insert("memory_part_qualification_evidence", part_id="v1/step-0", sequence=2, step_position=0, call_event_id="v2_call",
       verification_event_id="v2_check")
insert("memory_part_states", part_id="v1/step-0", sequence=1, state="usable", reason="evaluated again", recorded_at_ms=311,
       recorded_by="test")
assert db.execute("SELECT route_id, reason FROM memory_recall_work WHERE done_at_ms IS NULL").fetchall() == [("v1", "qualification")]
db.execute("UPDATE memory_recall_work SET done_at_ms=312, attempts=1 WHERE route_id='v1'")
insert("memory_part_states", part_id="v1/step-0", sequence=2, state="retired", reason="smentita", recorded_at_ms=313,
       recorded_by="test")
insert("memory_routes", route_id="v10", name="Esportare <documento> di nuovo", status="draft", created_at_ms=320,
       supersedes_route_id="v1")
insert("memory_procedure_interpretations", interpretation_id="i10", candidate_id="c1", revision=5, contract_version=1,
       payload_digest="v10", source="app", source_stream_id="worker", task_revision=1, attempt_state="ended", recorded_at_ms=320)
insert("memory_procedure_versions", route_id="v10", interpretation_id="i10", candidate_id="c1", task_id="t1",
       task_occurrence_id="o1", contract_version=1, built_at_ms=320)
db.execute("INSERT INTO memory_qualification_policies (policy_version, status, changed_at_ms, reason) "
           "VALUES ('qualification-a-2', 'quarantined', 321, 'wrong rule')")
db.execute("INSERT INTO memory_qualification_policies (policy_version, status, changed_at_ms) VALUES ('qualification-a-3', 'active', 322)")
db.execute("UPDATE memory_qualification_policies SET status='quarantined', reason='also wrong', changed_at_ms=323 "
           "WHERE policy_version='qualification-a-3'")
assert db.execute("SELECT ifnull(route_id, '*'), reason FROM memory_recall_work WHERE done_at_ms IS NULL ORDER BY work_id").fetchall() == \
    [("v1", "state"), ("v10", "publication"), ("*", "policy")]
ok("schema 6: a qualification, a state, a publication that supersedes and a quarantine each record index work; "
   "a pending row covers the next of its route or of the catalogue")
rejects("schema 6: work on a route for a whole rebuild", lambda: insert("memory_recall_work", route_id="v1", reason="rebuild",
        enqueued_at_ms=1))
rejects("schema 6: work on no route for a publication", lambda: insert("memory_recall_work", reason="publication",
        enqueued_at_ms=1))
rejects("schema 6: work done twice", lambda: db.execute("UPDATE memory_recall_work SET done_at_ms=400 WHERE done_at_ms=312"))
rejects("schema 6: work attempts go back", lambda: db.execute("UPDATE memory_recall_work SET attempts=0 WHERE done_at_ms=312"))
rejects("schema 6: work keeps its reason", lambda: db.execute("UPDATE memory_recall_work SET reason='rebuild' WHERE route_id='v10'"))
rejects("schema 6: work is kept", lambda: db.execute("DELETE FROM memory_recall_work"))
insert("memory_recall_work", reason="migration", enqueued_at_ms=330)
ok("schema 6: a migration's rebuild is work on the whole catalogue")

# A query, its need, the selection delivered, what it requires, a call linked to its step and the declared use.
def query(qid, **extra):
    row = dict(query_id=qid, task_id="t1", task_occurrence_id="o1", task_revision=1, source="app", source_stream_id="worker",
               reason="initial", remaining_work="Esportare il documento", generation_id=1, channel="lexical",
               search_status="completed", candidate_limit=48, candidates_considered=2, coverage="complete",
               delivery="delivered", delivery_bytes=900, selector_version="recall-selector-2", recorded_at_ms=340,
               duration_us=1200)
    row.update(extra)
    insert("memory_recall_queries", **row)

query("q1")
insert("memory_recall_needs", query_id="q1", position=0, text="Esportare il documento", coverage="complete")
insert("memory_recall_selections", query_id="q1", need_position=0, position=0, role="selected", route_id="v1",
       first_position=0, last_position=0, whole_part_id="v1/procedure", relevance=0.72, preparations=0)
insert("memory_recall_requirements", query_id="q1", need_position=0, selection_position=0, position=0, kind="entry_state",
       step_position=0, scene_id="scene1", bundle_id="com.example.Editor")
insert("memory_recall_requirements", query_id="q1", need_position=0, selection_position=0, position=1, kind="parameter_bound",
       parameter_id="v1p0", task_value_name="file", binding_match="name")
insert("memory_recall_links", query_id="q1", need_position=0, call_event_id="v2_call", step_position=0, confirmed=1,
       linked_at_ms=350)
insert("memory_recall_links", query_id="q1", need_position=0, call_event_id="v2_open", confirmed=0, linked_at_ms=350)
insert("memory_recall_reports", query_id="q1", need_position=0, sequence=1, declared="adapted", cause="driver", recorded_at_ms=351)
insert("memory_recall_reports", query_id="q1", need_position=0, sequence=2, declared="followed", recorded_at_ms=352)
ok("schema 6: a query with its need, its selection as a whole part, an entry state and a binding by name, two linked calls "
   "(one of the agent's own) and two declared uses")
query("q2", search_status="unavailable", search_note="no index exists yet", generation_id=None, channel="none",
      coverage="unknown", delivery="nothing", candidates_considered=0)
insert("memory_recall_needs", query_id="q2", position=0, text="Esportare il documento", coverage="unknown")
ok("schema 6: a search the index could not answer is unknown, not absent, and delivers nothing")
rejects("schema 6: an unavailable search that covers", lambda: query("x", search_status="unavailable", search_note="n"))
rejects("schema 6: a limited search without its note", lambda: query("x", search_status="limited"))
rejects("schema 6: a channel without its generation", lambda: query("x", generation_id=None))
rejects("schema 6: a coverage delivered as nothing", lambda: query("x", delivery="nothing"))
rejects("schema 6: an absence with a delivery", lambda: query("x", coverage="absent"))
rejects("schema 6: a query of another task's attempt", lambda: query("x", task_id="t2"))
rejects("schema 6: an unknown reason", lambda: query("x", reason="brain_updated"))
rejects("schema 6: a query is immutable", lambda: db.execute("UPDATE memory_recall_queries SET coverage='partial'"))
rejects("schema 6: a query is kept", lambda: db.execute("DELETE FROM memory_recall_queries"))
rejects("schema 6: a partial need for alternatives", lambda: insert("memory_recall_needs", query_id="q1", position=1, text="n",
        coverage="partial", reason="alternatives"))
rejects("schema 6: an ambiguous need for gaps", lambda: insert("memory_recall_needs", query_id="q1", position=1, text="n",
        coverage="ambiguous", reason="gaps"))
rejects("schema 6: a complete need with a reason", lambda: insert("memory_recall_needs", query_id="q1", position=1, text="n",
        coverage="complete", reason="gaps"))
rejects("schema 6: a need is immutable", lambda: db.execute("UPDATE memory_recall_needs SET coverage='absent'"))
rejects("schema 6: a selection past its version's steps", lambda: insert("memory_recall_selections", query_id="q1",
        need_position=0, position=1, role="alternative", route_id="v1", first_position=0, last_position=3, relevance=0.5,
        preparations=0))
rejects("schema 6: a whole part with another interval", lambda: insert("memory_recall_selections", query_id="q1",
        need_position=0, position=1, role="alternative", route_id="v10", first_position=0, last_position=0,
        whole_part_id="v1/procedure", relevance=0.5, preparations=0))
rejects("schema 6: a selection for a need with no coverage", lambda: insert("memory_recall_selections", query_id="q2",
        need_position=0, position=0, role="selected", route_id="v1", first_position=0, last_position=0, relevance=0.5,
        preparations=0))
rejects("schema 6: a selection is immutable", lambda: db.execute("UPDATE memory_recall_selections SET relevance=1"))
rejects("schema 6: a requirement on a step outside its selection", lambda: insert("memory_recall_requirements", query_id="q1",
        need_position=0, selection_position=0, position=2, kind="unknown_entry_state", step_position=1))
rejects("schema 6: a parameter of another version", lambda: insert("memory_recall_requirements", query_id="q1",
        need_position=0, selection_position=0, position=2, kind="parameter_missing", parameter_id="param1"))
rejects("schema 6: a binding without how it matched", lambda: insert("memory_recall_requirements", query_id="q1",
        need_position=0, selection_position=0, position=2, kind="parameter_bound", parameter_id="v1p0", task_value_name="file"))
rejects("schema 6: a binding without the task value it took", lambda: insert("memory_recall_requirements", query_id="q1",
        need_position=0, selection_position=0, position=2, kind="parameter_bound", parameter_id="v1p0", binding_match="role"))
rejects("schema 6: a prerequisite out of the catalogue that is no step of the version", lambda: insert("memory_recall_requirements",
        query_id="q1", need_position=0, selection_position=0, position=2, kind="prerequisite_out_of_catalogue", step_position=5))
rejects("schema 6: a prerequisite out of the catalogue without its step", lambda: insert("memory_recall_requirements",
        query_id="q1", need_position=0, selection_position=0, position=2, kind="prerequisite_out_of_catalogue"))
rejects("schema 6: a requirement is immutable", lambda: db.execute("UPDATE memory_recall_requirements SET bundle_id='x'"))
rejects("schema 6: a linked call of another attempt", lambda: insert("memory_recall_links", query_id="q1", need_position=0,
        call_event_id="v2_y", step_position=0, confirmed=0, linked_at_ms=350))
rejects("schema 6: a link confirmed without its step", lambda: insert("memory_recall_links", query_id="q1", need_position=0,
        call_event_id="v3_batch", confirmed=1, linked_at_ms=350))
rejects("schema 6: a link is immutable", lambda: db.execute("UPDATE memory_recall_links SET confirmed=0"))
rejects("schema 6: a call linked to a step and undetermined", lambda: insert("memory_recall_links", query_id="q1", need_position=0,
        call_event_id="v3_batch", step_position=0, confirmed=0, undetermined=1, linked_at_ms=350))
rejects("schema 6: a report out of order", lambda: insert("memory_recall_reports", query_id="q1", need_position=0, sequence=4,
        declared="abandoned", recorded_at_ms=353))
rejects("schema 6: an unknown cause", lambda: insert("memory_recall_reports", query_id="q1", need_position=0, sequence=3,
        declared="abandoned", cause="bad_luck", recorded_at_ms=353))
rejects("schema 6: a report is immutable", lambda: db.execute("UPDATE memory_recall_reports SET declared='abandoned'"))
rejects("schema 6: a report is kept", lambda: db.execute("DELETE FROM memory_recall_reports"))
# An absence because the relevant steps were excluded with a certain reason; the conditions a selection states.
query("q3", coverage="absent", delivery="nothing")
insert("memory_recall_needs", query_id="q3", position=0, text="Esportare in PNG", coverage="absent", reason="excluded")
insert("memory_recall_selections", query_id="q3", need_position=0, position=0, role="excluded", route_id="v1",
       first_position=0, last_position=0, relevance=0.8, preparations=0)
insert("memory_recall_requirements", query_id="q3", need_position=0, selection_position=0, position=0, kind="certain_conflict",
       step_position=0, task_value_name="output_format")
insert("memory_recall_requirements", query_id="q3", need_position=0, selection_position=0, position=1, kind="constraint_excluded",
       step_position=0, constraint_position=0)
insert("memory_recall_requirements", query_id="q1", need_position=0, selection_position=0, position=2, kind="constraint_unchecked",
       constraint_position=1)
insert("memory_recall_requirements", query_id="q1", need_position=0, selection_position=0, position=3, kind="observed_state",
       step_position=0, scene_id="scene1", bundle_id="com.example.Editor")
ok("schema 6: an absence whose relevant episode was excluded by a conflict and a constraint; an unchecked constraint and an "
   "observed state on a selection")
rejects("schema 6: a complete need said excluded", lambda: insert("memory_recall_needs", query_id="q1", position=1, text="n",
        coverage="complete", reason="excluded"))
rejects("schema 6: a partial need said excluded", lambda: insert("memory_recall_needs", query_id="q1", position=1, text="n",
        coverage="partial", reason="excluded"))
rejects("schema 6: an exclusion on a selected interval", lambda: insert("memory_recall_requirements", query_id="q1",
        need_position=0, selection_position=0, position=4, kind="certain_conflict", step_position=0, task_value_name="f"))
rejects("schema 6: an excluded episode stating a condition", lambda: insert("memory_recall_requirements", query_id="q3",
        need_position=0, selection_position=0, position=2, kind="entry_state", step_position=0, scene_id="scene1"))
rejects("schema 6: a conflict without the task value it contradicts", lambda: insert("memory_recall_requirements", query_id="q3",
        need_position=0, selection_position=0, position=2, kind="certain_conflict", step_position=0))
rejects("schema 6: a constraint requirement without its constraint", lambda: insert("memory_recall_requirements", query_id="q1",
        need_position=0, selection_position=0, position=4, kind="constraint_unchecked"))
rejects("schema 6: an observed state without its scene", lambda: insert("memory_recall_requirements", query_id="q1",
        need_position=0, selection_position=0, position=4, kind="observed_state", step_position=0, bundle_id="com.example.Editor"))
rejects("schema 6: a step done before the selection that is not before it", lambda: insert("memory_recall_requirements",
        query_id="q1", need_position=0, selection_position=0, position=4, kind="prepared_before", step_position=0))
rejects("schema 6: an output ready without how the task's value matched", lambda: insert("memory_recall_requirements",
        query_id="q1", need_position=0, selection_position=0, position=4, kind="output_ready", step_position=0,
        parameter_id="v1p0", task_value_name="file"))
rejects("schema 6: an exclusion for a search that could not answer", lambda: insert("memory_recall_selections", query_id="q2",
        need_position=0, position=0, role="excluded", route_id="v1", first_position=0, last_position=0, relevance=0.5,
        preparations=0))
insert("memory_schema_migrations", to_version=6, from_version=5, migrated_at_ms=4, copy_name="memory.sqlite.schema-5-x")
assert db.execute("PRAGMA foreign_key_check").fetchall() == []
ok("schema 6: the migration record")

# ================================================================== schema 7 (D3, the experiment of the agent's choice)
db.executescript(PARTS[7])

def proposal(pid, **extra):
    row = dict(proposal_id=pid, task_id="t1", task_occurrence_id="o1", task_revision=1, source="app", source_stream_id="worker",
               reason="initial", remaining_work="Esportare il documento", generation_id=1, channel="lexical",
               search_status="completed", candidates_considered=4, proposal_bytes=2400, format_version="recall-proposal-1",
               recorded_at_ms=360, duration_us=900)
    row.update(extra)
    insert("memory_recall_proposals", **row)

proposal("p1")
insert("memory_recall_proposal_needs", proposal_id="p1", position=0, text="Esportare il documento")
insert("memory_recall_proposal_sources", proposal_id="p1", need_position=0, position=0, source_key="s1", route_id="v1",
       relevance=0.7, suggested_first=0, suggested_last=0)
insert("memory_recall_proposal_sources", proposal_id="p1", need_position=0, position=1, source_key="s2", route_id="v10",
       relevance=0.4)
ok("schema 7: a proposal with its need and two versions shortlisted, one with the automatic suggestion")
rejects("schema 7: one name for two versions", lambda: insert("memory_recall_proposal_sources", proposal_id="p1", need_position=0,
        position=2, source_key="s1", route_id="v10", relevance=0.1))
rejects("schema 7: two names for one version", lambda: insert("memory_recall_proposal_sources", proposal_id="p1", need_position=0,
        position=2, source_key="s3", route_id="v1", relevance=0.1))
rejects("schema 7: a suggestion with one end", lambda: insert("memory_recall_proposal_sources", proposal_id="p1", need_position=0,
        position=2, source_key="s3", route_id="v2", relevance=0.1, suggested_first=0))
rejects("schema 7: a source for a need the proposal lacks", lambda: insert("memory_recall_proposal_sources", proposal_id="p1",
        need_position=1, position=0, source_key="s3", route_id="v2", relevance=0.1))
rejects("schema 7: a proposal of another task's attempt", lambda: proposal("x", task_id="t2"))
rejects("schema 7: a limited proposal without its note", lambda: proposal("x", search_status="limited"))
rejects("schema 7: a proposal is immutable", lambda: db.execute("UPDATE memory_recall_proposals SET proposal_bytes=1"))
rejects("schema 7: a proposal is kept", lambda: db.execute("DELETE FROM memory_recall_proposal_sources"))
query("q4", selector_version="recall-agent-choice-1", recorded_at_ms=370)
insert("memory_recall_needs", query_id="q4", position=0, text="Esportare il documento", coverage="complete")
insert("memory_recall_selections", query_id="q4", need_position=0, position=0, role="selected", route_id="v1",
       first_position=0, last_position=0, relevance=0.7, preparations=0)
insert("memory_recall_selections", query_id="q4", need_position=0, position=1, role="selected", route_id="v10",
       first_position=0, last_position=0, relevance=0.4, preparations=0)
insert("memory_recall_choices", query_id="q4", proposal_id="p1", recorded_at_ms=370)
insert("memory_recall_choice_needs", query_id="q4", need_position=0, declared="all")
insert("memory_recall_choice_links", query_id="q4", need_position=0, selection_position=1, call_event_id="v2_call",
       step_position=0, confirmed=1, linked_at_ms=380)
insert("memory_recall_choice_links", query_id="q4", need_position=0, call_event_id="v2_open", confirmed=0, linked_at_ms=380)
ok("schema 7: a choice of two tracts of two versions for one need, the agent's declaration, a call linked to the second tract "
   "and one of the agent's own")
rejects("schema 7: a second choice of one proposal", lambda: (query("q5", selector_version="recall-agent-choice-1"),
        insert("memory_recall_choices", query_id="q5", proposal_id="p1", recorded_at_ms=371)))
proposal("p2", source_stream_id="other")
rejects("schema 7: a choice of another producer's proposal", lambda: (query("q6", selector_version="recall-agent-choice-1"),
        insert("memory_recall_choices", query_id="q6", proposal_id="p2", recorded_at_ms=371)))
rejects("schema 7: a choice of a proposal of another revision", lambda: (query("q7", task_revision=2),
        insert("memory_recall_choices", query_id="q7", proposal_id="p2", recorded_at_ms=371)))
rejects("schema 7: all covered with something uncovered", lambda: insert("memory_recall_choice_needs", query_id="q4",
        need_position=0, declared="all", uncovered="the rotation"))
rejects("schema 7: a declaration for a need the query lacks", lambda: insert("memory_recall_choice_needs", query_id="q4",
        need_position=1, declared="none"))
rejects("schema 7: a declaration of a query that answers no proposal", lambda: insert("memory_recall_choice_needs", query_id="q1",
        need_position=0, declared="part", uncovered="x"))
rejects("schema 7: an unknown declaration", lambda: insert("memory_recall_choice_needs", query_id="q4", need_position=0,
        declared="most"))
rejects("schema 7: a linked step outside the tract it names", lambda: insert("memory_recall_choice_links", query_id="q4",
        need_position=0, selection_position=0, call_event_id="v3_batch", step_position=1, confirmed=0, linked_at_ms=380))
rejects("schema 7: a linked step without its tract", lambda: insert("memory_recall_choice_links", query_id="q4",
        need_position=0, call_event_id="v3_batch", step_position=0, confirmed=0, linked_at_ms=380))
rejects("schema 7: a tract with no step", lambda: insert("memory_recall_choice_links", query_id="q4",
        need_position=0, selection_position=0, call_event_id="v3_batch", confirmed=0, linked_at_ms=380))
rejects("schema 7: a call linked twice", lambda: insert("memory_recall_choice_links", query_id="q4", need_position=0,
        selection_position=0, call_event_id="v2_call", step_position=0, confirmed=1, linked_at_ms=381))
rejects("schema 7: a linked call of another attempt", lambda: insert("memory_recall_choice_links", query_id="q4",
        need_position=0, selection_position=0, call_event_id="v2_y", step_position=0, confirmed=0, linked_at_ms=380))
rejects("schema 7: a choice's call linked without its tract", lambda: insert("memory_recall_links", query_id="q4",
        need_position=0, call_event_id="v3_batch", step_position=0, confirmed=0, linked_at_ms=380))
rejects("schema 7: a choice is immutable", lambda: db.execute("UPDATE memory_recall_choices SET recorded_at_ms=1"))
rejects("schema 7: a declaration is kept", lambda: db.execute("DELETE FROM memory_recall_choice_needs"))
rejects("schema 7: a choice link is immutable", lambda: db.execute("UPDATE memory_recall_choice_links SET confirmed=0"))
db.execute("INSERT INTO memory_route_parameters (parameter_id, route_id, name, direction, value_type, is_required) "
           "VALUES ('v10p0', 'v10', 'allegato', 'input', 'text', 1)")
query("q8", selector_version="recall-agent-choice-1", recorded_at_ms=372)
insert("memory_recall_needs", query_id="q8", position=0, text="Esportare il documento e inviarlo", coverage="complete")
for position, (route, first, last) in enumerate([("v10", 0, 3), ("v10", 7, 9), ("v1", 0, 0)]):
    insert("memory_recall_selections", query_id="q8", need_position=0, position=position, role="selected", route_id=route,
           first_position=first, last_position=last, relevance=0.6, preparations=0)
insert("memory_recall_requirements", query_id="q8", need_position=0, selection_position=1, position=0, kind="input_produced",
       step_position=3, parameter_id="v10p0")
ok("schema 7: a tract's input produced by a step of an earlier tract of the same version")
rejects("schema 7: an input produced by a step of a later tract", lambda: insert("memory_recall_requirements", query_id="q8",
        need_position=0, selection_position=0, position=0, kind="input_produced", step_position=8, parameter_id="v10p0"))
rejects("schema 7: an input produced by a step between the tracts", lambda: insert("memory_recall_requirements", query_id="q8",
        need_position=0, selection_position=1, position=1, kind="input_produced", step_position=5, parameter_id="v10p0"))
rejects("schema 7: an input produced in an earlier tract of another version", lambda: insert("memory_recall_requirements",
        query_id="q8", need_position=0, selection_position=2, position=0, kind="input_produced", step_position=3,
        parameter_id="v1p0"))
rejects("schema 7: another requirement on a step of an earlier tract", lambda: insert("memory_recall_requirements",
        query_id="q8", need_position=0, selection_position=1, position=1, kind="unknown_entry_state", step_position=2))
rejects("schema 7: still, a requirement on a step outside its selection", lambda: insert("memory_recall_requirements", query_id="q1",
        need_position=0, selection_position=0, position=2, kind="unknown_entry_state", step_position=1))
# An ambiguous answer (review of experiment A, R5): no tract runs, the options are alternatives, the question is kept.
proposal("p3")
insert("memory_recall_proposal_needs", proposal_id="p3", position=0, text="Stampare il PDF")
insert("memory_recall_proposal_sources", proposal_id="p3", need_position=0, position=0, source_key="s1", route_id="v1", relevance=0.7)
insert("memory_recall_proposal_sources", proposal_id="p3", need_position=0, position=1, source_key="s2", route_id="v10", relevance=0.6)
query("q9", selector_version="recall-agent-choice-2", recorded_at_ms=373, coverage="ambiguous")
insert("memory_recall_needs", query_id="q9", position=0, text="Stampare il PDF", coverage="ambiguous", reason="alternatives")
for position, route in enumerate(["v1", "v10"]):
    insert("memory_recall_selections", query_id="q9", need_position=0, position=position, role="alternative", route_id=route,
           first_position=0, last_position=0, relevance=0.6, preparations=0)
insert("memory_recall_choices", query_id="q9", proposal_id="p3", recorded_at_ms=373)
insert("memory_recall_choice_needs", query_id="q9", need_position=0, declared="ambiguous", uncovered="Tutte le pagine o solo quella corrente?")
ok("schema 7: an ambiguous need of a choice, its two alternatives and the question for the person")
rejects("schema 7: an ambiguous declaration without the question", lambda: (proposal("p4"),
        query("q10", selector_version="recall-agent-choice-2", recorded_at_ms=374, coverage="ambiguous"),
        insert("memory_recall_needs", query_id="q10", position=0, text="x", coverage="ambiguous", reason="alternatives"),
        insert("memory_recall_choices", query_id="q10", proposal_id="p4", recorded_at_ms=374),
        insert("memory_recall_choice_needs", query_id="q10", need_position=0, declared="ambiguous")))
rejects("schema 7: an ambiguous declaration of a need with a tract to run", lambda: (proposal("p7"),
        query("q13", selector_version="recall-agent-choice-2", recorded_at_ms=377, coverage="ambiguous"),
        insert("memory_recall_needs", query_id="q13", position=0, text="x", coverage="ambiguous", reason="alternatives"),
        [insert("memory_recall_selections", query_id="q13", need_position=0, position=position, role=role, route_id="v1",
                first_position=0, last_position=0, relevance=0.6, preparations=0)
         for position, role in enumerate(["selected", "alternative", "alternative"])],
        insert("memory_recall_choices", query_id="q13", proposal_id="p7", recorded_at_ms=377),
        insert("memory_recall_choice_needs", query_id="q13", need_position=0, declared="ambiguous", uncovered="quale?")))
rejects("schema 7: an ambiguous declaration with one alternative", lambda: (proposal("p5"),
        query("q11", selector_version="recall-agent-choice-2", recorded_at_ms=375, coverage="ambiguous"),
        insert("memory_recall_needs", query_id="q11", position=0, text="x", coverage="ambiguous", reason="alternatives"),
        insert("memory_recall_selections", query_id="q11", need_position=0, position=0, role="alternative", route_id="v1",
               first_position=0, last_position=0, relevance=0.6, preparations=0),
        insert("memory_recall_choices", query_id="q11", proposal_id="p5", recorded_at_ms=375),
        insert("memory_recall_choice_needs", query_id="q11", need_position=0, declared="ambiguous", uncovered="quale?")))
rejects("schema 7: a choice settled for a need that runs nothing", lambda: (proposal("p6"),
        query("q12", selector_version="recall-agent-choice-2", recorded_at_ms=376, coverage="absent"),
        insert("memory_recall_needs", query_id="q12", position=0, text="x", coverage="absent"),
        insert("memory_recall_choices", query_id="q12", proposal_id="p6", recorded_at_ms=376),
        insert("memory_recall_choice_needs", query_id="q12", need_position=0, declared="none", settled_by="le parole")))
rejects("schema 7: an empty quotation", lambda: (proposal("p8"),
        query("q14", selector_version="recall-agent-choice-2", recorded_at_ms=378, coverage="complete"),
        insert("memory_recall_needs", query_id="q14", position=0, text="x", coverage="complete"),
        insert("memory_recall_choices", query_id="q14", proposal_id="p8", recorded_at_ms=378),
        insert("memory_recall_choice_needs", query_id="q14", need_position=0, declared="all", settled_by="")))
insert("memory_schema_migrations", to_version=7, from_version=6, migrated_at_ms=5, copy_name="memory.sqlite.schema-6-x")
assert db.execute("PRAGMA foreign_key_check").fetchall() == []
ok("schema 7: the migration record")

# ================================================================== integrity, file reopen
tables = db.execute("SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%'").fetchall()
assert len(tables) == 109, len(tables)
triggers = db.execute("SELECT count(*) FROM sqlite_schema WHERE type='trigger'").fetchone()[0]
indexes = db.execute("SELECT count(*) FROM sqlite_schema WHERE type='index' AND sql IS NOT NULL").fetchone()[0]
for (name,) in tables:
    db.execute(f"EXPLAIN DELETE FROM {name} WHERE 0")
    assert all("json" not in column[1].lower() for column in db.execute(f"PRAGMA table_info({name})"))
assert db.execute("PRAGMA foreign_key_check").fetchall() == []
assert db.execute("PRAGMA integrity_check").fetchall() == [("ok",)]
ok(f"109 tables, {triggers} triggers, {indexes} explicit indexes, all foreign keys prepared, no JSON columns, integrity checks")

db.commit()
with tempfile.TemporaryDirectory(prefix="braus-ddl-v7-") as folder:
    path = Path(folder) / "memory.sqlite"
    with sqlite3.connect(path) as saved:
        db.backup(saved)
    with sqlite3.connect(path) as reopened:
        reopened.execute("PRAGMA foreign_keys=ON")
        assert reopened.execute("PRAGMA foreign_keys").fetchone()[0] == 1
        assert reopened.execute("SELECT epoch FROM brain_app_window_epochs WHERE app_id=1 AND window_family='Chat'").fetchone()[0] == 4
        assert reopened.execute("SELECT retired_epoch,retirement_cause FROM brain_anchors WHERE anchor_id='anchor1'").fetchone() == (4, "stale")
        assert reopened.execute("SELECT count(*) FROM brain_evidence WHERE anchor_id='anchor1'").fetchone()[0] == 1
        assert [r[0] for r in reopened.execute("SELECT alias FROM brain_anchor_aliases WHERE anchor_id='anchor1_return' ORDER BY position")] == ["Send", "Invia ora"]
        assert [r[0] for r in reopened.execute("SELECT anchor_id FROM brain_anchors WHERE app_id=1 AND retired_at_ms IS NULL ORDER BY insertion_order")] == ["anchor1_return", "a2", "a3"]
        assert reopened.execute("SELECT count(*) FROM brain_scenes WHERE scene_kind='app'").fetchone()[0] == 1
        assert reopened.execute("SELECT count(*) FROM sqlite_schema WHERE type='trigger'").fetchone()[0] == triggers
        assert reopened.execute("PRAGMA foreign_key_check").fetchall() == []
        # journal mode is a property of the file: set once at bootstrap, verified on reopen (piano 1).
        assert reopened.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
    with sqlite3.connect(path) as again:
        assert again.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
ok("orders, app scope, triggers, retired identities and evidence persist after file reopen; WAL persists in the file")

# The parts are the whole text: the text alone creates what its parts create run in order.
assert objects_of(SCHEMA.read_text()) == objects_of("".join(PARTS[n] for n in range(1, 8)))
ok("the one text creates what its parts create in order")

rejected = sum(1 for p in passed if p.startswith("rejects: "))
print(f"PASS: {len(passed)} DDL checks ({rejected} negative) on SQLite {LIB[0]} [{LIB[1]}] via Python {sys.version.split()[0]} sqlite3 module {sqlite3.sqlite_version}")
print("109 tables (schema 7); triggers:", triggers, "; explicit indexes:", indexes)
for p in passed:
    print(" -", p)
