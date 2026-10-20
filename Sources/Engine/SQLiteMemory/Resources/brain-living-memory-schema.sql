-- Braus Brain and living memory: the schema of the SQLiteMemory module, version 19.
-- This one text creates a new archive in its bootstrap transaction, and the store compares every archive with the
-- exact shape it creates at each open. It is edited in place: a change of shape before a release adds no file, and
-- an archive of an earlier development shape is refused untouched, except the historical shapes the store recognizes
-- by the digest of their objects and rebuilds (main before the value change, the D3 build's version 7, rename-app's
-- version 7, main's version 8, this branch's version 9).
-- Version 8 is the shape version 7 had since D1-D3 were merged into rename-app with one CHECK widened (the origins of
-- the product's earlier name, `previous_product`); its number tells it apart from both versions 7 (the D3 build's and
-- rename-app's), so every migration records the version it came from. Both are recognized whole and rebuilt.
-- Version 9 is version 8 with one CHECK widened: a declared gap's reason admits `unclassified_target`, a text typed
-- where the call could not attest an ordinary target (W1). Version 8 as main shipped it is recognized whole and rebuilt.
-- Version 10 is version 9 with one CHECK widened: a verification's limit admits `settle_capped` and `settle_unwatched`,
-- a wait after the gesture that ended at its cap with the window still busy, or had nothing to watch (W12). Version 9
-- as this branch wrote it is recognized whole and rebuilt.
-- Part 1 is version 1, the base: an archive of version 1 at exactly its shape migrates in one transaction after a
-- verified copy. The store reads that shape from part 1 itself, creates every table, index and trigger of the
-- later parts the archive lacks, each as written here, and derives the rows a text cannot. Editing part 1 changes
-- which archives of version 1 are recognized: one bootstrapped before the edit is refused untouched, as the value
-- change of rename-app already refuses the archives created before it. Versions 2 to 6 were development steps of
-- the G76 plans, never released: an archive at one of them is refused untouched.
-- Documentation/Engine/MemorySchema.md says how and why.
-- Version 19 adds typed adapter evidence, confidential-content minimization, procedural step kinds, references,
-- account requirements, execution ownership and reconciliation. Its current shape has 121 tables, 217 triggers
-- and 75 explicit indexes. The exact shapes listed by SQLiteMemorySchema are the only migration sources.
-- Eight parts, in the order they were written; no later part alters a table of an earlier one, and no column is
-- reused with another meaning:
--   1. the base, version 1, with the value change;
--   2. the facts of plan D1 (Documentation/Engine/MemoryFacts.md);
--   3. procedures and Brain relations, plan D2 (Documentation/Engine/MemoryProcedures.md);
--   4. evaluations, the anchors' label keys and variant prefixes, plan D2 after its review;
--   5. the checks of a variant's prefix with its parameters' correspondence, plan D2 after its second review;
--   6. the Recall, plan D3 (Documentation/Engine/MemoryRecall.md);
--   7. the experiment of the Recall by the agent's choice, plan D3 (Documentation/Engine/RecallAgentChoice.md);
--   8. mixed procedures, reconciliation and data contexts, plans P1 and P2 (Documentation/Engine/MemoryProcedures.md).
-- Conventions: STRICT tables, no JSON column, no import. SQLite >= 3.37 (STRICT); >= 3.51.3 for concurrent WAL.
-- foreign_keys on EVERY connection. This text carries no PRAGMA, BEGIN or COMMIT of its own: the store runs it inside
-- one write transaction, enables foreign keys per connection and sets user_version in that same transaction.

-- =============================================================================================================
-- Part 1. The base, version 1, statement for statement: the schema main shipped, with the value change of
-- rename-app. Its history, as the resource recorded it while it was the only one:
--   Base: the S0 closing candidate v5 (41 tables, 32 triggers, 27 explicit indexes; sha256
--   f3e651892c6af2ff87d48109666b0d4727485605add37b6eddd51e23d2e55d86), whose logical model Ron
--   approved at v3. This resource is a CANDIDATE: the contract items of the v4->v5 diff are still to
--   be reconciled before it is frozen. Documentation/Engine/MemorySchema.md lists every difference
--   from the archived v5 with its reason and its test.
--   S1 corrections to v5: a structural role or label cannot be moved onto the app scope (UPDATE);
--   a capture sample that a scene association references keeps its whole identity, event_id
--   included (UPDATE), and cannot be deleted. Four triggers added, one narrowed: 36 triggers.
--   S2 (second increment, the brain's projection): brain_anchors.current_group_id, nullable, with a
--   per-app foreign key to brain_groups: ObjectAnchor.groupID is the one group the algorithm last
--   assigned, a datum distinct from the ordered membership (an anchor may be a member of two
--   groups). No table, trigger or index added; still schema 1.
--   S2 (increment 3a, the brain's applications): brain_applications, the register of every concluded
--   application of an observation, a record or a naming to the projection, changes or not; its
--   complete input in memory_operation_arguments under a third owner, brain_application_id; the
--   capture key memory_event_observations needs as the parent of a sample reference; two partial
--   unique keys, a lookup index, and the triggers that seal and keep an application. 42 tables,
--   42 triggers, 31 explicit indexes; still schema 1.
--   Merge of the value change: brain_transitions.effect_label and effect_value, and
--   memory_agent_actions.observed_effect_label and observed_effect_value with the CHECKs of their
--   family, valueChanged. No table, trigger or index added; still schema 1.
--   What v5 changed against v4, all motivated in the S0 diff:
--     A. app scope (decision 14): scene_kind is a closed vocabulary, the 'app' row has a fixed
--        shape, one per app, no element/role/label/association/evidence on the scope, no
--        transition into the scope; scene_kind is immutable.
--     B. observable orders: alias position; insertion_order of anchors, groups and transitions.
--     C. null-safe constraints and vocabularies of plan 1, section 3: IS / IS NOT triggers on the
--        derived app_id, immutable event identity, verification <-> membership, Watcher
--        correlations, Route and operation cycles; CHECK on the closed domains.
--     D. samples with quality (S0 part 3, section 3): identity event+phase+ordinal, typed capture
--        row, label origin, structural path, surface; the event-scene relation carries the ordinal;
--        confirmation only from a complete capture.
--   41 tables, no JSON column, no import, no new retention or recall policy.
--   SQLite >= 3.37 (STRICT); >= 3.51.3 for concurrent WAL (plan 1). foreign_keys on EVERY connection.
--   This file carries no PRAGMA, BEGIN or COMMIT of its own: the store's bootstrap runs it inside
--   one write transaction, enables foreign keys per connection and sets user_version = 1 in that
--   same transaction.
-- =============================================================================================================

-- Canonical knowledge per application. No import of the previous JSON files.
CREATE TABLE brain_apps (
    app_id INTEGER PRIMARY KEY,
    bundle_id TEXT NOT NULL UNIQUE,
    ingest_epoch INTEGER NOT NULL DEFAULT 0,
    last_epoch_advance_ms INTEGER
) STRICT;

-- Clock of the window families: UIBrain.windowEpochs, one row per family.
CREATE TABLE brain_app_window_epochs (
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    window_family TEXT NOT NULL,
    epoch INTEGER NOT NULL CHECK (epoch >= 0),
    PRIMARY KEY (app_id, window_family)
) STRICT;

-- Observed version and locale; the empty string means unknown.
CREATE TABLE brain_app_contexts (
    context_id INTEGER PRIMARY KEY,
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    app_version TEXT NOT NULL DEFAULT '',
    app_locale TEXT NOT NULL DEFAULT '',
    UNIQUE (app_id, app_version, app_locale),
    UNIQUE (app_id, context_id)
) STRICT;

-- A structural scene, or (scene_kind='app') the SCOPE of the current per-application knowledge.
-- The app scope is not a perceived surface: no element, role, label or fingerprint;
-- observation_count=0; title_bucket = '#app' (a marker: LabelText.letters never produces '#').
-- Title and fingerprint of a structural scene are NOT its identity and are NOT UNIQUE.
CREATE TABLE brain_scenes (
    scene_id TEXT PRIMARY KEY,
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    window_title_pattern TEXT,
    title_bucket TEXT NOT NULL,
    scene_kind TEXT NOT NULL DEFAULT 'window'
        CHECK (scene_kind IN ('window', 'dialog', 'sheet', 'app')),
    structural_key TEXT,
    first_seen_ms INTEGER NOT NULL,
    last_seen_ms INTEGER NOT NULL,
    observation_count INTEGER NOT NULL DEFAULT 1 CHECK (observation_count >= 0),
    UNIQUE (app_id, scene_id),
    CHECK (last_seen_ms >= first_seen_ms),
    CHECK (scene_kind <> 'app' OR (structural_key IS NULL AND window_title_pattern IS NULL
                                    AND title_bucket = '#app' AND observation_count = 0)),
    CHECK (scene_kind = 'app' OR title_bucket <> '#app')
) STRICT;

-- The global set of AX roles of a scene. count_bucket NULL = presence only (structure-v2 uses no
-- counts); a value is allowed for compatibility with v3.
CREATE TABLE brain_scene_roles (
    scene_id TEXT NOT NULL REFERENCES brain_scenes(scene_id),
    role TEXT NOT NULL,
    count_bucket INTEGER CHECK (count_bucket IS NULL OR count_bucket >= 0),
    PRIMARY KEY (scene_id, role)
) STRICT;

CREATE TABLE brain_scene_labels (
    scene_id TEXT NOT NULL REFERENCES brain_scenes(scene_id),
    label_token TEXT NOT NULL,
    PRIMARY KEY (scene_id, label_token)
) STRICT;

-- insertion_order reproduces the order of the UIBrain.objects array (observable: the cap on
-- ties, the index, Equatable). Aliases have a position (UIBrain uses aliases.first and prefix(3)).
-- current_group_id is ObjectAnchor.groupID: the group the algorithm last assigned, or NULL; it is
-- not derived from brain_group_members, which keeps every ordered membership, and nothing limits
-- an anchor to one group. A retired group keeps the reference valid.
CREATE TABLE brain_anchors (
    anchor_id TEXT PRIMARY KEY,
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    insertion_order INTEGER NOT NULL CHECK (insertion_order >= 0),
    kind TEXT NOT NULL,
    label TEXT NOT NULL,
    label_source TEXT CHECK (label_source IS NULL OR label_source IN ('observed', 'llm', 'user')),
    anchor_scope TEXT NOT NULL DEFAULT 'control'
        CHECK (anchor_scope IN ('control', 'collection', 'item_template')),
    typical_x REAL,
    typical_y REAL,
    typical_width REAL,
    typical_height REAL,
    window_family TEXT,
    first_seen_ms INTEGER NOT NULL,
    last_seen_ms INTEGER NOT NULL,
    seen_count INTEGER NOT NULL DEFAULT 1 CHECK (seen_count >= 0),
    last_seen_epoch INTEGER,
    current_group_id TEXT,
    retired_at_ms INTEGER,
    retired_epoch INTEGER CHECK (retired_epoch IS NULL OR retired_epoch >= 0),
    retirement_cause TEXT CHECK (retirement_cause IS NULL OR retirement_cause IN ('transient', 'stale', 'backstop', 'cap')),
    UNIQUE (app_id, anchor_id),
    UNIQUE (app_id, insertion_order),
    FOREIGN KEY (app_id, current_group_id) REFERENCES brain_groups(app_id, group_id),
    CHECK (last_seen_ms >= first_seen_ms),
    CHECK ((retired_at_ms IS NULL) = (retired_epoch IS NULL)),
    CHECK ((retired_at_ms IS NULL) = (retirement_cause IS NULL)),
    CHECK (retired_at_ms IS NULL OR retired_at_ms >= last_seen_ms)
) STRICT;

CREATE TABLE brain_anchor_aliases (
    anchor_id TEXT NOT NULL REFERENCES brain_anchors(anchor_id),
    alias TEXT NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    PRIMARY KEY (anchor_id, alias),
    UNIQUE (anchor_id, position)
) STRICT;

CREATE TABLE brain_anchor_states (
    anchor_id TEXT NOT NULL REFERENCES brain_anchors(anchor_id),
    state TEXT NOT NULL,
    seen_count INTEGER NOT NULL CHECK (seen_count >= 0),
    PRIMARY KEY (anchor_id, state)
) STRICT;

-- The structural skeleton of a scene: containers (a tree), controls with a caption, collections
-- and row templates. Real people and files stay in the events.
-- label_origin: the AX attribute the label came from; it does not prove a stable caption.
CREATE TABLE brain_scene_elements (
    scene_element_id TEXT PRIMARY KEY,
    app_id INTEGER NOT NULL,
    scene_id TEXT NOT NULL,
    element_key TEXT NOT NULL,
    element_scope TEXT NOT NULL DEFAULT 'control'
        CHECK (element_scope IN ('container', 'control', 'collection', 'item_template')),
    parent_element_id TEXT,
    edge_hash TEXT,
    cursor_affordance TEXT,
    anchor_id TEXT,
    label TEXT,
    label_origin TEXT CHECK (label_origin IS NULL OR label_origin IN ('title', 'description', 'value', 'column', 'row_content', 'identifier')),
    role TEXT,
    kind TEXT,
    source TEXT,
    bounds_x REAL,
    bounds_y REAL,
    bounds_width REAL,
    bounds_height REAL,
    first_seen_ms INTEGER NOT NULL,
    last_seen_ms INTEGER NOT NULL,
    observation_count INTEGER NOT NULL DEFAULT 1 CHECK (observation_count >= 0),
    UNIQUE (scene_id, element_key),
    UNIQUE (app_id, scene_element_id),
    UNIQUE (scene_id, scene_element_id),
    UNIQUE (app_id, scene_id, scene_element_id),
    CHECK (parent_element_id IS NULL OR parent_element_id <> scene_element_id),
    FOREIGN KEY (scene_id, parent_element_id) REFERENCES brain_scene_elements(scene_id, scene_element_id),
    FOREIGN KEY (app_id, scene_id) REFERENCES brain_scenes(app_id, scene_id),
    FOREIGN KEY (app_id, anchor_id) REFERENCES brain_anchors(app_id, anchor_id),
    CHECK (last_seen_ms >= first_seen_ms)
) STRICT;

CREATE TABLE brain_groups (
    group_id TEXT PRIMARY KEY,
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    insertion_order INTEGER NOT NULL CHECK (insertion_order >= 0),
    axis TEXT NOT NULL,
    shared_kind TEXT NOT NULL,
    cell_width REAL,
    cell_height REAL,
    name TEXT,
    last_seen_ms INTEGER NOT NULL,
    seen_count INTEGER NOT NULL DEFAULT 1 CHECK (seen_count >= 0),
    last_seen_epoch INTEGER,
    retired_at_ms INTEGER,
    retired_epoch INTEGER CHECK (retired_epoch IS NULL OR retired_epoch >= 0),
    retirement_cause TEXT CHECK (retirement_cause IS NULL OR retirement_cause IN ('members', 'stale', 'backstop')),
    UNIQUE (app_id, group_id),
    UNIQUE (app_id, insertion_order),
    CHECK ((retired_at_ms IS NULL) = (retired_epoch IS NULL)),
    CHECK ((retired_at_ms IS NULL) = (retirement_cause IS NULL)),
    CHECK (retired_at_ms IS NULL OR retired_at_ms >= last_seen_ms)
) STRICT;

-- Membership is the projection of SiblingGroup.memberAnchors (ordered along the axis):
-- position is rewritten at every merge; a row is deleted when the member leaves.
CREATE TABLE brain_group_members (
    app_id INTEGER NOT NULL,
    group_id TEXT NOT NULL,
    anchor_id TEXT NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    PRIMARY KEY (group_id, anchor_id),
    UNIQUE (group_id, position),
    FOREIGN KEY (app_id, group_id) REFERENCES brain_groups(app_id, group_id),
    FOREIGN KEY (app_id, anchor_id) REFERENCES brain_anchors(app_id, anchor_id)
) STRICT;

CREATE TABLE brain_menu_commands (
    menu_command_id TEXT PRIMARY KEY,
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    path_key TEXT NOT NULL,
    top_level_title TEXT NOT NULL,
    accessibility_identifier TEXT,
    has_submenu INTEGER NOT NULL CHECK (has_submenu IN (0, 1)),
    last_observed_enabled INTEGER NOT NULL CHECK (last_observed_enabled IN (0, 1)),
    mark_char TEXT,
    cmd_char TEXT,
    first_seen_ms INTEGER NOT NULL,
    last_seen_ms INTEGER NOT NULL,
    UNIQUE (app_id, menu_command_id),
    CHECK (last_seen_ms >= first_seen_ms)
) STRICT;

CREATE TABLE brain_menu_path_segments (
    menu_command_id TEXT NOT NULL REFERENCES brain_menu_commands(menu_command_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    title TEXT NOT NULL,
    PRIMARY KEY (menu_command_id, position)
) STRICT;

-- Graphs inside one application. from_scene_id may be the app scope (current anchor->effect
-- knowledge); to_scene_id NULL = unknown, never the app scope.
-- insertion_order reproduces UIBrain.transitions (observable: does/expectedEffect/revealers on ties).
CREATE TABLE brain_transitions (
    transition_id TEXT PRIMARY KEY,
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    insertion_order INTEGER NOT NULL CHECK (insertion_order >= 0),
    from_scene_id TEXT NOT NULL,
    anchor_id TEXT,
    scene_element_id TEXT,
    menu_command_id TEXT,
    trigger_kind TEXT NOT NULL,
    to_scene_id TEXT,
    effect_kind TEXT NOT NULL,
    effect_text TEXT,
    required_target_state TEXT,
    resulting_target_state TEXT,
    effect_label TEXT,
    effect_value TEXT,
    last_observed_epoch INTEGER,
    status TEXT NOT NULL CHECK (status IN ('candidate', 'trusted', 'rejected')),
    first_seen_ms INTEGER NOT NULL,
    last_seen_ms INTEGER NOT NULL,
    evidence_count INTEGER NOT NULL DEFAULT 0 CHECK (evidence_count >= 0),
    retired_at_ms INTEGER,
    retired_epoch INTEGER CHECK (retired_epoch IS NULL OR retired_epoch >= 0),
    retirement_cause TEXT CHECK (retirement_cause IS NULL OR retirement_cause IN ('anchor', 'stale', 'coincidence', 'backstop')),
    FOREIGN KEY (app_id, from_scene_id) REFERENCES brain_scenes(app_id, scene_id),
    FOREIGN KEY (app_id, to_scene_id) REFERENCES brain_scenes(app_id, scene_id),
    FOREIGN KEY (app_id, anchor_id) REFERENCES brain_anchors(app_id, anchor_id),
    FOREIGN KEY (app_id, menu_command_id) REFERENCES brain_menu_commands(app_id, menu_command_id),
    UNIQUE (app_id, transition_id),
    UNIQUE (app_id, insertion_order),
    CHECK ((anchor_id IS NOT NULL) + (scene_element_id IS NOT NULL) + (menu_command_id IS NOT NULL) <= 1),
    FOREIGN KEY (app_id, from_scene_id, scene_element_id)
        REFERENCES brain_scene_elements(app_id, scene_id, scene_element_id),
    CHECK (last_seen_ms >= first_seen_ms),
    CHECK ((retired_at_ms IS NULL) = (retired_epoch IS NULL)),
    CHECK ((retired_at_ms IS NULL) = (retirement_cause IS NULL)),
    CHECK (retired_at_ms IS NULL OR retired_at_ms >= last_seen_ms)
) STRICT;

CREATE TABLE brain_transition_menu_items (
    transition_id TEXT NOT NULL REFERENCES brain_transitions(transition_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    title TEXT NOT NULL,
    PRIMARY KEY (transition_id, position)
) STRICT;

-- Local write order, distinct from the source's time and order.
-- capture_status: the event's summary; per-sample quality lives in the capture row.
-- Identity and context are immutable after creation (trigger); only capture_status changes.
CREATE TABLE memory_events (
    local_order INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id TEXT NOT NULL UNIQUE,
    source TEXT NOT NULL CHECK (source IN ('app', 'cli', 'mcp', 'watcher', 'system')),
    source_stream_id TEXT NOT NULL,
    source_key TEXT,
    trace_id TEXT,
    session_id TEXT,
    parent_event_id TEXT REFERENCES memory_events(event_id),
    parent_position INTEGER CHECK (parent_position IS NULL OR parent_position >= 0),
    event_kind TEXT NOT NULL CHECK (event_kind IN ('action', 'input', 'observation', 'verification', 'diagnostic')),
    app_id INTEGER REFERENCES brain_apps(app_id),
    context_id INTEGER,
    occurred_at_ms INTEGER NOT NULL,
    monotonic_ns INTEGER,
    capture_status TEXT NOT NULL
        CHECK (capture_status IN ('not_applicable', 'complete', 'partial', 'failed', 'unknown')),
    -- S3-d correction: the call an observation was taken for, when a session observed on its own
    -- right after a call that could not name its application when planned (open_session). A
    -- durable reference apart from a batch's parent: an observation is no step.
    origin_event_id TEXT REFERENCES memory_events(event_id),
    UNIQUE (source, source_stream_id, source_key),
    UNIQUE (parent_event_id, parent_position),
    UNIQUE (app_id, event_id),
    UNIQUE (event_kind, event_id),
    CHECK ((parent_event_id IS NULL) = (parent_position IS NULL)),
    CHECK (parent_event_id IS NULL OR parent_event_id <> event_id),
    CHECK (context_id IS NULL OR app_id IS NOT NULL),
    CHECK (origin_event_id IS NULL OR event_kind = 'observation'),
    CHECK (origin_event_id IS NULL OR origin_event_id <> event_id),
    FOREIGN KEY (app_id, context_id) REFERENCES brain_app_contexts(app_id, context_id)
) STRICT;

CREATE TABLE memory_input_events (
    event_id TEXT PRIMARY KEY REFERENCES memory_events(event_id),
    event_kind TEXT NOT NULL DEFAULT 'input' CHECK (event_kind = 'input'),
    input_kind TEXT NOT NULL,
    sequence_number INTEGER,
    target_pid INTEGER,
    source_pid INTEGER,
    window_number INTEGER,
    window_title TEXT,
    window_x REAL,
    window_y REAL,
    window_width REAL,
    window_height REAL,
    point_x REAL,
    point_y REAL,
    delta_x REAL,
    delta_y REAL,
    started_at_ns INTEGER,
    ended_at_ns INTEGER,
    preceding_revision INTEGER,
    revision INTEGER,
    gap_first_sequence INTEGER,
    gap_last_sequence INTEGER,
    lost_critical INTEGER,
    lost_coalescible INTEGER,
    before_status TEXT,
    after_status TEXT,
    difference_status TEXT,
    FOREIGN KEY (event_kind, event_id) REFERENCES memory_events(event_kind, event_id)
) STRICT;

-- Signatures from the app's AutomationTools. Arguments have one place: memory_operation_arguments.
-- app_id is derived from the event (null-safe trigger): equal, or both NULL.
CREATE TABLE memory_agent_actions (
    event_id TEXT PRIMARY KEY REFERENCES memory_events(event_id),
    event_kind TEXT NOT NULL DEFAULT 'action' CHECK (event_kind = 'action'),
    app_id INTEGER,
    tool_kind TEXT NOT NULL,
    contract_version INTEGER NOT NULL DEFAULT 1 CHECK (contract_version > 0),
    execution_status TEXT NOT NULL CHECK (execution_status IN
        ('planned', 'started', 'completed', 'failed', 'cancelled', 'interrupted', 'skipped')),
    -- The calendar instant the tool was about to run (S3-d): NULL while planned, set at started and
    -- kept. completed_at_ms is the calendar instant of the end. Calendar instants are the chronology
    -- and may run backwards between them (a clock change): they are never subtracted.
    started_at_ms INTEGER,
    completed_at_ms INTEGER,
    -- How long the tool ran, measured by the producer on its own monotonic clock from started to the
    -- end (S3-d correction); only for a state reached from started.
    duration_ms INTEGER CHECK (duration_ms IS NULL OR duration_ms >= 0),
    result_kind TEXT,
    result_message TEXT,
    -- The effect the engine attributed to a completed action or input, typed by family (S3-d
    -- correction): observed_effect_text is the title of windowTitleChanged, the two states belong to
    -- stateFlip, and the labels of the three list families are rows of
    -- memory_agent_action_effect_labels, in order; textSelectionChanged is its family alone; the label
    -- and value columns belong to valueChanged. No encoded text, no separators.
    observed_effect_kind TEXT CHECK (observed_effect_kind IS NULL OR observed_effect_kind IN
        ('windowTitleChanged', 'stateFlip', 'menuOpened', 'elementsAppeared', 'elementsDisappeared',
         'textSelectionChanged', 'valueChanged')),
    observed_effect_text TEXT,
    observed_state_before TEXT CHECK (observed_state_before IS NULL OR observed_state_before IN ('on', 'off', 'mixed', 'unknown')),
    observed_state_after TEXT CHECK (observed_state_after IS NULL OR observed_state_after IN ('on', 'off', 'mixed', 'unknown')),
    observed_effect_label TEXT,
    observed_effect_value TEXT,
    requested_count INTEGER CHECK (requested_count IS NULL OR requested_count >= 0),
    attempted_count INTEGER CHECK (attempted_count IS NULL OR attempted_count >= 0),
    verified_count INTEGER CHECK (verified_count IS NULL OR verified_count >= 0),
    UNIQUE (app_id, event_id),
    CHECK (started_at_ms IS NULL OR execution_status <> 'planned'),
    CHECK (duration_ms IS NULL OR execution_status IN ('completed', 'failed', 'cancelled', 'interrupted')),
    CHECK ((observed_effect_kind IS 'windowTitleChanged') = (observed_effect_text IS NOT NULL)),
    CHECK ((observed_effect_kind IS 'stateFlip') = (observed_state_before IS NOT NULL AND observed_state_after IS NOT NULL)),
    CHECK (observed_effect_kind IS 'stateFlip' OR (observed_state_before IS NULL AND observed_state_after IS NULL)),
    CHECK ((observed_effect_kind IS 'valueChanged') = (observed_effect_label IS NOT NULL AND observed_effect_value IS NOT NULL)),
    CHECK (observed_effect_kind IS 'valueChanged' OR (observed_effect_label IS NULL AND observed_effect_value IS NULL)),
    CHECK (observed_effect_kind IS NULL OR execution_status = 'completed'),
    CHECK (attempted_count IS NULL OR requested_count IS NULL OR attempted_count <= requested_count),
    CHECK (verified_count IS NULL OR attempted_count IS NULL OR verified_count <= attempted_count),
    FOREIGN KEY (event_kind, event_id) REFERENCES memory_events(event_kind, event_id),
    FOREIGN KEY (app_id, event_id) REFERENCES memory_events(app_id, event_id)
) STRICT;

-- S3-d correction: the labels of a list effect (menuOpened, elementsAppeared, elementsDisappeared),
-- one row per label in the engine's order; an empty label is a label; zero rows is an empty list.
CREATE TABLE memory_agent_action_effect_labels (
    event_id TEXT NOT NULL REFERENCES memory_agent_actions(event_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    label TEXT NOT NULL,
    PRIMARY KEY (event_id, position)
) STRICT;

-- S3-d correction: the structured results of the listing and scene tools, one table per shape.
-- status: the session the host held and the three permissions as preflighted.
CREATE TABLE memory_agent_action_status (
    event_id TEXT PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    session_id TEXT,
    screen_recording INTEGER NOT NULL CHECK (screen_recording IN (0, 1)),
    accessibility INTEGER NOT NULL CHECK (accessibility IN (0, 1)),
    post_event INTEGER NOT NULL CHECK (post_event IN (0, 1))
) STRICT;

-- windows and apps: the listing's kind and how many candidates the answer left out.
CREATE TABLE memory_agent_action_listings (
    event_id TEXT PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    listing_kind TEXT NOT NULL CHECK (listing_kind IN ('windows', 'apps')),
    hidden_count INTEGER NOT NULL DEFAULT 0 CHECK (hidden_count >= 0)
) STRICT;

-- The applications a listing answered, in the order shown. A windows row carries the pid and no
-- apps field; an apps row carries is_running and no pid (trigger). is_default_browser is an apps
-- field: whether the application opens web links by default. NULL is a field the producer did not
-- know; the empty text is a text.
CREATE TABLE memory_agent_action_applications (
    event_id TEXT NOT NULL REFERENCES memory_agent_action_listings(event_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    name TEXT NOT NULL,
    bundle_id TEXT NOT NULL,
    pid INTEGER,
    app_version TEXT,
    is_running INTEGER CHECK (is_running IS NULL OR is_running IN (0, 1)),
    location TEXT,
    is_default_browser INTEGER CHECK (is_default_browser IS NULL OR is_default_browser IN (0, 1)),
    PRIMARY KEY (event_id, position),
    CHECK (length(name) > 0 OR length(bundle_id) > 0)
) STRICT;

-- The windows of one listed application, in the order listed; a title the window server did not
-- report is NULL.
CREATE TABLE memory_agent_action_windows (
    event_id TEXT NOT NULL,
    application_position INTEGER NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    window_number INTEGER NOT NULL,
    title TEXT,
    PRIMARY KEY (event_id, application_position, position),
    FOREIGN KEY (event_id, application_position) REFERENCES memory_agent_action_applications(event_id, position)
) STRICT;

-- open_session and observe: the session and its revision the scene was taken at, the calendar
-- instant the answer carried, and the real sample (current, primary) the scene text was rendered
-- from: the call's own event for observe, the session's own observation event for open_session.
CREATE TABLE memory_agent_action_observations (
    event_id TEXT PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    session_id TEXT NOT NULL CHECK (length(session_id) > 0),
    session_revision INTEGER NOT NULL CHECK (session_revision >= 0),
    observed_at_ms INTEGER NOT NULL,
    sample_event_id TEXT NOT NULL,
    sample_phase TEXT NOT NULL DEFAULT 'current' CHECK (sample_phase = 'current'),
    sample_ordinal INTEGER NOT NULL DEFAULT 0 CHECK (sample_ordinal >= 0),
    sample_observation_id INTEGER NOT NULL,
    sample_kind TEXT NOT NULL DEFAULT 'capture' CHECK (sample_kind = 'capture'),
    FOREIGN KEY (sample_observation_id, sample_event_id, sample_phase, sample_ordinal, sample_kind)
        REFERENCES memory_event_observations(observation_id, event_id, phase, sample_ordinal, observation_kind)
) STRICT;

-- Samples, elements, differences and typed diagnostic values. No serialized dump.
-- A SAMPLE is a row with observation_kind='capture' identified by (event, phase, ordinal):
-- status = the capture's quality; window_title, session_revision (the producer's ordinal),
-- surface_kind; the quality fields (walk_completed, stopped_by, window_found, grant_available,
-- window_subrole, nodes_visited, elements_emitted) are 'capture_field' child rows.
-- The sample's elements are child rows with role, label_origin and container_path
-- (structural path truncated at the collection: never row names).
-- Ordinal 0 = the primary sample: the perception the engine actually used in that phase.
CREATE TABLE memory_event_observations (
    observation_id INTEGER PRIMARY KEY,
    event_id TEXT NOT NULL REFERENCES memory_events(event_id),
    phase TEXT NOT NULL CHECK (phase IN ('before', 'menu', 'after', 'current')),
    sample_ordinal INTEGER NOT NULL DEFAULT 0 CHECK (sample_ordinal >= 0),
    observation_kind TEXT NOT NULL,
    observation_contract_version INTEGER NOT NULL DEFAULT 1 CHECK (observation_contract_version > 0),
    field_name TEXT,
    text_value TEXT,
    integer_value INTEGER,
    real_value REAL,
    boolean_value INTEGER CHECK (boolean_value IN (0, 1)),
    observation_group INTEGER,
    parent_observation_id INTEGER,
    window_title TEXT,
    session_revision INTEGER,
    surface_kind TEXT CHECK (surface_kind IS NULL OR surface_kind IN ('window', 'dialog', 'sheet', 'popup_union', 'unknown')),
    status TEXT NOT NULL,
    candidate_rank INTEGER,
    label TEXT,
    label_origin TEXT CHECK (label_origin IS NULL OR label_origin IN ('title', 'description', 'value', 'column', 'row_content', 'identifier')),
    container_path TEXT,
    role TEXT,
    element_kind TEXT,
    old_state TEXT,
    new_state TEXT,
    bounds_x REAL,
    bounds_y REAL,
    bounds_width REAL,
    bounds_height REAL,
    scene_age_ms REAL,
    name_resolution TEXT,
    label_source TEXT,
    UNIQUE (event_id, observation_id),
    CHECK ((text_value IS NOT NULL) + (integer_value IS NOT NULL) +
           (real_value IS NOT NULL) + (boolean_value IS NOT NULL) <= 1),
    CHECK (parent_observation_id IS NULL OR parent_observation_id <> observation_id),
    CHECK (observation_kind <> 'capture'
           OR (parent_observation_id IS NULL AND status IN ('complete', 'partial', 'failed', 'unknown'))),
    -- S2 3a: the parent key of a brain application's sample: the row, its event, phase, ordinal and kind.
    UNIQUE (observation_id, event_id, phase, sample_ordinal, observation_kind),
    FOREIGN KEY (event_id, parent_observation_id) REFERENCES memory_event_observations(event_id, observation_id)
) STRICT;

-- Zero rows = no candidate scene. At most one confirmed match per sample (event, phase, ordinal).
-- A sample exists as a capture row; it confirms only when complete. Never toward the app scope
-- (trigger).
CREATE TABLE memory_event_scenes (
    event_id TEXT NOT NULL,
    app_id INTEGER NOT NULL,
    phase TEXT NOT NULL CHECK (phase IN ('before', 'after', 'current')),
    sample_ordinal INTEGER NOT NULL DEFAULT 0 CHECK (sample_ordinal >= 0),
    scene_id TEXT NOT NULL,
    match_status TEXT NOT NULL CHECK (match_status IN ('candidate', 'confirmed', 'rejected')),
    matched_by TEXT NOT NULL,
    matcher_version TEXT NOT NULL,
    confidence REAL CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
    PRIMARY KEY (event_id, phase, sample_ordinal, scene_id),
    FOREIGN KEY (app_id, event_id) REFERENCES memory_events(app_id, event_id),
    FOREIGN KEY (app_id, scene_id) REFERENCES brain_scenes(app_id, scene_id)
) STRICT;

CREATE TABLE memory_verifications (
    event_id TEXT PRIMARY KEY REFERENCES memory_events(event_id),
    event_kind TEXT NOT NULL DEFAULT 'verification' CHECK (event_kind = 'verification'),
    step_occurrence_id TEXT REFERENCES memory_step_occurrences(step_occurrence_id),
    scope TEXT NOT NULL,
    method TEXT NOT NULL,
    verdict TEXT NOT NULL CHECK (verdict IN ('passed', 'failed', 'unknown')),
    expected_text TEXT,
    observed_text TEXT,
    FOREIGN KEY (event_kind, event_id) REFERENCES memory_events(event_kind, event_id)
) STRICT;

-- First event: watcher source, input kind. Second: an action of app or cli (trigger).
CREATE TABLE memory_action_correlations (
    watcher_event_id TEXT PRIMARY KEY REFERENCES memory_events(event_id),
    agent_event_id TEXT NOT NULL REFERENCES memory_events(event_id),
    basis_kind TEXT NOT NULL,
    time_offset_ms REAL,
    explanation TEXT,
    CHECK (watcher_event_id <> agent_event_id)
) STRICT;

-- S2 3a. A brain application is one concluded decision of the current algorithm about one fact: an
-- observation by (event, phase, ordinal) of a real capture sample, a record or a naming by the
-- event of its action. Written once, in the transaction that applied it, after its arguments
-- (which its insert seals) and never changed or removed: a later offer of the same key answers the
-- stored outcome. requested_at_ms is the instant asked for, effective_at_ms the application's
-- clock, never earlier than any instant the application's brain already holds. The outcome's
-- columns are required or forbidden by its code. Not an evidence: brain_evidence links knowledge.
CREATE TABLE brain_applications (
    application_id INTEGER PRIMARY KEY,
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    event_id TEXT NOT NULL,
    operation TEXT NOT NULL CHECK (operation IN ('observe', 'record', 'set_name')),
    phase TEXT CHECK (phase IS NULL OR phase IN ('before', 'menu', 'after', 'current')),
    sample_ordinal INTEGER CHECK (sample_ordinal IS NULL OR sample_ordinal >= 0),
    sample_observation_id INTEGER,
    sample_kind TEXT CHECK (sample_kind IS NULL OR sample_kind = 'capture'),
    contract_version INTEGER NOT NULL CHECK (contract_version > 0),
    algorithm_version TEXT NOT NULL CHECK (length(algorithm_version) > 0),
    requested_at_ms INTEGER NOT NULL,
    effective_at_ms INTEGER NOT NULL,
    outcome TEXT NOT NULL
        CHECK (outcome IN ('observed', 'no_effect', 'no_anchor', 'recorded', 'named', 'not_named')),
    created_count INTEGER CHECK (created_count IS NULL OR created_count >= 0),
    updated_count INTEGER CHECK (updated_count IS NULL OR updated_count >= 0),
    skipped_ambiguous_count INTEGER CHECK (skipped_ambiguous_count IS NULL OR skipped_ambiguous_count >= 0),
    anchor_id TEXT,
    transition_id TEXT,
    evidence_count INTEGER CHECK (evidence_count IS NULL OR evidence_count >= 1),
    UNIQUE (app_id, application_id),
    CHECK (effective_at_ms >= requested_at_ms),
    CHECK ((operation = 'observe') = (phase IS NOT NULL)),
    CHECK ((phase IS NULL) = (sample_ordinal IS NULL)),
    CHECK ((phase IS NULL) = (sample_observation_id IS NULL)),
    CHECK ((phase IS NULL) = (sample_kind IS NULL)),
    CHECK ((operation = 'observe' AND outcome = 'observed')
        OR (operation = 'record' AND outcome IN ('no_effect', 'no_anchor', 'recorded'))
        OR (operation = 'set_name' AND outcome IN ('named', 'not_named'))),
    CHECK ((outcome = 'observed')
           = (created_count IS NOT NULL AND updated_count IS NOT NULL AND skipped_ambiguous_count IS NOT NULL)),
    CHECK (outcome = 'observed' OR (created_count IS NULL AND updated_count IS NULL AND skipped_ambiguous_count IS NULL)),
    CHECK ((outcome IN ('recorded', 'named')) = (anchor_id IS NOT NULL)),
    CHECK ((outcome = 'recorded') = (transition_id IS NOT NULL)),
    CHECK ((outcome = 'recorded') = (evidence_count IS NOT NULL)),
    FOREIGN KEY (app_id, event_id) REFERENCES memory_events(app_id, event_id),
    FOREIGN KEY (sample_observation_id, event_id, phase, sample_ordinal, sample_kind)
        REFERENCES memory_event_observations(observation_id, event_id, phase, sample_ordinal, observation_kind),
    FOREIGN KEY (app_id, anchor_id) REFERENCES brain_anchors(app_id, anchor_id),
    FOREIGN KEY (app_id, transition_id) REFERENCES brain_transitions(app_id, transition_id)
) STRICT;

-- One evidence relation with six real FKs and exactly one target.
-- Links are not independent confirmations; never toward the app scope (trigger).
CREATE TABLE brain_evidence (
    evidence_id INTEGER PRIMARY KEY,
    app_id INTEGER NOT NULL,
    event_id TEXT NOT NULL,
    relation TEXT NOT NULL CHECK (relation IN ('supports', 'contradicts')),
    assessed_by TEXT NOT NULL,
    assessment_version TEXT NOT NULL,
    assessed_at_ms INTEGER NOT NULL,
    scene_id TEXT,
    anchor_id TEXT,
    scene_element_id TEXT,
    group_id TEXT,
    menu_command_id TEXT,
    transition_id TEXT,
    CHECK ((scene_id IS NOT NULL) + (anchor_id IS NOT NULL) + (scene_element_id IS NOT NULL)
         + (group_id IS NOT NULL) + (menu_command_id IS NOT NULL) + (transition_id IS NOT NULL) = 1),
    FOREIGN KEY (app_id, event_id) REFERENCES memory_events(app_id, event_id),
    FOREIGN KEY (app_id, scene_id) REFERENCES brain_scenes(app_id, scene_id),
    FOREIGN KEY (app_id, anchor_id) REFERENCES brain_anchors(app_id, anchor_id),
    FOREIGN KEY (app_id, scene_element_id) REFERENCES brain_scene_elements(app_id, scene_element_id),
    FOREIGN KEY (app_id, group_id) REFERENCES brain_groups(app_id, group_id),
    FOREIGN KEY (app_id, menu_command_id) REFERENCES brain_menu_commands(app_id, menu_command_id),
    FOREIGN KEY (app_id, transition_id) REFERENCES brain_transitions(app_id, transition_id)
) STRICT;

CREATE TABLE memory_task_occurrences (
    task_occurrence_id TEXT PRIMARY KEY,
    trace_id TEXT,
    started_at_ms INTEGER NOT NULL,
    ended_at_ms INTEGER,
    status TEXT NOT NULL
        CHECK (status IN ('observed', 'in_progress', 'completed', 'failed', 'cancelled', 'interrupted', 'unknown')),
    CHECK (ended_at_ms IS NULL OR ended_at_ms >= started_at_ms)
) STRICT;

CREATE TABLE memory_task_events (
    task_occurrence_id TEXT NOT NULL REFERENCES memory_task_occurrences(task_occurrence_id),
    event_id TEXT NOT NULL REFERENCES memory_events(event_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    role TEXT NOT NULL CHECK (role IN ('observation', 'action', 'verification', 'context')),
    PRIMARY KEY (task_occurrence_id, event_id, role),
    UNIQUE (task_occurrence_id, position)
) STRICT;

CREATE TABLE memory_task_labels (
    label_id TEXT PRIMARY KEY,
    task_occurrence_id TEXT NOT NULL REFERENCES memory_task_occurrences(task_occurrence_id),
    label TEXT NOT NULL,
    assigned_by TEXT NOT NULL,
    confidence REAL CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
    status TEXT NOT NULL CHECK (status IN ('candidate', 'confirmed', 'rejected')),
    assigned_at_ms INTEGER NOT NULL
) STRICT;

CREATE TABLE memory_routes (
    route_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('draft', 'active', 'retired')),
    supersedes_route_id TEXT REFERENCES memory_routes(route_id),
    created_at_ms INTEGER NOT NULL,
    last_used_ms INTEGER,
    demoted_at_ms INTEGER,
    demotion_cause TEXT,
    CHECK (supersedes_route_id IS NULL OR supersedes_route_id <> route_id)
) STRICT;

CREATE TABLE memory_route_parameters (
    parameter_id TEXT PRIMARY KEY,
    route_id TEXT NOT NULL REFERENCES memory_routes(route_id),
    name TEXT NOT NULL,
    direction TEXT NOT NULL CHECK (direction IN ('input', 'output', 'inout')),
    value_type TEXT NOT NULL CHECK (value_type IN ('text', 'integer', 'real', 'boolean')),
    is_required INTEGER NOT NULL CHECK (is_required IN (0, 1)),
    UNIQUE (route_id, name),
    UNIQUE (route_id, parameter_id),
    UNIQUE (route_id, parameter_id, value_type)
) STRICT;

-- Step = a verifiable result. A published Route has at least one step; the store checks that.
-- No recursive call between Routes, direct or indirect (trigger). A step is immutable in its app,
-- Route, kind and called Route: a change creates a new version of the Route.
CREATE TABLE memory_route_steps (
    step_id TEXT PRIMARY KEY,
    route_id TEXT NOT NULL REFERENCES memory_routes(route_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    step_kind TEXT NOT NULL CHECK (step_kind IN ('goal', 'route_call')),
    goal_text TEXT NOT NULL,
    app_id INTEGER REFERENCES brain_apps(app_id),
    called_route_id TEXT REFERENCES memory_routes(route_id),
    UNIQUE (route_id, position),
    UNIQUE (route_id, step_id),
    UNIQUE (app_id, step_id),
    UNIQUE (route_id, step_id, called_route_id),
    CHECK (called_route_id IS NULL OR called_route_id <> route_id),
    CHECK ((step_kind = 'goal' AND called_route_id IS NULL)
        OR (step_kind = 'route_call' AND called_route_id IS NOT NULL))
) STRICT;

-- app_id derived from the step (null-safe trigger).
CREATE TABLE memory_step_checks (
    check_id TEXT PRIMARY KEY,
    route_id TEXT NOT NULL,
    step_id TEXT NOT NULL,
    app_id INTEGER REFERENCES brain_apps(app_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    check_kind TEXT NOT NULL,
    expected_scene_id TEXT,
    expected_anchor_id TEXT,
    expected_state TEXT,
    expected_text TEXT,
    expected_integer INTEGER,
    expected_real REAL,
    expected_bool INTEGER CHECK (expected_bool IN (0, 1)),
    expected_parameter_id TEXT,
    comparison TEXT,
    UNIQUE (step_id, position),
    CHECK ((expected_state IS NOT NULL) + (expected_text IS NOT NULL) + (expected_integer IS NOT NULL)
         + (expected_real IS NOT NULL) + (expected_bool IS NOT NULL) + (expected_parameter_id IS NOT NULL) <= 1),
    CHECK ((expected_scene_id IS NULL AND expected_anchor_id IS NULL) OR app_id IS NOT NULL),
    FOREIGN KEY (route_id, step_id) REFERENCES memory_route_steps(route_id, step_id),
    FOREIGN KEY (app_id, step_id) REFERENCES memory_route_steps(app_id, step_id),
    FOREIGN KEY (app_id, expected_scene_id) REFERENCES brain_scenes(app_id, scene_id),
    FOREIGN KEY (app_id, expected_anchor_id) REFERENCES brain_anchors(app_id, anchor_id),
    FOREIGN KEY (route_id, expected_parameter_id) REFERENCES memory_route_parameters(route_id, parameter_id)
) STRICT;

-- Reproducible definitions. A batch holds child operations within the same step.
-- app_id derived from the step (null-safe trigger); no parent/child cycle (trigger).
CREATE TABLE memory_step_operations (
    operation_id TEXT PRIMARY KEY,
    route_id TEXT NOT NULL,
    step_id TEXT NOT NULL,
    parent_operation_id TEXT,
    position INTEGER NOT NULL CHECK (position >= 0),
    tool_kind TEXT NOT NULL,
    contract_version INTEGER NOT NULL DEFAULT 1 CHECK (contract_version > 0),
    app_id INTEGER REFERENCES brain_apps(app_id),
    UNIQUE (route_id, operation_id),
    UNIQUE (step_id, operation_id),
    UNIQUE (app_id, operation_id),
    CHECK (parent_operation_id IS NULL OR parent_operation_id <> operation_id),
    FOREIGN KEY (route_id, step_id) REFERENCES memory_route_steps(route_id, step_id),
    FOREIGN KEY (app_id, step_id) REFERENCES memory_route_steps(app_id, step_id),
    FOREIGN KEY (step_id, parent_operation_id) REFERENCES memory_step_operations(step_id, operation_id)
) STRICT;

-- A typed argument belongs to a Route operation OR to an observed call OR (S2 3a) to a brain
-- application, exactly one of them.
-- app_id derived from the owner (null-safe trigger): omitting it is no way around the rule. A brain
-- application's arguments name its app and are checked against it by a composite key deferred to
-- the commit, since they are written before the application row that seals them; they are plain
-- values, never a parameter, an anchor or a menu reference.
-- Names, cardinality, defaults and tool-specific constraints are validated by the shared contract.
CREATE TABLE memory_operation_arguments (
    argument_id INTEGER PRIMARY KEY,
    operation_id TEXT REFERENCES memory_step_operations(operation_id),
    event_id TEXT REFERENCES memory_agent_actions(event_id),
    brain_application_id INTEGER,
    route_id TEXT,
    app_id INTEGER REFERENCES brain_apps(app_id),
    argument_name TEXT NOT NULL,
    position INTEGER NOT NULL DEFAULT 0 CHECK (position >= 0),
    value_kind TEXT NOT NULL CHECK (value_kind IN ('text', 'integer', 'real', 'boolean', 'parameter', 'anchor', 'menu')),
    text_value TEXT,
    integer_value INTEGER,
    real_value REAL,
    boolean_value INTEGER CHECK (boolean_value IN (0, 1)),
    parameter_id TEXT,
    anchor_id TEXT,
    menu_command_id TEXT,
    CHECK ((operation_id IS NOT NULL) + (event_id IS NOT NULL) + (brain_application_id IS NOT NULL) = 1),
    CHECK ((operation_id IS NOT NULL AND route_id IS NOT NULL) OR
           (event_id IS NOT NULL AND route_id IS NULL AND parameter_id IS NULL) OR
           (brain_application_id IS NOT NULL AND route_id IS NULL AND parameter_id IS NULL AND app_id IS NOT NULL
            AND anchor_id IS NULL AND menu_command_id IS NULL)),
    CHECK (brain_application_id IS NULL OR value_kind IN ('text', 'integer', 'real', 'boolean')),
    CHECK ((anchor_id IS NULL AND menu_command_id IS NULL) OR app_id IS NOT NULL),
    CHECK ((text_value IS NOT NULL) + (integer_value IS NOT NULL) + (real_value IS NOT NULL)
         + (boolean_value IS NOT NULL) + (parameter_id IS NOT NULL) + (anchor_id IS NOT NULL)
         + (menu_command_id IS NOT NULL) = 1),
    CHECK ((value_kind = 'text' AND text_value IS NOT NULL)
        OR (value_kind = 'integer' AND integer_value IS NOT NULL)
        OR (value_kind = 'real' AND real_value IS NOT NULL)
        OR (value_kind = 'boolean' AND boolean_value IS NOT NULL)
        OR (value_kind = 'parameter' AND parameter_id IS NOT NULL)
        OR (value_kind = 'anchor' AND anchor_id IS NOT NULL)
        OR (value_kind = 'menu' AND menu_command_id IS NOT NULL)),
    FOREIGN KEY (route_id, operation_id) REFERENCES memory_step_operations(route_id, operation_id),
    FOREIGN KEY (route_id, parameter_id) REFERENCES memory_route_parameters(route_id, parameter_id),
    FOREIGN KEY (app_id, operation_id) REFERENCES memory_step_operations(app_id, operation_id),
    FOREIGN KEY (app_id, event_id) REFERENCES memory_agent_actions(app_id, event_id),
    FOREIGN KEY (app_id, anchor_id) REFERENCES brain_anchors(app_id, anchor_id),
    FOREIGN KEY (app_id, menu_command_id) REFERENCES brain_menu_commands(app_id, menu_command_id),
    FOREIGN KEY (app_id, brain_application_id) REFERENCES brain_applications(app_id, application_id)
        DEFERRABLE INITIALLY DEFERRED
) STRICT;

CREATE TABLE memory_route_call_bindings (
    step_id TEXT NOT NULL,
    route_id TEXT NOT NULL,
    called_route_id TEXT NOT NULL,
    called_parameter_id TEXT NOT NULL REFERENCES memory_route_parameters(parameter_id),
    source_parameter_id TEXT REFERENCES memory_route_parameters(parameter_id),
    literal_text TEXT,
    literal_integer INTEGER,
    literal_real REAL,
    literal_bool INTEGER CHECK (literal_bool IN (0, 1)),
    PRIMARY KEY (step_id, called_parameter_id),
    CHECK ((source_parameter_id IS NOT NULL) + (literal_text IS NOT NULL)
         + (literal_integer IS NOT NULL) + (literal_real IS NOT NULL)
         + (literal_bool IS NOT NULL) = 1),
    FOREIGN KEY (route_id, step_id, called_route_id) REFERENCES memory_route_steps(route_id, step_id, called_route_id),
    FOREIGN KEY (called_route_id, called_parameter_id) REFERENCES memory_route_parameters(route_id, parameter_id),
    FOREIGN KEY (route_id, source_parameter_id) REFERENCES memory_route_parameters(route_id, parameter_id)
) STRICT;

-- An occurrence observed even without a known definition. Assigning task/step certifies no success.
CREATE TABLE memory_step_occurrences (
    step_occurrence_id TEXT PRIMARY KEY,
    task_occurrence_id TEXT REFERENCES memory_task_occurrences(task_occurrence_id),
    step_id TEXT REFERENCES memory_route_steps(step_id),
    started_at_ms INTEGER NOT NULL,
    ended_at_ms INTEGER,
    status TEXT NOT NULL
        CHECK (status IN ('observed', 'in_progress', 'completed', 'failed', 'cancelled', 'interrupted', 'unknown')),
    assigned_by TEXT,
    UNIQUE (step_occurrence_id, step_id),
    CHECK (ended_at_ms IS NULL OR ended_at_ms >= started_at_ms)
) STRICT;

-- Membership of events in a step. The 'verification' role is not a second attribution: it must
-- point at the same occurrence as memory_verifications.step_occurrence_id (trigger).
CREATE TABLE memory_step_events (
    step_occurrence_id TEXT NOT NULL REFERENCES memory_step_occurrences(step_occurrence_id),
    event_id TEXT NOT NULL REFERENCES memory_events(event_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    attempt_number INTEGER,
    role TEXT NOT NULL CHECK (role IN ('observation', 'action', 'verification', 'context')),
    PRIMARY KEY (step_occurrence_id, event_id, role),
    UNIQUE (step_occurrence_id, position)
) STRICT;

CREATE TABLE memory_route_evidence (
    route_id TEXT NOT NULL REFERENCES memory_routes(route_id),
    task_occurrence_id TEXT NOT NULL REFERENCES memory_task_occurrences(task_occurrence_id),
    relation TEXT NOT NULL CHECK (relation IN ('supports', 'contradicts')),
    assessed_by TEXT NOT NULL,
    assessed_at_ms INTEGER NOT NULL,
    PRIMARY KEY (route_id, task_occurrence_id, relation)
) STRICT;

CREATE TABLE memory_step_evidence (
    step_id TEXT NOT NULL REFERENCES memory_route_steps(step_id),
    step_occurrence_id TEXT NOT NULL,
    relation TEXT NOT NULL CHECK (relation IN ('supports', 'contradicts')),
    assessed_by TEXT NOT NULL,
    assessed_at_ms INTEGER NOT NULL,
    PRIMARY KEY (step_id, step_occurrence_id, relation),
    FOREIGN KEY (step_occurrence_id, step_id)
        REFERENCES memory_step_occurrences(step_occurrence_id, step_id)
) STRICT;

CREATE TABLE memory_experiences (
    experience_id TEXT PRIMARY KEY,
    phrase TEXT NOT NULL,
    route_id TEXT NOT NULL REFERENCES memory_routes(route_id),
    step_id TEXT,
    created_at_ms INTEGER NOT NULL,
    UNIQUE (route_id, experience_id),
    FOREIGN KEY (route_id, step_id) REFERENCES memory_route_steps(route_id, step_id)
) STRICT;

-- A memory says where its parameters come from; it never reuses ephemeral UI references.
CREATE TABLE memory_experience_bindings (
    experience_id TEXT NOT NULL,
    route_id TEXT NOT NULL,
    parameter_id TEXT NOT NULL,
    value_type TEXT NOT NULL CHECK (value_type IN ('text', 'integer', 'real', 'boolean')),
    binding_kind TEXT NOT NULL CHECK (binding_kind IN ('literal', 'request_slot', 'context_slot')),
    binding_contract_version INTEGER NOT NULL DEFAULT 1 CHECK (binding_contract_version > 0),
    slot_name TEXT,
    literal_text TEXT,
    literal_integer INTEGER,
    literal_real REAL,
    literal_boolean INTEGER CHECK (literal_boolean IN (0, 1)),
    PRIMARY KEY (experience_id, parameter_id),
    FOREIGN KEY (route_id, experience_id) REFERENCES memory_experiences(route_id, experience_id),
    FOREIGN KEY (route_id, parameter_id, value_type)
        REFERENCES memory_route_parameters(route_id, parameter_id, value_type),
    CHECK (
        (binding_kind = 'literal' AND slot_name IS NULL
         AND ((literal_text IS NOT NULL) + (literal_integer IS NOT NULL)
            + (literal_real IS NOT NULL) + (literal_boolean IS NOT NULL) = 1)
         AND ((value_type = 'text' AND literal_text IS NOT NULL)
           OR (value_type = 'integer' AND literal_integer IS NOT NULL)
           OR (value_type = 'real' AND literal_real IS NOT NULL)
           OR (value_type = 'boolean' AND literal_boolean IS NOT NULL)))
        OR
        (binding_kind IN ('request_slot', 'context_slot')
         AND slot_name IS NOT NULL AND length(trim(slot_name)) > 0
         AND literal_text IS NULL AND literal_integer IS NULL
         AND literal_real IS NULL AND literal_boolean IS NULL)
    )
) STRICT;

CREATE TABLE memory_experience_uses (
    experience_id TEXT NOT NULL REFERENCES memory_experiences(experience_id),
    event_id TEXT NOT NULL REFERENCES memory_events(event_id),
    verdict TEXT NOT NULL CHECK (verdict IN ('passed', 'failed', 'unknown')),
    PRIMARY KEY (experience_id, event_id)
) STRICT;

-- ---------------------------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------------------------

-- Operational reads: retired knowledge stays available to diagnostics.
CREATE INDEX brain_anchors_active_by_kind ON brain_anchors(app_id, kind) WHERE retired_at_ms IS NULL;
CREATE INDEX brain_groups_active_by_app ON brain_groups(app_id) WHERE retired_at_ms IS NULL;
CREATE INDEX brain_transitions_active_by_anchor ON brain_transitions(app_id, anchor_id, trigger_kind) WHERE retired_at_ms IS NULL;

-- One scope row per app.
CREATE UNIQUE INDEX brain_scenes_one_app_scope ON brain_scenes(app_id) WHERE scene_kind = 'app';

CREATE UNIQUE INDEX brain_evidence_scene_id ON brain_evidence(scene_id, event_id, relation) WHERE scene_id IS NOT NULL;
CREATE UNIQUE INDEX brain_evidence_anchor_id ON brain_evidence(anchor_id, event_id, relation) WHERE anchor_id IS NOT NULL;
CREATE UNIQUE INDEX brain_evidence_scene_element_id ON brain_evidence(scene_element_id, event_id, relation) WHERE scene_element_id IS NOT NULL;
CREATE UNIQUE INDEX brain_evidence_group_id ON brain_evidence(group_id, event_id, relation) WHERE group_id IS NOT NULL;
CREATE UNIQUE INDEX brain_evidence_menu_command_id ON brain_evidence(menu_command_id, event_id, relation) WHERE menu_command_id IS NOT NULL;
CREATE UNIQUE INDEX brain_evidence_transition_id ON brain_evidence(transition_id, event_id, relation) WHERE transition_id IS NOT NULL;

-- One sample (capture row) per event, phase and ordinal; one confirmed match per sample.
CREATE UNIQUE INDEX memory_observation_captures ON memory_event_observations(event_id, phase, sample_ordinal) WHERE observation_kind = 'capture';
CREATE UNIQUE INDEX memory_event_scenes_confirmed ON memory_event_scenes(event_id, phase, sample_ordinal) WHERE match_status = 'confirmed';
CREATE UNIQUE INDEX memory_operations_roots ON memory_step_operations(step_id, position) WHERE parent_operation_id IS NULL;
CREATE UNIQUE INDEX memory_operations_children ON memory_step_operations(parent_operation_id, position) WHERE parent_operation_id IS NOT NULL;
CREATE UNIQUE INDEX memory_arguments_definition ON memory_operation_arguments(operation_id, argument_name, position) WHERE operation_id IS NOT NULL;
CREATE UNIQUE INDEX memory_arguments_event ON memory_operation_arguments(event_id, argument_name, position) WHERE event_id IS NOT NULL;
-- S2 3a: one argument per name and position of an application; one application per key, with no
-- NULL column in either key (an observation's phase and ordinal are required by its CHECK).
CREATE UNIQUE INDEX memory_arguments_brain_application ON memory_operation_arguments(brain_application_id, argument_name, position) WHERE brain_application_id IS NOT NULL;
CREATE UNIQUE INDEX brain_applications_observation_key ON brain_applications(event_id, phase, sample_ordinal) WHERE operation = 'observe';
CREATE UNIQUE INDEX brain_applications_call_key ON brain_applications(event_id, operation) WHERE operation <> 'observe';
CREATE INDEX brain_applications_by_app_clock ON brain_applications(app_id, effective_at_ms);
CREATE INDEX memory_events_by_context_time ON memory_events(context_id, occurred_at_ms);
CREATE INDEX memory_events_by_trace ON memory_events(trace_id, local_order);
CREATE INDEX memory_events_by_source_order ON memory_events(source, source_stream_id, local_order);
CREATE INDEX memory_task_labels_by_occurrence ON memory_task_labels(task_occurrence_id, status);
CREATE INDEX memory_step_occurrences_by_task ON memory_step_occurrences(task_occurrence_id, started_at_ms);
CREATE INDEX brain_transitions_by_source ON brain_transitions(app_id, from_scene_id, trigger_kind);
CREATE INDEX brain_transitions_by_destination ON brain_transitions(app_id, to_scene_id);
CREATE INDEX brain_menu_by_path_hint ON brain_menu_commands(app_id, path_key);
CREATE INDEX brain_evidence_by_event ON brain_evidence(event_id);
CREATE INDEX memory_task_events_by_event ON memory_task_events(event_id);
CREATE INDEX memory_step_events_by_event ON memory_step_events(event_id);

-- ---------------------------------------------------------------------------------------------
-- Triggers A: the app scope is a scope, not a surface. IS / IS NOT semantics: null-safe.
-- Every rule below covers INSERT and the UPDATE that could move a row onto the scope.
-- ---------------------------------------------------------------------------------------------

CREATE TRIGGER brain_scenes_kind_immutable BEFORE UPDATE OF scene_kind ON brain_scenes
BEGIN
    SELECT RAISE(ABORT, 'brain_scenes.scene_kind is immutable');
END;

CREATE TRIGGER brain_scene_elements_not_app_scope_insert BEFORE INSERT ON brain_scene_elements
BEGIN
    SELECT RAISE(ABORT, 'the app scope has no structural elements')
    WHERE (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.scene_id) = 'app';
END;

CREATE TRIGGER brain_scene_elements_not_app_scope_update BEFORE UPDATE OF scene_id ON brain_scene_elements
BEGIN
    SELECT RAISE(ABORT, 'the app scope has no structural elements')
    WHERE (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.scene_id) = 'app';
END;

CREATE TRIGGER brain_scene_roles_not_app_scope_insert BEFORE INSERT ON brain_scene_roles
BEGIN
    SELECT RAISE(ABORT, 'the app scope has no roles')
    WHERE (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.scene_id) = 'app';
END;

-- S1: v5 covered the INSERT only; an UPDATE of scene_id could move a role onto the scope.
CREATE TRIGGER brain_scene_roles_not_app_scope_update BEFORE UPDATE OF scene_id ON brain_scene_roles
BEGIN
    SELECT RAISE(ABORT, 'the app scope has no roles')
    WHERE (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.scene_id) = 'app';
END;

CREATE TRIGGER brain_scene_labels_not_app_scope_insert BEFORE INSERT ON brain_scene_labels
BEGIN
    SELECT RAISE(ABORT, 'the app scope has no labels')
    WHERE (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.scene_id) = 'app';
END;

-- S1: same symmetry for labels.
CREATE TRIGGER brain_scene_labels_not_app_scope_update BEFORE UPDATE OF scene_id ON brain_scene_labels
BEGIN
    SELECT RAISE(ABORT, 'the app scope has no labels')
    WHERE (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.scene_id) = 'app';
END;

CREATE TRIGGER memory_event_scenes_not_app_scope_insert BEFORE INSERT ON memory_event_scenes
BEGIN
    SELECT RAISE(ABORT, 'an observation is never associated with the app scope')
    WHERE (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.scene_id) = 'app';
END;

CREATE TRIGGER memory_event_scenes_not_app_scope_update BEFORE UPDATE OF scene_id ON memory_event_scenes
BEGIN
    SELECT RAISE(ABORT, 'an observation is never associated with the app scope')
    WHERE (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.scene_id) = 'app';
END;

CREATE TRIGGER brain_evidence_not_app_scope_insert BEFORE INSERT ON brain_evidence
BEGIN
    SELECT RAISE(ABORT, 'evidence never targets the app scope itself')
    WHERE NEW.scene_id IS NOT NULL
      AND (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.scene_id) = 'app';
END;

CREATE TRIGGER brain_evidence_not_app_scope_update BEFORE UPDATE OF scene_id ON brain_evidence
BEGIN
    SELECT RAISE(ABORT, 'evidence never targets the app scope itself')
    WHERE NEW.scene_id IS NOT NULL
      AND (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.scene_id) = 'app';
END;

CREATE TRIGGER brain_transitions_to_not_app_scope_insert BEFORE INSERT ON brain_transitions
BEGIN
    SELECT RAISE(ABORT, 'an unknown destination stays NULL; the app scope is never a destination')
    WHERE NEW.to_scene_id IS NOT NULL
      AND (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.to_scene_id) = 'app';
END;

CREATE TRIGGER brain_transitions_to_not_app_scope_update BEFORE UPDATE OF to_scene_id ON brain_transitions
BEGIN
    SELECT RAISE(ABORT, 'an unknown destination stays NULL; the app scope is never a destination')
    WHERE NEW.to_scene_id IS NOT NULL
      AND (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.to_scene_id) = 'app';
END;

-- ---------------------------------------------------------------------------------------------
-- Triggers C: app_id derived from the parent, immutable identity, verification/membership,
-- correlations, cycles. An unknown context (NULL) is never rewritten as if it had been known.
-- ---------------------------------------------------------------------------------------------

CREATE TRIGGER memory_events_identity_immutable BEFORE UPDATE OF
    event_id, source, source_stream_id, source_key, trace_id, session_id, parent_event_id,
    parent_position, event_kind, app_id, context_id, occurred_at_ms, monotonic_ns, origin_event_id
ON memory_events
BEGIN
    SELECT RAISE(ABORT, 'memory_events identity and context are immutable; only capture_status may change');
END;

CREATE TRIGGER memory_agent_actions_app_from_event_insert BEFORE INSERT ON memory_agent_actions
BEGIN
    SELECT RAISE(ABORT, 'memory_agent_actions.app_id must equal its event''s app_id (both may be NULL)')
    WHERE (SELECT app_id FROM memory_events WHERE event_id = NEW.event_id) IS NOT NEW.app_id;
END;

CREATE TRIGGER memory_agent_actions_identity_immutable BEFORE UPDATE OF
    event_id, event_kind, app_id, tool_kind, contract_version
ON memory_agent_actions
BEGIN
    SELECT RAISE(ABORT, 'memory_agent_actions identity is immutable; execution fields have dedicated updates');
END;

-- S3-d correction: the shape guards of a call's effect labels and structured results. Each row
-- belongs to a completed call of the tool that produces it; a label belongs to a list effect.
CREATE TRIGGER memory_agent_action_effect_labels_insert_guard BEFORE INSERT ON memory_agent_action_effect_labels
BEGIN
    SELECT RAISE(ABORT, 'an effect label belongs to a completed call whose effect is a list')
    WHERE NOT EXISTS (
        SELECT 1 FROM memory_agent_actions a WHERE a.event_id = NEW.event_id AND a.execution_status = 'completed'
            AND a.observed_effect_kind IN ('menuOpened', 'elementsAppeared', 'elementsDisappeared'));
END;

CREATE TRIGGER memory_agent_action_status_insert_guard BEFORE INSERT ON memory_agent_action_status
BEGIN
    SELECT RAISE(ABORT, 'a status result belongs to a completed status call')
    WHERE NOT EXISTS (
        SELECT 1 FROM memory_agent_actions a WHERE a.event_id = NEW.event_id AND a.execution_status = 'completed'
            AND a.tool_kind = 'status' AND a.result_kind = 'status');
END;

CREATE TRIGGER memory_agent_action_listings_insert_guard BEFORE INSERT ON memory_agent_action_listings
BEGIN
    SELECT RAISE(ABORT, 'a listing result belongs to a completed windows or apps call of its kind')
    WHERE NOT EXISTS (
        SELECT 1 FROM memory_agent_actions a WHERE a.event_id = NEW.event_id AND a.execution_status = 'completed'
            AND a.tool_kind = NEW.listing_kind AND a.result_kind = 'listing');
END;

CREATE TRIGGER memory_agent_action_applications_insert_guard BEFORE INSERT ON memory_agent_action_applications
BEGIN
    SELECT RAISE(ABORT, 'a windows row carries a pid and no apps field; an apps row carries is_running and no pid')
    WHERE NOT EXISTS (
        SELECT 1 FROM memory_agent_action_listings l WHERE l.event_id = NEW.event_id
            AND ((l.listing_kind = 'windows' AND NEW.pid IS NOT NULL AND NEW.is_running IS NULL
                  AND NEW.app_version IS NULL AND NEW.location IS NULL AND NEW.is_default_browser IS NULL)
              OR (l.listing_kind = 'apps' AND NEW.pid IS NULL AND NEW.is_running IS NOT NULL)));
END;

CREATE TRIGGER memory_agent_action_windows_insert_guard BEFORE INSERT ON memory_agent_action_windows
BEGIN
    SELECT RAISE(ABORT, 'a listed window belongs to a windows listing')
    WHERE NOT EXISTS (
        SELECT 1 FROM memory_agent_action_listings l WHERE l.event_id = NEW.event_id AND l.listing_kind = 'windows');
END;

CREATE TRIGGER memory_agent_action_observations_insert_guard BEFORE INSERT ON memory_agent_action_observations
BEGIN
    SELECT RAISE(ABORT, 'an observation result belongs to a completed open_session or observe call')
    WHERE NOT EXISTS (
        SELECT 1 FROM memory_agent_actions a WHERE a.event_id = NEW.event_id AND a.execution_status = 'completed'
            AND a.tool_kind IN ('open_session', 'observe') AND a.result_kind = 'observation');
END;

CREATE TRIGGER memory_route_steps_identity_immutable BEFORE UPDATE OF
    step_id, route_id, step_kind, app_id, called_route_id
ON memory_route_steps
BEGIN
    SELECT RAISE(ABORT, 'a step''s Route, kind, app and callee are immutable; publish a new Route version');
END;

CREATE TRIGGER memory_step_operations_app_from_step_insert BEFORE INSERT ON memory_step_operations
BEGIN
    SELECT RAISE(ABORT, 'memory_step_operations.app_id must equal its step''s app_id (both may be NULL)')
    WHERE (SELECT app_id FROM memory_route_steps WHERE step_id = NEW.step_id) IS NOT NEW.app_id;
END;

CREATE TRIGGER memory_step_operations_app_from_step_update BEFORE UPDATE OF app_id, step_id ON memory_step_operations
BEGIN
    SELECT RAISE(ABORT, 'memory_step_operations.app_id must equal its step''s app_id (both may be NULL)')
    WHERE (SELECT app_id FROM memory_route_steps WHERE step_id = NEW.step_id) IS NOT NEW.app_id;
END;

CREATE TRIGGER memory_step_checks_app_from_step_insert BEFORE INSERT ON memory_step_checks
BEGIN
    SELECT RAISE(ABORT, 'memory_step_checks.app_id must equal its step''s app_id (both may be NULL)')
    WHERE (SELECT app_id FROM memory_route_steps WHERE step_id = NEW.step_id) IS NOT NEW.app_id;
END;

CREATE TRIGGER memory_step_checks_app_from_step_update BEFORE UPDATE OF app_id, step_id ON memory_step_checks
BEGIN
    SELECT RAISE(ABORT, 'memory_step_checks.app_id must equal its step''s app_id (both may be NULL)')
    WHERE (SELECT app_id FROM memory_route_steps WHERE step_id = NEW.step_id) IS NOT NEW.app_id;
END;

CREATE TRIGGER memory_operation_arguments_app_from_owner_insert BEFORE INSERT ON memory_operation_arguments
BEGIN
    SELECT RAISE(ABORT, 'an argument''s app_id must equal its operation''s app_id (both may be NULL)')
    WHERE NEW.operation_id IS NOT NULL
      AND (SELECT app_id FROM memory_step_operations WHERE operation_id = NEW.operation_id) IS NOT NEW.app_id;
    SELECT RAISE(ABORT, 'an argument''s app_id must equal its action''s app_id (both may be NULL)')
    WHERE NEW.event_id IS NOT NULL
      AND (SELECT app_id FROM memory_agent_actions WHERE event_id = NEW.event_id) IS NOT NEW.app_id;
END;

CREATE TRIGGER memory_operation_arguments_app_from_owner_update BEFORE UPDATE OF
    app_id, operation_id, event_id
ON memory_operation_arguments
BEGIN
    SELECT RAISE(ABORT, 'an argument''s app_id must equal its operation''s app_id (both may be NULL)')
    WHERE NEW.operation_id IS NOT NULL
      AND (SELECT app_id FROM memory_step_operations WHERE operation_id = NEW.operation_id) IS NOT NEW.app_id;
    SELECT RAISE(ABORT, 'an argument''s app_id must equal its action''s app_id (both may be NULL)')
    WHERE NEW.event_id IS NOT NULL
      AND (SELECT app_id FROM memory_agent_actions WHERE event_id = NEW.event_id) IS NOT NEW.app_id;
END;

-- memory_verifications.step_occurrence_id is the one authoritative attribution. A membership with
-- the 'verification' role must point at the same occurrence, in either write order.
CREATE TRIGGER memory_step_events_verification_role_insert BEFORE INSERT ON memory_step_events
BEGIN
    SELECT RAISE(ABORT, 'a verification membership must name a verification event attributed to the same step occurrence')
    WHERE NEW.role = 'verification'
      AND (SELECT step_occurrence_id FROM memory_verifications WHERE event_id = NEW.event_id) IS NOT NEW.step_occurrence_id;
END;

CREATE TRIGGER memory_step_events_verification_role_update BEFORE UPDATE OF
    role, event_id, step_occurrence_id
ON memory_step_events
BEGIN
    SELECT RAISE(ABORT, 'a verification membership must name a verification event attributed to the same step occurrence')
    WHERE NEW.role = 'verification'
      AND (SELECT step_occurrence_id FROM memory_verifications WHERE event_id = NEW.event_id) IS NOT NEW.step_occurrence_id;
END;

CREATE TRIGGER memory_verifications_matches_membership_insert BEFORE INSERT ON memory_verifications
BEGIN
    SELECT RAISE(ABORT, 'a verification cannot be attributed to a step occurrence other than its membership''s')
    WHERE EXISTS (SELECT 1 FROM memory_step_events
                  WHERE event_id = NEW.event_id AND role = 'verification'
                    AND step_occurrence_id IS NOT NEW.step_occurrence_id);
END;

CREATE TRIGGER memory_verifications_matches_membership_update BEFORE UPDATE OF step_occurrence_id ON memory_verifications
BEGIN
    SELECT RAISE(ABORT, 'a verification cannot be attributed to a step occurrence other than its membership''s')
    WHERE EXISTS (SELECT 1 FROM memory_step_events
                  WHERE event_id = NEW.event_id AND role = 'verification'
                    AND step_occurrence_id IS NOT NEW.step_occurrence_id);
END;

CREATE TRIGGER memory_action_correlations_roles_insert BEFORE INSERT ON memory_action_correlations
BEGIN
    SELECT RAISE(ABORT, 'watcher_event_id must be a watcher input event')
    WHERE NOT EXISTS (SELECT 1 FROM memory_events
                      WHERE event_id = NEW.watcher_event_id AND source = 'watcher' AND event_kind = 'input');
    SELECT RAISE(ABORT, 'agent_event_id must be an app, cli or mcp action event')
    WHERE NOT EXISTS (SELECT 1 FROM memory_events
                      WHERE event_id = NEW.agent_event_id AND source IN ('app', 'cli', 'mcp') AND event_kind = 'action');
END;

CREATE TRIGGER memory_action_correlations_roles_update BEFORE UPDATE OF
    watcher_event_id, agent_event_id
ON memory_action_correlations
BEGIN
    SELECT RAISE(ABORT, 'watcher_event_id must be a watcher input event')
    WHERE NOT EXISTS (SELECT 1 FROM memory_events
                      WHERE event_id = NEW.watcher_event_id AND source = 'watcher' AND event_kind = 'input');
    SELECT RAISE(ABORT, 'agent_event_id must be an app, cli or mcp action event')
    WHERE NOT EXISTS (SELECT 1 FROM memory_events
                      WHERE event_id = NEW.agent_event_id AND source IN ('app', 'cli', 'mcp') AND event_kind = 'action');
END;

-- No recursive call between Routes: A -> B -> A is refused at the insert of the step that closes the cycle.
CREATE TRIGGER memory_route_steps_no_recursive_calls BEFORE INSERT ON memory_route_steps
WHEN NEW.called_route_id IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'a Route may not call itself, directly or through other Routes')
    WHERE NEW.route_id IN (
        WITH RECURSIVE reach(route_id) AS (
            SELECT NEW.called_route_id
            UNION
            SELECT s.called_route_id FROM memory_route_steps s JOIN reach ON s.route_id = reach.route_id
            WHERE s.called_route_id IS NOT NULL
        )
        SELECT route_id FROM reach
    );
END;

-- No parent/child cycle between operations (possible only through an UPDATE of the parent).
CREATE TRIGGER memory_step_operations_no_parent_cycle BEFORE UPDATE OF parent_operation_id ON memory_step_operations
WHEN NEW.parent_operation_id IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'an operation cannot be its own ancestor')
    WHERE NEW.operation_id IN (
        WITH RECURSIVE up(operation_id) AS (
            SELECT NEW.parent_operation_id
            UNION
            SELECT o.parent_operation_id FROM memory_step_operations o JOIN up ON o.operation_id = up.operation_id
            WHERE o.parent_operation_id IS NOT NULL
        )
        SELECT operation_id FROM up
    );
END;

-- ---------------------------------------------------------------------------------------------
-- Triggers D: samples. An association needs its own sample; confirmation only when complete.
-- A referenced sample keeps its identity and cannot be removed; a confirmed one keeps its
-- complete status as well.
-- ---------------------------------------------------------------------------------------------

CREATE TRIGGER memory_event_scenes_require_capture_insert BEFORE INSERT ON memory_event_scenes
BEGIN
    SELECT RAISE(ABORT, 'a scene association needs its capture sample (event, phase, ordinal)')
    WHERE NOT EXISTS (SELECT 1 FROM memory_event_observations
                      WHERE event_id = NEW.event_id AND phase = NEW.phase
                        AND sample_ordinal = NEW.sample_ordinal AND observation_kind = 'capture');
    SELECT RAISE(ABORT, 'only a complete capture can confirm a scene')
    WHERE NEW.match_status = 'confirmed'
      AND (SELECT status FROM memory_event_observations
           WHERE event_id = NEW.event_id AND phase = NEW.phase
             AND sample_ordinal = NEW.sample_ordinal AND observation_kind = 'capture') <> 'complete';
END;

CREATE TRIGGER memory_event_scenes_require_capture_update BEFORE UPDATE OF
    match_status, event_id, phase, sample_ordinal
ON memory_event_scenes
BEGIN
    SELECT RAISE(ABORT, 'a scene association needs its capture sample (event, phase, ordinal)')
    WHERE NOT EXISTS (SELECT 1 FROM memory_event_observations
                      WHERE event_id = NEW.event_id AND phase = NEW.phase
                        AND sample_ordinal = NEW.sample_ordinal AND observation_kind = 'capture');
    SELECT RAISE(ABORT, 'only a complete capture can confirm a scene')
    WHERE NEW.match_status = 'confirmed'
      AND (SELECT status FROM memory_event_observations
           WHERE event_id = NEW.event_id AND phase = NEW.phase
             AND sample_ordinal = NEW.sample_ordinal AND observation_kind = 'capture') <> 'complete';
END;

-- S1: a capture row that any scene association references keeps the identity the association
-- names (event, phase, ordinal) and stays a capture. v5 guarded phase and ordinal for confirmed
-- samples only; event_id could still move, leaving the association without its sample.
CREATE TRIGGER memory_event_observations_capture_identity_guard BEFORE UPDATE OF
    event_id, observation_kind, phase, sample_ordinal
ON memory_event_observations
WHEN OLD.observation_kind = 'capture'
BEGIN
    SELECT RAISE(ABORT, 'a referenced sample keeps its identity (event, phase, ordinal, capture)')
    WHERE EXISTS (SELECT 1 FROM memory_event_scenes
                  WHERE event_id = OLD.event_id AND phase = OLD.phase
                    AND sample_ordinal = OLD.sample_ordinal)
      AND (NEW.event_id <> OLD.event_id OR NEW.observation_kind <> 'capture'
           OR NEW.phase <> OLD.phase OR NEW.sample_ordinal <> OLD.sample_ordinal);
END;

-- A capture row does not lose its complete status after a scene was confirmed on it. An
-- unconfirmed sample may still be corrected.
CREATE TRIGGER memory_event_observations_capture_status_guard BEFORE UPDATE OF status
ON memory_event_observations
WHEN OLD.observation_kind = 'capture'
BEGIN
    SELECT RAISE(ABORT, 'a confirmed sample keeps its complete status')
    WHERE NEW.status <> 'complete'
      AND EXISTS (SELECT 1 FROM memory_event_scenes
                  WHERE event_id = OLD.event_id AND phase = OLD.phase
                    AND sample_ordinal = OLD.sample_ordinal AND match_status = 'confirmed');
END;

-- S1: a capture row that any scene association references cannot be deleted; v5 let the
-- association survive without its sample. This is a refusal, not a cleanup: nothing is deleted
-- on the store's own initiative.
CREATE TRIGGER memory_event_observations_capture_delete_guard BEFORE DELETE ON memory_event_observations
WHEN OLD.observation_kind = 'capture'
BEGIN
    SELECT RAISE(ABORT, 'a referenced sample cannot be deleted')
    WHERE EXISTS (SELECT 1 FROM memory_event_scenes
                  WHERE event_id = OLD.event_id AND phase = OLD.phase
                    AND sample_ordinal = OLD.sample_ordinal);
END;

-- ---------------------------------------------------------------------------------------------
-- Triggers E (S2 3a): a brain application is sealed by its own row and kept as written.
-- ---------------------------------------------------------------------------------------------

-- The row is the seal: it needs the arguments written before it, a record or a naming names an
-- action event, and a recorded transition is the recorded anchor's.
CREATE TRIGGER brain_applications_insert_guard BEFORE INSERT ON brain_applications
BEGIN
    SELECT RAISE(ABORT, 'a brain application is written after its arguments, which it seals')
    WHERE NOT EXISTS (SELECT 1 FROM memory_operation_arguments WHERE brain_application_id = NEW.application_id);
    SELECT RAISE(ABORT, 'a record or a naming is applied for an action event')
    WHERE NEW.operation IN ('record', 'set_name')
      AND (SELECT event_kind FROM memory_events WHERE event_id = NEW.event_id) IS NOT 'action';
    SELECT RAISE(ABORT, 'a recorded transition belongs to the recorded anchor')
    WHERE NEW.transition_id IS NOT NULL
      AND (SELECT anchor_id FROM brain_transitions WHERE transition_id = NEW.transition_id) IS NOT NEW.anchor_id;
END;

CREATE TRIGGER brain_applications_immutable BEFORE UPDATE ON brain_applications
BEGIN
    SELECT RAISE(ABORT, 'a concluded brain application is immutable');
END;

CREATE TRIGGER brain_applications_kept BEFORE DELETE ON brain_applications
BEGIN
    SELECT RAISE(ABORT, 'a concluded brain application is kept: it is what makes a retry a retry');
END;

CREATE TRIGGER memory_operation_arguments_application_sealed BEFORE INSERT ON memory_operation_arguments
WHEN NEW.brain_application_id IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'a concluded brain application''s input is sealed')
    WHERE EXISTS (SELECT 1 FROM brain_applications WHERE application_id = NEW.brain_application_id);
END;

CREATE TRIGGER memory_operation_arguments_application_immutable BEFORE UPDATE ON memory_operation_arguments
WHEN OLD.brain_application_id IS NOT NULL OR NEW.brain_application_id IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'a brain application''s input is immutable');
END;

CREATE TRIGGER memory_operation_arguments_application_kept BEFORE DELETE ON memory_operation_arguments
WHEN OLD.brain_application_id IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'a brain application''s input is kept with it');
END;

-- =============================================================================================================
-- Part 2. Facts (G76, plan D1). The calls, samples, verifications and episodes of the base keep their tables; these
-- tables say what the base could not:
--   - the task an agent communicates, its revisions, attempts (the episodes of memory_task_occurrences),
--     checkpoints, outputs, and the revision each call began under;
--   - what a call really did beside what it asked, and the typed verification of each call, with its
--     condition, method version, limits, target and samples (its verdict row is memory_verifications);
--   - the values withheld from the record and why;
--   - the archives the memory was unified from, and the source of every fact it took from them.
-- =============================================================================================================

-- The schema versions the archive went through: the bootstrap of a new archive (from 0), or a
-- migration with the name of the verified copy taken before it.
CREATE TABLE memory_schema_migrations (
    to_version INTEGER PRIMARY KEY CHECK (to_version > 1),
    from_version INTEGER NOT NULL CHECK (from_version >= 0 AND from_version < to_version),
    migrated_at_ms INTEGER NOT NULL,
    copy_name TEXT,
    CHECK ((from_version = 0) = (copy_name IS NULL))
) STRICT;

-- ---------------------------------------------------------------------------------------------
-- Tasks (TaskContext, contract 1). A task belongs to the producer that opened it. Its status is the
-- agent's declaration, moving from open to one closed status once.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE memory_tasks (
    task_id TEXT PRIMARY KEY CHECK (length(task_id) > 0),
    contract_version INTEGER NOT NULL CHECK (contract_version > 0),
    source TEXT NOT NULL CHECK (source IN ('app', 'cli', 'mcp', 'watcher', 'system')),
    source_stream_id TEXT NOT NULL CHECK (length(source_stream_id) > 0),
    trace_id TEXT,
    opened_at_ms INTEGER NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('open', 'completed', 'failed', 'abandoned')),
    closed_at_ms INTEGER,
    current_revision INTEGER NOT NULL CHECK (current_revision >= 1),
    CHECK ((status = 'open') = (closed_at_ms IS NULL)),
    CHECK (closed_at_ms IS NULL OR closed_at_ms >= opened_at_ms)
) STRICT;

-- A revision states the whole task as resolved then; a correction is a new revision, never an edit.
CREATE TABLE memory_task_revisions (
    task_id TEXT NOT NULL REFERENCES memory_tasks(task_id),
    revision INTEGER NOT NULL CHECK (revision >= 1),
    recorded_at_ms INTEGER NOT NULL,
    change_kind TEXT NOT NULL CHECK (change_kind IN ('opened', 'revised')),
    reason TEXT,
    goal TEXT NOT NULL CHECK (length(goal) > 0),
    requested_result TEXT,
    PRIMARY KEY (task_id, revision),
    CHECK ((revision = 1) = (change_kind = 'opened'))
) STRICT;

CREATE TABLE memory_task_constraints (
    task_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    constraint_text TEXT NOT NULL CHECK (length(constraint_text) > 0),
    PRIMARY KEY (task_id, revision, position),
    FOREIGN KEY (task_id, revision) REFERENCES memory_task_revisions(task_id, revision)
) STRICT;

-- The messages a revision came from, as the frontend names them: never their text.
CREATE TABLE memory_task_message_refs (
    task_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    message_ref TEXT NOT NULL CHECK (length(message_ref) > 0),
    PRIMARY KEY (task_id, revision, position),
    UNIQUE (task_id, revision, message_ref),
    FOREIGN KEY (task_id, revision) REFERENCES memory_task_revisions(task_id, revision)
) STRICT;

-- An attempt is an episode of memory_task_occurrences: its status and end live there. A resumption
-- is a new attempt that names the one it resumes.
CREATE TABLE memory_task_attempts (
    task_occurrence_id TEXT PRIMARY KEY REFERENCES memory_task_occurrences(task_occurrence_id),
    task_id TEXT NOT NULL REFERENCES memory_tasks(task_id),
    ordinal INTEGER NOT NULL CHECK (ordinal >= 1),
    resumes_task_occurrence_id TEXT REFERENCES memory_task_attempts(task_occurrence_id),
    source TEXT NOT NULL CHECK (source IN ('app', 'cli', 'mcp', 'watcher', 'system')),
    source_stream_id TEXT NOT NULL CHECK (length(source_stream_id) > 0),
    opened_at_ms INTEGER NOT NULL,
    opened_at_revision INTEGER NOT NULL,
    UNIQUE (task_id, ordinal),
    UNIQUE (task_occurrence_id, task_id),
    CHECK ((ordinal = 1) = (resumes_task_occurrence_id IS NULL)),
    CHECK (resumes_task_occurrence_id IS NULL OR resumes_task_occurrence_id <> task_occurrence_id),
    FOREIGN KEY (task_id, opened_at_revision) REFERENCES memory_task_revisions(task_id, revision)
) STRICT;

-- What the agent declares along an attempt, and its end. At most one end per attempt.
CREATE TABLE memory_task_checkpoints (
    task_occurrence_id TEXT NOT NULL,
    sequence INTEGER NOT NULL CHECK (sequence >= 1),
    checkpoint_kind TEXT NOT NULL CHECK (checkpoint_kind IN ('checkpoint', 'end')),
    task_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    recorded_at_ms INTEGER NOT NULL,
    declared_status TEXT CHECK (declared_status IS NULL OR declared_status IN ('completed', 'failed', 'abandoned')),
    note TEXT,
    PRIMARY KEY (task_occurrence_id, sequence),
    CHECK ((checkpoint_kind = 'end') = (declared_status IS NOT NULL)),
    FOREIGN KEY (task_occurrence_id, task_id) REFERENCES memory_task_attempts(task_occurrence_id, task_id),
    FOREIGN KEY (task_id, revision) REFERENCES memory_task_revisions(task_id, revision)
) STRICT;

-- A task's named values: the inputs of a revision, or the outputs declared at a checkpoint. A secret
-- keeps its name, role and source, never its text (content 'withheld').
CREATE TABLE memory_task_values (
    value_id INTEGER PRIMARY KEY,
    task_id TEXT NOT NULL REFERENCES memory_tasks(task_id),
    revision INTEGER,
    task_occurrence_id TEXT,
    checkpoint_sequence INTEGER,
    position INTEGER NOT NULL CHECK (position >= 0),
    name TEXT NOT NULL CHECK (length(name) > 0),
    role TEXT,
    value_kind TEXT NOT NULL CHECK (value_kind IN ('text', 'number', 'boolean', 'file', 'folder', 'reference', 'missing')),
    content TEXT NOT NULL CHECK (content IN ('text', 'missing', 'withheld')),
    text_value TEXT,
    sensitivity TEXT NOT NULL CHECK (sensitivity IN ('ordinary', 'secret')),
    source TEXT NOT NULL CHECK (source IN ('request', 'message', 'observation', 'previous_output', 'derived', 'unknown')),
    source_ref TEXT,
    source_version TEXT,
    CHECK ((revision IS NOT NULL) <> (checkpoint_sequence IS NOT NULL)),
    CHECK ((checkpoint_sequence IS NULL) = (task_occurrence_id IS NULL)),
    CHECK ((content = 'text') = (text_value IS NOT NULL)),
    CHECK ((value_kind = 'missing') = (content = 'missing')),
    CHECK (sensitivity = 'ordinary' OR content <> 'text'),
    CHECK (source <> 'previous_output' OR source_ref IS NOT NULL),
    FOREIGN KEY (task_id, revision) REFERENCES memory_task_revisions(task_id, revision),
    FOREIGN KEY (task_occurrence_id, checkpoint_sequence) REFERENCES memory_task_checkpoints(task_occurrence_id, sequence)
) STRICT;

-- The revision current when each call of an attempt began; the call's place in the episode is its
-- membership in memory_task_events (role 'action', or 'context' for a batch).
CREATE TABLE memory_task_call_revisions (
    event_id TEXT PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    task_occurrence_id TEXT NOT NULL,
    task_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    FOREIGN KEY (task_occurrence_id, task_id) REFERENCES memory_task_attempts(task_occurrence_id, task_id),
    FOREIGN KEY (task_id, revision) REFERENCES memory_task_revisions(task_id, revision)
) STRICT;

-- ---------------------------------------------------------------------------------------------
-- Operation facts. What a call really did beside its request, and how each of its conditions was
-- checked. A verification's event is a 'verification' event; its verdict row is memory_verifications
-- (scope 'call'); here are what it judged, the method's version, its limits, target and samples.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE memory_call_effects (
    event_id TEXT PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    performed TEXT NOT NULL CHECK (performed IN ('requested', 'substitute', 'none', 'uncertain')),
    substitute TEXT,
    not_sent_reason TEXT,
    target_element_id TEXT,
    target_role TEXT,
    target_label TEXT,
    target_section TEXT,
    checked INTEGER NOT NULL CHECK (checked IN (0, 1)),
    CHECK ((performed = 'substitute') = (substitute IS NOT NULL)),
    CHECK (not_sent_reason IS NULL OR performed = 'none'),
    CHECK ((target_element_id IS NULL) = (target_label IS NULL)),
    CHECK (target_element_id IS NOT NULL OR (target_role IS NULL AND target_section IS NULL))
) STRICT;

-- M05 (schema 11): the route a routing session dispatched a call on, written with the call's end from what the
-- session did, never from what was asked: the MacDriver in the app ('native'), the seat ('desktop') or the browser
-- engine ('web'), and the MacDriver's reason when it gave the app back to the desktop during the call. A call of a
-- session that is not routed, or that reached none, has no row.
CREATE TABLE memory_call_routes (
    event_id TEXT PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    route TEXT NOT NULL CHECK (route IN ('native', 'desktop', 'web')),
    handoff_reason TEXT CHECK (handoff_reason IS NULL OR length(handoff_reason) > 0),
    CHECK (handoff_reason IS NULL OR route = 'desktop')
) STRICT;

CREATE TABLE memory_call_adapter_dispatches (
    event_id TEXT PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    adapter TEXT NOT NULL CHECK (length(adapter) > 0),
    verb TEXT NOT NULL CHECK (length(verb) > 0)
) STRICT;


-- The rung the last gesture of a call took (M05). On the MacDriver: the accessibility action it performed (rung 1)
-- or the events it posted to the process in place (rung 2), what it did in the driver's words, and why rung 1 was
-- passed over, each separated by char(31). On the Seat: the call that posted the last send's events, as its receipt
-- says (CGEventPostToPid, SLEventPostToPid, or an accessibility action with no event), with the send's counts in
-- `how` and nothing skipped. On the web: the DevTools Input commands the last gesture was sent as, with the method's
-- name, the commands planned, handed to the connection and acknowledged by the browser, and how the sequence ended,
-- in `how`; an acknowledgement is not an effect. The actuator's own note or receipt of that gesture, taken once for
-- the call that sent it, never inferred from the tool, the consent or the answer; a call that sent no gesture, a
-- foreground call, an adapter call, has no row. It names the last gesture noted, not the whole sequence.
CREATE TABLE memory_call_rungs (
    event_id TEXT PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    rung TEXT NOT NULL CHECK (rung IN ('accessibility', 'in_place', 'seat_public_process', 'seat_skylight_process',
                                       'seat_accessibility_action', 'web_input_event')),
    how TEXT NOT NULL CHECK (length(how) > 0),
    skipped TEXT CHECK (skipped IS NULL OR length(skipped) > 0)
) STRICT;

-- The router's decision an open_session answered with its words (M05): `use` with the address of the route it named
-- and its message, or `ask` with its question, instead of opening; or `open`, the decision to open as asked, with the
-- note given with it (why the interface is driven instead of an adapter, or the advice on a contact's channel). A
-- decision and its words, not a dispatch: `use` and `ask` opened nothing (no route row, no sample, no effect, no rung);
-- `open` is the decision, not the opening's success: the route row says where the call went and the call's own result
-- how it ended, and the note stays when the opening fails. Written once with the call's end, the address and the words
-- minimized as every text of the call is; an open with no note, and a call refused before the router, have no row.
CREATE TABLE memory_call_route_advice (
    event_id TEXT PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    decision TEXT NOT NULL CHECK (decision IN ('use', 'ask', 'open')),
    route TEXT CHECK (((decision = 'use') = (route IS NOT NULL)) AND (route IS NULL OR length(route) > 0)),
    message TEXT NOT NULL CHECK (length(message) > 0)
) STRICT;

CREATE TABLE memory_operation_verifications (
    event_id TEXT PRIMARY KEY REFERENCES memory_verifications(event_id),
    call_event_id TEXT NOT NULL REFERENCES memory_agent_actions(event_id),
    contract_version INTEGER NOT NULL CHECK (contract_version > 0),
    condition_kind TEXT NOT NULL CHECK (condition_kind IN ('requested_state_already_present', 'state_after_gesture',
        'value_read_back', 'structural_effect', 'menu_closed_after_choice', 'submenu_opened', 'window_set_changed',
        'recovery_instead_of_request', 'menu_item_chosen', 'none', 'adapter_effect', 'adapter_read')),
    method_version TEXT NOT NULL CHECK (length(method_version) > 0),
    performed TEXT NOT NULL CHECK (performed IN ('requested', 'substitute', 'none', 'uncertain')),
    substitute TEXT,
    target_element_id TEXT,
    target_role TEXT,
    target_label TEXT,
    target_section TEXT,
    UNIQUE (call_event_id, condition_kind),
    CHECK (event_id <> call_event_id),
    CHECK ((performed = 'substitute') = (substitute IS NOT NULL)),
    CHECK ((target_element_id IS NULL) = (target_label IS NULL)),
    CHECK (target_element_id IS NOT NULL OR (target_role IS NULL AND target_section IS NULL))
) STRICT;

CREATE TABLE memory_operation_verification_limits (
    event_id TEXT NOT NULL REFERENCES memory_operation_verifications(event_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    limit_kind TEXT NOT NULL CHECK (limit_kind IN ('delivery_uncertain', 'no_after_scene', 'readback_unavailable',
        'previous_value_unknown', 'no_expectation', 'window_wide', 'command_effect_unchecked', 'label_match_only',
        'no_expected_value', 'target_not_resolved', 'unattributed', 'value_withheld', 'settle_capped',
        'settle_unwatched')),
    PRIMARY KEY (event_id, position),
    UNIQUE (event_id, limit_kind)
) STRICT;

CREATE TABLE memory_operation_verification_samples (
    event_id TEXT NOT NULL REFERENCES memory_operation_verifications(event_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    sample_observation_id INTEGER NOT NULL,
    sample_event_id TEXT NOT NULL,
    sample_phase TEXT NOT NULL CHECK (sample_phase IN ('before', 'menu', 'after', 'current')),
    sample_ordinal INTEGER NOT NULL CHECK (sample_ordinal >= 0),
    sample_kind TEXT NOT NULL DEFAULT 'capture' CHECK (sample_kind = 'capture'),
    PRIMARY KEY (event_id, position),
    UNIQUE (event_id, sample_event_id, sample_phase, sample_ordinal),
    FOREIGN KEY (sample_observation_id, sample_event_id, sample_phase, sample_ordinal, sample_kind)
        REFERENCES memory_event_observations(observation_id, event_id, phase, sample_ordinal, observation_kind)
) STRICT;

-- A part of a call's end the archive refused as offered (the contract's refusal, or another fact under
-- the same identity), which the call was concluded without: its state and result are kept. A call with a
-- row here is incomplete evidence: no qualification rests on it, and its missing verification is neither
-- a pass nor an operation without an oracle. The detail is a diagnosis, never a value.
CREATE TABLE memory_call_recording_gaps (
    event_id TEXT NOT NULL REFERENCES memory_agent_actions(event_id),
    part TEXT NOT NULL CHECK (part IN ('samples', 'effect', 'verification')),
    reason TEXT NOT NULL CHECK (reason IN ('refused', 'conflict')),
    detail TEXT CHECK (detail IS NULL OR (length(detail) > 0 AND length(CAST(detail AS BLOB)) <= 512)),
    PRIMARY KEY (event_id, part)
) STRICT;

-- A value withheld from an event's facts: where it was and why. Never the value, its length or a digest. A secure
-- field's text (`secure_field`), a text typed where the call could not attest an ordinary target
-- (`unclassified_target`, version 9) and the content of a confidential surface, mail, messages, notes, contacts,
-- calendars or reminders (`confidential_content`, version 19), are gaps of their own reasons.
CREATE TABLE memory_value_redactions (
    redaction_id INTEGER PRIMARY KEY,
    event_id TEXT NOT NULL REFERENCES memory_events(event_id),
    location_kind TEXT NOT NULL CHECK (location_kind IN ('argument', 'result_message', 'verification_expected',
        'verification_observed', 'target_label', 'target_section', 'target_element', 'sample_label',
        'sample_container', 'sample_title', 'observed_effect', 'listing_entry')),
    argument_name TEXT,
    argument_position INTEGER CHECK (argument_position IS NULL OR argument_position >= 0),
    condition_kind TEXT,
    sample_phase TEXT CHECK (sample_phase IS NULL OR sample_phase IN ('before', 'menu', 'after', 'current')),
    sample_ordinal INTEGER CHECK (sample_ordinal IS NULL OR sample_ordinal >= 0),
    element_position INTEGER CHECK (element_position IS NULL OR element_position >= 0),
    reason TEXT NOT NULL CHECK (reason IN ('declared_secret', 'credential_pattern', 'secret_target', 'secure_field',
        'unclassified_target', 'confidential_content')),
    CHECK ((location_kind = 'argument') = (argument_name IS NOT NULL AND argument_position IS NOT NULL)),
    CHECK (location_kind = 'argument' OR (argument_name IS NULL AND argument_position IS NULL)),
    CHECK ((location_kind IN ('verification_expected', 'verification_observed')) = (condition_kind IS NOT NULL)),
    CHECK ((location_kind IN ('sample_label', 'sample_container', 'sample_title'))
        = (sample_phase IS NOT NULL AND sample_ordinal IS NOT NULL)),
    CHECK ((location_kind IN ('sample_label', 'sample_container', 'listing_entry')) = (element_position IS NOT NULL))
) STRICT;

-- ---------------------------------------------------------------------------------------------
-- Unification. The archives the memory took facts from (the MCP clients' private archives of schema
-- 1, `mcp_profile`, and the Knowledge of the product's earlier name, `previous_product`, adopted whole or
-- taken in), the state of each transfer, and the source of every event it took: added as it was, found
-- already present with the same content (a proven duplicate, which adds no evidence), or added under
-- a new identity because its own was taken by another fact. An origin some of whose knowledge could
-- not be taken in is `partial`, never `completed`; what it kept is named in its contributions.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE memory_archive_origins (
    origin_id TEXT PRIMARY KEY CHECK (length(origin_id) > 0),
    origin_kind TEXT NOT NULL CHECK (origin_kind IN ('mcp_profile', 'previous_product')),
    location TEXT NOT NULL CHECK (length(location) > 0),
    status TEXT NOT NULL CHECK (status IN ('in_progress', 'completed', 'partial', 'refused', 'failed')),
    first_seen_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    source_schema_version INTEGER,
    high_local_order INTEGER CHECK (high_local_order IS NULL OR high_local_order >= 0),
    events_added INTEGER NOT NULL DEFAULT 0 CHECK (events_added >= 0),
    events_duplicate INTEGER NOT NULL DEFAULT 0 CHECK (events_duplicate >= 0),
    events_renamed INTEGER NOT NULL DEFAULT 0 CHECK (events_renamed >= 0),
    applications_added INTEGER NOT NULL DEFAULT 0 CHECK (applications_added >= 0),
    applications_duplicate INTEGER NOT NULL DEFAULT 0 CHECK (applications_duplicate >= 0),
    brains_imported INTEGER NOT NULL DEFAULT 0 CHECK (brains_imported >= 0),
    detail TEXT
) STRICT;

CREATE TABLE memory_origin_events (
    origin_id TEXT NOT NULL REFERENCES memory_archive_origins(origin_id),
    source_event_id TEXT NOT NULL CHECK (length(source_event_id) > 0),
    event_id TEXT NOT NULL REFERENCES memory_events(event_id),
    disposition TEXT NOT NULL CHECK (disposition IN ('added', 'duplicate', 'renamed')),
    PRIMARY KEY (origin_id, source_event_id),
    UNIQUE (origin_id, event_id),
    CHECK ((disposition = 'renamed') = (event_id <> source_event_id))
) STRICT;

-- What an origin's JSON Brains gave each application's Brain here, element by element: an anchor, a
-- group or a transition added with its origin's counts (its history, never a new confirmation), one
-- already present under the same identity (a proven duplicate, whose counts are not added), or one
-- excluded because it could not be taken in as it was (its identity is another application's here,
-- its anchor is not in the Brain, its group lost members, its effect held a value the admission
-- withholds). `withheld` says the admission withheld a text of it. The excluded stay in the origin's file.
-- An `application` is one of an origin archive's Brain applications that was not learned again.
CREATE TABLE memory_origin_brain_contributions (
    origin_id TEXT NOT NULL REFERENCES memory_archive_origins(origin_id),
    bundle_id TEXT NOT NULL CHECK (length(bundle_id) > 0),
    element_kind TEXT NOT NULL CHECK (element_kind IN ('anchor', 'group', 'transition', 'application')),
    element_key TEXT NOT NULL CHECK (length(element_key) > 0),
    disposition TEXT NOT NULL CHECK (disposition IN ('added', 'present', 'excluded')),
    withheld INTEGER NOT NULL DEFAULT 0 CHECK (withheld IN (0, 1)),
    PRIMARY KEY (origin_id, bundle_id, element_kind, element_key)
) STRICT;

CREATE UNIQUE INDEX memory_task_inputs_by_position ON memory_task_values(task_id, revision, position)
    WHERE revision IS NOT NULL;
CREATE UNIQUE INDEX memory_task_inputs_by_name ON memory_task_values(task_id, revision, name)
    WHERE revision IS NOT NULL;
CREATE UNIQUE INDEX memory_task_outputs_by_position ON memory_task_values(task_occurrence_id, checkpoint_sequence, position)
    WHERE checkpoint_sequence IS NOT NULL;
CREATE UNIQUE INDEX memory_task_outputs_by_name ON memory_task_values(task_occurrence_id, checkpoint_sequence, name)
    WHERE checkpoint_sequence IS NOT NULL;
CREATE UNIQUE INDEX memory_task_checkpoints_one_end ON memory_task_checkpoints(task_occurrence_id)
    WHERE checkpoint_kind = 'end';
CREATE INDEX memory_tasks_by_producer ON memory_tasks(source, source_stream_id, status);
CREATE INDEX memory_task_call_revisions_by_attempt ON memory_task_call_revisions(task_occurrence_id);
CREATE INDEX memory_operation_verifications_by_call ON memory_operation_verifications(call_event_id);
CREATE UNIQUE INDEX memory_value_redactions_by_location ON memory_value_redactions(event_id, location_kind,
    ifnull(argument_name, ''), ifnull(argument_position, -1), ifnull(condition_kind, ''), ifnull(sample_phase, ''),
    ifnull(sample_ordinal, -1), ifnull(element_position, -1));
CREATE INDEX memory_origin_events_by_event ON memory_origin_events(event_id);

-- ---------------------------------------------------------------------------------------------
-- Triggers D (part 2): facts are never rewritten; a task's status moves once, its revision forward.
-- ---------------------------------------------------------------------------------------------

CREATE TRIGGER memory_tasks_identity_immutable BEFORE UPDATE OF
    task_id, contract_version, source, source_stream_id, trace_id, opened_at_ms
ON memory_tasks
BEGIN
    SELECT RAISE(ABORT, 'memory_tasks identity is immutable; only the status, its close and the revision move');
END;

CREATE TRIGGER memory_tasks_forward_only BEFORE UPDATE OF status, closed_at_ms, current_revision ON memory_tasks
BEGIN
    SELECT RAISE(ABORT, 'a closed task does not move')
    WHERE OLD.status <> 'open';
    SELECT RAISE(ABORT, 'a task''s current revision only moves forward, to a stored revision')
    WHERE NEW.current_revision < OLD.current_revision
       OR NOT EXISTS (SELECT 1 FROM memory_task_revisions WHERE task_id = NEW.task_id AND revision = NEW.current_revision);
END;

CREATE TRIGGER memory_tasks_kept BEFORE DELETE ON memory_tasks
BEGIN
    SELECT RAISE(ABORT, 'a task is kept');
END;

CREATE TRIGGER memory_task_revisions_immutable BEFORE UPDATE ON memory_task_revisions
BEGIN
    SELECT RAISE(ABORT, 'a task revision is immutable: a correction is a new revision');
END;

CREATE TRIGGER memory_task_revisions_in_order BEFORE INSERT ON memory_task_revisions
BEGIN
    SELECT RAISE(ABORT, 'a task revision follows the last one by one')
    WHERE NEW.revision <> 1 + ifnull((SELECT max(revision) FROM memory_task_revisions WHERE task_id = NEW.task_id), 0);
END;

CREATE TRIGGER memory_task_constraints_immutable BEFORE UPDATE ON memory_task_constraints
BEGIN
    SELECT RAISE(ABORT, 'a task revision''s constraints are immutable');
END;

CREATE TRIGGER memory_task_message_refs_immutable BEFORE UPDATE ON memory_task_message_refs
BEGIN
    SELECT RAISE(ABORT, 'a task revision''s message references are immutable');
END;

CREATE TRIGGER memory_task_values_immutable BEFORE UPDATE ON memory_task_values
BEGIN
    SELECT RAISE(ABORT, 'a task''s values are immutable');
END;

CREATE TRIGGER memory_task_attempts_immutable BEFORE UPDATE ON memory_task_attempts
BEGIN
    SELECT RAISE(ABORT, 'a task attempt is immutable; its status is its episode''s');
END;

CREATE TRIGGER memory_task_attempts_resume_same_task BEFORE INSERT ON memory_task_attempts
WHEN NEW.resumes_task_occurrence_id IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'an attempt resumes an earlier attempt of the same task')
    WHERE (SELECT task_id FROM memory_task_attempts WHERE task_occurrence_id = NEW.resumes_task_occurrence_id)
          IS NOT NEW.task_id;
END;

CREATE TRIGGER memory_task_checkpoints_immutable BEFORE UPDATE ON memory_task_checkpoints
BEGIN
    SELECT RAISE(ABORT, 'a checkpoint is immutable');
END;

CREATE TRIGGER memory_task_checkpoints_in_order BEFORE INSERT ON memory_task_checkpoints
BEGIN
    SELECT RAISE(ABORT, 'a checkpoint follows the attempt''s last one by one, and nothing follows an end')
    WHERE NEW.sequence <> 1 + ifnull((SELECT max(sequence) FROM memory_task_checkpoints
                                      WHERE task_occurrence_id = NEW.task_occurrence_id), 0)
       OR EXISTS (SELECT 1 FROM memory_task_checkpoints
                  WHERE task_occurrence_id = NEW.task_occurrence_id AND checkpoint_kind = 'end');
END;

CREATE TRIGGER memory_task_call_revisions_immutable BEFORE UPDATE ON memory_task_call_revisions
BEGIN
    SELECT RAISE(ABORT, 'a call''s task attribution is immutable');
END;

CREATE TRIGGER memory_call_effects_immutable BEFORE UPDATE ON memory_call_effects
BEGIN
    SELECT RAISE(ABORT, 'a call''s effect is immutable');
END;

CREATE TRIGGER memory_call_effects_concluded_call BEFORE INSERT ON memory_call_effects
BEGIN
    SELECT RAISE(ABORT, 'a call''s effect belongs to a concluded call')
    WHERE (SELECT execution_status FROM memory_agent_actions WHERE event_id = NEW.event_id)
          NOT IN ('completed', 'failed', 'cancelled', 'interrupted');
END;

-- M05 (schema 11): a call's route is written once, with its end, as its effect is.
CREATE TRIGGER memory_call_routes_immutable BEFORE UPDATE ON memory_call_routes
BEGIN
    SELECT RAISE(ABORT, 'a call''s route is immutable');
END;

CREATE TRIGGER memory_call_routes_concluded_call BEFORE INSERT ON memory_call_routes
BEGIN
    SELECT RAISE(ABORT, 'a call''s route belongs to a concluded call')
    WHERE (SELECT execution_status FROM memory_agent_actions WHERE event_id = NEW.event_id)
          NOT IN ('completed', 'failed', 'cancelled', 'interrupted');
END;

CREATE TRIGGER memory_call_adapter_dispatches_immutable BEFORE UPDATE ON memory_call_adapter_dispatches
BEGIN
    SELECT RAISE(ABORT, 'a call''s adapter dispatch is immutable');
END;

CREATE TRIGGER memory_call_adapter_dispatches_concluded_call BEFORE INSERT ON memory_call_adapter_dispatches
BEGIN
    SELECT RAISE(ABORT, 'a call''s adapter dispatch belongs to a concluded call')
    WHERE (SELECT execution_status FROM memory_agent_actions WHERE event_id = NEW.event_id)
          NOT IN ('completed', 'failed', 'cancelled', 'interrupted');
END;



CREATE TRIGGER memory_call_rungs_immutable BEFORE UPDATE ON memory_call_rungs
BEGIN
    SELECT RAISE(ABORT, 'a call''s rung is immutable');
END;

CREATE TRIGGER memory_call_rungs_concluded_call BEFORE INSERT ON memory_call_rungs
BEGIN
    SELECT RAISE(ABORT, 'a call''s rung belongs to a concluded call')
    WHERE (SELECT execution_status FROM memory_agent_actions WHERE event_id = NEW.event_id)
          NOT IN ('completed', 'failed', 'cancelled', 'interrupted');
END;

CREATE TRIGGER memory_call_route_advice_immutable BEFORE UPDATE ON memory_call_route_advice
BEGIN
    SELECT RAISE(ABORT, 'a call''s route advice is immutable');
END;

CREATE TRIGGER memory_call_route_advice_concluded_call BEFORE INSERT ON memory_call_route_advice
BEGIN
    SELECT RAISE(ABORT, 'a call''s route advice belongs to a concluded call')
    WHERE (SELECT execution_status FROM memory_agent_actions WHERE event_id = NEW.event_id)
          NOT IN ('completed', 'failed', 'cancelled', 'interrupted');
END;

CREATE TRIGGER memory_operation_verifications_immutable BEFORE UPDATE ON memory_operation_verifications
BEGIN
    SELECT RAISE(ABORT, 'an operation verification is immutable');
END;

CREATE TRIGGER memory_operation_verifications_call_scope BEFORE INSERT ON memory_operation_verifications
BEGIN
    SELECT RAISE(ABORT, 'an operation verification''s verdict row has scope call')
    WHERE (SELECT scope FROM memory_verifications WHERE event_id = NEW.event_id) IS NOT 'call';
END;

CREATE TRIGGER memory_operation_verification_limits_immutable BEFORE UPDATE ON memory_operation_verification_limits
BEGIN
    SELECT RAISE(ABORT, 'a verification''s limits are immutable');
END;

CREATE TRIGGER memory_operation_verification_samples_immutable BEFORE UPDATE ON memory_operation_verification_samples
BEGIN
    SELECT RAISE(ABORT, 'a verification''s samples are immutable');
END;

CREATE TRIGGER memory_value_redactions_immutable BEFORE UPDATE ON memory_value_redactions
BEGIN
    SELECT RAISE(ABORT, 'a declared gap is immutable');
END;

CREATE TRIGGER memory_value_redactions_kept BEFORE DELETE ON memory_value_redactions
BEGIN
    SELECT RAISE(ABORT, 'a declared gap is kept');
END;

CREATE TRIGGER memory_call_recording_gaps_immutable BEFORE UPDATE ON memory_call_recording_gaps
BEGIN
    SELECT RAISE(ABORT, 'a recording gap is immutable');
END;

CREATE TRIGGER memory_call_recording_gaps_kept BEFORE DELETE ON memory_call_recording_gaps
BEGIN
    SELECT RAISE(ABORT, 'a recording gap is kept');
END;

CREATE TRIGGER memory_call_recording_gaps_concluded_call BEFORE INSERT ON memory_call_recording_gaps
BEGIN
    SELECT RAISE(ABORT, 'a recording gap belongs to a concluded call')
    WHERE (SELECT execution_status FROM memory_agent_actions WHERE event_id = NEW.event_id)
          NOT IN ('completed', 'failed', 'cancelled', 'interrupted');
END;

CREATE TRIGGER memory_origin_events_immutable BEFORE UPDATE ON memory_origin_events
BEGIN
    SELECT RAISE(ABORT, 'the source of a transferred fact is immutable');
END;

CREATE TRIGGER memory_origin_brain_contributions_immutable BEFORE UPDATE ON memory_origin_brain_contributions
BEGIN
    SELECT RAISE(ABORT, 'what an origin contributed is immutable');
END;

CREATE TRIGGER memory_origin_brain_contributions_kept BEFORE DELETE ON memory_origin_brain_contributions
BEGIN
    SELECT RAISE(ABORT, 'what an origin contributed is kept');
END;

-- =============================================================================================================
-- Part 3. Procedures and Brain relations (G76, plan D2). What D2 builds from the facts D1 keeps has tables of its
-- own, and the indexes and triggers below that concern earlier tables add to them without changing them.
--   - Memory: the system's segmentation of an attempt (a candidate), the agent's interpretations of it,
--     the procedure versions they produce over the Route tables, their parts (procedure, subprocedure,
--     step) with contracts, parameters' roles, templated arguments and episodic bindings, the link of
--     each definition step to the one occurrence of its call, and the qualification and operational
--     state of every part.
--   - Brain: relations from a functional state (a structural scene) through an element, a precise verb
--     and its relevant arguments to an outcome and a destination, each supported or contradicted by
--     one verified call at most once, with the register of what each call taught or why it taught
--     nothing.
-- =============================================================================================================

-- ---------------------------------------------------------------------------------------------
-- Candidates. One per attempt and structure: the operations an attempt started, in their order, each
-- an occurrence of a step, grouped in blocks of consecutive operations on one application. Built by
-- the system from the facts, never by the agent; built again over the same facts it is the same row.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE memory_procedure_candidates (
    candidate_id TEXT PRIMARY KEY CHECK (length(candidate_id) > 0),
    task_id TEXT NOT NULL,
    task_occurrence_id TEXT NOT NULL,
    policy_version TEXT NOT NULL CHECK (length(policy_version) > 0),
    structure_digest TEXT NOT NULL CHECK (length(structure_digest) > 0),
    checkpoint_sequence INTEGER,
    built_at_ms INTEGER NOT NULL,
    step_count INTEGER NOT NULL CHECK (step_count >= 1),
    block_count INTEGER NOT NULL CHECK (block_count >= 1),
    UNIQUE (task_occurrence_id, policy_version, structure_digest),
    UNIQUE (candidate_id, task_occurrence_id),
    CHECK (block_count <= step_count),
    FOREIGN KEY (task_occurrence_id, task_id) REFERENCES memory_task_attempts(task_occurrence_id, task_id),
    FOREIGN KEY (task_occurrence_id, checkpoint_sequence) REFERENCES memory_task_checkpoints(task_occurrence_id, sequence)
) STRICT;

CREATE TABLE memory_candidate_steps (
    candidate_id TEXT NOT NULL REFERENCES memory_procedure_candidates(candidate_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    step_occurrence_id TEXT NOT NULL REFERENCES memory_step_occurrences(step_occurrence_id),
    call_event_id TEXT NOT NULL REFERENCES memory_agent_actions(event_id),
    block_index INTEGER NOT NULL CHECK (block_index >= 0),
    app_id INTEGER REFERENCES brain_apps(app_id),
    step_kind TEXT NOT NULL DEFAULT 'operation'
        CHECK (step_kind IN ('operation', 'adapter_call', 'required_read')),
    PRIMARY KEY (candidate_id, position),
    UNIQUE (candidate_id, call_event_id),
    UNIQUE (candidate_id, step_occurrence_id)
) STRICT;

-- ---------------------------------------------------------------------------------------------
-- Interpretations. What the agent stated about one candidate: labels, declared outcomes, parameters and
-- their uses, a revision at a time. The candidate's boundaries are not the agent's to change. A finding
-- is a use the system could not confirm against the call it names: it is kept, and the step stays an
-- unqualified part with the argument as recorded.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE memory_procedure_interpretations (
    interpretation_id TEXT PRIMARY KEY CHECK (length(interpretation_id) > 0),
    candidate_id TEXT NOT NULL REFERENCES memory_procedure_candidates(candidate_id),
    revision INTEGER NOT NULL CHECK (revision >= 1),
    contract_version INTEGER NOT NULL CHECK (contract_version > 0),
    payload_digest TEXT NOT NULL CHECK (length(payload_digest) > 0),
    source TEXT NOT NULL CHECK (source IN ('app', 'cli', 'mcp', 'watcher', 'system')),
    source_stream_id TEXT NOT NULL CHECK (length(source_stream_id) > 0),
    task_revision INTEGER NOT NULL CHECK (task_revision >= 1),
    attempt_state TEXT NOT NULL CHECK (attempt_state IN ('running', 'ended', 'interrupted')),
    recorded_at_ms INTEGER NOT NULL,
    UNIQUE (candidate_id, revision)
) STRICT;

CREATE TABLE memory_interpretation_findings (
    interpretation_id TEXT NOT NULL REFERENCES memory_procedure_interpretations(interpretation_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    finding TEXT NOT NULL CHECK (finding IN ('use_mismatch', 'unverifiable_use')),
    step_position INTEGER NOT NULL CHECK (step_position >= 0),
    argument_name TEXT NOT NULL CHECK (length(argument_name) > 0),
    argument_position INTEGER NOT NULL CHECK (argument_position >= 0),
    PRIMARY KEY (interpretation_id, position)
) STRICT;

-- ---------------------------------------------------------------------------------------------
-- Procedure versions. A Route of memory_routes whose steps are one UI operation each, built from one
-- interpretation of one candidate. A Route without a row here is a legacy definition: it keeps its own
-- meaning and is never qualified by these rules. A correction is a new version that supersedes the old
-- one (memory_routes.supersedes_route_id); a variant names the version it diverges from and where.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE memory_procedure_versions (
    route_id TEXT PRIMARY KEY REFERENCES memory_routes(route_id),
    interpretation_id TEXT NOT NULL UNIQUE REFERENCES memory_procedure_interpretations(interpretation_id),
    candidate_id TEXT NOT NULL,
    task_id TEXT NOT NULL,
    task_occurrence_id TEXT NOT NULL,
    contract_version INTEGER NOT NULL CHECK (contract_version > 0),
    variant_of_route_id TEXT REFERENCES memory_procedure_versions(route_id),
    divergence_position INTEGER CHECK (divergence_position IS NULL OR divergence_position >= 0),
    built_at_ms INTEGER NOT NULL,
    CHECK ((variant_of_route_id IS NULL) = (divergence_position IS NULL)),
    CHECK (variant_of_route_id IS NULL OR variant_of_route_id <> route_id),
    FOREIGN KEY (candidate_id, task_occurrence_id) REFERENCES memory_procedure_candidates(candidate_id, task_occurrence_id),
    FOREIGN KEY (task_occurrence_id, task_id) REFERENCES memory_task_attempts(task_occurrence_id, task_id)
) STRICT;

-- A part of a version: the procedure itself, a subprocedure (a block of consecutive operations on one
-- application) or a step (one operation), over an ordered interval of the version's steps. Containment
-- goes from a kind to a finer kind only, inside the parent's interval: it cannot close a cycle. The
-- interval of a step is its own position. A label is the agent's; a part without one is kept and never
-- qualified.
CREATE TABLE memory_procedure_parts (
    part_id TEXT PRIMARY KEY CHECK (length(part_id) > 0),
    route_id TEXT NOT NULL REFERENCES memory_procedure_versions(route_id),
    part_kind TEXT NOT NULL CHECK (part_kind IN ('procedure', 'subprocedure', 'step')),
    parent_part_id TEXT,
    first_position INTEGER NOT NULL CHECK (first_position >= 0),
    last_position INTEGER NOT NULL,
    step_id TEXT,
    app_id INTEGER REFERENCES brain_apps(app_id),
    label TEXT CHECK (label IS NULL OR length(label) > 0),
    declared_outcome TEXT NOT NULL CHECK (declared_outcome IN ('completed', 'failed', 'not_completed', 'not_declared')),
    UNIQUE (route_id, part_id),
    UNIQUE (route_id, part_kind, first_position, last_position),
    CHECK (last_position >= first_position),
    CHECK ((part_kind = 'procedure') = (parent_part_id IS NULL)),
    CHECK ((part_kind = 'step') = (step_id IS NOT NULL)),
    CHECK (part_kind <> 'step' OR first_position = last_position),
    CHECK (part_kind <> 'procedure' OR label IS NOT NULL),
    FOREIGN KEY (route_id, parent_part_id) REFERENCES memory_procedure_parts(route_id, part_id),
    FOREIGN KEY (route_id, step_id) REFERENCES memory_route_steps(route_id, step_id)
) STRICT;

-- What a part needs and gives: the parameters it reads (propagated from its steps' uses) and those it
-- produces, the application it runs in, and the functional state its first operation started from (a
-- structural scene, or NULL stated explicitly when the state is not known).
CREATE TABLE memory_part_contract_items (
    part_id TEXT NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    route_id TEXT NOT NULL,
    item_kind TEXT NOT NULL CHECK (item_kind IN ('input', 'output', 'application', 'entry_state')),
    parameter_id TEXT,
    app_id INTEGER REFERENCES brain_apps(app_id),
    scene_id TEXT,
    PRIMARY KEY (part_id, position),
    CHECK ((item_kind IN ('input', 'output')) = (parameter_id IS NOT NULL)),
    CHECK ((item_kind IN ('application', 'entry_state')) = (app_id IS NOT NULL)),
    CHECK (scene_id IS NULL OR item_kind = 'entry_state'),
    FOREIGN KEY (route_id, part_id) REFERENCES memory_procedure_parts(route_id, part_id),
    FOREIGN KEY (route_id, parameter_id) REFERENCES memory_route_parameters(route_id, parameter_id),
    FOREIGN KEY (app_id, scene_id) REFERENCES brain_scenes(app_id, scene_id)
) STRICT;

-- A parameter's role as the agent described it, its base kind, its unit or format when it has one,
-- whether it is a secret, and the part that produces it when it is an output. Never a value.
CREATE TABLE memory_parameter_details (
    parameter_id TEXT PRIMARY KEY,
    route_id TEXT NOT NULL,
    role TEXT NOT NULL CHECK (length(role) > 0),
    value_kind TEXT NOT NULL CHECK (value_kind IN ('text', 'number', 'boolean', 'file', 'folder', 'reference')),
    unit TEXT CHECK (unit IS NULL OR length(unit) > 0),
    sensitivity TEXT NOT NULL CHECK (sensitivity IN ('ordinary', 'secret')),
    produced_by_part_id TEXT,
    FOREIGN KEY (route_id, parameter_id) REFERENCES memory_route_parameters(route_id, parameter_id),
    FOREIGN KEY (route_id, produced_by_part_id) REFERENCES memory_procedure_parts(route_id, part_id)
) STRICT;

-- A templated text argument of a definition's operation: literal segments and parameters in order, so
-- `<name>.<extension>` keeps the name and the extension distinct and the literal dot fixed. An argument
-- is either a row of memory_operation_arguments or segments here, never both. `argument_index` is its
-- place among the operation's arguments.
CREATE TABLE memory_operation_argument_segments (
    route_id TEXT NOT NULL,
    operation_id TEXT NOT NULL,
    argument_name TEXT NOT NULL CHECK (length(argument_name) > 0),
    argument_position INTEGER NOT NULL CHECK (argument_position >= 0),
    argument_index INTEGER NOT NULL CHECK (argument_index >= 0),
    segment_position INTEGER NOT NULL CHECK (segment_position >= 0),
    segment_kind TEXT NOT NULL CHECK (segment_kind IN ('literal', 'parameter')),
    literal_text TEXT,
    parameter_id TEXT,
    PRIMARY KEY (operation_id, argument_name, argument_position, segment_position),
    CHECK ((segment_kind = 'literal') = (literal_text IS NOT NULL)),
    CHECK ((segment_kind = 'parameter') = (parameter_id IS NOT NULL)),
    CHECK (literal_text IS NULL OR length(literal_text) > 0),
    FOREIGN KEY (route_id, operation_id) REFERENCES memory_step_operations(route_id, operation_id),
    FOREIGN KEY (route_id, parameter_id) REFERENCES memory_route_parameters(route_id, parameter_id)
) STRICT;

-- The value a parameter had in one attempt and where it came from: an episodic fact beside the
-- definition, never a default of it. A secret keeps its source and never its text.
CREATE TABLE memory_parameter_bindings (
    parameter_id TEXT NOT NULL,
    route_id TEXT NOT NULL,
    task_occurrence_id TEXT NOT NULL REFERENCES memory_task_attempts(task_occurrence_id),
    content TEXT NOT NULL CHECK (content IN ('text', 'missing', 'withheld')),
    text_value TEXT,
    source TEXT NOT NULL CHECK (source IN ('request', 'message', 'observation', 'previous_output', 'derived', 'unknown')),
    source_ref TEXT,
    source_version TEXT,
    PRIMARY KEY (parameter_id, task_occurrence_id),
    CHECK ((content = 'text') = (text_value IS NOT NULL)),
    CHECK (source <> 'previous_output' OR source_ref IS NOT NULL),
    FOREIGN KEY (route_id, parameter_id) REFERENCES memory_route_parameters(route_id, parameter_id)
) STRICT;

-- The occurrence each definition step of a version stands for. The occurrence itself is one per call
-- (memory_step_occurrences, with the call and its verifications as memberships), whatever the number of
-- candidates and versions that include it.
CREATE TABLE memory_procedure_step_occurrences (
    route_id TEXT NOT NULL,
    step_id TEXT NOT NULL,
    step_occurrence_id TEXT NOT NULL REFERENCES memory_step_occurrences(step_occurrence_id),
    PRIMARY KEY (route_id, step_id),
    UNIQUE (route_id, step_occurrence_id),
    FOREIGN KEY (route_id, step_id) REFERENCES memory_route_steps(route_id, step_id)
) STRICT;

-- ---------------------------------------------------------------------------------------------
-- Qualification. A policy's verdict on one part, with its reasons and the verifications it rests on.
-- Evaluations are appended: the latest under a policy is current, an identical one is not repeated. A
-- policy put in quarantine stops what it admitted from being used, without deleting anything.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE memory_qualification_policies (
    policy_version TEXT PRIMARY KEY CHECK (length(policy_version) > 0),
    status TEXT NOT NULL CHECK (status IN ('active', 'quarantined')),
    changed_at_ms INTEGER NOT NULL,
    reason TEXT,
    CHECK ((status = 'quarantined') = (reason IS NOT NULL)),
    CHECK (reason IS NULL OR length(reason) > 0)
) STRICT;

CREATE TABLE memory_part_qualifications (
    part_id TEXT NOT NULL REFERENCES memory_procedure_parts(part_id),
    sequence INTEGER NOT NULL CHECK (sequence >= 1),
    policy_version TEXT NOT NULL REFERENCES memory_qualification_policies(policy_version),
    verdict TEXT NOT NULL CHECK (verdict IN ('admitted', 'refused')),
    evaluated_at_ms INTEGER NOT NULL,
    PRIMARY KEY (part_id, sequence)
) STRICT;

CREATE TABLE memory_part_qualification_reasons (
    part_id TEXT NOT NULL,
    sequence INTEGER NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    reason TEXT NOT NULL CHECK (reason IN ('missing_label', 'completion_not_declared', 'declared_failed',
        'declared_late', 'call_incomplete', 'call_failed', 'call_cancelled', 'call_interrupted', 'recording_gap',
        'no_verification', 'verification_failed', 'verification_unknown', 'verification_not_positive',
        'use_mismatch', 'unverifiable_use', 'missing_input', 'withheld_literal', 'adapter_unverified',
        'read_without_result', 'reference_unresolved')),
    step_position INTEGER CHECK (step_position IS NULL OR step_position >= 0),
    call_event_id TEXT REFERENCES memory_agent_actions(event_id),
    PRIMARY KEY (part_id, sequence, position),
    UNIQUE (part_id, sequence, reason, step_position),
    FOREIGN KEY (part_id, sequence) REFERENCES memory_part_qualifications(part_id, sequence)
) STRICT;

CREATE TABLE memory_part_qualification_evidence (
    part_id TEXT NOT NULL,
    sequence INTEGER NOT NULL,
    step_position INTEGER NOT NULL CHECK (step_position >= 0),
    call_event_id TEXT NOT NULL REFERENCES memory_agent_actions(event_id),
    verification_event_id TEXT NOT NULL REFERENCES memory_operation_verifications(event_id),
    origin TEXT NOT NULL DEFAULT 'own' CHECK (origin IN ('own', 'inherited')),
    PRIMARY KEY (part_id, sequence, call_event_id),
    FOREIGN KEY (part_id, sequence) REFERENCES memory_part_qualifications(part_id, sequence)
) STRICT;

-- A part's operational state, appended: usable, to be evaluated again, or retired for good, with why
-- and by whom. No row means the qualification alone decides.
CREATE TABLE memory_part_states (
    part_id TEXT NOT NULL REFERENCES memory_procedure_parts(part_id),
    sequence INTEGER NOT NULL CHECK (sequence >= 1),
    state TEXT NOT NULL CHECK (state IN ('usable', 'to_reevaluate', 'retired')),
    reason TEXT NOT NULL CHECK (length(reason) > 0),
    recorded_at_ms INTEGER NOT NULL,
    recorded_by TEXT NOT NULL CHECK (length(recorded_by) > 0),
    PRIMARY KEY (part_id, sequence)
) STRICT;

-- ---------------------------------------------------------------------------------------------
-- Brain relations. From a functional state (a structural scene, never the app scope), through an element
-- of it (its structural key, or none for a verb aimed at the window or the focus), a precise verb and the
-- arguments that change its meaning, to an outcome and a destination (NULL when not recognized), in one
-- application context. Values, document names and typed texts stay in the calls the proofs name.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE brain_relations (
    relation_id TEXT PRIMARY KEY CHECK (length(relation_id) > 0),
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    context_id INTEGER,
    from_scene_id TEXT NOT NULL,
    element_key TEXT CHECK (element_key IS NULL OR length(element_key) > 0),
    scene_element_id TEXT,
    verb TEXT NOT NULL CHECK (verb IN ('click', 'double_click', 'triple_click', 'right_click', 'set_toggle', 'select',
        'type_text', 'insert_text', 'press_key', 'scroll', 'drag', 'context_menu', 'menu', 'press')),
    arguments_key TEXT NOT NULL,
    to_scene_id TEXT,
    outcome TEXT NOT NULL CHECK (outcome IN ('effect', 'state_set', 'already_satisfied', 'value_set', 'item_chosen',
        'window_set_changed')),
    effect_kind TEXT CHECK (effect_kind IS NULL OR effect_kind IN ('windowTitleChanged', 'stateFlip', 'menuOpened',
        'elementsAppeared', 'elementsDisappeared', 'textSelectionChanged', 'valueChanged')),
    first_seen_ms INTEGER NOT NULL,
    last_seen_ms INTEGER NOT NULL,
    UNIQUE (app_id, relation_id),
    CHECK ((outcome = 'effect') = (effect_kind IS NOT NULL)),
    CHECK (outcome <> 'already_satisfied' OR to_scene_id IS from_scene_id),
    CHECK (scene_element_id IS NULL OR element_key IS NOT NULL),
    CHECK (last_seen_ms >= first_seen_ms),
    FOREIGN KEY (app_id, context_id) REFERENCES brain_app_contexts(app_id, context_id),
    FOREIGN KEY (app_id, from_scene_id) REFERENCES brain_scenes(app_id, scene_id),
    FOREIGN KEY (app_id, to_scene_id) REFERENCES brain_scenes(app_id, scene_id),
    FOREIGN KEY (app_id, from_scene_id, scene_element_id)
        REFERENCES brain_scene_elements(app_id, scene_id, scene_element_id)
) STRICT;

-- One verified call supports or contradicts one relation at most once: a retried write, a copy of the
-- same call or a rebuild adds nothing. The verification is the call's own.
CREATE TABLE brain_relation_proofs (
    relation_id TEXT NOT NULL REFERENCES brain_relations(relation_id),
    call_event_id TEXT NOT NULL REFERENCES memory_agent_actions(event_id),
    relation TEXT NOT NULL CHECK (relation IN ('supports', 'contradicts')),
    verification_event_id TEXT NOT NULL REFERENCES memory_operation_verifications(event_id),
    policy_version TEXT NOT NULL CHECK (length(policy_version) > 0),
    assessed_at_ms INTEGER NOT NULL,
    PRIMARY KEY (relation_id, call_event_id)
) STRICT;

-- What each operation taught the relations, once: a support, a contradiction, or nothing and why.
CREATE TABLE brain_relation_applications (
    call_event_id TEXT PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    app_id INTEGER REFERENCES brain_apps(app_id),
    policy_version TEXT NOT NULL CHECK (length(policy_version) > 0),
    outcome TEXT NOT NULL CHECK (outcome IN ('supported', 'contradicted', 'excluded')),
    reason TEXT CHECK (reason IS NULL OR reason IN ('not_an_operation', 'not_concluded', 'call_failed',
        'recording_gap', 'no_verification', 'verdict_unknown', 'no_oracle', 'substitute_gesture', 'delivery_uncertain',
        'value_withheld', 'no_before_state', 'no_structural_element', 'ambiguous_element', 'nothing_to_contradict',
        'not_learnable', 'no_application')),
    applied_at_ms INTEGER NOT NULL,
    CHECK ((outcome = 'excluded') = (reason IS NOT NULL))
) STRICT;

-- The shape of a structural scene the matcher's first test reads: its surface and its set of roles. A
-- complete capture is the same as, or uncertain against, only a scene of the same role set.
CREATE TABLE brain_scene_shapes (
    scene_id TEXT PRIMARY KEY,
    app_id INTEGER NOT NULL,
    role_key TEXT NOT NULL,
    FOREIGN KEY (app_id, scene_id) REFERENCES brain_scenes(app_id, scene_id)
) STRICT;

-- ---------------------------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------------------------

CREATE UNIQUE INDEX memory_procedure_parts_one_procedure ON memory_procedure_parts(route_id) WHERE part_kind = 'procedure';
CREATE INDEX memory_procedure_parts_by_parent ON memory_procedure_parts(parent_part_id);
CREATE INDEX memory_procedure_versions_by_attempt ON memory_procedure_versions(task_occurrence_id);
CREATE INDEX memory_procedure_candidates_by_attempt ON memory_procedure_candidates(task_occurrence_id, built_at_ms);
CREATE INDEX memory_candidate_steps_by_call ON memory_candidate_steps(call_event_id);
CREATE UNIQUE INDEX memory_part_contract_items_once ON memory_part_contract_items(part_id, item_kind, ifnull(parameter_id, ''));
CREATE INDEX memory_part_qualifications_by_verdict ON memory_part_qualifications(verdict, policy_version);
CREATE UNIQUE INDEX brain_relations_identity ON brain_relations(app_id, ifnull(context_id, -1), from_scene_id,
    ifnull(element_key, ''), verb, arguments_key, ifnull(to_scene_id, ''), outcome, ifnull(effect_kind, ''));
CREATE INDEX brain_relations_by_state ON brain_relations(app_id, from_scene_id, element_key, verb);
CREATE INDEX brain_relation_proofs_by_call ON brain_relation_proofs(call_event_id);
CREATE INDEX brain_scene_shapes_by_roles ON brain_scene_shapes(app_id, role_key);

-- ---------------------------------------------------------------------------------------------
-- Triggers E (part 3)
-- ---------------------------------------------------------------------------------------------

CREATE TRIGGER memory_procedure_candidates_immutable BEFORE UPDATE ON memory_procedure_candidates
BEGIN
    SELECT RAISE(ABORT, 'a candidate is immutable: other facts make another candidate');
END;

CREATE TRIGGER memory_procedure_candidates_kept BEFORE DELETE ON memory_procedure_candidates
BEGIN
    SELECT RAISE(ABORT, 'a candidate is kept');
END;

CREATE TRIGGER memory_candidate_steps_immutable BEFORE UPDATE ON memory_candidate_steps
BEGIN
    SELECT RAISE(ABORT, 'a candidate step is immutable');
END;

CREATE TRIGGER memory_candidate_steps_kept BEFORE DELETE ON memory_candidate_steps
BEGIN
    SELECT RAISE(ABORT, 'a candidate step is kept');
END;

-- One step per started UI operation of the candidate's attempt, the occurrence naming that call; a
-- batch, a context tool and a step that never started are no step. Blocks follow the order.
CREATE TRIGGER memory_candidate_steps_operation BEFORE INSERT ON memory_candidate_steps
BEGIN
    SELECT RAISE(ABORT, 'a candidate step is a started UI operation or adapter call of its kind')
    WHERE NOT ((NEW.step_kind = 'operation' AND (SELECT tool_kind FROM memory_agent_actions WHERE event_id = NEW.call_event_id)
                  IN ('act', 'select', 'type_text', 'insert_text', 'press_key', 'scroll', 'drag', 'context_menu', 'menu', 'press'))
            OR (NEW.step_kind IN ('adapter_call', 'required_read')
                AND (SELECT tool_kind FROM memory_agent_actions WHERE event_id = NEW.call_event_id) IN ('app_call'))
)
       OR (SELECT execution_status FROM memory_agent_actions WHERE event_id = NEW.call_event_id) IN ('planned', 'skipped');
    SELECT RAISE(ABORT, 'a candidate step belongs to the candidate''s attempt')
    WHERE NOT EXISTS (SELECT 1 FROM memory_task_events e JOIN memory_procedure_candidates c
                          ON c.task_occurrence_id = e.task_occurrence_id
                      WHERE c.candidate_id = NEW.candidate_id AND e.event_id = NEW.call_event_id AND e.role = 'action');
    SELECT RAISE(ABORT, 'a candidate step''s occurrence is its call''s')
    WHERE NOT EXISTS (SELECT 1 FROM memory_step_events
                      WHERE step_occurrence_id = NEW.step_occurrence_id AND event_id = NEW.call_event_id AND role = 'action');
    SELECT RAISE(ABORT, 'a candidate step follows the last one by one')
    WHERE NEW.position <> 1 + ifnull((SELECT max(position) FROM memory_candidate_steps WHERE candidate_id = NEW.candidate_id), -1);
    SELECT RAISE(ABORT, 'a block is a run of consecutive operations on one application')
    WHERE (NEW.position = 0 AND NEW.block_index <> 0)
       OR EXISTS (SELECT 1 FROM memory_candidate_steps p
                  WHERE p.candidate_id = NEW.candidate_id AND p.position = NEW.position - 1
                    AND NOT ((p.block_index = NEW.block_index AND p.app_id IS NEW.app_id)
                          OR (p.block_index + 1 = NEW.block_index AND p.app_id IS NOT NEW.app_id)));
    SELECT RAISE(ABORT, 'a candidate step''s application is its call''s')
    WHERE (SELECT app_id FROM memory_agent_actions WHERE event_id = NEW.call_event_id) IS NOT NEW.app_id;
END;

CREATE TRIGGER memory_procedure_interpretations_immutable BEFORE UPDATE ON memory_procedure_interpretations
BEGIN
    SELECT RAISE(ABORT, 'an interpretation is immutable: a change is a new revision');
END;

CREATE TRIGGER memory_procedure_interpretations_kept BEFORE DELETE ON memory_procedure_interpretations
BEGIN
    SELECT RAISE(ABORT, 'an interpretation is kept');
END;

CREATE TRIGGER memory_procedure_interpretations_in_order BEFORE INSERT ON memory_procedure_interpretations
BEGIN
    SELECT RAISE(ABORT, 'an interpretation follows the candidate''s last one by one')
    WHERE NEW.revision <> 1 + ifnull((SELECT max(revision) FROM memory_procedure_interpretations
                                      WHERE candidate_id = NEW.candidate_id), 0);
END;

CREATE TRIGGER memory_interpretation_findings_immutable BEFORE UPDATE ON memory_interpretation_findings
BEGIN
    SELECT RAISE(ABORT, 'a finding is immutable');
END;

CREATE TRIGGER memory_interpretation_findings_kept BEFORE DELETE ON memory_interpretation_findings
BEGIN
    SELECT RAISE(ABORT, 'a finding is kept');
END;

CREATE TRIGGER memory_procedure_versions_immutable BEFORE UPDATE ON memory_procedure_versions
BEGIN
    SELECT RAISE(ABORT, 'a procedure version is immutable');
END;

CREATE TRIGGER memory_procedure_versions_kept BEFORE DELETE ON memory_procedure_versions
BEGIN
    SELECT RAISE(ABORT, 'a procedure version is kept');
END;

CREATE TRIGGER memory_procedure_versions_insert_guard BEFORE INSERT ON memory_procedure_versions
BEGIN
    SELECT RAISE(ABORT, 'a version is built from an interpretation of its own candidate')
    WHERE (SELECT candidate_id FROM memory_procedure_interpretations WHERE interpretation_id = NEW.interpretation_id)
          IS NOT NEW.candidate_id;
    SELECT RAISE(ABORT, 'a variant diverges within the version it names')
    WHERE NEW.variant_of_route_id IS NOT NULL
      AND NEW.divergence_position > (SELECT count(*) FROM memory_route_steps WHERE route_id = NEW.variant_of_route_id);
END;

CREATE TRIGGER memory_procedure_parts_immutable BEFORE UPDATE ON memory_procedure_parts
BEGIN
    SELECT RAISE(ABORT, 'a part is immutable: a correction is a new version');
END;

CREATE TRIGGER memory_procedure_parts_kept BEFORE DELETE ON memory_procedure_parts
BEGIN
    SELECT RAISE(ABORT, 'a part is kept');
END;

-- Containment only from a coarser kind to a finer one and inside the parent's interval: a cycle cannot
-- be written. A step part names the step at its position.
CREATE TRIGGER memory_procedure_parts_containment BEFORE INSERT ON memory_procedure_parts
WHEN NEW.parent_part_id IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'a part is contained by a coarser part of its version, inside its interval')
    WHERE NOT EXISTS (
        SELECT 1 FROM memory_procedure_parts p
        WHERE p.part_id = NEW.parent_part_id AND p.route_id = NEW.route_id
          AND p.first_position <= NEW.first_position AND NEW.last_position <= p.last_position
          AND ((p.part_kind = 'procedure' AND NEW.part_kind IN ('subprocedure', 'step'))
            OR (p.part_kind = 'subprocedure' AND NEW.part_kind = 'step'))
    );
END;

CREATE TRIGGER memory_procedure_parts_step_position BEFORE INSERT ON memory_procedure_parts
WHEN NEW.part_kind = 'step'
BEGIN
    SELECT RAISE(ABORT, 'a step part names the step at its position')
    WHERE (SELECT position FROM memory_route_steps WHERE step_id = NEW.step_id) IS NOT NEW.first_position;
END;

CREATE TRIGGER memory_part_contract_items_immutable BEFORE UPDATE ON memory_part_contract_items
BEGIN
    SELECT RAISE(ABORT, 'a part''s contract is immutable');
END;

CREATE TRIGGER memory_parameter_details_immutable BEFORE UPDATE ON memory_parameter_details
BEGIN
    SELECT RAISE(ABORT, 'a parameter''s details are immutable');
END;

CREATE TRIGGER memory_operation_argument_segments_immutable BEFORE UPDATE ON memory_operation_argument_segments
BEGIN
    SELECT RAISE(ABORT, 'a templated argument is immutable');
END;

-- An argument is a row or a template, never both.
CREATE TRIGGER memory_operation_argument_segments_alone BEFORE INSERT ON memory_operation_argument_segments
BEGIN
    SELECT RAISE(ABORT, 'an argument is a row or a template, never both')
    WHERE EXISTS (SELECT 1 FROM memory_operation_arguments
                  WHERE operation_id = NEW.operation_id AND argument_name = NEW.argument_name
                    AND position = NEW.argument_position);
END;

CREATE TRIGGER memory_operation_arguments_not_templated BEFORE INSERT ON memory_operation_arguments
WHEN NEW.operation_id IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'an argument is a row or a template, never both')
    WHERE EXISTS (SELECT 1 FROM memory_operation_argument_segments
                  WHERE operation_id = NEW.operation_id AND argument_name = NEW.argument_name
                    AND argument_position = NEW.position);
END;

CREATE TRIGGER memory_parameter_bindings_immutable BEFORE UPDATE ON memory_parameter_bindings
BEGIN
    SELECT RAISE(ABORT, 'a binding is an episodic fact and is immutable');
END;

CREATE TRIGGER memory_parameter_bindings_secret BEFORE INSERT ON memory_parameter_bindings
BEGIN
    SELECT RAISE(ABORT, 'a secret parameter keeps no text')
    WHERE NEW.content = 'text'
      AND (SELECT sensitivity FROM memory_parameter_details WHERE parameter_id = NEW.parameter_id) IS 'secret';
END;

CREATE TRIGGER memory_procedure_step_occurrences_immutable BEFORE UPDATE ON memory_procedure_step_occurrences
BEGIN
    SELECT RAISE(ABORT, 'a definition step''s occurrence is immutable');
END;

CREATE TRIGGER memory_part_qualifications_immutable BEFORE UPDATE ON memory_part_qualifications
BEGIN
    SELECT RAISE(ABORT, 'a qualification is immutable: an evaluation is appended');
END;

CREATE TRIGGER memory_part_qualifications_kept BEFORE DELETE ON memory_part_qualifications
BEGIN
    SELECT RAISE(ABORT, 'a qualification is kept');
END;

CREATE TRIGGER memory_part_qualifications_in_order BEFORE INSERT ON memory_part_qualifications
BEGIN
    SELECT RAISE(ABORT, 'an evaluation follows the part''s last one by one')
    WHERE NEW.sequence <> 1 + ifnull((SELECT max(sequence) FROM memory_part_qualifications WHERE part_id = NEW.part_id), 0);
END;

CREATE TRIGGER memory_part_qualification_reasons_immutable BEFORE UPDATE ON memory_part_qualification_reasons
BEGIN
    SELECT RAISE(ABORT, 'a qualification''s reasons are immutable');
END;

CREATE TRIGGER memory_part_qualification_reasons_refused_only BEFORE INSERT ON memory_part_qualification_reasons
BEGIN
    SELECT RAISE(ABORT, 'an admitted part has no reason against it')
    WHERE (SELECT verdict FROM memory_part_qualifications
           WHERE part_id = NEW.part_id AND sequence = NEW.sequence) IS 'admitted';
END;

CREATE TRIGGER memory_part_qualification_evidence_immutable BEFORE UPDATE ON memory_part_qualification_evidence
BEGIN
    SELECT RAISE(ABORT, 'a qualification''s evidence is immutable');
END;

CREATE TRIGGER memory_part_qualification_evidence_own_call BEFORE INSERT ON memory_part_qualification_evidence
BEGIN
    SELECT RAISE(ABORT, 'a qualification rests on the verification of the call it names')
    WHERE (SELECT call_event_id FROM memory_operation_verifications WHERE event_id = NEW.verification_event_id)
          IS NOT NEW.call_event_id;
END;

CREATE TRIGGER memory_part_states_immutable BEFORE UPDATE ON memory_part_states
BEGIN
    SELECT RAISE(ABORT, 'a part''s state is appended, never changed');
END;

CREATE TRIGGER memory_part_states_kept BEFORE DELETE ON memory_part_states
BEGIN
    SELECT RAISE(ABORT, 'a part''s state history is kept');
END;

CREATE TRIGGER memory_part_states_in_order BEFORE INSERT ON memory_part_states
BEGIN
    SELECT RAISE(ABORT, 'a state follows the part''s last one by one, and nothing follows retirement')
    WHERE NEW.sequence <> 1 + ifnull((SELECT max(sequence) FROM memory_part_states WHERE part_id = NEW.part_id), 0)
       OR (SELECT state FROM memory_part_states WHERE part_id = NEW.part_id
           ORDER BY sequence DESC LIMIT 1) IS 'retired';
END;

CREATE TRIGGER memory_qualification_policies_forward BEFORE UPDATE ON memory_qualification_policies
BEGIN
    SELECT RAISE(ABORT, 'a policy''s version is its identity')
    WHERE NEW.policy_version IS NOT OLD.policy_version;
    SELECT RAISE(ABORT, 'a policy''s change never goes back in time')
    WHERE NEW.changed_at_ms < OLD.changed_at_ms;
END;

CREATE TRIGGER memory_qualification_policies_kept BEFORE DELETE ON memory_qualification_policies
BEGIN
    SELECT RAISE(ABORT, 'a policy is kept');
END;

CREATE TRIGGER brain_relations_identity_immutable BEFORE UPDATE OF
    relation_id, app_id, context_id, from_scene_id, element_key, scene_element_id, verb, arguments_key, to_scene_id,
    outcome, effect_kind, first_seen_ms
ON brain_relations
BEGIN
    SELECT RAISE(ABORT, 'a relation''s identity is immutable; only its last sighting moves');
END;

CREATE TRIGGER brain_relations_kept BEFORE DELETE ON brain_relations
BEGIN
    SELECT RAISE(ABORT, 'a relation is kept');
END;

CREATE TRIGGER brain_relations_not_app_scope BEFORE INSERT ON brain_relations
BEGIN
    SELECT RAISE(ABORT, 'a relation goes from and to functional states, never the app scope')
    WHERE (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.from_scene_id) IS 'app'
       OR (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.to_scene_id) IS 'app';
END;

CREATE TRIGGER brain_relation_proofs_immutable BEFORE UPDATE ON brain_relation_proofs
BEGIN
    SELECT RAISE(ABORT, 'a proof is immutable');
END;

CREATE TRIGGER brain_relation_proofs_kept BEFORE DELETE ON brain_relation_proofs
BEGIN
    SELECT RAISE(ABORT, 'a proof is kept');
END;

CREATE TRIGGER brain_relation_proofs_own_call BEFORE INSERT ON brain_relation_proofs
BEGIN
    SELECT RAISE(ABORT, 'a proof is the verification of the call it names, of the relation''s application')
    WHERE (SELECT call_event_id FROM memory_operation_verifications WHERE event_id = NEW.verification_event_id)
          IS NOT NEW.call_event_id
       OR (SELECT app_id FROM memory_agent_actions WHERE event_id = NEW.call_event_id)
          IS NOT (SELECT app_id FROM brain_relations WHERE relation_id = NEW.relation_id);
END;

CREATE TRIGGER brain_relation_applications_immutable BEFORE UPDATE ON brain_relation_applications
BEGIN
    SELECT RAISE(ABORT, 'what a call taught is immutable');
END;

CREATE TRIGGER brain_relation_applications_kept BEFORE DELETE ON brain_relation_applications
BEGIN
    SELECT RAISE(ABORT, 'what a call taught is kept');
END;

CREATE TRIGGER brain_scene_shapes_immutable BEFORE UPDATE ON brain_scene_shapes
BEGIN
    SELECT RAISE(ABORT, 'a scene''s shape is immutable');
END;

CREATE TRIGGER brain_scene_shapes_not_app_scope BEFORE INSERT ON brain_scene_shapes
BEGIN
    SELECT RAISE(ABORT, 'the app scope has no shape')
    WHERE (SELECT scene_kind FROM brain_scenes WHERE scene_id = NEW.scene_id) IS 'app';
END;

-- =============================================================================================================
-- Part 4. Evaluations, label keys and variant prefixes (G76, plan D2 after its independent review). Part 3's register
-- of what each call taught under brain-relations-1 (brain_relation_applications, brain_relation_proofs) is written no
-- more: no build writes it, and it stays empty in every archive this schema opens.
--   - Brain: what each call taught is now an append-only history of evaluations, one per call and decision. An
--     exclusion waiting for evidence that has not arrived yet (a sample not yet placed in a state, a call not
--     concluded yet, a failure with nothing yet to contradict) is recoverable and is evaluated again when the
--     evidence arrives; a new policy evaluates every call again. A relation's support and contradictions are
--     the evidence of each call's latest evaluation only, so a call counts once however often it is
--     evaluated.
--   - Brain projection: the normalized labels and aliases of the anchors, derived, so a scene's labels find
--     their anchors without reading an application's whole projection.
--   - Memory: whether the common prefix a variant declared was verified on the operations, or is kept as
--     suggested only.
-- =============================================================================================================

-- ---------------------------------------------------------------------------------------------
-- Relation evaluations. Each evaluation is what one call teaches under one policy at one moment: a
-- support, contradictions, or an exclusion and why, recoverable when the evidence it lacks may still
-- arrive. The cause says why it was made: the call's own acquisition, a recovery of one a stopped
-- process never wrote, newly arrived evidence, or a new policy. A later evaluation never erases an
-- earlier one.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE brain_relation_evaluations (
    call_event_id TEXT NOT NULL REFERENCES memory_agent_actions(event_id),
    sequence INTEGER NOT NULL CHECK (sequence >= 1),
    app_id INTEGER REFERENCES brain_apps(app_id),
    policy_version TEXT NOT NULL CHECK (length(policy_version) > 0),
    cause TEXT NOT NULL CHECK (cause IN ('acquisition', 'recovery', 'evidence', 'policy')),
    outcome TEXT NOT NULL CHECK (outcome IN ('supported', 'contradicted', 'excluded')),
    reason TEXT CHECK (reason IS NULL OR reason IN ('not_an_operation', 'not_concluded', 'call_failed',
        'recording_gap', 'no_verification', 'verdict_unknown', 'no_oracle', 'substitute_gesture', 'delivery_uncertain',
        'value_withheld', 'no_before_state', 'awaiting_state', 'no_structural_element', 'ambiguous_element',
        'indistinct_element', 'nothing_to_contradict', 'not_learnable', 'no_application')),
    recoverable INTEGER NOT NULL CHECK (recoverable IN (0, 1)),
    group_key TEXT CHECK (group_key IS NULL OR length(group_key) > 0),
    expected_effect_kind TEXT CHECK (expected_effect_kind IS NULL OR expected_effect_kind IN ('windowTitleChanged',
        'stateFlip', 'menuOpened', 'elementsAppeared', 'elementsDisappeared', 'textSelectionChanged', 'valueChanged')),
    evaluated_at_ms INTEGER NOT NULL,
    PRIMARY KEY (call_event_id, sequence),
    CHECK ((outcome = 'excluded') = (reason IS NOT NULL)),
    CHECK (recoverable = 0 OR outcome = 'excluded'),
    CHECK ((group_key IS NOT NULL) = (reason IS 'nothing_to_contradict')),
    CHECK (expected_effect_kind IS NULL OR group_key IS NOT NULL)
) STRICT;

-- One call's evidence for one relation under one evaluation of it. Only the call's latest evaluation counts.
CREATE TABLE brain_relation_evidence (
    relation_id TEXT NOT NULL REFERENCES brain_relations(relation_id),
    call_event_id TEXT NOT NULL,
    sequence INTEGER NOT NULL,
    relation TEXT NOT NULL CHECK (relation IN ('supports', 'contradicts')),
    verification_event_id TEXT NOT NULL REFERENCES memory_operation_verifications(event_id),
    policy_version TEXT NOT NULL CHECK (length(policy_version) > 0),
    assessed_at_ms INTEGER NOT NULL,
    PRIMARY KEY (relation_id, call_event_id, sequence),
    FOREIGN KEY (call_event_id, sequence) REFERENCES brain_relation_evaluations(call_event_id, sequence)
) STRICT;

-- ---------------------------------------------------------------------------------------------
-- Anchor label keys. Derived from brain_anchors.label and brain_anchor_aliases, normalized as labels are
-- compared (lowercase alphanumerics), written with the anchors they derive from, so the enrichment of a
-- scene reads only the anchors its labels, kinds and groups can match.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE brain_anchor_label_keys (
    anchor_id TEXT NOT NULL REFERENCES brain_anchors(anchor_id),
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    label_key TEXT NOT NULL CHECK (length(label_key) > 0),
    PRIMARY KEY (anchor_id, label_key)
) STRICT;

-- ---------------------------------------------------------------------------------------------
-- Variant prefixes. A variant names the version it varies and the first step that differs: verified when
-- every step before it is the same operation on the generalized definitions (application, tool, the same
-- literal or the same parameter shape in every argument), suggested when that could not be shown
-- (a withheld literal, a step that could not be read, or a variant declared before this schema).
-- A prefix the operations contradict is refused and has no row.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE memory_variant_prefixes (
    route_id TEXT PRIMARY KEY REFERENCES memory_procedure_versions(route_id),
    status TEXT NOT NULL CHECK (status IN ('verified', 'suggested')),
    compared_steps INTEGER NOT NULL CHECK (compared_steps >= 0),
    reason TEXT CHECK (reason IS NULL OR reason IN ('withheld_literal', 'unreadable_step', 'declared_before_verification')),
    checked_at_ms INTEGER NOT NULL,
    CHECK ((status = 'verified') = (reason IS NULL))
) STRICT;

-- ---------------------------------------------------------------------------------------------
-- Indexes.
-- ---------------------------------------------------------------------------------------------

CREATE INDEX brain_relation_evaluations_by_group ON brain_relation_evaluations(group_key) WHERE group_key IS NOT NULL;
CREATE INDEX brain_relation_evaluations_recoverable ON brain_relation_evaluations(call_event_id) WHERE recoverable = 1;
CREATE INDEX brain_relation_evaluations_by_policy ON brain_relation_evaluations(policy_version);
CREATE INDEX brain_relation_evidence_by_call ON brain_relation_evidence(call_event_id, sequence);
CREATE INDEX brain_anchor_label_keys_by_label ON brain_anchor_label_keys(app_id, label_key);
-- The anchors a model named, read by every scene of their kinds (their positional pull) without a scan
-- of the application's anchors.
CREATE INDEX brain_anchors_named_by_model ON brain_anchors(app_id, kind) WHERE retired_at_ms IS NULL AND label_source = 'llm';
-- The unlabeled anchors, the only group members a labeled detection can take by its slot, and the groups
-- an anchor belongs to: the ordinal rescue reads the groups near a scene without a scan of their members.
CREATE INDEX brain_anchors_unlabeled ON brain_anchors(app_id, kind) WHERE retired_at_ms IS NULL AND label = '';
CREATE INDEX brain_group_members_by_anchor ON brain_group_members(anchor_id);

-- ---------------------------------------------------------------------------------------------
-- Triggers.
-- ---------------------------------------------------------------------------------------------

CREATE TRIGGER brain_relation_evaluations_immutable BEFORE UPDATE ON brain_relation_evaluations
BEGIN
    SELECT RAISE(ABORT, 'an evaluation is immutable');
END;

CREATE TRIGGER brain_relation_evaluations_kept BEFORE DELETE ON brain_relation_evaluations
BEGIN
    SELECT RAISE(ABORT, 'an evaluation is kept');
END;

CREATE TRIGGER brain_relation_evaluations_in_order BEFORE INSERT ON brain_relation_evaluations
BEGIN
    SELECT RAISE(ABORT, 'an evaluation follows the call''s last one by one')
    WHERE NEW.sequence <> 1 + ifnull((SELECT max(sequence) FROM brain_relation_evaluations
                                      WHERE call_event_id = NEW.call_event_id), 0);
    SELECT RAISE(ABORT, 'an evaluation names the application of the call it evaluates')
    WHERE NEW.app_id IS NOT NULL
      AND NEW.app_id IS NOT (SELECT app_id FROM memory_agent_actions WHERE event_id = NEW.call_event_id);
END;

CREATE TRIGGER brain_relation_evidence_immutable BEFORE UPDATE ON brain_relation_evidence
BEGIN
    SELECT RAISE(ABORT, 'evidence is immutable');
END;

CREATE TRIGGER brain_relation_evidence_kept BEFORE DELETE ON brain_relation_evidence
BEGIN
    SELECT RAISE(ABORT, 'evidence is kept');
END;

CREATE TRIGGER brain_relation_evidence_own_call BEFORE INSERT ON brain_relation_evidence
BEGIN
    SELECT RAISE(ABORT, 'evidence is the verification of the call it names, of the relation''s application')
    WHERE (SELECT call_event_id FROM memory_operation_verifications WHERE event_id = NEW.verification_event_id)
          IS NOT NEW.call_event_id
       OR (SELECT app_id FROM memory_agent_actions WHERE event_id = NEW.call_event_id)
          IS NOT (SELECT app_id FROM brain_relations WHERE relation_id = NEW.relation_id);
    SELECT RAISE(ABORT, 'evidence belongs to the evaluation that found it, which supported or contradicted')
    WHERE (SELECT outcome FROM brain_relation_evaluations
           WHERE call_event_id = NEW.call_event_id AND sequence = NEW.sequence)
          IS NOT (CASE NEW.relation WHEN 'supports' THEN 'supported' ELSE 'contradicted' END);
END;

CREATE TRIGGER brain_anchor_label_keys_own_app BEFORE INSERT ON brain_anchor_label_keys
BEGIN
    SELECT RAISE(ABORT, 'a label key names its anchor''s application')
    WHERE NEW.app_id IS NOT (SELECT app_id FROM brain_anchors WHERE anchor_id = NEW.anchor_id);
END;

CREATE TRIGGER memory_variant_prefixes_of_variants BEFORE INSERT ON memory_variant_prefixes
BEGIN
    SELECT RAISE(ABORT, 'only a variant has a prefix')
    WHERE (SELECT variant_of_route_id FROM memory_procedure_versions WHERE route_id = NEW.route_id) IS NULL;
    SELECT RAISE(ABORT, 'a prefix compares at most the steps before the divergence')
    WHERE NEW.compared_steps > (SELECT divergence_position FROM memory_procedure_versions WHERE route_id = NEW.route_id);
END;

CREATE TRIGGER memory_variant_prefixes_immutable BEFORE UPDATE ON memory_variant_prefixes
BEGIN
    SELECT RAISE(ABORT, 'a prefix check is immutable');
END;

CREATE TRIGGER memory_variant_prefixes_kept BEFORE DELETE ON memory_variant_prefixes
BEGIN
    SELECT RAISE(ABORT, 'a prefix check is kept');
END;

-- =============================================================================================================
-- Part 5. Prefix checks (G76, plan D2 after its second review).
--   - Memory: a variant's common prefix is checked with the two versions' parameters matched one to one across it,
--     with the same contract, so a parameter shared by two steps is not taken for two independent ones. Part 4's
--     memory_variant_prefixes cannot say why such a prefix is only suggested and is written no more:
--     memory_variant_prefix_checks takes every check.
-- =============================================================================================================

-- ---------------------------------------------------------------------------------------------
-- Variant prefix checks. A variant names the version it varies and the first step that differs: verified when
-- every step before it is the same operation on the generalized definitions (application, tool, the same literal
-- or a parameter in the same place) and the two versions' parameters correspond one to one across those steps
-- with the same contract; suggested when that could not be shown (a withheld literal, a step that could not be
-- read, parameters that do not correspond, or a variant declared before prefixes were checked). A prefix the
-- operations contradict is refused and has no row.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE memory_variant_prefix_checks (
    route_id TEXT PRIMARY KEY REFERENCES memory_procedure_versions(route_id),
    status TEXT NOT NULL CHECK (status IN ('verified', 'suggested')),
    compared_steps INTEGER NOT NULL CHECK (compared_steps >= 0),
    reason TEXT CHECK (reason IS NULL OR reason IN ('withheld_literal', 'unreadable_step', 'declared_before_verification',
        'parameter_correspondence')),
    checked_at_ms INTEGER NOT NULL,
    CHECK ((status = 'verified') = (reason IS NULL))
) STRICT;

-- ---------------------------------------------------------------------------------------------
-- Triggers.
-- ---------------------------------------------------------------------------------------------

CREATE TRIGGER memory_variant_prefix_checks_of_variants BEFORE INSERT ON memory_variant_prefix_checks
BEGIN
    SELECT RAISE(ABORT, 'only a variant has a prefix')
    WHERE (SELECT variant_of_route_id FROM memory_procedure_versions WHERE route_id = NEW.route_id) IS NULL;
    SELECT RAISE(ABORT, 'a prefix compares at most the steps before the divergence')
    WHERE NEW.compared_steps > (SELECT divergence_position FROM memory_procedure_versions WHERE route_id = NEW.route_id);
END;

CREATE TRIGGER memory_variant_prefix_checks_immutable BEFORE UPDATE ON memory_variant_prefix_checks
BEGIN
    SELECT RAISE(ABORT, 'a prefix check is immutable');
END;

CREATE TRIGGER memory_variant_prefix_checks_kept BEFORE DELETE ON memory_variant_prefix_checks
BEGIN
    SELECT RAISE(ABORT, 'a prefix check is kept');
END;

-- =============================================================================================================
-- Part 6. The Recall (G76, plan D3). Triggers are added on part 3 tables so every write that changes what the
-- catalogue offers also records the index work it needs.
--   - The Recall's index, derived and rebuildable from the catalogue: the embedding spaces (a model, its exact
--     revision and artifacts, the formats of its two roles), the generations (a document format in a space, built
--     before it is made current), the canonical documents of admitted parts, the vectors of a document in a space
--     (shared by identical documents, never by different ones), the entries that put a part in a generation, and
--     the durable queue of index work. Entries and their documents carry no episodic value: labels, roles and
--     applications of the definitions only.
--   - The Recall's facts: each query a task made and why, its needs, the selections delivered with their source,
--     interval and evidence, the relevant steps excluded with their certain reason, what each selection requires
--     (entry states or the state observed, application switches, steps done before it, producers included or not
--     repeated, bindings of the current task's values by name, never the values themselves, unknown compatibilities,
--     constraints not checked), the calls of the task linked afterwards to the steps they carried out or marked as
--     new, and the agent's declared use.
-- =============================================================================================================

-- ---------------------------------------------------------------------------------------------
-- Embedding spaces. One configuration that produces comparable vectors: a model at an exact revision, the
-- sha256 of its weights and tokenizer, the dimensions, the pooling, the normalization, the precision, the
-- formats of a query and of a document, the context. Immutable: a change of any of them is another space.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE memory_recall_spaces (
    space_id TEXT PRIMARY KEY CHECK (length(space_id) > 0),
    model_id TEXT NOT NULL CHECK (length(model_id) > 0),
    model_revision TEXT NOT NULL CHECK (length(model_revision) > 0),
    weights_digest TEXT NOT NULL CHECK (length(weights_digest) = 64),
    tokenizer_digest TEXT NOT NULL CHECK (length(tokenizer_digest) = 64),
    dimensions INTEGER NOT NULL CHECK (dimensions > 0),
    pooling TEXT NOT NULL CHECK (pooling IN ('mean', 'cls')),
    normalization TEXT NOT NULL CHECK (normalization IN ('l2')),
    precision TEXT NOT NULL CHECK (precision IN ('float32')),
    query_prefix TEXT NOT NULL,
    document_prefix TEXT NOT NULL,
    maximum_tokens INTEGER NOT NULL CHECK (maximum_tokens > 2),
    recorded_at_ms INTEGER NOT NULL
) STRICT;

-- ---------------------------------------------------------------------------------------------
-- Generations. The index of one document format, in a space or in none (lexical only). A generation is built
-- (`building`, the catalogue's versions enumerated a page at a time after `cursor_route_id`) and becomes current (`ready`)
-- only when complete, retiring the one it replaces in the same transaction; a build that stops or fails leaves
-- the ready one as it was. At most one is ready and one building. `revision` counts the changes of its entries,
-- so a reader keeping them in memory knows when to read them again.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE memory_recall_generations (
    generation_id INTEGER PRIMARY KEY,
    document_format TEXT NOT NULL CHECK (length(document_format) > 0),
    space_id TEXT REFERENCES memory_recall_spaces(space_id),
    status TEXT NOT NULL CHECK (status IN ('building', 'ready', 'retired', 'failed')),
    cursor_route_id TEXT,
    enumerated INTEGER NOT NULL DEFAULT 0 CHECK (enumerated IN (0, 1)),
    revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
    started_at_ms INTEGER NOT NULL,
    ready_at_ms INTEGER,
    ended_at_ms INTEGER,
    reason TEXT CHECK (reason IS NULL OR length(reason) > 0),
    CHECK (status <> 'building' OR (ready_at_ms IS NULL AND ended_at_ms IS NULL)),
    CHECK (status <> 'ready' OR (ready_at_ms IS NOT NULL AND ended_at_ms IS NULL AND enumerated = 1)),
    CHECK (status NOT IN ('retired', 'failed') OR ended_at_ms IS NOT NULL),
    CHECK (status <> 'failed' OR (reason IS NOT NULL AND ready_at_ms IS NULL))
) STRICT;

CREATE UNIQUE INDEX memory_recall_generations_one_ready ON memory_recall_generations(status) WHERE status = 'ready';
CREATE UNIQUE INDEX memory_recall_generations_one_building ON memory_recall_generations(status) WHERE status = 'building';

-- ---------------------------------------------------------------------------------------------
-- Documents and vectors. A document is the canonical text of a part for retrieval, in one format, named by the
-- sha256 of its format and text: two parts with exactly that text share it, and in one space its vector, while
-- each keeps its own entry, source and evidence. A vector holds `dimensions` float32 values, little-endian,
-- normalized as its space says, with the tokens the model read and whether the text was cut to its context.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE memory_recall_documents (
    document_digest TEXT PRIMARY KEY CHECK (length(document_digest) = 64),
    document_format TEXT NOT NULL CHECK (length(document_format) > 0),
    text TEXT NOT NULL CHECK (length(text) > 0),
    recorded_at_ms INTEGER NOT NULL
) STRICT;

CREATE TABLE memory_recall_vectors (
    space_id TEXT NOT NULL REFERENCES memory_recall_spaces(space_id),
    document_digest TEXT NOT NULL REFERENCES memory_recall_documents(document_digest),
    token_count INTEGER NOT NULL CHECK (token_count > 0),
    truncated INTEGER NOT NULL CHECK (truncated IN (0, 1)),
    vector BLOB NOT NULL,
    recorded_at_ms INTEGER NOT NULL,
    PRIMARY KEY (space_id, document_digest)
) STRICT;

-- ---------------------------------------------------------------------------------------------
-- Entries. A part offered by the catalogue, in one generation, with its document and the qualification and
-- state it had when it was entered. Derived: an entry whose part is no longer offered is removed, and a reader
-- checks the catalogue again before anything is delivered, so an entry never brings a part back.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE memory_recall_entries (
    generation_id INTEGER NOT NULL REFERENCES memory_recall_generations(generation_id),
    part_id TEXT NOT NULL REFERENCES memory_procedure_parts(part_id),
    route_id TEXT NOT NULL REFERENCES memory_procedure_versions(route_id),
    part_kind TEXT NOT NULL CHECK (part_kind IN ('procedure', 'subprocedure', 'step')),
    document_digest TEXT NOT NULL REFERENCES memory_recall_documents(document_digest),
    qualification_sequence INTEGER NOT NULL CHECK (qualification_sequence >= 1),
    state_sequence INTEGER NOT NULL CHECK (state_sequence >= 0),
    entered_at_ms INTEGER NOT NULL,
    PRIMARY KEY (generation_id, part_id)
) STRICT;

CREATE INDEX memory_recall_entries_by_route ON memory_recall_entries(route_id, generation_id);
CREATE INDEX memory_recall_entries_by_document ON memory_recall_entries(document_digest);

-- ---------------------------------------------------------------------------------------------
-- Index work. What the index must look at again, written by triggers in the same transaction as the write that
-- changed what the catalogue may offer: a version published or superseded, a part evaluated, a part's state, a
-- policy quarantined; and a whole rebuild after a migration or on request. A worker takes the oldest pending
-- rows after the commit, never inside it; a row is done once its effect is in every live generation. A row
-- already pending for the same route, or for the whole catalogue, covers a new one.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE memory_recall_work (
    work_id INTEGER PRIMARY KEY,
    route_id TEXT REFERENCES memory_procedure_versions(route_id),
    reason TEXT NOT NULL CHECK (reason IN ('publication', 'supersession', 'qualification', 'state', 'policy', 'migration',
        'rebuild')),
    enqueued_at_ms INTEGER NOT NULL,
    done_at_ms INTEGER,
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    last_error TEXT CHECK (last_error IS NULL OR length(last_error) > 0),
    CHECK ((route_id IS NULL) = (reason IN ('policy', 'migration', 'rebuild')))
) STRICT;

CREATE INDEX memory_recall_work_pending ON memory_recall_work(work_id) WHERE done_at_ms IS NULL;
CREATE INDEX memory_recall_work_pending_route ON memory_recall_work(route_id) WHERE done_at_ms IS NULL;

-- ---------------------------------------------------------------------------------------------
-- Recall queries. One search a task's attempt made, why (the initial preparation, or a reason recorded for a
-- later one), the remaining work it searched for, the generation and channel it used, how far the search went
-- (completed in its declared perimeter, limited, unavailable, failed) apart from what it covered, and whether
-- its details were delivered. Kept as written.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE memory_recall_queries (
    query_id TEXT PRIMARY KEY CHECK (length(query_id) > 0),
    task_id TEXT NOT NULL,
    task_occurrence_id TEXT NOT NULL,
    task_revision INTEGER NOT NULL CHECK (task_revision >= 1),
    source TEXT NOT NULL CHECK (source IN ('app', 'cli', 'mcp', 'watcher', 'system')),
    source_stream_id TEXT NOT NULL CHECK (length(source_stream_id) > 0),
    reason TEXT NOT NULL CHECK (reason IN ('initial', 'request_changed', 'input_changed', 'new_need', 'path_unusable')),
    remaining_work TEXT NOT NULL CHECK (length(remaining_work) > 0),
    generation_id INTEGER REFERENCES memory_recall_generations(generation_id),
    channel TEXT NOT NULL CHECK (channel IN ('semantic', 'lexical', 'hybrid', 'none')),
    search_status TEXT NOT NULL CHECK (search_status IN ('completed', 'limited', 'unavailable', 'failed')),
    search_note TEXT CHECK (search_note IS NULL OR length(search_note) > 0),
    candidate_limit INTEGER NOT NULL CHECK (candidate_limit > 0),
    candidates_considered INTEGER NOT NULL CHECK (candidates_considered >= 0),
    coverage TEXT NOT NULL CHECK (coverage IN ('complete', 'partial', 'ambiguous', 'absent', 'unknown')),
    delivery TEXT NOT NULL CHECK (delivery IN ('delivered', 'not_delivered', 'nothing')),
    delivery_bytes INTEGER CHECK (delivery_bytes IS NULL OR delivery_bytes >= 0),
    selector_version TEXT NOT NULL CHECK (length(selector_version) > 0),
    recorded_at_ms INTEGER NOT NULL,
    duration_us INTEGER CHECK (duration_us IS NULL OR duration_us >= 0),
    FOREIGN KEY (task_occurrence_id, task_id) REFERENCES memory_task_attempts(task_occurrence_id, task_id),
    CHECK ((search_status IN ('unavailable', 'failed')) = (coverage = 'unknown')),
    CHECK (search_status = 'completed' OR search_note IS NOT NULL),
    CHECK ((generation_id IS NULL) = (channel = 'none')),
    CHECK ((delivery = 'nothing') = (coverage IN ('absent', 'unknown')))
) STRICT;

CREATE INDEX memory_recall_queries_by_attempt ON memory_recall_queries(task_occurrence_id, recorded_at_ms);

-- One need of a query: a sub-result the agent named, or the remaining work itself, with the application it is
-- bound to when the agent said so, and its own coverage and the reason of a coverage that is not complete: gaps for
-- a partial one, alternatives or an unresolved input for an ambiguous one, and for an absence, `excluded` when the
-- relevant steps were excluded with a certain reason rather than not found.
CREATE TABLE memory_recall_needs (
    query_id TEXT NOT NULL REFERENCES memory_recall_queries(query_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    text TEXT NOT NULL CHECK (length(text) > 0),
    bundle_id TEXT CHECK (bundle_id IS NULL OR length(bundle_id) > 0),
    coverage TEXT NOT NULL CHECK (coverage IN ('complete', 'partial', 'ambiguous', 'absent', 'unknown')),
    reason TEXT CHECK (reason IS NULL OR reason IN ('gaps', 'alternatives', 'unresolved_input', 'excluded')),
    PRIMARY KEY (query_id, position),
    CHECK (CASE coverage
        WHEN 'partial' THEN ifnull(reason, '') = 'gaps'
        WHEN 'ambiguous' THEN ifnull(reason, '') IN ('alternatives', 'unresolved_input')
        WHEN 'absent' THEN ifnull(reason, 'excluded') = 'excluded'
        ELSE reason IS NULL END)
) STRICT;

-- A selection: the ordered interval of one version's steps proposed for a need, the part it is whole when it is
-- one, its relevance and the preparations it needs. `alternative` rows are the candidates an ambiguity names, of
-- which no detail is delivered; `excluded` rows are relevant episodes a certain conflict or a constraint removed,
-- each with the requirements that say why.
CREATE TABLE memory_recall_selections (
    query_id TEXT NOT NULL,
    need_position INTEGER NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    role TEXT NOT NULL CHECK (role IN ('selected', 'alternative', 'excluded')),
    route_id TEXT NOT NULL REFERENCES memory_procedure_versions(route_id),
    first_position INTEGER NOT NULL CHECK (first_position >= 0),
    last_position INTEGER NOT NULL,
    whole_part_id TEXT REFERENCES memory_procedure_parts(part_id),
    relevance REAL NOT NULL,
    preparations INTEGER NOT NULL CHECK (preparations >= 0),
    PRIMARY KEY (query_id, need_position, position),
    FOREIGN KEY (query_id, need_position) REFERENCES memory_recall_needs(query_id, position),
    CHECK (last_position >= first_position)
) STRICT;

-- What a selection requires or states: the entry state of its first step, or the state the session's latest
-- observation showed when the selection starts there; a switch of application the source made between its
-- blocks; the last step of the same block before it (what such steps left no contract states); an entry state no
-- step of it produces and nothing recorded; a step of its version the catalogue does not offer, outside the
-- interval it would have been part of; each parameter bound to the current task's value of a name (never the
-- value), missing or ambiguous; an input produced by an earlier part the selection includes, or an output the task
-- already holds whose producer it leaves out; a compatibility not observed; a value the task still lacks about a
-- choice the selection fixes; a constraint of the request (by position) it does not check. An excluded selection
-- states why: a fixed choice a value of the task contradicts, or a step a constraint forbids.
CREATE TABLE memory_recall_requirements (
    query_id TEXT NOT NULL,
    need_position INTEGER NOT NULL,
    selection_position INTEGER NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    kind TEXT NOT NULL CHECK (kind IN ('entry_state', 'observed_state', 'application_switch', 'prepared_before',
        'unknown_entry_state', 'prerequisite_out_of_catalogue', 'parameter_bound', 'parameter_missing', 'parameter_ambiguous',
        'input_produced', 'output_ready', 'compatibility_unknown', 'unbound_task_input', 'constraint_unchecked',
        'certain_conflict', 'constraint_excluded', 'adapter_available', 'step_result_pending', 'account_to_resolve')),
    step_position INTEGER CHECK (step_position IS NULL OR step_position >= 0),
    parameter_id TEXT CHECK (parameter_id IS NULL OR length(parameter_id) > 0),
    scene_id TEXT CHECK (scene_id IS NULL OR length(scene_id) > 0),
    bundle_id TEXT CHECK (bundle_id IS NULL OR length(bundle_id) > 0),
    task_value_name TEXT CHECK (task_value_name IS NULL OR length(task_value_name) > 0),
    binding_match TEXT CHECK (binding_match IS NULL OR binding_match IN ('name', 'role', 'derived', 'produced')),
    constraint_position INTEGER CHECK (constraint_position IS NULL OR constraint_position >= 0),
    PRIMARY KEY (query_id, need_position, selection_position, position),
    FOREIGN KEY (query_id, need_position, selection_position)
        REFERENCES memory_recall_selections(query_id, need_position, position),
    CHECK ((kind IN ('parameter_bound', 'parameter_missing', 'parameter_ambiguous', 'compatibility_unknown', 'input_produced',
        'output_ready')) = (parameter_id IS NOT NULL)),
    CHECK ((kind IN ('parameter_bound', 'output_ready')) = (binding_match IS NOT NULL)),
    CHECK (kind NOT IN ('parameter_bound', 'output_ready', 'unbound_task_input', 'certain_conflict') OR task_value_name IS NOT NULL),
    CHECK ((kind IN ('constraint_unchecked', 'constraint_excluded')) = (constraint_position IS NOT NULL)),
    CHECK (kind <> 'observed_state' OR (scene_id IS NOT NULL AND bundle_id IS NOT NULL)),
    CHECK (kind NOT IN ('observed_state', 'prepared_before', 'input_produced', 'output_ready', 'certain_conflict',
        'constraint_excluded', 'unknown_entry_state', 'prerequisite_out_of_catalogue', 'application_switch', 'entry_state',
        'compatibility_unknown', 'unbound_task_input', 'adapter_available', 'step_result_pending', 'account_to_resolve')
        OR step_position IS NOT NULL),
    CHECK (kind <> 'adapter_available' OR bundle_id IS NOT NULL)
) STRICT;

-- A call of the task's attempt after a query delivered, linked to the step of the selection it carried out
-- (the same tool on the same application, from the same state when known, on the same element, with the
-- operation's defining arguments and the bound values) or to none (an operation of the agent's own: a raccordo or
-- a deviation, or undetermined when it would carry out the next step were the facts it lacks to agree); confirmed
-- when the call's own check passed. Written once, by the system's comparison, never from the agent's account.
CREATE TABLE memory_recall_links (
    query_id TEXT NOT NULL,
    need_position INTEGER NOT NULL,
    call_event_id TEXT NOT NULL REFERENCES memory_agent_actions(event_id),
    step_position INTEGER CHECK (step_position IS NULL OR step_position >= 0),
    confirmed INTEGER NOT NULL CHECK (confirmed IN (0, 1)),
    undetermined INTEGER NOT NULL DEFAULT 0 CHECK (undetermined IN (0, 1)),
    linked_at_ms INTEGER NOT NULL,
    PRIMARY KEY (query_id, call_event_id),
    FOREIGN KEY (query_id, need_position) REFERENCES memory_recall_needs(query_id, position),
    CHECK (step_position IS NOT NULL OR confirmed = 0),
    CHECK (step_position IS NULL OR undetermined = 0)
) STRICT;

-- The agent's declared use of a need's selection: followed, adapted, abandoned or not executed, with the cause of
-- a failure when it knows one. Appended; a declaration is never a verification.
CREATE TABLE memory_recall_reports (
    query_id TEXT NOT NULL,
    need_position INTEGER NOT NULL,
    sequence INTEGER NOT NULL CHECK (sequence >= 1),
    declared TEXT NOT NULL CHECK (declared IN ('followed', 'adapted', 'abandoned', 'not_executed')),
    cause TEXT CHECK (cause IS NULL OR cause IN ('method', 'driver', 'application', 'agent', 'input', 'unknown')),
    note TEXT CHECK (note IS NULL OR length(note) > 0),
    recorded_at_ms INTEGER NOT NULL,
    PRIMARY KEY (query_id, need_position, sequence),
    FOREIGN KEY (query_id, need_position) REFERENCES memory_recall_needs(query_id, position)
) STRICT;

-- Lookups by version that part 3 left without an index, made for every version a query reads (the version's
-- bindings, parameter details and contract, whether a later version supersedes it, its confirmed reuses): each
-- would otherwise scan its whole table, a cost that grows with the catalogue.
CREATE INDEX memory_parameter_bindings_by_route ON memory_parameter_bindings(route_id);
CREATE INDEX memory_parameter_details_by_route ON memory_parameter_details(route_id);
CREATE INDEX memory_part_contract_items_by_route ON memory_part_contract_items(route_id);
CREATE INDEX memory_routes_by_superseded ON memory_routes(supersedes_route_id) WHERE supersedes_route_id IS NOT NULL;
CREATE INDEX memory_recall_selections_by_route ON memory_recall_selections(route_id, role);

-- ---------------------------------------------------------------------------------------------
-- Triggers: index work recorded with the writes that change what the catalogue may offer.
-- ---------------------------------------------------------------------------------------------

CREATE TRIGGER memory_recall_work_on_version AFTER INSERT ON memory_procedure_versions
BEGIN
    INSERT INTO memory_recall_work (route_id, reason, enqueued_at_ms)
    SELECT NEW.route_id, 'publication', NEW.built_at_ms
    WHERE NOT EXISTS (SELECT 1 FROM memory_recall_work WHERE done_at_ms IS NULL AND route_id = NEW.route_id);
    INSERT INTO memory_recall_work (route_id, reason, enqueued_at_ms)
    SELECT r.supersedes_route_id, 'supersession', NEW.built_at_ms FROM memory_routes r
    WHERE r.route_id = NEW.route_id AND r.supersedes_route_id IS NOT NULL
      AND EXISTS (SELECT 1 FROM memory_procedure_versions v WHERE v.route_id = r.supersedes_route_id)
      AND NOT EXISTS (SELECT 1 FROM memory_recall_work w WHERE w.done_at_ms IS NULL AND w.route_id = r.supersedes_route_id);
END;

CREATE TRIGGER memory_recall_work_on_qualification AFTER INSERT ON memory_part_qualifications
BEGIN
    INSERT INTO memory_recall_work (route_id, reason, enqueued_at_ms)
    SELECT p.route_id, 'qualification', NEW.evaluated_at_ms FROM memory_procedure_parts p
    WHERE p.part_id = NEW.part_id
      AND NOT EXISTS (SELECT 1 FROM memory_recall_work w WHERE w.done_at_ms IS NULL AND w.route_id = p.route_id);
END;

CREATE TRIGGER memory_recall_work_on_state AFTER INSERT ON memory_part_states
BEGIN
    INSERT INTO memory_recall_work (route_id, reason, enqueued_at_ms)
    SELECT p.route_id, 'state', NEW.recorded_at_ms FROM memory_procedure_parts p
    WHERE p.part_id = NEW.part_id
      AND NOT EXISTS (SELECT 1 FROM memory_recall_work w WHERE w.done_at_ms IS NULL AND w.route_id = p.route_id);
END;

CREATE TRIGGER memory_recall_work_on_policy_insert AFTER INSERT ON memory_qualification_policies
WHEN NEW.status = 'quarantined'
BEGIN
    INSERT INTO memory_recall_work (route_id, reason, enqueued_at_ms)
    SELECT NULL, 'policy', NEW.changed_at_ms
    WHERE NOT EXISTS (SELECT 1 FROM memory_recall_work WHERE done_at_ms IS NULL AND route_id IS NULL);
END;

CREATE TRIGGER memory_recall_work_on_policy_update AFTER UPDATE OF status ON memory_qualification_policies
WHEN NEW.status IS NOT OLD.status
BEGIN
    INSERT INTO memory_recall_work (route_id, reason, enqueued_at_ms)
    SELECT NULL, 'policy', NEW.changed_at_ms
    WHERE NOT EXISTS (SELECT 1 FROM memory_recall_work WHERE done_at_ms IS NULL AND route_id IS NULL);
END;

-- ---------------------------------------------------------------------------------------------
-- Triggers: the index's own rows.
-- ---------------------------------------------------------------------------------------------

CREATE TRIGGER memory_recall_spaces_immutable BEFORE UPDATE ON memory_recall_spaces
BEGIN
    SELECT RAISE(ABORT, 'an embedding space is immutable');
END;

CREATE TRIGGER memory_recall_spaces_kept BEFORE DELETE ON memory_recall_spaces
BEGIN
    SELECT RAISE(ABORT, 'an embedding space is kept');
END;

CREATE TRIGGER memory_recall_generations_born_building BEFORE INSERT ON memory_recall_generations
BEGIN
    SELECT RAISE(ABORT, 'a generation is born building')
    WHERE NEW.status <> 'building' OR NEW.enumerated <> 0 OR NEW.revision <> 0;
END;

CREATE TRIGGER memory_recall_generations_transitions BEFORE UPDATE ON memory_recall_generations
BEGIN
    SELECT RAISE(ABORT, 'a generation keeps its format and space')
    WHERE NEW.document_format IS NOT OLD.document_format OR NEW.space_id IS NOT OLD.space_id
       OR NEW.generation_id IS NOT OLD.generation_id OR NEW.started_at_ms IS NOT OLD.started_at_ms;
    SELECT RAISE(ABORT, 'a generation moves building to ready, failed or retired, and ready to retired')
    WHERE NEW.status IS NOT OLD.status AND NOT (
        (OLD.status = 'building' AND NEW.status IN ('ready', 'failed', 'retired'))
        OR (OLD.status = 'ready' AND NEW.status = 'retired'));
    SELECT RAISE(ABORT, 'a retired or failed generation is final')
    WHERE OLD.status IN ('retired', 'failed') AND (NEW.status IS NOT OLD.status OR NEW.revision IS NOT OLD.revision
        OR NEW.cursor_route_id IS NOT OLD.cursor_route_id OR NEW.enumerated IS NOT OLD.enumerated);
    SELECT RAISE(ABORT, 'an enumerated generation stays enumerated')
    WHERE OLD.enumerated = 1 AND NEW.enumerated = 0;
    SELECT RAISE(ABORT, 'a generation''s revision only grows')
    WHERE NEW.revision < OLD.revision;
END;

CREATE TRIGGER memory_recall_generations_kept BEFORE DELETE ON memory_recall_generations
BEGIN
    SELECT RAISE(ABORT, 'a generation is kept');
END;

CREATE TRIGGER memory_recall_documents_immutable BEFORE UPDATE ON memory_recall_documents
BEGIN
    SELECT RAISE(ABORT, 'a recall document is immutable');
END;

CREATE TRIGGER memory_recall_vectors_shape BEFORE INSERT ON memory_recall_vectors
BEGIN
    SELECT RAISE(ABORT, 'a vector holds the space''s dimensions as float32')
    WHERE length(NEW.vector) <> 4 * (SELECT dimensions FROM memory_recall_spaces WHERE space_id = NEW.space_id);
END;

CREATE TRIGGER memory_recall_vectors_immutable BEFORE UPDATE ON memory_recall_vectors
BEGIN
    SELECT RAISE(ABORT, 'a vector is immutable');
END;

CREATE TRIGGER memory_recall_entries_valid BEFORE INSERT ON memory_recall_entries
BEGIN
    SELECT RAISE(ABORT, 'an entry belongs to a generation being built or ready')
    WHERE (SELECT status FROM memory_recall_generations WHERE generation_id = NEW.generation_id) NOT IN ('building', 'ready');
    SELECT RAISE(ABORT, 'an entry names its part''s version and kind')
    WHERE NOT EXISTS (SELECT 1 FROM memory_procedure_parts p WHERE p.part_id = NEW.part_id AND p.route_id = NEW.route_id
                      AND p.part_kind = NEW.part_kind);
    SELECT RAISE(ABORT, 'an entry''s document is in its generation''s format')
    WHERE (SELECT document_format FROM memory_recall_documents WHERE document_digest = NEW.document_digest)
          IS NOT (SELECT document_format FROM memory_recall_generations WHERE generation_id = NEW.generation_id);
END;

CREATE TRIGGER memory_recall_entries_counted AFTER INSERT ON memory_recall_entries
BEGIN
    UPDATE memory_recall_generations SET revision = revision + 1 WHERE generation_id = NEW.generation_id;
END;

CREATE TRIGGER memory_recall_entries_removed AFTER DELETE ON memory_recall_entries
BEGIN
    UPDATE memory_recall_generations SET revision = revision + 1
    WHERE generation_id = OLD.generation_id AND status IN ('building', 'ready');
END;

CREATE TRIGGER memory_recall_entries_immutable BEFORE UPDATE ON memory_recall_entries
BEGIN
    SELECT RAISE(ABORT, 'an entry is replaced, never changed');
END;

CREATE TRIGGER memory_recall_work_progress BEFORE UPDATE ON memory_recall_work
BEGIN
    SELECT RAISE(ABORT, 'index work keeps its route, reason and time')
    WHERE NEW.route_id IS NOT OLD.route_id OR NEW.reason IS NOT OLD.reason OR NEW.enqueued_at_ms IS NOT OLD.enqueued_at_ms
       OR NEW.work_id IS NOT OLD.work_id;
    SELECT RAISE(ABORT, 'index work is done once')
    WHERE OLD.done_at_ms IS NOT NULL AND NEW.done_at_ms IS NOT OLD.done_at_ms;
    SELECT RAISE(ABORT, 'index work attempts only grow')
    WHERE NEW.attempts < OLD.attempts;
END;

CREATE TRIGGER memory_recall_work_kept BEFORE DELETE ON memory_recall_work
BEGIN
    SELECT RAISE(ABORT, 'index work is kept');
END;

-- ---------------------------------------------------------------------------------------------
-- Triggers: the Recall's facts, coherent and kept as written.
-- ---------------------------------------------------------------------------------------------

CREATE TRIGGER memory_recall_queries_immutable BEFORE UPDATE ON memory_recall_queries
BEGIN
    SELECT RAISE(ABORT, 'a recall query is immutable');
END;

CREATE TRIGGER memory_recall_queries_kept BEFORE DELETE ON memory_recall_queries
BEGIN
    SELECT RAISE(ABORT, 'a recall query is kept');
END;

CREATE TRIGGER memory_recall_needs_immutable BEFORE UPDATE ON memory_recall_needs
BEGIN
    SELECT RAISE(ABORT, 'a recall need is immutable');
END;

CREATE TRIGGER memory_recall_needs_kept BEFORE DELETE ON memory_recall_needs
BEGIN
    SELECT RAISE(ABORT, 'a recall need is kept');
END;

CREATE TRIGGER memory_recall_selections_valid BEFORE INSERT ON memory_recall_selections
BEGIN
    SELECT RAISE(ABORT, 'a selection lies within its version''s steps')
    WHERE NEW.last_position > (SELECT max(last_position) FROM memory_procedure_parts WHERE route_id = NEW.route_id);
    SELECT RAISE(ABORT, 'a whole part is a part of the selection''s version with its interval')
    WHERE NEW.whole_part_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM memory_procedure_parts p WHERE p.part_id = NEW.whole_part_id AND p.route_id = NEW.route_id
          AND p.first_position = NEW.first_position AND p.last_position = NEW.last_position);
    SELECT RAISE(ABORT, 'a need with no coverage has no selection')
    WHERE NEW.role <> 'excluded' AND (SELECT coverage FROM memory_recall_needs WHERE query_id = NEW.query_id AND position = NEW.need_position)
          IN ('absent', 'unknown');
    SELECT RAISE(ABORT, 'a search that could not answer excludes nothing')
    WHERE NEW.role = 'excluded' AND (SELECT coverage FROM memory_recall_needs WHERE query_id = NEW.query_id AND position = NEW.need_position)
          = 'unknown';
END;

CREATE TRIGGER memory_recall_selections_immutable BEFORE UPDATE ON memory_recall_selections
BEGIN
    SELECT RAISE(ABORT, 'a recall selection is immutable');
END;

CREATE TRIGGER memory_recall_selections_kept BEFORE DELETE ON memory_recall_selections
BEGIN
    SELECT RAISE(ABORT, 'a recall selection is kept');
END;

CREATE TRIGGER memory_recall_requirements_immutable BEFORE UPDATE ON memory_recall_requirements
BEGIN
    SELECT RAISE(ABORT, 'a recall requirement is immutable');
END;

CREATE TRIGGER memory_recall_requirements_kept BEFORE DELETE ON memory_recall_requirements
BEGIN
    SELECT RAISE(ABORT, 'a recall requirement is kept');
END;

CREATE TRIGGER memory_recall_links_valid BEFORE INSERT ON memory_recall_links
BEGIN
    SELECT RAISE(ABORT, 'a linked call belongs to the query''s attempt')
    WHERE NOT EXISTS (
        SELECT 1 FROM memory_task_events t JOIN memory_recall_queries q ON q.task_occurrence_id = t.task_occurrence_id
        WHERE q.query_id = NEW.query_id AND t.event_id = NEW.call_event_id AND t.role = 'action');
    SELECT RAISE(ABORT, 'a linked step lies in the need''s selected interval')
    WHERE NEW.step_position IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM memory_recall_selections s WHERE s.query_id = NEW.query_id AND s.need_position = NEW.need_position
          AND s.role = 'selected' AND NEW.step_position BETWEEN s.first_position AND s.last_position);
END;

CREATE TRIGGER memory_recall_links_immutable BEFORE UPDATE ON memory_recall_links
BEGIN
    SELECT RAISE(ABORT, 'a recall link is immutable');
END;

CREATE TRIGGER memory_recall_links_kept BEFORE DELETE ON memory_recall_links
BEGIN
    SELECT RAISE(ABORT, 'a recall link is kept');
END;

CREATE TRIGGER memory_recall_reports_in_order BEFORE INSERT ON memory_recall_reports
BEGIN
    SELECT RAISE(ABORT, 'a report follows the need''s last one by one')
    WHERE NEW.sequence <> 1 + ifnull((SELECT max(sequence) FROM memory_recall_reports
                                       WHERE query_id = NEW.query_id AND need_position = NEW.need_position), 0);
END;

CREATE TRIGGER memory_recall_reports_immutable BEFORE UPDATE ON memory_recall_reports
BEGIN
    SELECT RAISE(ABORT, 'a recall report is immutable');
END;

CREATE TRIGGER memory_recall_reports_kept BEFORE DELETE ON memory_recall_reports
BEGIN
    SELECT RAISE(ABORT, 'a recall report is kept');
END;

-- =============================================================================================================
-- Part 7. The experiment of the Recall by the agent's choice (G76, plan D3, Documentation/Engine/RecallAgentChoice.md).
-- One trigger is added on a part 6 table, and the check of a requirement's step admits one more case.
--   - A proposal: the few versions a query shortlisted per need for the agent to choose from, with the automatic
--     selector's suggestion, before anything is delivered. A proposal is not a delivery.
--   - A choice: the delivered query (part 6's rows, unchanged in meaning) that answers one proposal, the agent's
--     own declaration of how much of each need its tracts cover, kept apart from the coverage Engine derives, and the
--     links of the calls that followed to the tract and step each carried out.
-- =============================================================================================================

-- ---------------------------------------------------------------------------------------------
-- A proposal: the task, attempt and revision it was made for, by whom and why, the remaining work, the index and
-- channel that answered and how far the search went, the parts it considered, the size of the text the agent read
-- and the format of that text, when, and how long it took. Immutable.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE memory_recall_proposals (
    proposal_id TEXT PRIMARY KEY CHECK (length(proposal_id) > 0),
    task_id TEXT NOT NULL,
    task_occurrence_id TEXT NOT NULL,
    task_revision INTEGER NOT NULL CHECK (task_revision >= 1),
    source TEXT NOT NULL CHECK (source IN ('app', 'cli', 'mcp', 'watcher', 'system')),
    source_stream_id TEXT NOT NULL CHECK (length(source_stream_id) > 0),
    reason TEXT NOT NULL CHECK (reason IN ('initial', 'request_changed', 'input_changed', 'new_need', 'path_unusable')),
    remaining_work TEXT NOT NULL CHECK (length(remaining_work) > 0),
    generation_id INTEGER REFERENCES memory_recall_generations(generation_id),
    channel TEXT NOT NULL CHECK (channel IN ('semantic', 'lexical', 'hybrid', 'none')),
    search_status TEXT NOT NULL CHECK (search_status IN ('completed', 'limited', 'unavailable', 'failed')),
    search_note TEXT CHECK (search_note IS NULL OR length(search_note) > 0),
    candidates_considered INTEGER NOT NULL CHECK (candidates_considered >= 0),
    proposal_bytes INTEGER NOT NULL CHECK (proposal_bytes >= 0),
    format_version TEXT NOT NULL CHECK (length(format_version) > 0),
    recorded_at_ms INTEGER NOT NULL,
    duration_us INTEGER CHECK (duration_us IS NULL OR duration_us >= 0),
    FOREIGN KEY (task_occurrence_id, task_id) REFERENCES memory_task_attempts(task_occurrence_id, task_id),
    CHECK (search_status = 'completed' OR search_note IS NOT NULL),
    CHECK ((generation_id IS NULL) = (channel = 'none'))
) STRICT;

CREATE INDEX memory_recall_proposals_by_attempt ON memory_recall_proposals(task_occurrence_id, recorded_at_ms);

-- The needs a proposal was made for, in the agent's words, with the application a need is bound to.
CREATE TABLE memory_recall_proposal_needs (
    proposal_id TEXT NOT NULL REFERENCES memory_recall_proposals(proposal_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    text TEXT NOT NULL CHECK (length(text) > 0),
    bundle_id TEXT CHECK (bundle_id IS NULL OR length(bundle_id) > 0),
    PRIMARY KEY (proposal_id, position)
) STRICT;

-- A version a proposal shortlisted for a need: the proposal's own name for it (`s1`, `s2`: one name, one version, in
-- the whole proposal), its relevance to the need, and the interval the automatic selector suggested in it, when it
-- named one.
CREATE TABLE memory_recall_proposal_sources (
    proposal_id TEXT NOT NULL,
    need_position INTEGER NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    source_key TEXT NOT NULL CHECK (length(source_key) > 0),
    route_id TEXT NOT NULL REFERENCES memory_procedure_versions(route_id),
    relevance REAL NOT NULL,
    suggested_first INTEGER CHECK (suggested_first IS NULL OR suggested_first >= 0),
    suggested_last INTEGER,
    PRIMARY KEY (proposal_id, need_position, position),
    FOREIGN KEY (proposal_id, need_position) REFERENCES memory_recall_proposal_needs(proposal_id, position),
    CHECK ((suggested_first IS NULL) = (suggested_last IS NULL)),
    CHECK (suggested_last IS NULL OR suggested_last >= suggested_first)
) STRICT;

-- ---------------------------------------------------------------------------------------------
-- A choice: the delivered query that answers a proposal, at most one per proposal. Its needs, tracts (selected
-- rows, in order) and requirements are part 6's rows; `input_produced` names a producer the need's plan includes
-- in an earlier tract of the same need.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE memory_recall_choices (
    query_id TEXT PRIMARY KEY REFERENCES memory_recall_queries(query_id),
    proposal_id TEXT NOT NULL UNIQUE REFERENCES memory_recall_proposals(proposal_id),
    recorded_at_ms INTEGER NOT NULL
) STRICT;

-- The agent's declaration, per need, of how much of it the tracts it chose cover (`all`, `part`, `none`) and, in its
-- words, what remains. A declaration is never a verification and never changes the coverage Engine derives.
CREATE TABLE memory_recall_choice_needs (
    query_id TEXT NOT NULL REFERENCES memory_recall_choices(query_id),
    need_position INTEGER NOT NULL,
    declared TEXT NOT NULL CHECK (declared IN ('all', 'part', 'none', 'ambiguous')),
    uncovered TEXT CHECK (uncovered IS NULL OR length(uncovered) > 0),
    settled_by TEXT CHECK (settled_by IS NULL OR length(settled_by) > 0),
    PRIMARY KEY (query_id, need_position),
    FOREIGN KEY (query_id, need_position) REFERENCES memory_recall_needs(query_id, position),
    CHECK (declared <> 'all' OR uncovered IS NULL),
    CHECK (declared <> 'ambiguous' OR uncovered IS NOT NULL),
    CHECK (declared NOT IN ('none', 'ambiguous') OR settled_by IS NULL)
) STRICT;

-- A call of the choice's attempt, linked to the tract (its selection's position) and step it carried out, or to none
-- (an operation of the agent's own, or undetermined); confirmed when the call's own check passed. A call is linked
-- once per query, so it confirms at most one step of one tract. Written once, by the system's comparison.
CREATE TABLE memory_recall_choice_links (
    query_id TEXT NOT NULL REFERENCES memory_recall_choices(query_id),
    need_position INTEGER NOT NULL,
    selection_position INTEGER,
    call_event_id TEXT NOT NULL REFERENCES memory_agent_actions(event_id),
    step_position INTEGER CHECK (step_position IS NULL OR step_position >= 0),
    confirmed INTEGER NOT NULL CHECK (confirmed IN (0, 1)),
    undetermined INTEGER NOT NULL DEFAULT 0 CHECK (undetermined IN (0, 1)),
    linked_at_ms INTEGER NOT NULL,
    PRIMARY KEY (query_id, call_event_id),
    FOREIGN KEY (query_id, need_position) REFERENCES memory_recall_needs(query_id, position),
    FOREIGN KEY (query_id, need_position, selection_position) REFERENCES memory_recall_selections(query_id, need_position, position),
    CHECK ((step_position IS NULL) = (selection_position IS NULL)),
    CHECK (step_position IS NOT NULL OR confirmed = 0),
    CHECK (step_position IS NULL OR undetermined = 0)
) STRICT;

-- ---------------------------------------------------------------------------------------------
-- Triggers: every row is immutable and kept; names, attempts and intervals agree.
-- ---------------------------------------------------------------------------------------------

CREATE TRIGGER memory_recall_proposals_immutable BEFORE UPDATE ON memory_recall_proposals
BEGIN
    SELECT RAISE(ABORT, 'a recall proposal is immutable');
END;

CREATE TRIGGER memory_recall_proposals_kept BEFORE DELETE ON memory_recall_proposals
BEGIN
    SELECT RAISE(ABORT, 'a recall proposal is kept');
END;

CREATE TRIGGER memory_recall_proposal_needs_immutable BEFORE UPDATE ON memory_recall_proposal_needs
BEGIN
    SELECT RAISE(ABORT, 'a proposal''s need is immutable');
END;

CREATE TRIGGER memory_recall_proposal_needs_kept BEFORE DELETE ON memory_recall_proposal_needs
BEGIN
    SELECT RAISE(ABORT, 'a proposal''s need is kept');
END;

CREATE TRIGGER memory_recall_proposal_sources_named BEFORE INSERT ON memory_recall_proposal_sources
BEGIN
    SELECT RAISE(ABORT, 'a proposal names one version by one name')
    WHERE EXISTS (SELECT 1 FROM memory_recall_proposal_sources s WHERE s.proposal_id = NEW.proposal_id
                  AND ((s.source_key = NEW.source_key) <> (s.route_id = NEW.route_id)));
END;

CREATE TRIGGER memory_recall_proposal_sources_immutable BEFORE UPDATE ON memory_recall_proposal_sources
BEGIN
    SELECT RAISE(ABORT, 'a proposal''s source is immutable');
END;

CREATE TRIGGER memory_recall_proposal_sources_kept BEFORE DELETE ON memory_recall_proposal_sources
BEGIN
    SELECT RAISE(ABORT, 'a proposal''s source is kept');
END;

CREATE TRIGGER memory_recall_choices_valid BEFORE INSERT ON memory_recall_choices
BEGIN
    SELECT RAISE(ABORT, 'a choice answers a proposal of its query''s attempt, revision and producer')
    WHERE NOT EXISTS (
        SELECT 1 FROM memory_recall_queries q JOIN memory_recall_proposals p ON p.proposal_id = NEW.proposal_id
        WHERE q.query_id = NEW.query_id AND q.task_occurrence_id = p.task_occurrence_id AND q.task_id = p.task_id
          AND q.task_revision = p.task_revision AND q.source = p.source AND q.source_stream_id = p.source_stream_id);
END;

CREATE TRIGGER memory_recall_choices_immutable BEFORE UPDATE ON memory_recall_choices
BEGIN
    SELECT RAISE(ABORT, 'a recall choice is immutable');
END;

CREATE TRIGGER memory_recall_choices_kept BEFORE DELETE ON memory_recall_choices
BEGIN
    SELECT RAISE(ABORT, 'a recall choice is kept');
END;

CREATE TRIGGER memory_recall_choice_needs_valid BEFORE INSERT ON memory_recall_choice_needs
BEGIN
    SELECT RAISE(ABORT, 'an ambiguous need runs no tract and gives at least two alternatives')
    WHERE NEW.declared = 'ambiguous' AND (
        EXISTS (SELECT 1 FROM memory_recall_selections s WHERE s.query_id = NEW.query_id AND s.need_position = NEW.need_position
                  AND s.role = 'selected')
        OR (SELECT count(*) FROM memory_recall_selections s WHERE s.query_id = NEW.query_id AND s.need_position = NEW.need_position
              AND s.role = 'alternative') < 2
        OR (SELECT coverage FROM memory_recall_needs WHERE query_id = NEW.query_id AND position = NEW.need_position) <> 'ambiguous');
END;

CREATE TRIGGER memory_recall_choice_needs_immutable BEFORE UPDATE ON memory_recall_choice_needs
BEGIN
    SELECT RAISE(ABORT, 'a choice''s declaration is immutable');
END;

CREATE TRIGGER memory_recall_choice_needs_kept BEFORE DELETE ON memory_recall_choice_needs
BEGIN
    SELECT RAISE(ABORT, 'a choice''s declaration is kept');
END;

CREATE TRIGGER memory_recall_choice_links_valid BEFORE INSERT ON memory_recall_choice_links
BEGIN
    SELECT RAISE(ABORT, 'a linked call belongs to the query''s attempt')
    WHERE NOT EXISTS (
        SELECT 1 FROM memory_task_events t JOIN memory_recall_queries q ON q.task_occurrence_id = t.task_occurrence_id
        WHERE q.query_id = NEW.query_id AND t.event_id = NEW.call_event_id AND t.role = 'action');
    SELECT RAISE(ABORT, 'a linked step lies in the selected tract it names')
    WHERE NEW.step_position IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM memory_recall_selections s WHERE s.query_id = NEW.query_id AND s.need_position = NEW.need_position
          AND s.position = NEW.selection_position AND s.role = 'selected'
          AND NEW.step_position BETWEEN s.first_position AND s.last_position);
END;

CREATE TRIGGER memory_recall_choice_links_immutable BEFORE UPDATE ON memory_recall_choice_links
BEGIN
    SELECT RAISE(ABORT, 'a recall link is immutable');
END;

CREATE TRIGGER memory_recall_choice_links_kept BEFORE DELETE ON memory_recall_choice_links
BEGIN
    SELECT RAISE(ABORT, 'a recall link is kept');
END;

-- A choice's calls are linked to the tract they carried out, never through the links of part 6, which name no tract.
CREATE TRIGGER memory_recall_links_not_of_choices BEFORE INSERT ON memory_recall_links
BEGIN
    SELECT RAISE(ABORT, 'a choice''s links name their tract')
    WHERE EXISTS (SELECT 1 FROM memory_recall_choices c WHERE c.query_id = NEW.query_id);
END;

-- ---------------------------------------------------------------------------------------------
-- A requirement of a chosen tract. A choice may hold several tracts of one version for a need, and an input of a later
-- tract may be produced in an earlier one: that `input_produced` names the producer's step, outside its own selection,
-- inside an earlier selected tract of the same version and need. The check of a requirement admits that one case; every
-- other requirement is checked as part 6 states it.
-- ---------------------------------------------------------------------------------------------

CREATE TRIGGER memory_recall_requirements_valid BEFORE INSERT ON memory_recall_requirements
BEGIN
    SELECT RAISE(ABORT, 'a requirement names a step of its selection')
    WHERE NEW.step_position IS NOT NULL AND NEW.kind NOT IN ('prerequisite_out_of_catalogue', 'prepared_before', 'output_ready')
      AND NOT EXISTS (
        SELECT 1 FROM memory_recall_selections s WHERE s.query_id = NEW.query_id AND s.need_position = NEW.need_position
          AND s.position = NEW.selection_position AND NEW.step_position BETWEEN s.first_position AND s.last_position)
      AND NOT (NEW.kind = 'input_produced' AND EXISTS (
        SELECT 1 FROM memory_recall_selections s JOIN memory_recall_selections e
          ON e.query_id = s.query_id AND e.need_position = s.need_position AND e.route_id = s.route_id
         AND e.position < s.position AND e.role = 'selected'
        WHERE s.query_id = NEW.query_id AND s.need_position = NEW.need_position AND s.position = NEW.selection_position
          AND s.role = 'selected' AND NEW.step_position BETWEEN e.first_position AND e.last_position));
    SELECT RAISE(ABORT, 'a step out of the selection names a step of the selection''s version before it, or out of the catalogue')
    WHERE NEW.kind IN ('prerequisite_out_of_catalogue', 'prepared_before', 'output_ready') AND NOT EXISTS (
        SELECT 1 FROM memory_recall_selections s JOIN memory_procedure_parts p ON p.route_id = s.route_id AND p.part_kind = 'step'
        WHERE s.query_id = NEW.query_id AND s.need_position = NEW.need_position AND s.position = NEW.selection_position
          AND p.first_position = NEW.step_position
          AND (NEW.kind = 'prerequisite_out_of_catalogue' OR NEW.step_position < s.first_position));
    SELECT RAISE(ABORT, 'an exclusion belongs to an excluded selection, and an excluded selection only states exclusions')
    WHERE (NEW.kind IN ('certain_conflict', 'constraint_excluded')) <> ((
        SELECT s.role FROM memory_recall_selections s WHERE s.query_id = NEW.query_id AND s.need_position = NEW.need_position
          AND s.position = NEW.selection_position) = 'excluded');
    SELECT RAISE(ABORT, 'a parameter requirement names a parameter of the selection''s version')
    WHERE NEW.parameter_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM memory_route_parameters r JOIN memory_recall_selections s ON s.route_id = r.route_id
        WHERE r.parameter_id = NEW.parameter_id AND s.query_id = NEW.query_id AND s.need_position = NEW.need_position
          AND s.position = NEW.selection_position);
END;

-- =============================================================================================================
-- Part 8. Mixed procedures, reconciliation and data contexts (version 19, plans P1 and P2 of the unified integration,
-- Documentation/Engine/MemoryProcedures.md). The facts a call's structured arguments and results, its data context, its
-- earlier table changes meaning. Every row is append-only; a later fact never rewrites an earlier one.
-- =============================================================================================================

-- P2-02: the fields of an adapter's argument object, as the call's end admits them, one row per leaf
-- with its JSON pointer. A field is a constant as recorded, a reference to the one result field of an earlier call of
-- the same attempt that held exactly its value (`result_reference`), or a value two or more earlier results held
-- (`ambiguous_reference`), which is never resolved implicitly. A withheld value keeps its reason, never its text.
CREATE TABLE memory_call_argument_fields (
    event_id TEXT NOT NULL REFERENCES memory_agent_actions(event_id),
    field_path TEXT NOT NULL CHECK (length(field_path) > 0 AND substr(field_path, 1, 1) = '/'),
    value_kind TEXT NOT NULL CHECK (value_kind IN ('text', 'number', 'boolean', 'null')),
    field_kind TEXT NOT NULL CHECK (field_kind IN ('constant', 'result_reference', 'ambiguous_reference')),
    text_value TEXT,
    withheld_reason TEXT CHECK (withheld_reason IS NULL OR withheld_reason IN ('declared_secret', 'credential_pattern', 'secret_target', 'secure_field',
        'unclassified_target', 'confidential_content')),
    source_event_id TEXT REFERENCES memory_agent_actions(event_id),
    source_path TEXT CHECK (source_path IS NULL OR (length(source_path) > 0 AND substr(source_path, 1, 1) = '/')),
    PRIMARY KEY (event_id, field_path),
    CHECK (withheld_reason IS NULL OR text_value IS NULL),
    CHECK (withheld_reason IS NOT NULL OR value_kind = 'null' OR text_value IS NOT NULL),
    CHECK ((field_kind = 'result_reference') = (source_event_id IS NOT NULL AND source_path IS NOT NULL)),
    CHECK (field_kind = 'result_reference' OR (source_event_id IS NULL AND source_path IS NULL)),
    CHECK (source_event_id IS NULL OR source_event_id <> event_id)
) STRICT;

-- P2-02: the fields of an adapter's result as the record may keep them, one row per leaf: an
-- identifier, a date, a flag or a count kept; a confidential or secret text withheld with its reason, never its value,
-- its length or a digest.
CREATE TABLE memory_call_result_fields (
    event_id TEXT NOT NULL REFERENCES memory_agent_actions(event_id),
    field_path TEXT NOT NULL CHECK (length(field_path) > 0 AND substr(field_path, 1, 1) = '/'),
    value_kind TEXT NOT NULL CHECK (value_kind IN ('text', 'number', 'boolean', 'null')),
    text_value TEXT,
    withheld_reason TEXT CHECK (withheld_reason IS NULL OR withheld_reason IN ('declared_secret', 'credential_pattern', 'secret_target', 'secure_field',
        'unclassified_target', 'confidential_content')),
    PRIMARY KEY (event_id, field_path),
    CHECK (withheld_reason IS NULL OR text_value IS NULL),
    CHECK (withheld_reason IS NOT NULL OR value_kind = 'null' OR text_value IS NOT NULL)
) STRICT;

-- P2-02: a field of a definition's adapter argument: a constant, a parameter of the version, a value the
-- definition keeps withheld, or the result field of an earlier step of the same version, which a run fills from its
-- own step's result and never from the episode it was learned from.
CREATE TABLE memory_operation_argument_fields (
    route_id TEXT NOT NULL,
    operation_id TEXT NOT NULL,
    argument_name TEXT NOT NULL CHECK (length(argument_name) > 0),
    argument_position INTEGER NOT NULL CHECK (argument_position >= 0),
    field_path TEXT NOT NULL CHECK (length(field_path) > 0 AND substr(field_path, 1, 1) = '/'),
    field_kind TEXT NOT NULL CHECK (field_kind IN ('constant', 'parameter', 'withheld', 'step_result')),
    value_kind TEXT NOT NULL CHECK (value_kind IN ('text', 'number', 'boolean', 'null')),
    text_value TEXT,
    parameter_id TEXT,
    source_step_position INTEGER CHECK (source_step_position IS NULL OR source_step_position >= 0),
    source_path TEXT CHECK (source_path IS NULL OR (length(source_path) > 0 AND substr(source_path, 1, 1) = '/')),
    PRIMARY KEY (operation_id, argument_name, argument_position, field_path),
    CHECK ((field_kind = 'parameter') = (parameter_id IS NOT NULL)),
    CHECK ((field_kind = 'step_result') = (source_step_position IS NOT NULL AND source_path IS NOT NULL)),
    CHECK (field_kind = 'step_result' OR (source_step_position IS NULL AND source_path IS NULL)),
    CHECK (field_kind = 'constant' OR text_value IS NULL),
    CHECK (field_kind <> 'constant' OR value_kind = 'null' OR text_value IS NOT NULL),
    FOREIGN KEY (route_id, operation_id) REFERENCES memory_step_operations(route_id, operation_id),
    FOREIGN KEY (route_id, parameter_id) REFERENCES memory_route_parameters(route_id, parameter_id)
) STRICT;

-- route, the profile, the account and the resource, each only when the call attests it. The account is a minimal
-- identifier (`account_ref`, sixteen hex digits of a digest salted per archive), never an address; a profile is the
-- instance a page was bound to; a resource is an item's kind and identifier. Unknown stays NULL, never inferred.
CREATE TABLE memory_call_data_contexts (
    event_id TEXT PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    service TEXT NOT NULL CHECK (length(service) > 0),
    route TEXT NOT NULL CHECK (route IN ('native', 'desktop', 'web', 'adapter')),
    profile_ref TEXT CHECK (profile_ref IS NULL OR length(profile_ref) > 0),
    account_ref TEXT CHECK (account_ref IS NULL OR length(account_ref) = 16),
    account_source TEXT NOT NULL CHECK (account_source IN ('argument', 'result', 'default', 'unknown')),
    resource_kind TEXT CHECK (resource_kind IS NULL OR length(resource_kind) > 0),
    resource_ref TEXT CHECK (resource_ref IS NULL OR length(resource_ref) > 0),
    CHECK ((account_source IN ('argument', 'result')) = (account_ref IS NOT NULL)),
    CHECK ((resource_kind IS NULL) = (resource_ref IS NULL))
) STRICT;

-- The salt of this archive's account identifiers: one random row, made the first time an account is noted.
CREATE TABLE memory_identity_salts (
    salt_id INTEGER PRIMARY KEY CHECK (salt_id = 1),
    salt BLOB NOT NULL CHECK (length(salt) = 32)
) STRICT;

-- P2-06: the processes that ran calls, one row per process instance, and the executor of each call, written with its
-- start. Whether an executor still runs is not a fact of the archive: its lock file says it (`MemoryExecutor`).
CREATE TABLE memory_executors (
    executor_id TEXT PRIMARY KEY CHECK (length(executor_id) > 0),
    source TEXT NOT NULL CHECK (length(source) > 0),
    process_id INTEGER NOT NULL CHECK (process_id > 0),
    started_at_ms INTEGER NOT NULL
) STRICT;

CREATE TABLE memory_call_executors (
    event_id TEXT PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    executor_id TEXT NOT NULL REFERENCES memory_executors(executor_id)
) STRICT;

-- P2-06: what later evidence says of an earlier call, appended in order, never rewriting the call's own end: its executor
-- ended while the call was started (`executor_terminated`), a result arrived after the call concluded
-- (`late_result`), a later completed call of the same attempt read whether the effect happened (`observed`, with its
-- finding and that call as evidence), or the person acknowledged it (`acknowledged`). A finding is the declarer's.
CREATE TABLE memory_call_reconciliations (
    event_id TEXT NOT NULL REFERENCES memory_agent_actions(event_id),
    sequence INTEGER NOT NULL CHECK (sequence >= 1),
    kind TEXT NOT NULL CHECK (kind IN ('executor_terminated', 'late_result', 'observed', 'acknowledged')),
    finding TEXT CHECK (finding IS NULL OR finding IN ('happened', 'not_happened', 'unknown')),
    evidence_event_id TEXT REFERENCES memory_agent_actions(event_id),
    declared_by TEXT NOT NULL CHECK (declared_by IN ('braus', 'agent', 'person')),
    recorded_at_ms INTEGER NOT NULL,
    detail TEXT CHECK (detail IS NULL OR (length(detail) > 0 AND length(CAST(detail AS BLOB)) <= 512)),
    PRIMARY KEY (event_id, sequence),
    CHECK ((kind = 'observed') = (evidence_event_id IS NOT NULL)),
    CHECK (kind IN ('observed', 'acknowledged') OR finding IS NULL),
    CHECK (kind <> 'observed' OR finding IS NOT NULL),
    CHECK (kind <> 'executor_terminated' OR declared_by = 'braus'),
    CHECK (evidence_event_id IS NULL OR evidence_event_id <> event_id)
) STRICT;


CREATE INDEX memory_call_result_fields_value ON memory_call_result_fields(text_value) WHERE text_value IS NOT NULL;
CREATE INDEX memory_call_reconciliations_evidence ON memory_call_reconciliations(evidence_event_id)
    WHERE evidence_event_id IS NOT NULL;

CREATE TRIGGER memory_call_argument_fields_immutable BEFORE UPDATE ON memory_call_argument_fields
BEGIN
    SELECT RAISE(ABORT, 'a call''s argument field is immutable');
END;
CREATE TRIGGER memory_call_argument_fields_kept BEFORE DELETE ON memory_call_argument_fields
BEGIN
    SELECT RAISE(ABORT, 'a call''s argument field is kept');
END;
CREATE TRIGGER memory_call_argument_fields_concluded_call BEFORE INSERT ON memory_call_argument_fields
BEGIN
    SELECT RAISE(ABORT, 'a call''s argument field belongs to a concluded call')
    WHERE (SELECT execution_status FROM memory_agent_actions WHERE event_id = NEW.event_id)
          NOT IN ('completed', 'failed', 'cancelled', 'interrupted');
END;
CREATE TRIGGER memory_call_result_fields_immutable BEFORE UPDATE ON memory_call_result_fields
BEGIN
    SELECT RAISE(ABORT, 'a call''s result field is immutable');
END;
CREATE TRIGGER memory_call_result_fields_kept BEFORE DELETE ON memory_call_result_fields
BEGIN
    SELECT RAISE(ABORT, 'a call''s result field is kept');
END;
CREATE TRIGGER memory_call_result_fields_concluded_call BEFORE INSERT ON memory_call_result_fields
BEGIN
    SELECT RAISE(ABORT, 'a call''s result field belongs to a concluded call')
    WHERE (SELECT execution_status FROM memory_agent_actions WHERE event_id = NEW.event_id)
          NOT IN ('completed', 'failed', 'cancelled', 'interrupted');
END;
CREATE TRIGGER memory_call_data_contexts_immutable BEFORE UPDATE ON memory_call_data_contexts
BEGIN
    SELECT RAISE(ABORT, 'a call''s data context is immutable');
END;
CREATE TRIGGER memory_call_data_contexts_kept BEFORE DELETE ON memory_call_data_contexts
BEGIN
    SELECT RAISE(ABORT, 'a call''s data context is kept');
END;
CREATE TRIGGER memory_call_data_contexts_concluded_call BEFORE INSERT ON memory_call_data_contexts
BEGIN
    SELECT RAISE(ABORT, 'a call''s data context belongs to a concluded call')
    WHERE (SELECT execution_status FROM memory_agent_actions WHERE event_id = NEW.event_id)
          NOT IN ('completed', 'failed', 'cancelled', 'interrupted');
END;
CREATE TRIGGER memory_operation_argument_fields_immutable BEFORE UPDATE ON memory_operation_argument_fields
BEGIN
    SELECT RAISE(ABORT, 'a definition''s argument field is immutable');
END;
CREATE TRIGGER memory_operation_argument_fields_kept BEFORE DELETE ON memory_operation_argument_fields
BEGIN
    SELECT RAISE(ABORT, 'a definition''s argument field is kept');
END;
CREATE TRIGGER memory_identity_salts_immutable BEFORE UPDATE ON memory_identity_salts
BEGIN
    SELECT RAISE(ABORT, 'the archive''s salt is immutable');
END;
CREATE TRIGGER memory_identity_salts_kept BEFORE DELETE ON memory_identity_salts
BEGIN
    SELECT RAISE(ABORT, 'the archive''s salt is kept');
END;
CREATE TRIGGER memory_executors_immutable BEFORE UPDATE ON memory_executors
BEGIN
    SELECT RAISE(ABORT, 'an executor is immutable');
END;
CREATE TRIGGER memory_executors_kept BEFORE DELETE ON memory_executors
BEGIN
    SELECT RAISE(ABORT, 'an executor is kept');
END;
CREATE TRIGGER memory_call_executors_immutable BEFORE UPDATE ON memory_call_executors
BEGIN
    SELECT RAISE(ABORT, 'a call''s executor is immutable');
END;
CREATE TRIGGER memory_call_executors_kept BEFORE DELETE ON memory_call_executors
BEGIN
    SELECT RAISE(ABORT, 'a call''s executor is kept');
END;
CREATE TRIGGER memory_call_reconciliations_immutable BEFORE UPDATE ON memory_call_reconciliations
BEGIN
    SELECT RAISE(ABORT, 'a reconciliation is immutable');
END;
CREATE TRIGGER memory_call_reconciliations_kept BEFORE DELETE ON memory_call_reconciliations
BEGIN
    SELECT RAISE(ABORT, 'a reconciliation is kept');
END;
CREATE TRIGGER memory_call_argument_fields_reference BEFORE INSERT ON memory_call_argument_fields
BEGIN
    SELECT RAISE(ABORT, 'a reference names a kept result field of an earlier call of the same attempt')
    WHERE NEW.field_kind = 'result_reference' AND NOT EXISTS (
        SELECT 1 FROM memory_call_result_fields r
        JOIN memory_task_events s ON s.event_id = NEW.source_event_id AND s.role = 'action'
        JOIN memory_task_events c ON c.event_id = NEW.event_id AND c.role = 'action'
                                 AND c.task_occurrence_id = s.task_occurrence_id
        WHERE r.event_id = NEW.source_event_id AND r.field_path = NEW.source_path AND r.withheld_reason IS NULL
          AND s.position < c.position);
END;
CREATE TRIGGER memory_operation_argument_fields_one_form BEFORE INSERT ON memory_operation_argument_fields
BEGIN
    SELECT RAISE(ABORT, 'a definition argument is a row, a template or fields, never two')
    WHERE EXISTS (SELECT 1 FROM memory_operation_arguments a WHERE a.operation_id = NEW.operation_id
                    AND a.argument_name = NEW.argument_name AND a.position = NEW.argument_position)
       OR EXISTS (SELECT 1 FROM memory_operation_argument_segments g WHERE g.operation_id = NEW.operation_id
                    AND g.argument_name = NEW.argument_name AND g.argument_position = NEW.argument_position);
    SELECT RAISE(ABORT, 'a step result names an earlier step of the same version')
    WHERE NEW.field_kind = 'step_result' AND NEW.source_step_position >= (
        SELECT p.first_position FROM memory_procedure_parts p JOIN memory_route_steps rs
          ON rs.route_id = p.route_id AND rs.step_id = p.step_id
        JOIN memory_step_operations o ON o.route_id = rs.route_id AND o.step_id = rs.step_id
        WHERE o.operation_id = NEW.operation_id AND p.part_kind = 'step');
END;
CREATE TRIGGER memory_call_reconciliations_order BEFORE INSERT ON memory_call_reconciliations
BEGIN
    SELECT RAISE(ABORT, 'a reconciliation follows the last one by one')
    WHERE NEW.sequence <> 1 + ifnull((SELECT max(sequence) FROM memory_call_reconciliations WHERE event_id = NEW.event_id), 0);
    SELECT RAISE(ABORT, 'an observation rests on a later completed call')
    WHERE NEW.evidence_event_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM memory_agent_actions e JOIN memory_agent_actions c ON c.event_id = NEW.event_id
        WHERE e.event_id = NEW.evidence_event_id AND e.execution_status = 'completed'
          AND e.started_at_ms IS NOT NULL AND c.started_at_ms IS NOT NULL AND e.started_at_ms >= c.started_at_ms);
END;
