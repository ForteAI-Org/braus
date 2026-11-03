-- Braus memory schema, version 22. Proposed resource; DB2 owns activation and migration.
-- tables: 163
-- triggers: 330
-- indexes: 91
-- STRICT tables; integer identities; the caller owns foreign keys and transaction boundaries.

-- section: tables
CREATE TABLE brain_apps (
    app_id INTEGER PRIMARY KEY,
    bundle_id TEXT NOT NULL UNIQUE,
    ingest_epoch INTEGER NOT NULL DEFAULT 0,
    last_epoch_advance_ms INTEGER
) STRICT;

CREATE TABLE brain_app_window_epochs (
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    window_family TEXT NOT NULL,
    epoch INTEGER NOT NULL CHECK (epoch >= 0),
    PRIMARY KEY (app_id, window_family)
) STRICT;

CREATE TABLE brain_app_contexts (
    context_id INTEGER PRIMARY KEY,
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    app_version TEXT NOT NULL DEFAULT '',
    app_locale TEXT NOT NULL DEFAULT '',
    UNIQUE (app_id, app_version, app_locale)
) STRICT;

CREATE TABLE brain_scenes (
    scene_id INTEGER PRIMARY KEY,
    scene_uuid TEXT NOT NULL UNIQUE,
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    window_title_pattern TEXT,
    title_bucket TEXT,
    scene_kind TEXT NOT NULL DEFAULT 'window'
        CHECK (scene_kind IN ('window', 'dialog', 'sheet', 'app')),
    structural_key TEXT,
    first_seen_ms INTEGER NOT NULL,
    last_seen_ms INTEGER NOT NULL,
    observation_count INTEGER NOT NULL DEFAULT 1 CHECK (observation_count >= 0),
    set_id INTEGER REFERENCES memory_element_sets(set_id),
    skeleton_digest BLOB CHECK (length(skeleton_digest) = 16),
    CHECK (last_seen_ms >= first_seen_ms),
    CHECK (scene_kind <> 'app' OR (structural_key IS NULL AND window_title_pattern IS NULL
                                    AND observation_count = 0))
) STRICT;

CREATE TABLE brain_scene_roles (
    scene_id INTEGER NOT NULL REFERENCES brain_scenes(scene_id),
    role TEXT NOT NULL,
    count_bucket INTEGER CHECK (count_bucket IS NULL OR count_bucket >= 0),
    PRIMARY KEY (scene_id, role)
) STRICT;

CREATE TABLE brain_scene_labels (
    scene_id INTEGER NOT NULL REFERENCES brain_scenes(scene_id),
    label_token TEXT NOT NULL,
    PRIMARY KEY (scene_id, label_token)
) STRICT;

CREATE TABLE brain_anchors (
    anchor_id INTEGER PRIMARY KEY,
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
    current_group_id INTEGER,
    retired_at_ms INTEGER,
    retired_epoch INTEGER CHECK (retired_epoch IS NULL OR retired_epoch >= 0),
    retirement_cause TEXT CHECK (retirement_cause IS NULL OR retirement_cause IN ('transient', 'stale', 'backstop', 'cap')),
    UNIQUE (app_id, insertion_order),
    CHECK (last_seen_ms >= first_seen_ms),
    CHECK ((retired_at_ms IS NULL) = (retired_epoch IS NULL)),
    CHECK ((retired_at_ms IS NULL) = (retirement_cause IS NULL)),
    CHECK (retired_at_ms IS NULL OR retired_at_ms >= last_seen_ms),
    FOREIGN KEY (current_group_id) REFERENCES brain_groups(group_id)
) STRICT;

CREATE TABLE brain_anchor_aliases (
    anchor_id INTEGER NOT NULL REFERENCES brain_anchors(anchor_id),
    alias TEXT NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    PRIMARY KEY (anchor_id, alias),
    UNIQUE (anchor_id, position)
) STRICT;

CREATE TABLE brain_anchor_states (
    anchor_id INTEGER NOT NULL REFERENCES brain_anchors(anchor_id),
    state TEXT NOT NULL,
    seen_count INTEGER NOT NULL CHECK (seen_count >= 0),
    PRIMARY KEY (anchor_id, state)
) STRICT;

CREATE TABLE brain_scene_elements (
    scene_element_id INTEGER PRIMARY KEY,
    app_id INTEGER NOT NULL,
    scene_id INTEGER NOT NULL,
    element_key TEXT NOT NULL,
    element_scope TEXT NOT NULL DEFAULT 'control'
        CHECK (element_scope IN ('container', 'control', 'collection', 'item_template')),
    parent_element_id INTEGER,
    edge_hash TEXT,
    cursor_affordance TEXT,
    anchor_id INTEGER,
    label TEXT,
    label_origin TEXT CHECK (label_origin IS NULL OR label_origin IN ('title', 'description', 'value', 'column', 'row_content', 'identifier', 'caption')),
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
    replaced_by_id INTEGER REFERENCES brain_scene_elements(scene_element_id),
    CHECK (parent_element_id IS NULL OR parent_element_id <> scene_element_id),
    CHECK (last_seen_ms >= first_seen_ms),
    FOREIGN KEY (parent_element_id) REFERENCES brain_scene_elements(scene_element_id),
    FOREIGN KEY (scene_id) REFERENCES brain_scenes(scene_id),
    FOREIGN KEY (anchor_id) REFERENCES brain_anchors(anchor_id)
) STRICT;

CREATE TABLE brain_groups (
    group_id INTEGER PRIMARY KEY,
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
    UNIQUE (app_id, insertion_order),
    CHECK ((retired_at_ms IS NULL) = (retired_epoch IS NULL)),
    CHECK ((retired_at_ms IS NULL) = (retirement_cause IS NULL)),
    CHECK (retired_at_ms IS NULL OR retired_at_ms >= last_seen_ms)
) STRICT;

CREATE TABLE brain_group_members (
    app_id INTEGER NOT NULL,
    group_id INTEGER NOT NULL,
    anchor_id INTEGER NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    PRIMARY KEY (group_id, anchor_id),
    UNIQUE (group_id, position),
    FOREIGN KEY (group_id) REFERENCES brain_groups(group_id),
    FOREIGN KEY (anchor_id) REFERENCES brain_anchors(anchor_id)
) STRICT;

CREATE TABLE brain_menu_commands (
    menu_command_id INTEGER PRIMARY KEY,
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
    CHECK (last_seen_ms >= first_seen_ms)
) STRICT;

CREATE TABLE brain_menu_path_segments (
    menu_command_id INTEGER NOT NULL REFERENCES brain_menu_commands(menu_command_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    title TEXT NOT NULL,
    PRIMARY KEY (menu_command_id, position)
) STRICT;

CREATE TABLE brain_transitions (
    transition_id INTEGER PRIMARY KEY,
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    insertion_order INTEGER NOT NULL CHECK (insertion_order >= 0),
    from_scene_id INTEGER NOT NULL,
    anchor_id INTEGER,
    scene_element_id INTEGER,
    menu_command_id INTEGER,
    trigger_kind TEXT NOT NULL,
    to_scene_id INTEGER,
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
    UNIQUE (app_id, insertion_order),
    CHECK ((anchor_id IS NOT NULL) + (scene_element_id IS NOT NULL) + (menu_command_id IS NOT NULL) <= 1),
    CHECK (last_seen_ms >= first_seen_ms),
    CHECK ((retired_at_ms IS NULL) = (retired_epoch IS NULL)),
    CHECK ((retired_at_ms IS NULL) = (retirement_cause IS NULL)),
    CHECK (retired_at_ms IS NULL OR retired_at_ms >= last_seen_ms),
    FOREIGN KEY (from_scene_id) REFERENCES brain_scenes(scene_id),
    FOREIGN KEY (to_scene_id) REFERENCES brain_scenes(scene_id),
    FOREIGN KEY (anchor_id) REFERENCES brain_anchors(anchor_id),
    FOREIGN KEY (menu_command_id) REFERENCES brain_menu_commands(menu_command_id),
    FOREIGN KEY (scene_element_id) REFERENCES brain_scene_elements(scene_element_id)
) STRICT;

CREATE TABLE brain_transition_menu_items (
    transition_id INTEGER NOT NULL REFERENCES brain_transitions(transition_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    title TEXT NOT NULL,
    PRIMARY KEY (transition_id, position)
) STRICT;

CREATE TABLE memory_events (
    event_id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_uuid TEXT NOT NULL UNIQUE,
    source TEXT NOT NULL CHECK (source IN ('app', 'cli', 'mcp', 'watcher', 'system')),
    source_stream_id TEXT NOT NULL,
    source_key TEXT,
    trace_id TEXT,
    session_id TEXT,
    parent_event_id INTEGER REFERENCES memory_events(event_id),
    parent_position INTEGER CHECK (parent_position IS NULL OR parent_position >= 0),
    event_kind TEXT NOT NULL CHECK (event_kind IN ('action', 'input', 'observation', 'verification', 'diagnostic')),
    app_id INTEGER REFERENCES brain_apps(app_id),
    context_id INTEGER,
    occurred_at_ms INTEGER NOT NULL,
    monotonic_ns INTEGER,
    capture_status TEXT NOT NULL
        CHECK (capture_status IN ('not_applicable', 'complete', 'partial', 'failed', 'unknown')),
    origin_event_id INTEGER REFERENCES memory_events(event_id),
    UNIQUE (source, source_stream_id, source_key),
    UNIQUE (parent_event_id, parent_position),
    CHECK ((parent_event_id IS NULL) = (parent_position IS NULL)),
    CHECK (parent_event_id IS NULL OR parent_event_id <> event_id),
    CHECK (context_id IS NULL OR app_id IS NOT NULL),
    CHECK (origin_event_id IS NULL OR event_kind = 'observation'),
    CHECK (origin_event_id IS NULL OR origin_event_id <> event_id),
    FOREIGN KEY (context_id) REFERENCES brain_app_contexts(context_id)
) STRICT;

CREATE TABLE memory_input_events (
    event_id INTEGER PRIMARY KEY REFERENCES memory_events(event_id),
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
    FOREIGN KEY (event_id) REFERENCES memory_events(event_id)
) STRICT;

CREATE TABLE memory_agent_actions (
    event_id INTEGER PRIMARY KEY REFERENCES memory_events(event_id),
    event_kind TEXT NOT NULL DEFAULT 'action' CHECK (event_kind = 'action'),
    app_id INTEGER,
    tool_kind TEXT NOT NULL,
    contract_version INTEGER NOT NULL DEFAULT 1 CHECK (contract_version > 0),
    execution_status TEXT NOT NULL CHECK (execution_status IN
        ('planned', 'started', 'completed', 'failed', 'cancelled', 'interrupted', 'skipped')),
    started_at_ms INTEGER,
    completed_at_ms INTEGER,
    duration_ms INTEGER CHECK (duration_ms IS NULL OR duration_ms >= 0),
    result_kind TEXT,
    result_message TEXT,
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
    gesture TEXT CHECK (gesture IN ('sent','not_sent','uncertain')),
    effect TEXT CHECK (effect IN ('confirmed','absent','unknown')),
    effect_reason TEXT CHECK (effect_reason IN ('still_changing','not_watched','not_classified','not_readable','not_applicable')),
    recovery TEXT CHECK (recovery IN ('continue','observe','do_not_repeat','change_target','ask_person','retry','postpone')),
    recovery_reason TEXT CHECK (recovery_reason IN ('not_found','ambiguous','unreachable','disabled','destructive','not_permitted')),
    outcome_origin TEXT CHECK (outcome_origin IN ('recorded','converted','converted_partial')),
    learnable INTEGER CHECK (learnable IN (0,1)),
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
    FOREIGN KEY (event_id) REFERENCES memory_events(event_id),
    CHECK (gesture IS NULL OR result_kind IS NULL),
    CHECK ((effect IS 'unknown') = (effect_reason IS NOT NULL)),
    CHECK ((recovery IS 'change_target') = (recovery_reason IS NOT NULL)),
    CHECK ((gesture IS NULL AND effect IS NULL AND recovery IS NULL AND outcome_origin IS NULL AND learnable IS NULL) OR (gesture IS NOT NULL AND effect IS NOT NULL AND recovery IS NOT NULL AND outcome_origin IS NOT NULL AND learnable IS NOT NULL))
) STRICT;

CREATE TABLE memory_agent_action_effect_labels (
    event_id INTEGER NOT NULL REFERENCES memory_agent_actions(event_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    label TEXT NOT NULL,
    PRIMARY KEY (event_id, position)
) STRICT;

CREATE TABLE memory_agent_action_status (
    event_id INTEGER PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    session_id TEXT,
    screen_recording INTEGER NOT NULL CHECK (screen_recording IN (0, 1)),
    accessibility INTEGER NOT NULL CHECK (accessibility IN (0, 1)),
    post_event INTEGER NOT NULL CHECK (post_event IN (0, 1))
) STRICT;

CREATE TABLE memory_agent_action_listings (
    event_id INTEGER PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    listing_kind TEXT NOT NULL CHECK (listing_kind IN ('windows', 'apps')),
    hidden_count INTEGER NOT NULL DEFAULT 0 CHECK (hidden_count >= 0)
) STRICT;

CREATE TABLE memory_agent_action_applications (
    listing_application_id INTEGER PRIMARY KEY,
    event_id INTEGER NOT NULL REFERENCES memory_agent_action_listings(event_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    name TEXT NOT NULL,
    bundle_id TEXT NOT NULL,
    pid INTEGER,
    app_version TEXT,
    is_running INTEGER CHECK (is_running IS NULL OR is_running IN (0, 1)),
    location TEXT,
    is_default_browser INTEGER CHECK (is_default_browser IS NULL OR is_default_browser IN (0, 1)),
    UNIQUE (event_id, position),
    CHECK (length(name) > 0 OR length(bundle_id) > 0)
) STRICT;

CREATE TABLE memory_agent_action_windows (
    event_id INTEGER NOT NULL,
    application_position INTEGER NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    window_number INTEGER NOT NULL,
    title TEXT,
    listing_application_id INTEGER NOT NULL,
    PRIMARY KEY (event_id, application_position, position),
    FOREIGN KEY (listing_application_id) REFERENCES memory_agent_action_applications(listing_application_id)
) STRICT;

CREATE TABLE memory_agent_action_observations (
    event_id INTEGER PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    session_id TEXT NOT NULL CHECK (length(session_id) > 0),
    session_revision INTEGER NOT NULL CHECK (session_revision >= 0),
    observed_at_ms INTEGER NOT NULL,
    sample_event_id INTEGER NOT NULL,
    sample_phase TEXT NOT NULL DEFAULT 'current' CHECK (sample_phase = 'current'),
    sample_ordinal INTEGER NOT NULL DEFAULT 0 CHECK (sample_ordinal >= 0),
    sample_observation_id INTEGER NOT NULL,
    sample_kind TEXT NOT NULL DEFAULT 'capture' CHECK (sample_kind = 'capture'),
    FOREIGN KEY (sample_observation_id) REFERENCES memory_event_observations(observation_id)
) STRICT;

-- window_number is the captured window, including the parent window for a sheet (BR2, ID6).
CREATE TABLE memory_event_observations (
    observation_id INTEGER PRIMARY KEY,
    event_id INTEGER NOT NULL REFERENCES memory_events(event_id),
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
    label_origin TEXT CHECK (label_origin IS NULL OR label_origin IN ('title', 'description', 'value', 'column', 'row_content', 'identifier', 'caption')),
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
    set_id INTEGER REFERENCES memory_element_sets(set_id),
    window_number INTEGER,
    window_subrole TEXT,
    reject_reason TEXT CHECK (reject_reason IN ('incomplete','uncertain_surface')),
    CHECK ((text_value IS NOT NULL) + (integer_value IS NOT NULL) +
           (real_value IS NOT NULL) + (boolean_value IS NOT NULL) <= 1),
    CHECK (parent_observation_id IS NULL OR parent_observation_id <> observation_id),
    CHECK (observation_kind <> 'capture'
           OR (parent_observation_id IS NULL AND status IN ('complete', 'partial', 'failed', 'unknown'))),
    FOREIGN KEY (parent_observation_id) REFERENCES memory_event_observations(observation_id)
) STRICT;

CREATE TABLE memory_event_scenes (
    event_id INTEGER NOT NULL,
    app_id INTEGER NOT NULL,
    phase TEXT NOT NULL CHECK (phase IN ('before', 'after', 'current')),
    sample_ordinal INTEGER NOT NULL DEFAULT 0 CHECK (sample_ordinal >= 0),
    scene_id INTEGER NOT NULL,
    match_status TEXT NOT NULL CHECK (match_status IN ('candidate', 'confirmed', 'rejected')),
    matched_by TEXT NOT NULL,
    matcher_version TEXT NOT NULL,
    confidence REAL CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
    PRIMARY KEY (event_id, phase, sample_ordinal, scene_id),
    FOREIGN KEY (event_id) REFERENCES memory_events(event_id),
    FOREIGN KEY (scene_id) REFERENCES brain_scenes(scene_id)
) STRICT;

CREATE TABLE memory_verifications (
    event_id INTEGER PRIMARY KEY REFERENCES memory_events(event_id),
    event_kind TEXT NOT NULL DEFAULT 'verification' CHECK (event_kind = 'verification'),
    step_occurrence_id INTEGER REFERENCES memory_step_occurrences(step_occurrence_id),
    scope TEXT NOT NULL,
    method TEXT NOT NULL,
    verdict TEXT NOT NULL CHECK (verdict IN ('passed', 'failed', 'unknown')),
    expected_text TEXT,
    observed_text TEXT,
    FOREIGN KEY (event_id) REFERENCES memory_events(event_id)
) STRICT;

CREATE TABLE memory_action_correlations (
    watcher_event_id INTEGER PRIMARY KEY REFERENCES memory_events(event_id),
    agent_event_id INTEGER NOT NULL REFERENCES memory_events(event_id),
    basis_kind TEXT NOT NULL,
    time_offset_ms REAL,
    explanation TEXT,
    CHECK (watcher_event_id <> agent_event_id)
) STRICT;

CREATE TABLE brain_applications (
    application_id INTEGER PRIMARY KEY,
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    event_id INTEGER NOT NULL,
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
    anchor_id INTEGER,
    transition_id INTEGER,
    evidence_count INTEGER CHECK (evidence_count IS NULL OR evidence_count >= 1),
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
    FOREIGN KEY (event_id) REFERENCES memory_events(event_id),
    FOREIGN KEY (sample_observation_id) REFERENCES memory_event_observations(observation_id),
    FOREIGN KEY (anchor_id) REFERENCES brain_anchors(anchor_id),
    FOREIGN KEY (transition_id) REFERENCES brain_transitions(transition_id)
) STRICT;

CREATE TABLE brain_evidence (
    evidence_id INTEGER PRIMARY KEY,
    app_id INTEGER NOT NULL,
    event_id INTEGER NOT NULL,
    relation TEXT NOT NULL CHECK (relation IN ('supports', 'contradicts')),
    assessed_by TEXT NOT NULL,
    assessment_version TEXT NOT NULL,
    assessed_at_ms INTEGER NOT NULL,
    scene_id INTEGER,
    anchor_id INTEGER,
    scene_element_id INTEGER,
    group_id INTEGER,
    menu_command_id INTEGER,
    transition_id INTEGER,
    CHECK ((scene_id IS NOT NULL) + (anchor_id IS NOT NULL) + (scene_element_id IS NOT NULL)
         + (group_id IS NOT NULL) + (menu_command_id IS NOT NULL) + (transition_id IS NOT NULL) = 1),
    FOREIGN KEY (event_id) REFERENCES memory_events(event_id),
    FOREIGN KEY (scene_id) REFERENCES brain_scenes(scene_id),
    FOREIGN KEY (anchor_id) REFERENCES brain_anchors(anchor_id),
    FOREIGN KEY (scene_element_id) REFERENCES brain_scene_elements(scene_element_id),
    FOREIGN KEY (group_id) REFERENCES brain_groups(group_id),
    FOREIGN KEY (menu_command_id) REFERENCES brain_menu_commands(menu_command_id),
    FOREIGN KEY (transition_id) REFERENCES brain_transitions(transition_id)
) STRICT;

CREATE TABLE memory_task_occurrences (
    task_occurrence_id INTEGER PRIMARY KEY,
    task_occurrence_uuid TEXT NOT NULL UNIQUE,
    trace_id TEXT,
    started_at_ms INTEGER NOT NULL,
    ended_at_ms INTEGER,
    status TEXT NOT NULL
        CHECK (status IN ('observed', 'in_progress', 'completed', 'failed', 'cancelled', 'interrupted', 'unknown')),
    CHECK (ended_at_ms IS NULL OR ended_at_ms >= started_at_ms)
) STRICT;

CREATE TABLE memory_task_events (
    task_occurrence_id INTEGER NOT NULL REFERENCES memory_task_occurrences(task_occurrence_id),
    event_id INTEGER NOT NULL REFERENCES memory_events(event_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    role TEXT NOT NULL CHECK (role IN ('observation', 'action', 'verification', 'context')),
    PRIMARY KEY (task_occurrence_id, event_id, role),
    UNIQUE (task_occurrence_id, position)
) STRICT;

CREATE TABLE memory_task_labels (
    label_id INTEGER PRIMARY KEY,
    task_occurrence_id INTEGER NOT NULL REFERENCES memory_task_occurrences(task_occurrence_id),
    label TEXT NOT NULL,
    assigned_by TEXT NOT NULL,
    confidence REAL CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
    status TEXT NOT NULL CHECK (status IN ('candidate', 'confirmed', 'rejected')),
    assigned_at_ms INTEGER NOT NULL
) STRICT;

CREATE TABLE memory_routes (
    route_id INTEGER PRIMARY KEY,
    route_uuid TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('draft', 'active', 'retired')),
    supersedes_route_id INTEGER REFERENCES memory_routes(route_id),
    created_at_ms INTEGER NOT NULL,
    last_used_ms INTEGER,
    demoted_at_ms INTEGER,
    demotion_cause TEXT,
    CHECK (supersedes_route_id IS NULL OR supersedes_route_id <> route_id)
) STRICT;

CREATE TABLE memory_route_parameters (
    parameter_id INTEGER PRIMARY KEY,
    route_id INTEGER NOT NULL REFERENCES memory_routes(route_id),
    name TEXT NOT NULL,
    direction TEXT NOT NULL CHECK (direction IN ('input', 'output', 'inout')),
    value_type TEXT NOT NULL CHECK (value_type IN ('text', 'integer', 'real', 'boolean')),
    is_required INTEGER NOT NULL CHECK (is_required IN (0, 1)),
    UNIQUE (route_id, name)
) STRICT;

CREATE TABLE memory_route_steps (
    step_id INTEGER PRIMARY KEY,
    route_id INTEGER NOT NULL REFERENCES memory_routes(route_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    step_kind TEXT NOT NULL CHECK (step_kind IN ('goal', 'route_call')),
    goal_text TEXT NOT NULL,
    app_id INTEGER REFERENCES brain_apps(app_id),
    called_route_id INTEGER REFERENCES memory_routes(route_id),
    actor TEXT NOT NULL DEFAULT 'agent' CHECK (actor IN ('agent','person')),
    segment_id INTEGER REFERENCES memory_person_segments(segment_id),
    person_evidence TEXT CHECK (person_evidence IN ('observed_net','unobserved','cause_ranked')),
    UNIQUE (route_id, position),
    CHECK (called_route_id IS NULL OR called_route_id <> route_id),
    CHECK ((step_kind = 'goal' AND called_route_id IS NULL)
        OR (step_kind = 'route_call' AND called_route_id IS NOT NULL)),
    CHECK ((actor = 'person') = (segment_id IS NOT NULL)),
    CHECK (actor <> 'person' OR step_kind = 'goal')
) STRICT;

CREATE TABLE memory_step_checks (
    check_id INTEGER PRIMARY KEY,
    route_id INTEGER NOT NULL,
    step_id INTEGER NOT NULL,
    app_id INTEGER REFERENCES brain_apps(app_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    check_kind TEXT NOT NULL,
    expected_scene_id INTEGER,
    expected_anchor_id INTEGER,
    expected_state TEXT,
    expected_text TEXT,
    expected_integer INTEGER,
    expected_real REAL,
    expected_bool INTEGER CHECK (expected_bool IN (0, 1)),
    expected_parameter_id INTEGER,
    comparison TEXT,
    UNIQUE (step_id, position),
    CHECK ((expected_state IS NOT NULL) + (expected_text IS NOT NULL) + (expected_integer IS NOT NULL)
         + (expected_real IS NOT NULL) + (expected_bool IS NOT NULL) + (expected_parameter_id IS NOT NULL) <= 1),
    CHECK ((expected_scene_id IS NULL AND expected_anchor_id IS NULL) OR app_id IS NOT NULL),
    FOREIGN KEY (step_id) REFERENCES memory_route_steps(step_id),
    FOREIGN KEY (expected_scene_id) REFERENCES brain_scenes(scene_id),
    FOREIGN KEY (expected_anchor_id) REFERENCES brain_anchors(anchor_id),
    FOREIGN KEY (expected_parameter_id) REFERENCES memory_route_parameters(parameter_id)
) STRICT;

CREATE TABLE memory_step_operations (
    operation_id INTEGER PRIMARY KEY,
    route_id INTEGER NOT NULL,
    step_id INTEGER NOT NULL,
    parent_operation_id INTEGER,
    position INTEGER NOT NULL CHECK (position >= 0),
    tool_kind TEXT NOT NULL,
    contract_version INTEGER NOT NULL DEFAULT 1 CHECK (contract_version > 0),
    app_id INTEGER REFERENCES brain_apps(app_id),
    CHECK (parent_operation_id IS NULL OR parent_operation_id <> operation_id),
    FOREIGN KEY (step_id) REFERENCES memory_route_steps(step_id),
    FOREIGN KEY (parent_operation_id) REFERENCES memory_step_operations(operation_id)
) STRICT;

CREATE TABLE memory_operation_arguments (
    argument_id INTEGER PRIMARY KEY,
    operation_id INTEGER REFERENCES memory_step_operations(operation_id),
    event_id INTEGER REFERENCES memory_agent_actions(event_id),
    brain_application_id INTEGER,
    route_id INTEGER,
    app_id INTEGER REFERENCES brain_apps(app_id),
    argument_name TEXT NOT NULL,
    position INTEGER NOT NULL DEFAULT 0 CHECK (position >= 0),
    value_kind TEXT NOT NULL CHECK (value_kind IN ('text', 'integer', 'real', 'boolean', 'parameter', 'anchor', 'menu')),
    text_value TEXT,
    integer_value INTEGER,
    real_value REAL,
    boolean_value INTEGER CHECK (boolean_value IN (0, 1)),
    parameter_id INTEGER,
    anchor_id INTEGER,
    menu_command_id INTEGER,
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
    FOREIGN KEY (operation_id) REFERENCES memory_step_operations(operation_id),
    FOREIGN KEY (parameter_id) REFERENCES memory_route_parameters(parameter_id),
    FOREIGN KEY (event_id) REFERENCES memory_agent_actions(event_id),
    FOREIGN KEY (anchor_id) REFERENCES brain_anchors(anchor_id),
    FOREIGN KEY (menu_command_id) REFERENCES brain_menu_commands(menu_command_id),
    FOREIGN KEY (brain_application_id) REFERENCES brain_applications(application_id) DEFERRABLE INITIALLY DEFERRED
) STRICT;

CREATE TABLE memory_route_call_bindings (
    step_id INTEGER NOT NULL,
    route_id INTEGER NOT NULL,
    called_route_id INTEGER NOT NULL,
    called_parameter_id INTEGER NOT NULL REFERENCES memory_route_parameters(parameter_id),
    source_parameter_id INTEGER REFERENCES memory_route_parameters(parameter_id),
    literal_text TEXT,
    literal_integer INTEGER,
    literal_real REAL,
    literal_bool INTEGER CHECK (literal_bool IN (0, 1)),
    PRIMARY KEY (step_id, called_parameter_id),
    CHECK ((source_parameter_id IS NOT NULL) + (literal_text IS NOT NULL)
         + (literal_integer IS NOT NULL) + (literal_real IS NOT NULL)
         + (literal_bool IS NOT NULL) = 1),
    FOREIGN KEY (step_id) REFERENCES memory_route_steps(step_id),
    FOREIGN KEY (called_parameter_id) REFERENCES memory_route_parameters(parameter_id),
    FOREIGN KEY (source_parameter_id) REFERENCES memory_route_parameters(parameter_id)
) STRICT;

CREATE TABLE memory_step_occurrences (
    step_occurrence_id INTEGER PRIMARY KEY,
    task_occurrence_id INTEGER REFERENCES memory_task_occurrences(task_occurrence_id),
    step_id INTEGER REFERENCES memory_route_steps(step_id),
    started_at_ms INTEGER NOT NULL,
    ended_at_ms INTEGER,
    status TEXT NOT NULL
        CHECK (status IN ('observed', 'in_progress', 'completed', 'failed', 'cancelled', 'interrupted', 'unknown')),
    assigned_by TEXT,
    CHECK (ended_at_ms IS NULL OR ended_at_ms >= started_at_ms)
) STRICT;

CREATE TABLE memory_step_events (
    step_occurrence_id INTEGER NOT NULL REFERENCES memory_step_occurrences(step_occurrence_id),
    event_id INTEGER NOT NULL REFERENCES memory_events(event_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    attempt_number INTEGER,
    role TEXT NOT NULL CHECK (role IN ('observation', 'action', 'verification', 'context')),
    PRIMARY KEY (step_occurrence_id, event_id, role),
    UNIQUE (step_occurrence_id, position)
) STRICT;

CREATE TABLE memory_route_evidence (
    route_id INTEGER NOT NULL REFERENCES memory_routes(route_id),
    task_occurrence_id INTEGER NOT NULL REFERENCES memory_task_occurrences(task_occurrence_id),
    relation TEXT NOT NULL CHECK (relation IN ('supports', 'contradicts')),
    assessed_by TEXT NOT NULL,
    assessed_at_ms INTEGER NOT NULL,
    PRIMARY KEY (route_id, task_occurrence_id, relation)
) STRICT;

CREATE TABLE memory_step_evidence (
    step_id INTEGER NOT NULL REFERENCES memory_route_steps(step_id),
    step_occurrence_id INTEGER NOT NULL,
    relation TEXT NOT NULL CHECK (relation IN ('supports', 'contradicts')),
    assessed_by TEXT NOT NULL,
    assessed_at_ms INTEGER NOT NULL,
    PRIMARY KEY (step_id, step_occurrence_id, relation),
    FOREIGN KEY (step_occurrence_id) REFERENCES memory_step_occurrences(step_occurrence_id)
) STRICT;

CREATE TABLE memory_experiences (
    experience_id INTEGER PRIMARY KEY,
    phrase TEXT NOT NULL,
    route_id INTEGER NOT NULL REFERENCES memory_routes(route_id),
    step_id INTEGER,
    created_at_ms INTEGER NOT NULL,
    FOREIGN KEY (step_id) REFERENCES memory_route_steps(step_id)
) STRICT;

CREATE TABLE memory_experience_bindings (
    experience_id INTEGER NOT NULL,
    route_id INTEGER NOT NULL,
    parameter_id INTEGER NOT NULL,
    value_type TEXT NOT NULL CHECK (value_type IN ('text', 'integer', 'real', 'boolean')),
    binding_kind TEXT NOT NULL CHECK (binding_kind IN ('literal', 'request_slot', 'context_slot')),
    binding_contract_version INTEGER NOT NULL DEFAULT 1 CHECK (binding_contract_version > 0),
    slot_name TEXT,
    literal_text TEXT,
    literal_integer INTEGER,
    literal_real REAL,
    literal_boolean INTEGER CHECK (literal_boolean IN (0, 1)),
    PRIMARY KEY (experience_id, parameter_id),
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
    ),
    FOREIGN KEY (experience_id) REFERENCES memory_experiences(experience_id),
    FOREIGN KEY (parameter_id) REFERENCES memory_route_parameters(parameter_id)
) STRICT;

CREATE TABLE memory_experience_uses (
    experience_id INTEGER NOT NULL REFERENCES memory_experiences(experience_id),
    event_id INTEGER NOT NULL REFERENCES memory_events(event_id),
    verdict TEXT NOT NULL CHECK (verdict IN ('passed', 'failed', 'unknown')),
    PRIMARY KEY (experience_id, event_id)
) STRICT;

CREATE TABLE memory_schema_migrations (
    to_version INTEGER PRIMARY KEY CHECK (to_version > 1),
    from_version INTEGER NOT NULL CHECK (from_version >= 0 AND from_version < to_version),
    migrated_at_ms INTEGER NOT NULL,
    copy_name TEXT,
    CHECK ((from_version = 0) = (copy_name IS NULL))
) STRICT;

CREATE TABLE memory_tasks (
    task_id INTEGER PRIMARY KEY,
    task_uuid TEXT NOT NULL UNIQUE,
    contract_version INTEGER NOT NULL CHECK (contract_version > 0),
    source TEXT NOT NULL CHECK (source IN ('app', 'cli', 'mcp', 'watcher', 'system')),
    source_stream_id TEXT NOT NULL CHECK (length(source_stream_id) > 0),
    trace_id TEXT,
    opened_at_ms INTEGER NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('open', 'completed', 'failed', 'abandoned', 'postponed')),
    closed_at_ms INTEGER,
    current_revision INTEGER NOT NULL CHECK (current_revision >= 1),
    CHECK ((status IN ('open', 'postponed')) = (closed_at_ms IS NULL)),
    CHECK (closed_at_ms IS NULL OR closed_at_ms >= opened_at_ms)
) STRICT;

CREATE TABLE memory_task_revisions (
    task_revision_id INTEGER PRIMARY KEY,
    task_id INTEGER NOT NULL REFERENCES memory_tasks(task_id),
    revision INTEGER NOT NULL CHECK (revision >= 1),
    recorded_at_ms INTEGER NOT NULL,
    change_kind TEXT NOT NULL CHECK (change_kind IN ('opened', 'revised')),
    reason TEXT,
    goal TEXT NOT NULL CHECK (length(goal) > 0),
    requested_result TEXT,
    UNIQUE (task_id, revision),
    CHECK ((revision = 1) = (change_kind = 'opened'))
) STRICT;

CREATE TABLE memory_task_constraints (
    task_id INTEGER NOT NULL,
    revision INTEGER NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    constraint_text TEXT NOT NULL CHECK (length(constraint_text) > 0),
    task_revision_id INTEGER NOT NULL,
    PRIMARY KEY (task_id, revision, position),
    FOREIGN KEY (task_revision_id) REFERENCES memory_task_revisions(task_revision_id)
) STRICT;

CREATE TABLE memory_task_message_refs (
    task_id INTEGER NOT NULL,
    revision INTEGER NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    message_ref TEXT NOT NULL CHECK (length(message_ref) > 0),
    task_revision_id INTEGER NOT NULL,
    PRIMARY KEY (task_id, revision, position),
    UNIQUE (task_id, revision, message_ref),
    FOREIGN KEY (task_revision_id) REFERENCES memory_task_revisions(task_revision_id)
) STRICT;

CREATE TABLE memory_task_attempts (
    task_occurrence_id INTEGER PRIMARY KEY REFERENCES memory_task_occurrences(task_occurrence_id),
    task_id INTEGER NOT NULL REFERENCES memory_tasks(task_id),
    ordinal INTEGER NOT NULL CHECK (ordinal >= 1),
    resumes_task_occurrence_id INTEGER REFERENCES memory_task_attempts(task_occurrence_id),
    source TEXT NOT NULL CHECK (source IN ('app', 'cli', 'mcp', 'watcher', 'system')),
    source_stream_id TEXT NOT NULL CHECK (length(source_stream_id) > 0),
    opened_at_ms INTEGER NOT NULL,
    opened_at_revision INTEGER NOT NULL,
    task_revision_id INTEGER NOT NULL,
    takeover TEXT NOT NULL DEFAULT 'none' CHECK (takeover IN ('none','person_episode')),
    UNIQUE (task_id, ordinal),
    CHECK ((ordinal = 1) = (resumes_task_occurrence_id IS NULL)),
    CHECK (resumes_task_occurrence_id IS NULL OR resumes_task_occurrence_id <> task_occurrence_id),
    FOREIGN KEY (task_revision_id) REFERENCES memory_task_revisions(task_revision_id)
) STRICT;

CREATE TABLE memory_task_checkpoints (
    checkpoint_id INTEGER PRIMARY KEY,
    task_occurrence_id INTEGER NOT NULL,
    sequence INTEGER NOT NULL CHECK (sequence >= 1),
    checkpoint_kind TEXT NOT NULL CHECK (checkpoint_kind IN ('checkpoint', 'end')),
    task_id INTEGER NOT NULL,
    revision INTEGER NOT NULL,
    recorded_at_ms INTEGER NOT NULL,
    declared_status TEXT CHECK (declared_status IS NULL OR declared_status IN ('completed', 'failed', 'abandoned')),
    note TEXT,
    task_revision_id INTEGER NOT NULL,
    UNIQUE (task_occurrence_id, sequence),
    CHECK ((checkpoint_kind = 'end') = (declared_status IS NOT NULL)),
    FOREIGN KEY (task_occurrence_id) REFERENCES memory_task_attempts(task_occurrence_id),
    FOREIGN KEY (task_revision_id) REFERENCES memory_task_revisions(task_revision_id)
) STRICT;

CREATE TABLE memory_task_values (
    value_id INTEGER PRIMARY KEY,
    task_id INTEGER NOT NULL REFERENCES memory_tasks(task_id),
    revision INTEGER,
    task_occurrence_id INTEGER,
    checkpoint_sequence INTEGER,
    position INTEGER NOT NULL CHECK (position >= 0),
    name TEXT NOT NULL CHECK (length(name) > 0),
    role TEXT,
    value_kind TEXT NOT NULL CHECK (value_kind IN ('text', 'number', 'boolean', 'file', 'folder', 'reference', 'missing')),
    content TEXT NOT NULL CHECK (content IN ('text', 'missing', 'withheld', 'reference')),
    text_value TEXT,
    sensitivity TEXT NOT NULL CHECK (sensitivity IN ('ordinary', 'personal', 'secret')),
    source TEXT NOT NULL CHECK (source IN ('request', 'message', 'observation', 'previous_output', 'derived', 'unknown', 'person')),
    source_ref TEXT,
    source_version TEXT,
    task_revision_id INTEGER,
    checkpoint_id INTEGER,
    value_digest BLOB CHECK (length(value_digest) = 16),
    CHECK ((revision IS NOT NULL) <> (checkpoint_sequence IS NOT NULL)),
    CHECK ((checkpoint_sequence IS NULL) = (task_occurrence_id IS NULL)),
    CHECK ((content = 'text') = (text_value IS NOT NULL)),
    CHECK ((value_kind = 'missing') = (content = 'missing')),
    CHECK (sensitivity = 'ordinary' OR content <> 'text'),
    CHECK (source <> 'previous_output' OR source_ref IS NOT NULL),
    FOREIGN KEY (task_revision_id) REFERENCES memory_task_revisions(task_revision_id),
    FOREIGN KEY (checkpoint_id) REFERENCES memory_task_checkpoints(checkpoint_id),
    CHECK (content NOT IN ('missing','withheld') OR value_digest IS NULL)
) STRICT;

CREATE TABLE memory_task_call_revisions (
    event_id INTEGER PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    task_occurrence_id INTEGER NOT NULL,
    task_id INTEGER NOT NULL,
    revision INTEGER NOT NULL,
    task_revision_id INTEGER NOT NULL,
    FOREIGN KEY (task_occurrence_id) REFERENCES memory_task_attempts(task_occurrence_id),
    FOREIGN KEY (task_revision_id) REFERENCES memory_task_revisions(task_revision_id)
) STRICT;

CREATE TABLE memory_call_effects (
    event_id INTEGER PRIMARY KEY REFERENCES memory_agent_actions(event_id),
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

CREATE TABLE memory_call_routes (
    event_id INTEGER PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    route TEXT NOT NULL CHECK (route IN ('native', 'desktop', 'web')),
    handoff_reason TEXT CHECK (handoff_reason IS NULL OR length(handoff_reason) > 0),
    CHECK (handoff_reason IS NULL OR route = 'desktop')
) STRICT;

CREATE TABLE memory_call_adapter_dispatches (
    event_id INTEGER PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    adapter TEXT NOT NULL CHECK (length(adapter) > 0),
    verb TEXT NOT NULL CHECK (length(verb) > 0)
) STRICT;

CREATE TABLE memory_call_rungs (
    event_id INTEGER PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    rung TEXT NOT NULL CHECK (rung IN ('accessibility', 'in_place', 'seat_public_process', 'seat_skylight_process',
                                       'seat_accessibility_action', 'web_input_event')),
    how TEXT NOT NULL CHECK (length(how) > 0),
    skipped TEXT CHECK (skipped IS NULL OR length(skipped) > 0)
) STRICT;

CREATE TABLE memory_call_route_advice (
    event_id INTEGER PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    decision TEXT NOT NULL CHECK (decision IN ('use', 'ask', 'open')),
    route TEXT CHECK (((decision = 'use') = (route IS NOT NULL)) AND (route IS NULL OR length(route) > 0)),
    message TEXT NOT NULL CHECK (length(message) > 0)
) STRICT;

CREATE TABLE memory_operation_verifications (
    event_id INTEGER PRIMARY KEY REFERENCES memory_verifications(event_id),
    call_event_id INTEGER NOT NULL REFERENCES memory_agent_actions(event_id),
    contract_version INTEGER NOT NULL CHECK (contract_version > 0),
    condition_kind TEXT NOT NULL CHECK (condition_kind IN ('requested_state_already_present', 'state_after_gesture',
        'value_read_back', 'structural_effect', 'menu_closed_after_choice', 'submenu_opened', 'window_set_changed',
        'recovery_instead_of_request', 'menu_item_chosen', 'none', 'adapter_effect', 'adapter_read', 'state_read_back')),
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
    event_id INTEGER NOT NULL REFERENCES memory_operation_verifications(event_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    limit_kind TEXT NOT NULL CHECK (limit_kind IN ('delivery_uncertain', 'no_after_scene', 'readback_unavailable',
        'previous_value_unknown', 'no_expectation', 'window_wide', 'command_effect_unchecked', 'label_match_only',
        'no_expected_value', 'target_not_resolved', 'unattributed', 'value_withheld', 'settle_capped',
        'settle_unwatched', 'instance_value', 'outside_target_scope', 'self_changing_seen', 'partial_capture')),
    PRIMARY KEY (event_id, position),
    UNIQUE (event_id, limit_kind)
) STRICT;

CREATE TABLE memory_operation_verification_samples (
    event_id INTEGER NOT NULL REFERENCES memory_operation_verifications(event_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    sample_observation_id INTEGER NOT NULL,
    sample_event_id INTEGER NOT NULL,
    sample_phase TEXT NOT NULL CHECK (sample_phase IN ('before', 'menu', 'after', 'current')),
    sample_ordinal INTEGER NOT NULL CHECK (sample_ordinal >= 0),
    sample_kind TEXT NOT NULL DEFAULT 'capture' CHECK (sample_kind = 'capture'),
    PRIMARY KEY (event_id, position),
    UNIQUE (event_id, sample_event_id, sample_phase, sample_ordinal),
    FOREIGN KEY (sample_observation_id) REFERENCES memory_event_observations(observation_id)
) STRICT;

CREATE TABLE memory_call_recording_gaps (
    event_id INTEGER NOT NULL REFERENCES memory_agent_actions(event_id),
    part TEXT NOT NULL CHECK (part IN ('samples', 'effect', 'verification')),
    reason TEXT NOT NULL CHECK (reason IN ('refused', 'conflict')),
    detail TEXT CHECK (detail IS NULL OR (length(detail) > 0 AND length(CAST(detail AS BLOB)) <= 512)),
    PRIMARY KEY (event_id, part)
) STRICT;

CREATE TABLE memory_value_redactions (
    redaction_id INTEGER PRIMARY KEY,
    event_id INTEGER NOT NULL REFERENCES memory_events(event_id),
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
    set_id INTEGER REFERENCES memory_element_sets(set_id),
    set_position INTEGER CHECK (set_position >= 0),
    CHECK ((location_kind = 'argument') = (argument_name IS NOT NULL AND argument_position IS NOT NULL)),
    CHECK (location_kind = 'argument' OR (argument_name IS NULL AND argument_position IS NULL)),
    CHECK ((location_kind IN ('verification_expected', 'verification_observed')) = (condition_kind IS NOT NULL)),
    CHECK ((location_kind IN ('sample_label', 'sample_container', 'sample_title'))
        = (sample_phase IS NOT NULL AND sample_ordinal IS NOT NULL)),
    CHECK ((location_kind IN ('sample_label', 'sample_container', 'listing_entry')) = (element_position IS NOT NULL)),
    CHECK ((set_id IS NULL) = (set_position IS NULL))
) STRICT;

CREATE TABLE memory_archive_origins (
    origin_id INTEGER PRIMARY KEY,
    origin_uuid TEXT NOT NULL UNIQUE,
    origin_kind TEXT NOT NULL CHECK (origin_kind IN ('mcp_profile', 'previous_product', 'archive_import')),
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
    origin_id INTEGER NOT NULL REFERENCES memory_archive_origins(origin_id),
    source_event_id TEXT NOT NULL CHECK (length(source_event_id) > 0),
    event_id INTEGER NOT NULL REFERENCES memory_events(event_id),
    disposition TEXT NOT NULL CHECK (disposition IN ('added', 'duplicate', 'renamed')),
    PRIMARY KEY (origin_id, source_event_id),
    UNIQUE (origin_id, event_id),
    CHECK (length(source_event_id) > 0)
) STRICT;

CREATE TABLE memory_origin_brain_contributions (
    origin_id INTEGER NOT NULL REFERENCES memory_archive_origins(origin_id),
    bundle_id TEXT NOT NULL CHECK (length(bundle_id) > 0),
    element_kind TEXT NOT NULL CHECK (element_kind IN ('anchor', 'group', 'transition', 'application')),
    element_key TEXT NOT NULL CHECK (length(element_key) > 0),
    disposition TEXT NOT NULL CHECK (disposition IN ('added', 'present', 'excluded')),
    withheld INTEGER NOT NULL DEFAULT 0 CHECK (withheld IN (0, 1)),
    PRIMARY KEY (origin_id, bundle_id, element_kind, element_key)
) STRICT;

CREATE TABLE memory_procedure_candidates (
    candidate_id INTEGER PRIMARY KEY,
    task_id INTEGER NOT NULL,
    task_occurrence_id INTEGER NOT NULL,
    policy_version TEXT NOT NULL CHECK (length(policy_version) > 0),
    structure_digest BLOB NOT NULL CHECK (length(structure_digest) = 16),
    checkpoint_sequence INTEGER,
    built_at_ms INTEGER NOT NULL,
    step_count INTEGER NOT NULL CHECK (step_count >= 1),
    block_count INTEGER NOT NULL CHECK (block_count >= 1),
    checkpoint_id INTEGER,
    UNIQUE (task_occurrence_id, policy_version, structure_digest),
    CHECK (block_count <= step_count),
    FOREIGN KEY (task_occurrence_id) REFERENCES memory_task_attempts(task_occurrence_id),
    FOREIGN KEY (checkpoint_id) REFERENCES memory_task_checkpoints(checkpoint_id)
) STRICT;

CREATE TABLE memory_candidate_steps (
    candidate_id INTEGER NOT NULL REFERENCES memory_procedure_candidates(candidate_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    step_occurrence_id INTEGER REFERENCES memory_step_occurrences(step_occurrence_id),
    call_event_id INTEGER REFERENCES memory_agent_actions(event_id),
    block_index INTEGER NOT NULL CHECK (block_index >= 0),
    app_id INTEGER REFERENCES brain_apps(app_id),
    step_kind TEXT NOT NULL DEFAULT 'operation'
        CHECK (step_kind IN ('operation', 'adapter_call', 'required_read', 'person_only', 'capability_call')),
    actor TEXT NOT NULL DEFAULT 'agent' CHECK (actor IN ('agent','person')),
    segment_id INTEGER REFERENCES memory_person_segments(segment_id),
    person_evidence TEXT CHECK (person_evidence IN ('observed_net','unobserved','cause_ranked')),
    PRIMARY KEY (candidate_id, position),
    UNIQUE (candidate_id, call_event_id),
    UNIQUE (candidate_id, step_occurrence_id),
    CHECK ((actor = 'person') = (segment_id IS NOT NULL)),
    CHECK ((actor = 'person') = (call_event_id IS NULL)),
    CHECK (actor <> 'person' OR step_occurrence_id IS NULL)
) STRICT;

CREATE TABLE memory_procedure_interpretations (
    interpretation_id INTEGER PRIMARY KEY,
    candidate_id INTEGER NOT NULL REFERENCES memory_procedure_candidates(candidate_id),
    revision INTEGER NOT NULL CHECK (revision >= 1),
    contract_version INTEGER NOT NULL CHECK (contract_version > 0),
    payload_digest BLOB NOT NULL CHECK (length(payload_digest) = 16),
    source TEXT NOT NULL CHECK (source IN ('app', 'cli', 'mcp', 'watcher', 'system')),
    source_stream_id TEXT NOT NULL CHECK (length(source_stream_id) > 0),
    task_revision INTEGER NOT NULL CHECK (task_revision >= 1),
    attempt_state TEXT NOT NULL CHECK (attempt_state IN ('running', 'ended', 'interrupted')),
    recorded_at_ms INTEGER NOT NULL,
    UNIQUE (candidate_id, revision)
) STRICT;

CREATE TABLE memory_interpretation_findings (
    interpretation_id INTEGER NOT NULL REFERENCES memory_procedure_interpretations(interpretation_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    finding TEXT NOT NULL CHECK (finding IN ('use_mismatch', 'unverifiable_use')),
    step_position INTEGER NOT NULL CHECK (step_position >= 0),
    argument_name TEXT NOT NULL CHECK (length(argument_name) > 0),
    argument_position INTEGER NOT NULL CHECK (argument_position >= 0),
    PRIMARY KEY (interpretation_id, position)
) STRICT;

CREATE TABLE memory_procedure_versions (
    route_id INTEGER PRIMARY KEY REFERENCES memory_routes(route_id),
    interpretation_id INTEGER NOT NULL UNIQUE REFERENCES memory_procedure_interpretations(interpretation_id),
    candidate_id INTEGER NOT NULL,
    task_id INTEGER NOT NULL,
    task_occurrence_id INTEGER NOT NULL,
    contract_version INTEGER NOT NULL CHECK (contract_version > 0),
    variant_of_route_id INTEGER REFERENCES memory_procedure_versions(route_id),
    divergence_position INTEGER CHECK (divergence_position IS NULL OR divergence_position >= 0),
    built_at_ms INTEGER NOT NULL,
    CHECK ((variant_of_route_id IS NULL) = (divergence_position IS NULL)),
    CHECK (variant_of_route_id IS NULL OR variant_of_route_id <> route_id),
    FOREIGN KEY (candidate_id) REFERENCES memory_procedure_candidates(candidate_id),
    FOREIGN KEY (task_occurrence_id) REFERENCES memory_task_attempts(task_occurrence_id)
) STRICT;

CREATE TABLE memory_procedure_parts (
    part_id INTEGER PRIMARY KEY,
    part_uuid TEXT NOT NULL UNIQUE,
    route_id INTEGER NOT NULL REFERENCES memory_procedure_versions(route_id),
    part_kind TEXT NOT NULL CHECK (part_kind IN ('procedure', 'subprocedure', 'step')),
    parent_part_id INTEGER,
    first_position INTEGER NOT NULL CHECK (first_position >= 0),
    last_position INTEGER NOT NULL,
    step_id INTEGER,
    app_id INTEGER REFERENCES brain_apps(app_id),
    label TEXT CHECK (label IS NULL OR length(label) > 0),
    declared_outcome TEXT NOT NULL CHECK (declared_outcome IN ('completed', 'failed', 'not_completed', 'not_declared')),
    UNIQUE (route_id, part_kind, first_position, last_position),
    CHECK (last_position >= first_position),
    CHECK ((part_kind = 'procedure') = (parent_part_id IS NULL)),
    CHECK ((part_kind = 'step') = (step_id IS NOT NULL)),
    CHECK (part_kind <> 'step' OR first_position = last_position),
    CHECK (part_kind <> 'procedure' OR label IS NOT NULL),
    FOREIGN KEY (parent_part_id) REFERENCES memory_procedure_parts(part_id),
    FOREIGN KEY (step_id) REFERENCES memory_route_steps(step_id)
) STRICT;

CREATE TABLE memory_part_contract_items (
    part_id INTEGER NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    route_id INTEGER NOT NULL,
    item_kind TEXT NOT NULL CHECK (item_kind IN ('input', 'output', 'application', 'entry_state')),
    parameter_id INTEGER,
    app_id INTEGER REFERENCES brain_apps(app_id),
    scene_id INTEGER,
    PRIMARY KEY (part_id, position),
    CHECK ((item_kind IN ('input', 'output')) = (parameter_id IS NOT NULL)),
    CHECK ((item_kind IN ('application', 'entry_state')) = (app_id IS NOT NULL)),
    CHECK (scene_id IS NULL OR item_kind = 'entry_state'),
    FOREIGN KEY (part_id) REFERENCES memory_procedure_parts(part_id),
    FOREIGN KEY (parameter_id) REFERENCES memory_route_parameters(parameter_id),
    FOREIGN KEY (scene_id) REFERENCES brain_scenes(scene_id)
) STRICT;

CREATE TABLE memory_parameter_details (
    parameter_id INTEGER PRIMARY KEY,
    route_id INTEGER NOT NULL,
    role TEXT NOT NULL CHECK (length(role) > 0),
    value_kind TEXT NOT NULL CHECK (value_kind IN ('text', 'number', 'boolean', 'file', 'folder', 'reference')),
    unit TEXT CHECK (unit IS NULL OR length(unit) > 0),
    sensitivity TEXT NOT NULL CHECK (sensitivity IN ('ordinary', 'personal', 'secret')),
    produced_by_part_id INTEGER,
    FOREIGN KEY (parameter_id) REFERENCES memory_route_parameters(parameter_id),
    FOREIGN KEY (produced_by_part_id) REFERENCES memory_procedure_parts(part_id)
) STRICT;

CREATE TABLE memory_operation_argument_segments (
    route_id INTEGER NOT NULL,
    operation_id INTEGER NOT NULL,
    argument_name TEXT NOT NULL CHECK (length(argument_name) > 0),
    argument_position INTEGER NOT NULL CHECK (argument_position >= 0),
    argument_index INTEGER NOT NULL CHECK (argument_index >= 0),
    segment_position INTEGER NOT NULL CHECK (segment_position >= 0),
    segment_kind TEXT NOT NULL CHECK (segment_kind IN ('literal', 'parameter')),
    literal_text TEXT,
    parameter_id INTEGER,
    PRIMARY KEY (operation_id, argument_name, argument_position, segment_position),
    CHECK ((segment_kind = 'literal') = (literal_text IS NOT NULL)),
    CHECK ((segment_kind = 'parameter') = (parameter_id IS NOT NULL)),
    CHECK (literal_text IS NULL OR length(literal_text) > 0),
    FOREIGN KEY (operation_id) REFERENCES memory_step_operations(operation_id),
    FOREIGN KEY (parameter_id) REFERENCES memory_route_parameters(parameter_id)
) STRICT;

CREATE TABLE memory_parameter_bindings (
    parameter_id INTEGER NOT NULL,
    route_id INTEGER NOT NULL,
    task_occurrence_id INTEGER NOT NULL REFERENCES memory_task_attempts(task_occurrence_id),
    content TEXT NOT NULL CHECK (content IN ('text', 'missing', 'withheld', 'reference')),
    text_value TEXT,
    source TEXT NOT NULL CHECK (source IN ('request', 'message', 'observation', 'previous_output', 'derived', 'unknown', 'person')),
    source_ref TEXT,
    source_version TEXT,
    value_digest BLOB CHECK (length(value_digest) = 16),
    PRIMARY KEY (parameter_id, task_occurrence_id),
    CHECK ((content = 'text') = (text_value IS NOT NULL)),
    CHECK (source <> 'previous_output' OR source_ref IS NOT NULL),
    FOREIGN KEY (parameter_id) REFERENCES memory_route_parameters(parameter_id),
    CHECK (content NOT IN ('missing','withheld') OR value_digest IS NULL)
) STRICT;

CREATE TABLE memory_procedure_step_occurrences (
    route_id INTEGER NOT NULL,
    step_id INTEGER NOT NULL,
    step_occurrence_id INTEGER NOT NULL REFERENCES memory_step_occurrences(step_occurrence_id),
    PRIMARY KEY (route_id, step_id),
    UNIQUE (route_id, step_occurrence_id),
    FOREIGN KEY (step_id) REFERENCES memory_route_steps(step_id)
) STRICT;

CREATE TABLE memory_qualification_policies (
    policy_id INTEGER PRIMARY KEY,
    policy_version TEXT NOT NULL UNIQUE CHECK (length(policy_version) > 0),
    status TEXT NOT NULL CHECK (status IN ('active', 'quarantined')),
    changed_at_ms INTEGER NOT NULL,
    reason TEXT,
    CHECK ((status = 'quarantined') = (reason IS NOT NULL)),
    CHECK (reason IS NULL OR length(reason) > 0)
) STRICT;

CREATE TABLE memory_part_qualifications (
    qualification_id INTEGER PRIMARY KEY,
    part_id INTEGER NOT NULL REFERENCES memory_procedure_parts(part_id),
    sequence INTEGER NOT NULL CHECK (sequence >= 1),
    policy_id INTEGER NOT NULL REFERENCES memory_qualification_policies(policy_id),
    verdict TEXT NOT NULL CHECK (verdict IN ('admitted', 'refused')),
    evaluated_at_ms INTEGER NOT NULL,
    complete INTEGER NOT NULL DEFAULT 1 CHECK (complete IN (0,1)),
    UNIQUE (part_id, sequence)
) STRICT;

CREATE TABLE memory_part_qualification_reasons (
    part_id INTEGER NOT NULL,
    sequence INTEGER NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    reason TEXT NOT NULL CHECK (reason IN ('missing_label', 'completion_not_declared', 'declared_failed',
        'declared_late', 'call_incomplete', 'call_failed', 'call_cancelled', 'call_interrupted', 'recording_gap',
        'no_verification', 'verification_failed', 'verification_unknown', 'verification_not_positive',
        'use_mismatch', 'unverifiable_use', 'missing_input', 'withheld_literal', 'adapter_unverified',
        'read_without_result', 'reference_unresolved')),
    step_position INTEGER CHECK (step_position IS NULL OR step_position >= 0),
    call_event_id INTEGER REFERENCES memory_agent_actions(event_id),
    qualification_id INTEGER NOT NULL,
    PRIMARY KEY (part_id, sequence, position),
    UNIQUE (part_id, sequence, reason, step_position),
    FOREIGN KEY (qualification_id) REFERENCES memory_part_qualifications(qualification_id)
) STRICT;

CREATE TABLE memory_part_qualification_evidence (
    part_id INTEGER NOT NULL,
    sequence INTEGER NOT NULL,
    step_position INTEGER NOT NULL CHECK (step_position >= 0),
    call_event_id INTEGER NOT NULL REFERENCES memory_agent_actions(event_id),
    verification_event_id INTEGER NOT NULL REFERENCES memory_operation_verifications(event_id),
    origin TEXT NOT NULL DEFAULT 'own' CHECK (origin IN ('own', 'inherited')),
    qualification_id INTEGER NOT NULL,
    PRIMARY KEY (part_id, sequence, call_event_id),
    FOREIGN KEY (qualification_id) REFERENCES memory_part_qualifications(qualification_id)
) STRICT;

CREATE TABLE memory_part_states (
    part_id INTEGER NOT NULL REFERENCES memory_procedure_parts(part_id),
    sequence INTEGER NOT NULL CHECK (sequence >= 1),
    state TEXT NOT NULL CHECK (state IN ('usable', 'to_reevaluate', 'retired')),
    reason_code TEXT NOT NULL CHECK (reason_code IN ('qualified', 'requalified', 'policy_quarantined', 'superseded', 'judged_wrong', 'retired_by_person', 'retired_by_curation', 'forgotten_by_person', 'merged_same_screen', 'split_distinct_surfaces', 'imported', 'migrated')),
    recorded_at_ms INTEGER NOT NULL,
    recorded_by TEXT NOT NULL CHECK (recorded_by IN ('braus', 'person', 'import')),
    origin_id INTEGER REFERENCES memory_archive_origins(origin_id),
    PRIMARY KEY (part_id, sequence),
    CHECK ((recorded_by = 'import') = (origin_id IS NOT NULL))
) STRICT;

CREATE TABLE brain_relations (
    relation_id INTEGER PRIMARY KEY,
    relation_uuid TEXT NOT NULL UNIQUE,
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    context_id INTEGER,
    from_scene_id INTEGER,
    scene_element_id INTEGER,
    verb TEXT NOT NULL CHECK (verb IN ('click', 'double_click', 'triple_click', 'right_click', 'set_toggle', 'select',
        'type_text', 'insert_text', 'press_key', 'scroll', 'drag', 'context_menu', 'menu', 'press')),
    arguments_key TEXT NOT NULL,
    to_scene_id INTEGER,
    outcome TEXT NOT NULL CHECK (outcome IN ('effect', 'state_set', 'already_satisfied', 'value_set', 'item_chosen',
        'window_set_changed')),
    effect_kind TEXT CHECK (effect_kind IS NULL OR effect_kind IN ('windowTitleChanged', 'stateFlip', 'menuOpened',
        'elementsAppeared', 'elementsDisappeared', 'textSelectionChanged', 'valueChanged')),
    first_seen_ms INTEGER NOT NULL,
    last_seen_ms INTEGER NOT NULL,
    kind_id INTEGER REFERENCES brain_screen_kinds(kind_id),
    element_key_id INTEGER REFERENCES brain_element_keys(element_key_id),
    CHECK ((outcome = 'effect') = (effect_kind IS NOT NULL)),
    CHECK (kind_id IS NOT NULL OR outcome <> 'already_satisfied' OR to_scene_id IS from_scene_id),
    CHECK (scene_element_id IS NULL OR element_key_id IS NOT NULL),
    CHECK (last_seen_ms >= first_seen_ms),
    FOREIGN KEY (context_id) REFERENCES brain_app_contexts(context_id),
    FOREIGN KEY (from_scene_id) REFERENCES brain_scenes(scene_id),
    FOREIGN KEY (to_scene_id) REFERENCES brain_scenes(scene_id),
    FOREIGN KEY (scene_element_id) REFERENCES brain_scene_elements(scene_element_id),
    CHECK ((kind_id IS NULL AND from_scene_id IS NOT NULL) OR (kind_id IS NOT NULL AND from_scene_id IS NULL AND to_scene_id IS NULL))
) STRICT;

CREATE TABLE brain_relation_proofs (
    relation_id INTEGER NOT NULL REFERENCES brain_relations(relation_id),
    call_event_id INTEGER NOT NULL REFERENCES memory_agent_actions(event_id),
    relation TEXT NOT NULL CHECK (relation IN ('supports', 'contradicts')),
    verification_event_id INTEGER NOT NULL REFERENCES memory_operation_verifications(event_id),
    policy_version TEXT NOT NULL CHECK (length(policy_version) > 0),
    assessed_at_ms INTEGER NOT NULL,
    to_scene_id INTEGER REFERENCES brain_scenes(scene_id),
    PRIMARY KEY (relation_id, call_event_id)
) STRICT;

CREATE TABLE brain_relation_applications (
    call_event_id INTEGER PRIMARY KEY REFERENCES memory_agent_actions(event_id),
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

CREATE TABLE brain_scene_shapes (
    scene_id INTEGER PRIMARY KEY,
    app_id INTEGER NOT NULL,
    role_key TEXT NOT NULL,
    FOREIGN KEY (scene_id) REFERENCES brain_scenes(scene_id)
) STRICT;

CREATE TABLE brain_relation_evaluations (
    evaluation_id INTEGER PRIMARY KEY,
    call_event_id INTEGER NOT NULL REFERENCES memory_agent_actions(event_id),
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
    UNIQUE (call_event_id, sequence),
    CHECK ((outcome = 'excluded') = (reason IS NOT NULL)),
    CHECK (recoverable = 0 OR outcome = 'excluded'),
    CHECK ((group_key IS NOT NULL) = (reason IS 'nothing_to_contradict')),
    CHECK (expected_effect_kind IS NULL OR group_key IS NOT NULL)
) STRICT;

CREATE TABLE brain_relation_evidence (
    relation_id INTEGER NOT NULL REFERENCES brain_relations(relation_id),
    call_event_id INTEGER NOT NULL,
    sequence INTEGER NOT NULL,
    relation TEXT NOT NULL CHECK (relation IN ('supports', 'contradicts')),
    verification_event_id INTEGER NOT NULL REFERENCES memory_operation_verifications(event_id),
    policy_version TEXT NOT NULL CHECK (length(policy_version) > 0),
    assessed_at_ms INTEGER NOT NULL,
    evaluation_id INTEGER NOT NULL,
    PRIMARY KEY (relation_id, call_event_id, sequence),
    FOREIGN KEY (evaluation_id) REFERENCES brain_relation_evaluations(evaluation_id)
) STRICT;

CREATE TABLE brain_anchor_label_keys (
    label_key_id INTEGER PRIMARY KEY,
    anchor_id INTEGER NOT NULL REFERENCES brain_anchors(anchor_id),
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    label_key TEXT NOT NULL CHECK (length(label_key) > 0),
    replaced_by_id INTEGER REFERENCES brain_anchor_label_keys(label_key_id)
) STRICT;

CREATE TABLE memory_variant_prefixes (
    route_id INTEGER PRIMARY KEY REFERENCES memory_procedure_versions(route_id),
    status TEXT NOT NULL CHECK (status IN ('verified', 'suggested')),
    compared_steps INTEGER NOT NULL CHECK (compared_steps >= 0),
    reason TEXT CHECK (reason IS NULL OR reason IN ('withheld_literal', 'unreadable_step', 'declared_before_verification')),
    checked_at_ms INTEGER NOT NULL,
    CHECK ((status = 'verified') = (reason IS NULL))
) STRICT;

CREATE TABLE memory_variant_prefix_checks (
    route_id INTEGER PRIMARY KEY REFERENCES memory_procedure_versions(route_id),
    status TEXT NOT NULL CHECK (status IN ('verified', 'suggested')),
    compared_steps INTEGER NOT NULL CHECK (compared_steps >= 0),
    reason TEXT CHECK (reason IS NULL OR reason IN ('withheld_literal', 'unreadable_step', 'declared_before_verification',
        'parameter_correspondence')),
    checked_at_ms INTEGER NOT NULL,
    CHECK ((status = 'verified') = (reason IS NULL))
) STRICT;

CREATE TABLE memory_recall_spaces (
    space_int_id INTEGER PRIMARY KEY,
    space_id TEXT NOT NULL UNIQUE CHECK (length(space_id) > 0),
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

CREATE TABLE memory_recall_generations (
    generation_id INTEGER PRIMARY KEY,
    document_format TEXT NOT NULL CHECK (length(document_format) > 0),
    space_int_id INTEGER REFERENCES memory_recall_spaces(space_int_id),
    status TEXT NOT NULL CHECK (status IN ('building', 'ready', 'retired', 'failed')),
    cursor_route_id INTEGER REFERENCES memory_procedure_versions(route_id),
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

CREATE TABLE memory_recall_documents (
    document_id INTEGER PRIMARY KEY,
    text_id INTEGER NOT NULL REFERENCES memory_recall_texts(text_id),
    document_format TEXT NOT NULL CHECK (length(document_format) > 0),
    recorded_at_ms INTEGER NOT NULL,
    UNIQUE (text_id,document_format)
) STRICT;

CREATE TABLE memory_recall_vectors (
    text_id INTEGER NOT NULL REFERENCES memory_recall_texts(text_id),
    space_int_id INTEGER NOT NULL REFERENCES memory_recall_spaces(space_int_id),
    token_count INTEGER NOT NULL CHECK (token_count > 0),
    truncated INTEGER NOT NULL CHECK (truncated IN (0,1)),
    vector BLOB NOT NULL,
    PRIMARY KEY (text_id,space_int_id)
) STRICT, WITHOUT ROWID;

CREATE TABLE memory_recall_entries (
    generation_id INTEGER NOT NULL REFERENCES memory_recall_generations(generation_id),
    part_id INTEGER NOT NULL REFERENCES memory_procedure_parts(part_id),
    route_id INTEGER NOT NULL REFERENCES memory_procedure_versions(route_id),
    part_kind TEXT NOT NULL CHECK (part_kind IN ('procedure', 'subprocedure', 'step')),
    document_id INTEGER NOT NULL REFERENCES memory_recall_documents(document_id),
    qualification_sequence INTEGER NOT NULL CHECK (qualification_sequence >= 1),
    state_sequence INTEGER NOT NULL CHECK (state_sequence >= 0),
    entered_at_ms INTEGER NOT NULL,
    PRIMARY KEY (generation_id, part_id)
) STRICT;

CREATE TABLE memory_recall_work (
    work_id INTEGER PRIMARY KEY,
    route_id INTEGER REFERENCES memory_procedure_versions(route_id),
    reason TEXT NOT NULL CHECK (reason IN ('publication', 'supersession', 'qualification', 'state', 'policy', 'migration',
        'rebuild')),
    enqueued_at_ms INTEGER NOT NULL,
    done_at_ms INTEGER,
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    last_error TEXT CHECK (last_error IS NULL OR length(last_error) > 0),
    CHECK ((route_id IS NULL) = (reason IN ('policy', 'migration', 'rebuild')))
) STRICT;

CREATE TABLE memory_recall_queries (
    query_id INTEGER PRIMARY KEY,
    task_id INTEGER NOT NULL,
    task_occurrence_id INTEGER NOT NULL,
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
    CHECK ((search_status IN ('unavailable', 'failed')) = (coverage = 'unknown')),
    CHECK (search_status = 'completed' OR search_note IS NOT NULL),
    CHECK ((generation_id IS NULL) = (channel = 'none')),
    CHECK ((delivery = 'nothing') = (coverage IN ('absent', 'unknown'))),
    FOREIGN KEY (task_occurrence_id) REFERENCES memory_task_attempts(task_occurrence_id)
) STRICT;

CREATE TABLE memory_recall_needs (
    need_id INTEGER PRIMARY KEY,
    query_id INTEGER NOT NULL REFERENCES memory_recall_queries(query_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    text TEXT NOT NULL CHECK (length(text) > 0),
    bundle_id TEXT CHECK (bundle_id IS NULL OR length(bundle_id) > 0),
    coverage TEXT NOT NULL CHECK (coverage IN ('complete', 'partial', 'ambiguous', 'absent', 'unknown')),
    reason TEXT CHECK (reason IS NULL OR reason IN ('gaps', 'alternatives', 'unresolved_input', 'excluded')),
    UNIQUE (query_id, position),
    CHECK (CASE coverage
        WHEN 'partial' THEN ifnull(reason, '') = 'gaps'
        WHEN 'ambiguous' THEN ifnull(reason, '') IN ('alternatives', 'unresolved_input')
        WHEN 'absent' THEN ifnull(reason, 'excluded') = 'excluded'
        ELSE reason IS NULL END)
) STRICT;

CREATE TABLE memory_recall_selections (
    selection_id INTEGER PRIMARY KEY,
    query_id INTEGER NOT NULL,
    need_position INTEGER NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    role TEXT NOT NULL CHECK (role IN ('selected', 'alternative', 'excluded')),
    route_id INTEGER NOT NULL REFERENCES memory_procedure_versions(route_id),
    first_position INTEGER NOT NULL CHECK (first_position >= 0),
    last_position INTEGER NOT NULL,
    whole_part_id INTEGER REFERENCES memory_procedure_parts(part_id),
    relevance REAL NOT NULL,
    preparations INTEGER NOT NULL CHECK (preparations >= 0),
    need_id INTEGER NOT NULL,
    UNIQUE (query_id, need_position, position),
    CHECK (last_position >= first_position),
    FOREIGN KEY (need_id) REFERENCES memory_recall_needs(need_id)
) STRICT;

CREATE TABLE memory_recall_requirements (
    query_id INTEGER NOT NULL,
    need_position INTEGER NOT NULL,
    selection_position INTEGER NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    kind TEXT NOT NULL CHECK (kind IN ('entry_state', 'observed_state', 'application_switch', 'prepared_before',
        'unknown_entry_state', 'prerequisite_out_of_catalogue', 'parameter_bound', 'parameter_missing', 'parameter_ambiguous',
        'input_produced', 'output_ready', 'compatibility_unknown', 'unbound_task_input', 'constraint_unchecked',
        'certain_conflict', 'constraint_excluded', 'adapter_available', 'step_result_pending', 'account_to_resolve', 'task_value_not_taken')),
    step_position INTEGER CHECK (step_position IS NULL OR step_position >= 0),
    parameter_id INTEGER,
    scene_id INTEGER,
    bundle_id TEXT CHECK (bundle_id IS NULL OR length(bundle_id) > 0),
    task_value_name TEXT CHECK (task_value_name IS NULL OR length(task_value_name) > 0),
    binding_match TEXT CHECK (binding_match IS NULL OR binding_match IN ('name', 'role', 'derived', 'produced')),
    constraint_position INTEGER CHECK (constraint_position IS NULL OR constraint_position >= 0),
    selection_id INTEGER NOT NULL,
    PRIMARY KEY (query_id, need_position, selection_position, position),
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
    CHECK (kind <> 'adapter_available' OR bundle_id IS NOT NULL),
    FOREIGN KEY (selection_id) REFERENCES memory_recall_selections(selection_id)
) STRICT;

CREATE TABLE memory_recall_links (
    query_id INTEGER NOT NULL,
    need_position INTEGER NOT NULL,
    call_event_id INTEGER NOT NULL REFERENCES memory_agent_actions(event_id),
    step_position INTEGER CHECK (step_position IS NULL OR step_position >= 0),
    confirmed INTEGER NOT NULL CHECK (confirmed IN (0, 1)),
    undetermined INTEGER NOT NULL DEFAULT 0 CHECK (undetermined IN (0, 1)),
    linked_at_ms INTEGER NOT NULL,
    need_id INTEGER NOT NULL,
    PRIMARY KEY (query_id, call_event_id),
    CHECK (step_position IS NOT NULL OR confirmed = 0),
    CHECK (step_position IS NULL OR undetermined = 0),
    FOREIGN KEY (need_id) REFERENCES memory_recall_needs(need_id)
) STRICT;

CREATE TABLE memory_recall_reports (
    query_id INTEGER NOT NULL,
    need_position INTEGER NOT NULL,
    sequence INTEGER NOT NULL CHECK (sequence >= 1),
    declared TEXT NOT NULL CHECK (declared IN ('followed', 'adapted', 'abandoned', 'not_executed')),
    cause TEXT CHECK (cause IS NULL OR cause IN ('method', 'driver', 'application', 'agent', 'input', 'unknown')),
    note TEXT CHECK (note IS NULL OR length(note) > 0),
    recorded_at_ms INTEGER NOT NULL,
    need_id INTEGER NOT NULL,
    PRIMARY KEY (query_id, need_position, sequence),
    FOREIGN KEY (need_id) REFERENCES memory_recall_needs(need_id)
) STRICT;

CREATE TABLE memory_recall_proposals (
    proposal_id INTEGER PRIMARY KEY,
    task_id INTEGER NOT NULL,
    task_occurrence_id INTEGER NOT NULL,
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
    CHECK (search_status = 'completed' OR search_note IS NOT NULL),
    CHECK ((generation_id IS NULL) = (channel = 'none')),
    FOREIGN KEY (task_occurrence_id) REFERENCES memory_task_attempts(task_occurrence_id)
) STRICT;

CREATE TABLE memory_recall_proposal_needs (
    proposal_need_id INTEGER PRIMARY KEY,
    proposal_id INTEGER NOT NULL REFERENCES memory_recall_proposals(proposal_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    text TEXT NOT NULL CHECK (length(text) > 0),
    bundle_id TEXT CHECK (bundle_id IS NULL OR length(bundle_id) > 0),
    UNIQUE (proposal_id, position)
) STRICT;

CREATE TABLE memory_recall_proposal_sources (
    proposal_id INTEGER NOT NULL,
    need_position INTEGER NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    source_key TEXT NOT NULL CHECK (length(source_key) > 0),
    route_id INTEGER NOT NULL REFERENCES memory_procedure_versions(route_id),
    relevance REAL NOT NULL,
    suggested_first INTEGER CHECK (suggested_first IS NULL OR suggested_first >= 0),
    suggested_last INTEGER,
    proposal_need_id INTEGER NOT NULL,
    PRIMARY KEY (proposal_id, need_position, position),
    CHECK ((suggested_first IS NULL) = (suggested_last IS NULL)),
    CHECK (suggested_last IS NULL OR suggested_last >= suggested_first),
    FOREIGN KEY (proposal_need_id) REFERENCES memory_recall_proposal_needs(proposal_need_id)
) STRICT;

CREATE TABLE memory_recall_choices (
    query_id INTEGER PRIMARY KEY REFERENCES memory_recall_queries(query_id),
    proposal_id INTEGER NOT NULL UNIQUE REFERENCES memory_recall_proposals(proposal_id),
    recorded_at_ms INTEGER NOT NULL
) STRICT;

CREATE TABLE memory_recall_choice_needs (
    query_id INTEGER NOT NULL REFERENCES memory_recall_choices(query_id),
    need_position INTEGER NOT NULL,
    declared TEXT NOT NULL CHECK (declared IN ('all', 'part', 'none', 'ambiguous')),
    uncovered TEXT CHECK (uncovered IS NULL OR length(uncovered) > 0),
    settled_by TEXT CHECK (settled_by IS NULL OR length(settled_by) > 0),
    need_id INTEGER NOT NULL,
    PRIMARY KEY (query_id, need_position),
    CHECK (declared <> 'all' OR uncovered IS NULL),
    CHECK (declared <> 'ambiguous' OR uncovered IS NOT NULL),
    CHECK (declared NOT IN ('none', 'ambiguous') OR settled_by IS NULL),
    FOREIGN KEY (need_id) REFERENCES memory_recall_needs(need_id)
) STRICT;

CREATE TABLE memory_recall_choice_links (
    query_id INTEGER NOT NULL REFERENCES memory_recall_choices(query_id),
    need_position INTEGER NOT NULL,
    selection_position INTEGER,
    call_event_id INTEGER NOT NULL REFERENCES memory_agent_actions(event_id),
    step_position INTEGER CHECK (step_position IS NULL OR step_position >= 0),
    confirmed INTEGER NOT NULL CHECK (confirmed IN (0, 1)),
    undetermined INTEGER NOT NULL DEFAULT 0 CHECK (undetermined IN (0, 1)),
    linked_at_ms INTEGER NOT NULL,
    need_id INTEGER NOT NULL,
    selection_id INTEGER,
    PRIMARY KEY (query_id, call_event_id),
    CHECK ((step_position IS NULL) = (selection_position IS NULL)),
    CHECK (step_position IS NOT NULL OR confirmed = 0),
    CHECK (step_position IS NULL OR undetermined = 0),
    FOREIGN KEY (need_id) REFERENCES memory_recall_needs(need_id),
    FOREIGN KEY (selection_id) REFERENCES memory_recall_selections(selection_id)
) STRICT;

CREATE TABLE memory_call_argument_fields (
    event_id INTEGER NOT NULL REFERENCES memory_agent_actions(event_id),
    field_path TEXT NOT NULL CHECK (length(field_path) > 0 AND substr(field_path, 1, 1) = '/'),
    value_kind TEXT NOT NULL CHECK (value_kind IN ('text', 'number', 'boolean', 'null')),
    field_kind TEXT NOT NULL CHECK (field_kind IN ('constant', 'result_reference', 'ambiguous_reference')),
    text_value TEXT,
    withheld_reason TEXT CHECK (withheld_reason IS NULL OR withheld_reason IN ('declared_secret', 'credential_pattern', 'secret_target', 'secure_field',
        'unclassified_target', 'confidential_content')),
    source_event_id INTEGER REFERENCES memory_agent_actions(event_id),
    source_path TEXT CHECK (source_path IS NULL OR (length(source_path) > 0 AND substr(source_path, 1, 1) = '/')),
    PRIMARY KEY (event_id, field_path),
    CHECK (withheld_reason IS NULL OR text_value IS NULL),
    CHECK (withheld_reason IS NOT NULL OR value_kind = 'null' OR text_value IS NOT NULL),
    CHECK ((field_kind = 'result_reference') = (source_event_id IS NOT NULL AND source_path IS NOT NULL)),
    CHECK (field_kind = 'result_reference' OR (source_event_id IS NULL AND source_path IS NULL)),
    CHECK (source_event_id IS NULL OR source_event_id <> event_id)
) STRICT;

CREATE TABLE memory_call_result_fields (
    event_id INTEGER NOT NULL REFERENCES memory_agent_actions(event_id),
    field_path TEXT NOT NULL CHECK (length(field_path) > 0 AND substr(field_path, 1, 1) = '/'),
    value_kind TEXT NOT NULL CHECK (value_kind IN ('text', 'number', 'boolean', 'null')),
    text_value TEXT,
    withheld_reason TEXT CHECK (withheld_reason IS NULL OR withheld_reason IN ('declared_secret', 'credential_pattern', 'secret_target', 'secure_field',
        'unclassified_target', 'confidential_content')),
    PRIMARY KEY (event_id, field_path),
    CHECK (withheld_reason IS NULL OR text_value IS NULL),
    CHECK (withheld_reason IS NOT NULL OR value_kind = 'null' OR text_value IS NOT NULL)
) STRICT;

CREATE TABLE memory_operation_argument_fields (
    route_id INTEGER NOT NULL,
    operation_id INTEGER NOT NULL,
    argument_name TEXT NOT NULL CHECK (length(argument_name) > 0),
    argument_position INTEGER NOT NULL CHECK (argument_position >= 0),
    field_path TEXT NOT NULL CHECK (length(field_path) > 0 AND substr(field_path, 1, 1) = '/'),
    field_kind TEXT NOT NULL CHECK (field_kind IN ('constant', 'parameter', 'withheld', 'step_result')),
    value_kind TEXT NOT NULL CHECK (value_kind IN ('text', 'number', 'boolean', 'null')),
    text_value TEXT,
    parameter_id INTEGER,
    source_step_position INTEGER CHECK (source_step_position IS NULL OR source_step_position >= 0),
    source_path TEXT CHECK (source_path IS NULL OR (length(source_path) > 0 AND substr(source_path, 1, 1) = '/')),
    PRIMARY KEY (operation_id, argument_name, argument_position, field_path),
    CHECK ((field_kind = 'parameter') = (parameter_id IS NOT NULL)),
    CHECK ((field_kind = 'step_result') = (source_step_position IS NOT NULL AND source_path IS NOT NULL)),
    CHECK (field_kind = 'step_result' OR (source_step_position IS NULL AND source_path IS NULL)),
    CHECK (field_kind = 'constant' OR text_value IS NULL),
    CHECK (field_kind <> 'constant' OR value_kind = 'null' OR text_value IS NOT NULL),
    FOREIGN KEY (operation_id) REFERENCES memory_step_operations(operation_id),
    FOREIGN KEY (parameter_id) REFERENCES memory_route_parameters(parameter_id)
) STRICT;

CREATE TABLE memory_call_data_contexts (
    event_id INTEGER PRIMARY KEY REFERENCES memory_agent_actions(event_id),
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

CREATE TABLE memory_identity_salts (
    salt_id INTEGER PRIMARY KEY CHECK (salt_id = 1),
    salt BLOB NOT NULL CHECK (length(salt) = 32)
) STRICT;

CREATE TABLE memory_executors (
    executor_id INTEGER PRIMARY KEY,
    source TEXT NOT NULL CHECK (length(source) > 0),
    process_id INTEGER NOT NULL CHECK (process_id > 0),
    started_at_ms INTEGER NOT NULL
) STRICT;

CREATE TABLE memory_call_executors (
    event_id INTEGER PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    executor_id INTEGER NOT NULL REFERENCES memory_executors(executor_id)
) STRICT;

CREATE TABLE memory_call_reconciliations (
    event_id INTEGER NOT NULL REFERENCES memory_agent_actions(event_id),
    sequence INTEGER NOT NULL CHECK (sequence >= 1),
    kind TEXT NOT NULL CHECK (kind IN ('executor_terminated', 'late_result', 'observed', 'acknowledged')),
    finding TEXT CHECK (finding IS NULL OR finding IN ('happened', 'not_happened', 'unknown')),
    evidence_event_id INTEGER REFERENCES memory_agent_actions(event_id),
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

CREATE TABLE memory_todo_revisions (
    todo_revision_id INTEGER PRIMARY KEY,
    task_id INTEGER NOT NULL REFERENCES memory_tasks(task_id),
    revision INTEGER NOT NULL CHECK (revision >= 1),
    task_revision_id INTEGER NOT NULL REFERENCES memory_task_revisions(task_revision_id),
    reason_kind TEXT NOT NULL CHECK (reason_kind IN ('drafted','revised','row_started','row_finished','stopped','postponed','resumed')),
    reason_text TEXT CHECK (length(CAST(reason_text AS BLOB)) <= 200),
    recorded_at_ms INTEGER NOT NULL,
    UNIQUE (task_id, revision)
) STRICT;

CREATE TABLE memory_todo_items (
    item_id INTEGER PRIMARY KEY,
    item_uuid TEXT NOT NULL UNIQUE,
    task_id INTEGER NOT NULL REFERENCES memory_tasks(task_id),
    first_revision INTEGER NOT NULL CHECK (first_revision >= 1),
    row_key TEXT NOT NULL CHECK (row_key GLOB 'r[1-9]*' AND substr(row_key,2) NOT GLOB '*[^0-9]*'),
    origin TEXT NOT NULL CHECK (origin IN ('plan','memory')),
    UNIQUE (task_id,row_key)
) STRICT;

CREATE TABLE memory_todo_item_states (
    item_id INTEGER NOT NULL REFERENCES memory_todo_items(item_id),
    todo_revision_id INTEGER NOT NULL REFERENCES memory_todo_revisions(todo_revision_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    title TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 120),
    app_name TEXT,
    linked_part_id INTEGER REFERENCES memory_procedure_parts(part_id),
    status TEXT NOT NULL CHECK (status IN ('pending','in_progress','done','abandoned')),
    closed_by TEXT CHECK (closed_by IN ('agent','person','braus')),
    check_verdict TEXT CHECK (check_verdict IN ('passed','failed','unknown')),
    expectation_revision_id INTEGER REFERENCES memory_todo_revisions(todo_revision_id),
    PRIMARY KEY (item_id,todo_revision_id)
) STRICT;

CREATE TABLE memory_todo_item_expectations (
    item_id INTEGER NOT NULL REFERENCES memory_todo_items(item_id),
    todo_revision_id INTEGER NOT NULL REFERENCES memory_todo_revisions(todo_revision_id),
    predicate_position INTEGER NOT NULL CHECK (predicate_position >= 0),
    kind TEXT NOT NULL CHECK (kind IN ('file_written','file_changed','file_unchanged','file_absent','file_contains',
 'file_moved','file_copied','no_other_files','window','element','none')),
    operand TEXT NOT NULL CHECK (operand IN ('parameter','withheld','none')),
    parameter_name TEXT,
    second_parameter_name TEXT,
    app_id INTEGER REFERENCES brain_apps(app_id),
    subject_key TEXT,
    expected_state TEXT CHECK (expected_state IN ('on','off','mixed','unknown')),
    presence INTEGER CHECK (presence IN (0,1)),
    PRIMARY KEY (item_id,todo_revision_id,predicate_position),
    CHECK ((operand = 'parameter') = (parameter_name IS NOT NULL))
) STRICT;

CREATE TABLE memory_call_steps (
    event_id INTEGER PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    item_id INTEGER NOT NULL REFERENCES memory_todo_items(item_id)
) STRICT;

CREATE TABLE memory_task_end_checks (
    task_occurrence_id INTEGER PRIMARY KEY REFERENCES memory_task_attempts(task_occurrence_id),
    verdict TEXT NOT NULL CHECK (verdict IN ('passed','failed','unknown')),
    scope TEXT NOT NULL CHECK (scope IN ('window_presence_only','declared_predicates_only')),
    goal_match INTEGER NOT NULL CHECK (goal_match IN (0,1))
) STRICT;

-- readback: after insert_text (ES10); before pressing Save, as its precondition (ES11).
CREATE TABLE memory_gesture_evidence (
    event_id INTEGER PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    comparable INTEGER NOT NULL CHECK (comparable IN (0,1)),
    looked_again INTEGER NOT NULL CHECK (looked_again IN (0,1)),
    settle_kind TEXT CHECK (settle_kind IN ('click','pointer_menu','key','text','scroll','drag','menu_command','dialog_button','popup_step','activation')),
    settle_ending TEXT CHECK (settle_ending IN ('settled','capped','unwatched')),
    settle_detail TEXT CHECK (settle_detail IN ('unchanged','changed_then_still','notifications','pixels','surface_pending','requests_in_flight','no_role','accessibility_untrusted','observer_failed','process_gone','stream_not_live','stream_other_window','stream_recovering','stream_resting','frame_unplaced')),
    settle_waited_ms INTEGER CHECK (settle_waited_ms >= 0),
    settle_cap_ms INTEGER CHECK (settle_cap_ms >= 0),
    settle_channels INTEGER CHECK (settle_channels BETWEEN 0 AND 15),
    settle_surfaces INTEGER CHECK (settle_surfaces >= 0),
    readback TEXT CHECK (readback IN ('matches','differs','not_read')),
    verdict_change_position INTEGER CHECK (verdict_change_position >= 0),
    verdict_differs_from_learning INTEGER NOT NULL CHECK (verdict_differs_from_learning IN (0,1))
) STRICT;

CREATE TABLE memory_gesture_changes (
    event_id INTEGER NOT NULL REFERENCES memory_agent_actions(event_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    kind TEXT NOT NULL CHECK (kind IN ('structural','state','field_value','native_text','selection','recognized_text')),
    subject_key TEXT NOT NULL CHECK (length(subject_key) BETWEEN 1 AND 512),
    scope TEXT NOT NULL CHECK (scope IN ('target','target_container','window','elsewhere')),
    stability TEXT NOT NULL CHECK (stability IN ('stable_label','instance_value','self_changing','unreliable')),
    family TEXT NOT NULL CHECK (family IN ('windowTitleChanged','stateFlip','menuOpened','elementsAppeared','elementsDisappeared','textSelectionChanged','valueChanged')),
    PRIMARY KEY (event_id,position)
) STRICT;

-- stopped_at_position is the zero-based step whose preflight or result stopped the batch (EC2).
CREATE TABLE memory_batch_stops (
    event_id INTEGER PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    stopped_at_position INTEGER NOT NULL CHECK (stopped_at_position >= 0),
    reason TEXT NOT NULL CHECK (reason IN ('refused','ambiguous','target_missing','unexpected_surface','expected_absent','unknown_without_next_target','committing_not_last','committing_after_unconfirmed','person_in_control','time_cap','other_app','error'))
) STRICT;

-- template: date_format/number_format stores format tokens and separators, never a task value (ME1).
CREATE TABLE memory_operation_argument_links (
    event_id INTEGER NOT NULL REFERENCES memory_agent_actions(event_id),
    argument_name TEXT NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    link_kind TEXT NOT NULL CHECK (link_kind IN ('reference','template','derived','to_provide')),
    parameter_name TEXT,
    template TEXT,
    derivation TEXT CHECK (derivation IN ('stem','file_extension','folder','date_format','number_format')),
    field_role TEXT,
    value_digest BLOB NOT NULL CHECK (length(value_digest) = 16),
    PRIMARY KEY (event_id,argument_name,position)
) STRICT;

CREATE TABLE memory_step_signatures (
    signature_id INTEGER PRIMARY KEY,
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    signature_digest BLOB NOT NULL CHECK (length(signature_digest) = 16),
    verb TEXT NOT NULL,
    element_key_id INTEGER REFERENCES brain_element_keys(element_key_id),
    arguments_shape TEXT NOT NULL,
    UNIQUE (app_id,signature_digest)
) STRICT;

CREATE TABLE memory_step_signature_members (
    signature_id INTEGER NOT NULL REFERENCES memory_step_signatures(signature_id),
    step_id INTEGER NOT NULL REFERENCES memory_route_steps(step_id),
    PRIMARY KEY (signature_id,step_id)
) STRICT;

CREATE TABLE memory_phase_families (
    family_id INTEGER PRIMARY KEY,
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    kind TEXT NOT NULL CHECK (kind IN ('step','subprocedure','procedure')),
    method_text TEXT NOT NULL,
    method_digest BLOB NOT NULL CHECK (length(method_digest) = 16),
    masked_digest BLOB NOT NULL CHECK (length(masked_digest) = 16),
    has_parameter INTEGER NOT NULL CHECK (has_parameter IN (0,1)),
    length INTEGER NOT NULL CHECK (length >= 1),
    label TEXT NOT NULL,
    members INTEGER NOT NULL CHECK (members >= 0),
    procedures INTEGER NOT NULL CHECK (procedures >= 0),
    first_member_seq INTEGER NOT NULL,
    first_attempt_id INTEGER NOT NULL REFERENCES memory_task_attempts(task_occurrence_id),
    latest_route_id INTEGER REFERENCES memory_procedure_versions(route_id),
    recorded_at_ms INTEGER NOT NULL,
    UNIQUE (app_id,kind,method_digest),
    CHECK (latest_route_id IS NULL OR kind = 'procedure')
) STRICT;

CREATE TABLE memory_phase_family_labels (
    family_id INTEGER NOT NULL REFERENCES memory_phase_families(family_id) ON DELETE CASCADE,
    position INTEGER NOT NULL CHECK (position >= 0),
    label TEXT NOT NULL,
    count INTEGER NOT NULL CHECK (count >= 1),
    PRIMARY KEY (family_id,position),
    UNIQUE (family_id,label)
) STRICT;

CREATE TABLE memory_phase_family_attempts (
    family_id INTEGER NOT NULL REFERENCES memory_phase_families(family_id) ON DELETE CASCADE,
    task_occurrence_id INTEGER NOT NULL REFERENCES memory_task_attempts(task_occurrence_id),
    members INTEGER NOT NULL CHECK (members >= 0),
    routes INTEGER NOT NULL CHECK (routes >= 0),
    PRIMARY KEY (family_id,task_occurrence_id)
) STRICT;

CREATE TABLE memory_phase_family_attempt_labels (
    family_id INTEGER NOT NULL,
    task_occurrence_id INTEGER NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    label TEXT NOT NULL,
    count INTEGER NOT NULL CHECK (count >= 1),
    PRIMARY KEY (family_id,task_occurrence_id,position),
    UNIQUE (family_id,task_occurrence_id,label),
    FOREIGN KEY (family_id,task_occurrence_id)
        REFERENCES memory_phase_family_attempts(family_id,task_occurrence_id) ON DELETE CASCADE
) STRICT;

CREATE TABLE memory_recall_texts (
    text_id INTEGER PRIMARY KEY,
    digest BLOB NOT NULL CHECK (length(digest) = 16),
    format TEXT NOT NULL,
    text TEXT NOT NULL,
    UNIQUE (digest)
) STRICT;

CREATE TABLE memory_recall_text_pieces (
    text_id INTEGER NOT NULL REFERENCES memory_recall_texts(text_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    piece_kind TEXT NOT NULL CHECK (piece_kind IN ('label','app','within','contents','needs','produces')),
    piece_text_id INTEGER NOT NULL REFERENCES memory_recall_texts(text_id),
    PRIMARY KEY (text_id,position),
    UNIQUE (text_id,piece_kind)
) STRICT;

CREATE TABLE memory_recall_calibration (
    query_id INTEGER NOT NULL REFERENCES memory_recall_queries(query_id),
    need_position INTEGER NOT NULL CHECK (need_position >= 0),
    part_id INTEGER NOT NULL REFERENCES memory_procedure_parts(part_id),
    rank INTEGER NOT NULL CHECK (rank >= 0),
    cosine REAL,
    lexical REAL,
    score REAL NOT NULL,
    threshold REAL NOT NULL,
    delivered INTEGER NOT NULL CHECK (delivered IN (0,1)),
    used INTEGER CHECK (used IN (0,1)),
    PRIMARY KEY (query_id,need_position,part_id)
) STRICT;

CREATE TABLE memory_part_misses (
    miss_id INTEGER PRIMARY KEY,
    item_id INTEGER NOT NULL REFERENCES memory_todo_items(item_id),
    query_id INTEGER REFERENCES memory_recall_queries(query_id),
    part_id INTEGER NOT NULL REFERENCES memory_procedure_parts(part_id),
    similarity REAL NOT NULL CHECK (similarity BETWEEN 0 AND 1),
    recorded_at_ms INTEGER NOT NULL,
    UNIQUE (item_id,part_id)
) STRICT;

CREATE TABLE memory_part_reuse (
    part_id INTEGER PRIMARY KEY REFERENCES memory_procedure_parts(part_id),
    offered INTEGER NOT NULL CHECK (offered >= 0),
    used INTEGER NOT NULL CHECK (used BETWEEN 0 AND offered),
    succeeded INTEGER NOT NULL CHECK (succeeded BETWEEN 0 AND used),
    updated_at_ms INTEGER NOT NULL
) STRICT;

CREATE TABLE memory_attempt_reused_parts (
    reuse_id INTEGER PRIMARY KEY,
    task_occurrence_id INTEGER NOT NULL REFERENCES memory_task_attempts(task_occurrence_id),
    part_id INTEGER NOT NULL REFERENCES memory_procedure_parts(part_id),
    item_id INTEGER REFERENCES memory_todo_items(item_id),
    recorded_at_ms INTEGER NOT NULL
) STRICT;

CREATE TABLE memory_elements (
    element_id INTEGER PRIMARY KEY,
    digest BLOB NOT NULL CHECK (length(digest) = 16),
    role TEXT,
    kind TEXT,
    label TEXT,
    label_origin TEXT CHECK (label_origin IN ('title','description','value','column','row_content','identifier','caption')),
    container_path TEXT,
    state TEXT,
    replaced_by_id INTEGER REFERENCES memory_elements(element_id),
    CHECK (replaced_by_id IS NULL OR replaced_by_id <> element_id)
) STRICT;

CREATE TABLE memory_element_sets (
    set_id INTEGER PRIMARY KEY,
    digest BLOB NOT NULL CHECK (length(digest) = 16),
    members BLOB NOT NULL,
    replaced_by_id INTEGER REFERENCES memory_element_sets(set_id),
    CHECK (replaced_by_id IS NULL OR replaced_by_id <> set_id)
) STRICT;

CREATE TABLE brain_element_keys (
    element_key_id INTEGER PRIMARY KEY,
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    key_text TEXT NOT NULL CHECK (length(key_text) BETWEEN 1 AND 512),
    digest BLOB NOT NULL CHECK (length(digest) = 16),
    first_seen_ms INTEGER NOT NULL,
    replaced_by_id INTEGER REFERENCES brain_element_keys(element_key_id),
    CHECK (replaced_by_id IS NULL OR replaced_by_id <> element_key_id)
) STRICT;

CREATE TABLE brain_screen_kinds (
    kind_id INTEGER PRIMARY KEY,
    kind_uuid TEXT NOT NULL UNIQUE,
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    method_name TEXT NOT NULL CHECK (length(method_name) > 0)
) STRICT;

CREATE TABLE brain_scene_kind_members (
    membership_id INTEGER PRIMARY KEY,
    scene_id INTEGER NOT NULL REFERENCES brain_scenes(scene_id),
    kind_id INTEGER NOT NULL REFERENCES brain_screen_kinds(kind_id),
    since_ms INTEGER NOT NULL,
    merge_id INTEGER REFERENCES brain_scene_merges(merge_id)
) STRICT;

CREATE TABLE brain_scene_merges (
    merge_id INTEGER PRIMARY KEY,
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    subject TEXT NOT NULL CHECK (subject IN ('scene','kind')),
    from_scene_id INTEGER REFERENCES brain_scenes(scene_id),
    into_scene_id INTEGER REFERENCES brain_scenes(scene_id),
    from_kind_id INTEGER REFERENCES brain_screen_kinds(kind_id),
    into_kind_id INTEGER REFERENCES brain_screen_kinds(kind_id),
    action TEXT NOT NULL CHECK (action IN ('merge','split')),
    recorded_by TEXT NOT NULL CHECK (recorded_by IN ('braus', 'person', 'import')),
    reason_code TEXT NOT NULL CHECK (reason_code IN ('qualified', 'requalified', 'policy_quarantined', 'superseded', 'judged_wrong', 'retired_by_person', 'retired_by_curation', 'forgotten_by_person', 'merged_same_screen', 'split_distinct_surfaces', 'imported', 'migrated')),
    origin_id INTEGER REFERENCES memory_archive_origins(origin_id),
    recorded_at_ms INTEGER NOT NULL,
    CHECK ((subject = 'scene' AND from_scene_id IS NOT NULL AND into_scene_id IS NOT NULL AND from_kind_id IS NULL AND into_kind_id IS NULL AND from_scene_id <> into_scene_id)
 OR (subject = 'kind' AND from_kind_id IS NOT NULL AND into_kind_id IS NOT NULL AND from_scene_id IS NULL AND into_scene_id IS NULL AND from_kind_id <> into_kind_id)),
    CHECK ((recorded_by = 'import') = (origin_id IS NOT NULL))
) STRICT;

-- SK4 seals minimized Brain inputs with their fact; no role is required for a pixel detection.
CREATE TABLE memory_brain_command_inputs (
    command_input_id INTEGER PRIMARY KEY,
    event_id INTEGER NOT NULL REFERENCES memory_events(event_id),
    sample_observation_id INTEGER REFERENCES memory_event_observations(observation_id),
    operation TEXT NOT NULL CHECK (operation IN ('observe', 'record')),
    requested_at_ms INTEGER NOT NULL,
    contract_version INTEGER NOT NULL CHECK (contract_version IN (1, 2, 3)),
    detection_count INTEGER NOT NULL CHECK (detection_count >= 0),
    window TEXT,
    capture_completeness TEXT CHECK (capture_completeness IN ('complete', 'partial', 'failed', 'unknown')),
    capture_surface TEXT CHECK (capture_surface IN ('window', 'dialog', 'sheet', 'popup_union', 'unknown')),
    representation TEXT CHECK (representation IN ('native', 'desktop', 'web', 'unknown')),
    spatial_coverage TEXT CHECK (spatial_coverage IN ('visible', 'whole_surface', 'legacy_window')),
    verb TEXT CHECK (verb IN ('click', 'double_click', 'triple_click', 'right_click', 'set_toggle')),
    effect_event_id INTEGER REFERENCES memory_agent_actions(event_id),
    CHECK (effect_event_id IS NULL OR effect_event_id = event_id),
    CHECK ((operation = 'observe') = (sample_observation_id IS NOT NULL)),
    CHECK ((operation = 'record') = (verb IS NOT NULL)),
    CHECK (operation = 'observe' OR (window IS NULL AND detection_count = 1 AND contract_version = 1)),
    CHECK (operation = 'record' OR effect_event_id IS NULL),
    CHECK ((contract_version = 1 AND capture_completeness IS NULL AND capture_surface IS NULL
            AND representation IS NULL AND spatial_coverage IS NULL)
        OR (contract_version IN (2, 3) AND capture_completeness IS NOT NULL AND capture_surface IS NOT NULL
            AND representation IS NOT NULL AND spatial_coverage IS NOT NULL)),
    CHECK (contract_version <> 2 OR spatial_coverage = 'legacy_window'),
    CHECK (contract_version <> 3 OR spatial_coverage IN ('visible', 'whole_surface'))
) STRICT;

-- Observe keeps every detection in command order; record keeps its resolved target at position zero.
CREATE TABLE memory_brain_command_detections (
    command_input_id INTEGER NOT NULL REFERENCES memory_brain_command_inputs(command_input_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    kind TEXT NOT NULL CHECK (kind IN ('text', 'icon', 'control', 'image', 'overlay-candidate')),
    -- Same minimized text as schema 19's detection_label/target_label in memory_operation_arguments.
    -- SK4 writes label only after ValueMinimization.
    label TEXT NOT NULL,
    x REAL NOT NULL CHECK (abs(x) <= 1.7976931348623157e308),
    y REAL NOT NULL CHECK (abs(y) <= 1.7976931348623157e308),
    width REAL NOT NULL CHECK (abs(width) <= 1.7976931348623157e308),
    height REAL NOT NULL CHECK (abs(height) <= 1.7976931348623157e308),
    state TEXT CHECK (state IN ('on', 'off', 'mixed', 'unknown')),
    PRIMARY KEY (command_input_id, position)
) STRICT;

CREATE TABLE memory_consolidation_queue (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    job_kind TEXT NOT NULL CHECK (job_kind GLOB '[a-z]*' AND job_kind NOT GLOB '*[^a-z_]*' AND length(job_kind) <= 40),
    ref_id INTEGER NOT NULL,
    enqueued_at_ms INTEGER NOT NULL
) STRICT;

CREATE TABLE memory_consolidation_cursors (
    job_kind TEXT PRIMARY KEY CHECK (job_kind GLOB '[a-z]*' AND job_kind NOT GLOB '*[^a-z_]*' AND length(job_kind) <= 40),
    last_seq INTEGER NOT NULL CHECK (last_seq >= 0),
    algorithm_version INTEGER NOT NULL CHECK (algorithm_version >= 1),
    generation INTEGER NOT NULL CHECK (generation >= 1),
    backfill_after_fact_id INTEGER,
    backfill_until_fact_id INTEGER,
    queue_from_seq INTEGER,
    continuation BLOB
) STRICT;

CREATE TABLE memory_part_judgments (
    judgment_id INTEGER PRIMARY KEY,
    part_id INTEGER NOT NULL REFERENCES memory_procedure_parts(part_id),
    family_root_route_id INTEGER NOT NULL REFERENCES memory_procedure_versions(route_id),
    judgment TEXT NOT NULL CHECK (judgment = 'wrong'),
    recorded_by TEXT NOT NULL CHECK (recorded_by IN ('braus', 'person', 'import')),
    reason_code TEXT NOT NULL CHECK (reason_code IN ('qualified', 'requalified', 'policy_quarantined', 'superseded', 'judged_wrong', 'retired_by_person', 'retired_by_curation', 'forgotten_by_person', 'merged_same_screen', 'split_distinct_surfaces', 'imported', 'migrated')),
    origin_id INTEGER REFERENCES memory_archive_origins(origin_id),
    recorded_at_ms INTEGER NOT NULL,
    CHECK ((recorded_by = 'import') = (origin_id IS NOT NULL))
) STRICT;

CREATE TABLE memory_forget_tombstones (
    tombstone_id INTEGER PRIMARY KEY,
    tombstone_uuid TEXT NOT NULL UNIQUE,
    bundle_id TEXT NOT NULL,
    key_kind TEXT NOT NULL CHECK (key_kind IN ('procedure_family','screen_kind','relation')),
    method_key TEXT NOT NULL,
    verb TEXT,
    recorded_at_ms INTEGER NOT NULL,
    reason_code TEXT NOT NULL CHECK (reason_code IN ('qualified', 'requalified', 'policy_quarantined', 'superseded', 'judged_wrong', 'retired_by_person', 'retired_by_curation', 'forgotten_by_person', 'merged_same_screen', 'split_distinct_surfaces', 'imported', 'migrated'))
) STRICT;

CREATE TABLE memory_part_origins (
    part_id INTEGER PRIMARY KEY REFERENCES memory_procedure_parts(part_id),
    origin_id INTEGER NOT NULL REFERENCES memory_archive_origins(origin_id),
    source_part_uuid TEXT NOT NULL,
    recorded_at_ms INTEGER NOT NULL
) STRICT;

CREATE TABLE memory_procedure_provenance (
    route_id INTEGER PRIMARY KEY REFERENCES memory_procedure_versions(route_id),
    third_party_content INTEGER NOT NULL CHECK (third_party_content IN (0,1)),
    exit_point INTEGER NOT NULL CHECK (exit_point IN (0,1)),
    person_episode INTEGER NOT NULL CHECK (person_episode IN (0,1)),
    learned_via TEXT NOT NULL CHECK (learned_via IN ('agent','mcp_client','import','person_demonstration')),
    client_ref TEXT,
    confirmed INTEGER NOT NULL CHECK (confirmed IN (0,1)),
    confirmed_by_attempt INTEGER REFERENCES memory_task_attempts(task_occurrence_id)
) STRICT;

CREATE TABLE memory_procedure_exit_points (
    route_id INTEGER NOT NULL REFERENCES memory_procedure_versions(route_id),
    step_position INTEGER NOT NULL CHECK (step_position >= 0),
    exit_point TEXT NOT NULL CHECK (exit_point IN ('send','type_outward','open_address','write_file','permission','memory')),
    PRIMARY KEY (route_id,step_position,exit_point)
) STRICT;

CREATE TABLE memory_person_segments (
    segment_id INTEGER PRIMARY KEY,
    task_occurrence_id INTEGER NOT NULL REFERENCES memory_task_attempts(task_occurrence_id),
    before_event_id INTEGER REFERENCES memory_events(event_id),
    after_event_id INTEGER REFERENCES memory_events(event_id),
    started_at_ms INTEGER NOT NULL,
    ended_at_ms INTEGER,
    reason TEXT NOT NULL CHECK (reason IN ('unblock','person_only','correct','teach','unrelated')),
    person_only_kind TEXT CHECK (person_only_kind IN ('credential','captcha','consent','payment','send','other')),
    coverage TEXT NOT NULL CHECK (coverage IN ('complete','range','viewport','unobserved')),
    CHECK ((reason = 'person_only') = (person_only_kind IS NOT NULL)),
    CHECK (ended_at_ms IS NULL OR ended_at_ms >= started_at_ms)
) STRICT;

CREATE TABLE memory_segment_checks (
    segment_id INTEGER NOT NULL REFERENCES memory_person_segments(segment_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    kind TEXT NOT NULL CHECK (kind IN ('created','deleted','renamed','value','state','title')),
    app_id INTEGER NOT NULL REFERENCES brain_apps(app_id),
    window_number INTEGER,
    subject_key TEXT CHECK (length(subject_key) BETWEEN 1 AND 512),
    operand TEXT NOT NULL CHECK (operand IN ('parameter','withheld','none')),
    parameter_name TEXT,
    expected_state TEXT CHECK (expected_state IN ('on','off','mixed','unknown')),
    coverage TEXT NOT NULL CHECK (coverage IN ('complete','range','viewport','unobserved')),
    PRIMARY KEY (segment_id,position),
    CHECK ((operand = 'parameter') = (parameter_name IS NOT NULL)),
    CHECK ((kind = 'state') = (expected_state IS NOT NULL))
) STRICT;

CREATE TABLE memory_person_commands (
    command_id INTEGER PRIMARY KEY,
    segment_id INTEGER NOT NULL REFERENCES memory_person_segments(segment_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    kind TEXT NOT NULL CHECK (kind IN ('menu_path','field_edit','shortcut','drag','click','selection','scroll')),
    element_key_id INTEGER REFERENCES brain_element_keys(element_key_id),
    menu_path TEXT,
    key_code INTEGER,
    modifiers INTEGER,
    effect_kind TEXT CHECK (effect_kind IN ('windowTitleChanged','stateFlip','menuOpened','elementsAppeared','elementsDisappeared','textSelectionChanged','valueChanged')),
    coverage TEXT NOT NULL CHECK (coverage IN ('complete','range','viewport','unobserved')),
    cause TEXT NOT NULL CHECK (cause IN ('rule','ranked')),
    scene_before_id INTEGER REFERENCES brain_scenes(scene_id),
    scene_after_id INTEGER REFERENCES brain_scenes(scene_id),
    arrival_kind TEXT NOT NULL CHECK (arrival_kind IN ('state','selected','unselected','expanded','collapsed','value','unknown')),
    arrival_state TEXT CHECK (arrival_state IN ('on','off')),
    arrival_parameter TEXT,
    UNIQUE (segment_id,position),
    CHECK (arrival_state IS NULL OR arrival_kind = 'state'),
    CHECK (arrival_parameter IS NULL OR arrival_kind = 'value')
) STRICT;

CREATE TABLE memory_call_capabilities (
    event_id INTEGER PRIMARY KEY REFERENCES memory_agent_actions(event_id),
    capability_id TEXT NOT NULL,
    effect_class TEXT NOT NULL CHECK (effect_class IN ('read','write','irreversible')),
    channel TEXT NOT NULL CHECK (channel IN ('seat','native','web','adapter','connector','command','braus')),
    origin TEXT NOT NULL CHECK (origin IN ('core','adapter','registered')),
    origin_name TEXT,
    CHECK ((origin = 'core') = (origin_name IS NULL))
) STRICT;

CREATE TABLE memory_step_capabilities (
    step_id INTEGER NOT NULL REFERENCES memory_route_steps(step_id),
    position INTEGER NOT NULL CHECK (position >= 0),
    capability_id TEXT NOT NULL,
    PRIMARY KEY (step_id,position)
) STRICT;

-- section: indexes
CREATE UNIQUE INDEX memory_brain_command_inputs_by_sample ON memory_brain_command_inputs(sample_observation_id) WHERE operation = 'observe';
CREATE UNIQUE INDEX memory_brain_command_inputs_by_record ON memory_brain_command_inputs(event_id) WHERE operation = 'record';

CREATE INDEX brain_anchors_active_by_kind ON brain_anchors(app_id, kind) WHERE retired_at_ms IS NULL;
CREATE INDEX brain_groups_active_by_app ON brain_groups(app_id) WHERE retired_at_ms IS NULL;
CREATE INDEX brain_transitions_active_by_anchor ON brain_transitions(app_id, anchor_id, trigger_kind) WHERE retired_at_ms IS NULL;
CREATE UNIQUE INDEX brain_scenes_one_app_scope ON brain_scenes(app_id) WHERE scene_kind = 'app';
CREATE UNIQUE INDEX brain_evidence_scene_id ON brain_evidence(scene_id, event_id, relation) WHERE scene_id IS NOT NULL;
CREATE UNIQUE INDEX brain_evidence_anchor_id ON brain_evidence(anchor_id, event_id, relation) WHERE anchor_id IS NOT NULL;
CREATE UNIQUE INDEX brain_evidence_scene_element_id ON brain_evidence(scene_element_id, event_id, relation) WHERE scene_element_id IS NOT NULL;
CREATE UNIQUE INDEX brain_evidence_group_id ON brain_evidence(group_id, event_id, relation) WHERE group_id IS NOT NULL;
CREATE UNIQUE INDEX brain_evidence_menu_command_id ON brain_evidence(menu_command_id, event_id, relation) WHERE menu_command_id IS NOT NULL;
CREATE UNIQUE INDEX brain_evidence_transition_id ON brain_evidence(transition_id, event_id, relation) WHERE transition_id IS NOT NULL;
CREATE UNIQUE INDEX memory_observation_captures ON memory_event_observations(event_id, phase, sample_ordinal) WHERE observation_kind = 'capture';
CREATE UNIQUE INDEX memory_event_scenes_confirmed ON memory_event_scenes(event_id, phase, sample_ordinal) WHERE match_status = 'confirmed';
CREATE UNIQUE INDEX memory_operations_roots ON memory_step_operations(step_id, position) WHERE parent_operation_id IS NULL;
CREATE UNIQUE INDEX memory_operations_children ON memory_step_operations(parent_operation_id, position) WHERE parent_operation_id IS NOT NULL;
CREATE UNIQUE INDEX memory_arguments_definition ON memory_operation_arguments(operation_id, argument_name, position) WHERE operation_id IS NOT NULL;
CREATE UNIQUE INDEX memory_arguments_event ON memory_operation_arguments(event_id, argument_name, position) WHERE event_id IS NOT NULL;
CREATE UNIQUE INDEX memory_arguments_brain_application ON memory_operation_arguments(brain_application_id, argument_name, position) WHERE brain_application_id IS NOT NULL;
CREATE UNIQUE INDEX brain_applications_observation_key ON brain_applications(event_id, phase, sample_ordinal) WHERE operation = 'observe';
CREATE UNIQUE INDEX brain_applications_call_key ON brain_applications(event_id, operation) WHERE operation <> 'observe';
CREATE INDEX brain_applications_by_app_clock ON brain_applications(app_id, effective_at_ms);
CREATE INDEX memory_events_by_context_time ON memory_events(context_id, occurred_at_ms);
CREATE INDEX memory_events_by_trace ON memory_events(trace_id, event_id);
CREATE INDEX memory_events_by_source_order ON memory_events(source, source_stream_id, event_id);
CREATE INDEX memory_task_labels_by_occurrence ON memory_task_labels(task_occurrence_id, status);
CREATE INDEX memory_step_occurrences_by_task ON memory_step_occurrences(task_occurrence_id, started_at_ms);
CREATE INDEX brain_transitions_by_source ON brain_transitions(app_id, from_scene_id, trigger_kind);
CREATE INDEX brain_transitions_by_destination ON brain_transitions(app_id, to_scene_id);
CREATE INDEX brain_menu_by_path_hint ON brain_menu_commands(app_id, path_key);
CREATE INDEX brain_evidence_by_event ON brain_evidence(event_id);
CREATE INDEX memory_task_events_by_event ON memory_task_events(event_id);
CREATE INDEX memory_step_events_by_event ON memory_step_events(event_id);
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
CREATE UNIQUE INDEX memory_procedure_parts_one_procedure ON memory_procedure_parts(route_id) WHERE part_kind = 'procedure';
CREATE INDEX memory_procedure_parts_by_parent ON memory_procedure_parts(parent_part_id);
CREATE INDEX memory_procedure_versions_by_attempt ON memory_procedure_versions(task_occurrence_id);
CREATE INDEX memory_procedure_candidates_by_attempt ON memory_procedure_candidates(task_occurrence_id, built_at_ms);
CREATE INDEX memory_candidate_steps_by_call ON memory_candidate_steps(call_event_id);
CREATE UNIQUE INDEX memory_part_contract_items_once ON memory_part_contract_items(part_id, item_kind, ifnull(parameter_id, ''));
CREATE INDEX memory_part_qualifications_by_verdict ON memory_part_qualifications(verdict, policy_id);
CREATE UNIQUE INDEX brain_relations_identity ON brain_relations(app_id, ifnull(context_id, -1), from_scene_id,
    ifnull(element_key_id, ''), verb, arguments_key, ifnull(to_scene_id, ''), outcome, ifnull(effect_kind, ''));
CREATE INDEX brain_relations_by_state ON brain_relations(app_id, from_scene_id, element_key_id, verb);
CREATE INDEX brain_relation_proofs_by_call ON brain_relation_proofs(call_event_id);
CREATE INDEX brain_scene_shapes_by_roles ON brain_scene_shapes(app_id, role_key);
CREATE INDEX brain_relation_evaluations_by_group ON brain_relation_evaluations(group_key) WHERE group_key IS NOT NULL;
CREATE INDEX brain_relation_evaluations_recoverable ON brain_relation_evaluations(call_event_id) WHERE recoverable = 1;
CREATE INDEX brain_relation_evaluations_by_policy ON brain_relation_evaluations(policy_version);
CREATE INDEX brain_relation_evidence_by_call ON brain_relation_evidence(call_event_id, sequence);
CREATE INDEX brain_anchor_label_keys_by_label ON brain_anchor_label_keys(app_id, label_key);
CREATE INDEX brain_anchors_named_by_model ON brain_anchors(app_id, kind) WHERE retired_at_ms IS NULL AND label_source = 'llm';
CREATE INDEX brain_anchors_unlabeled ON brain_anchors(app_id, kind) WHERE retired_at_ms IS NULL AND label = '';
CREATE INDEX brain_group_members_by_anchor ON brain_group_members(anchor_id);
CREATE UNIQUE INDEX memory_recall_generations_one_ready ON memory_recall_generations(status) WHERE status = 'ready';
CREATE UNIQUE INDEX memory_recall_generations_one_building ON memory_recall_generations(status) WHERE status = 'building';
CREATE INDEX memory_recall_entries_by_route ON memory_recall_entries(route_id, generation_id);
CREATE INDEX memory_recall_entries_by_document ON memory_recall_entries(document_id);
CREATE INDEX memory_recall_work_pending ON memory_recall_work(work_id) WHERE done_at_ms IS NULL;
CREATE INDEX memory_recall_work_pending_route ON memory_recall_work(route_id) WHERE done_at_ms IS NULL;
CREATE INDEX memory_recall_queries_by_attempt ON memory_recall_queries(task_occurrence_id, recorded_at_ms);
CREATE INDEX memory_parameter_bindings_by_route ON memory_parameter_bindings(route_id);
CREATE INDEX memory_parameter_details_by_route ON memory_parameter_details(route_id);
CREATE INDEX memory_part_contract_items_by_route ON memory_part_contract_items(route_id);
CREATE INDEX memory_routes_by_superseded ON memory_routes(supersedes_route_id) WHERE supersedes_route_id IS NOT NULL;
CREATE INDEX memory_recall_selections_by_route ON memory_recall_selections(route_id, role);
CREATE INDEX memory_recall_proposals_by_attempt ON memory_recall_proposals(task_occurrence_id, recorded_at_ms);
CREATE INDEX memory_call_result_fields_value ON memory_call_result_fields(text_value) WHERE text_value IS NOT NULL;
CREATE INDEX memory_call_reconciliations_evidence ON memory_call_reconciliations(evidence_event_id)
    WHERE evidence_event_id IS NOT NULL;
CREATE UNIQUE INDEX brain_element_keys_live ON brain_element_keys(app_id,digest) WHERE replaced_by_id IS NULL;
CREATE UNIQUE INDEX memory_elements_live ON memory_elements(digest) WHERE replaced_by_id IS NULL;
CREATE UNIQUE INDEX memory_element_sets_live ON memory_element_sets(digest) WHERE replaced_by_id IS NULL;
CREATE UNIQUE INDEX brain_scene_elements_live ON brain_scene_elements(scene_id,element_key) WHERE replaced_by_id IS NULL;
CREATE UNIQUE INDEX brain_anchor_label_keys_live ON brain_anchor_label_keys(anchor_id,label_key) WHERE replaced_by_id IS NULL;
CREATE INDEX brain_scenes_skeleton ON brain_scenes(app_id,skeleton_digest);
CREATE INDEX brain_scene_kind_members_latest ON brain_scene_kind_members(scene_id,membership_id);
CREATE UNIQUE INDEX brain_relations_kind_identity ON brain_relations(app_id,kind_id,ifnull(element_key_id,0),verb,arguments_key,outcome,ifnull(effect_kind,'')) WHERE kind_id IS NOT NULL;
CREATE INDEX memory_phase_families_masked ON memory_phase_families(app_id,kind,has_parameter,masked_digest);
CREATE UNIQUE INDEX memory_attempt_reused_parts_once ON memory_attempt_reused_parts(task_occurrence_id,part_id,ifnull(item_id,0));
CREATE INDEX memory_procedure_parts_app_kind ON memory_procedure_parts(app_id,part_kind);
CREATE INDEX memory_part_contract_items_scene_kind ON memory_part_contract_items(scene_id,item_kind) WHERE scene_id IS NOT NULL;
CREATE INDEX memory_todo_item_states_part_revision ON memory_todo_item_states(linked_part_id,todo_revision_id) WHERE linked_part_id IS NOT NULL;
CREATE INDEX memory_value_redactions_set_position ON memory_value_redactions(set_id,set_position) WHERE set_id IS NOT NULL;

-- section: triggers
CREATE TRIGGER memory_brain_command_inputs_history_immutable BEFORE UPDATE OF command_input_id,event_id,sample_observation_id,operation,requested_at_ms,contract_version,detection_count,window,capture_completeness,capture_surface,representation,spatial_coverage,verb,effect_event_id ON memory_brain_command_inputs
BEGIN
    SELECT RAISE(ABORT, 'immutable Brain command input');
END;

CREATE TRIGGER memory_brain_command_inputs_history_no_delete BEFORE DELETE ON memory_brain_command_inputs
BEGIN
    SELECT RAISE(ABORT, 'immutable Brain command input');
END;

CREATE TRIGGER memory_brain_command_detections_history_immutable BEFORE UPDATE OF command_input_id,position,kind,label,x,y,width,height,state ON memory_brain_command_detections
BEGIN
    SELECT RAISE(ABORT, 'immutable Brain command input');
END;

CREATE TRIGGER memory_brain_command_detections_history_no_delete BEFORE DELETE ON memory_brain_command_detections
BEGIN
    SELECT RAISE(ABORT, 'immutable Brain command input');
END;

CREATE TRIGGER brain_scenes_kind_immutable BEFORE UPDATE OF scene_id,scene_uuid,app_id,window_title_pattern,title_bucket,scene_kind,structural_key,first_seen_ms,set_id,skeleton_digest ON brain_scenes
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_events_identity_immutable BEFORE UPDATE OF event_id,event_uuid,source,source_stream_id,source_key,trace_id,session_id,parent_event_id,parent_position,event_kind,app_id,context_id,occurred_at_ms,monotonic_ns,origin_event_id ON memory_events
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_agent_actions_identity_immutable BEFORE UPDATE OF event_id,event_kind,app_id,tool_kind,contract_version,requested_count ON memory_agent_actions
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_agent_actions_gesture_once
BEFORE UPDATE OF gesture ON memory_agent_actions WHEN OLD.gesture IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'an outcome field is set once, never rewritten');
END;

CREATE TRIGGER memory_agent_actions_effect_once
BEFORE UPDATE OF effect ON memory_agent_actions WHEN OLD.effect IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'an outcome field is set once, never rewritten');
END;

CREATE TRIGGER memory_agent_actions_effect_reason_once
BEFORE UPDATE OF effect_reason ON memory_agent_actions WHEN OLD.effect_reason IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'an outcome field is set once, never rewritten');
END;

CREATE TRIGGER memory_agent_actions_recovery_once
BEFORE UPDATE OF recovery ON memory_agent_actions WHEN OLD.recovery IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'an outcome field is set once, never rewritten');
END;

CREATE TRIGGER memory_agent_actions_recovery_reason_once
BEFORE UPDATE OF recovery_reason ON memory_agent_actions WHEN OLD.recovery_reason IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'an outcome field is set once, never rewritten');
END;

CREATE TRIGGER memory_agent_actions_outcome_origin_once
BEFORE UPDATE OF outcome_origin ON memory_agent_actions WHEN OLD.outcome_origin IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'an outcome field is set once, never rewritten');
END;

CREATE TRIGGER memory_agent_actions_learnable_once
BEFORE UPDATE OF learnable ON memory_agent_actions WHEN OLD.learnable IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'an outcome field is set once, never rewritten');
END;

CREATE TRIGGER memory_route_steps_identity_immutable BEFORE UPDATE OF step_id,route_id,position,step_kind,goal_text,app_id,called_route_id,actor,segment_id,person_evidence ON memory_route_steps
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER brain_applications_immutable BEFORE UPDATE OF application_id,app_id,event_id,operation,phase,sample_ordinal,sample_observation_id,sample_kind,contract_version,algorithm_version,requested_at_ms,effective_at_ms,outcome,created_count,updated_count,skipped_ambiguous_count,anchor_id,transition_id,evidence_count ON brain_applications
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER brain_applications_kept BEFORE DELETE ON brain_applications
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_tasks_identity_immutable BEFORE UPDATE OF task_id,task_uuid,contract_version,source,source_stream_id,trace_id,opened_at_ms ON memory_tasks
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_tasks_forward_only BEFORE UPDATE OF status,closed_at_ms,current_revision ON memory_tasks
BEGIN
    SELECT RAISE(ABORT, 'a closed task does not move') WHERE OLD.status IN ('completed','failed','abandoned');
    SELECT RAISE(ABORT, 'task revisions move forward') WHERE NEW.current_revision < OLD.current_revision;
END;

CREATE TRIGGER memory_tasks_kept BEFORE DELETE ON memory_tasks
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_task_revisions_immutable BEFORE UPDATE OF task_revision_id,task_id,revision,recorded_at_ms,change_kind,reason,goal,requested_result ON memory_task_revisions
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_task_constraints_immutable BEFORE UPDATE OF task_id,revision,position,constraint_text,task_revision_id ON memory_task_constraints
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_task_message_refs_immutable BEFORE UPDATE OF task_id,revision,position,message_ref,task_revision_id ON memory_task_message_refs
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_task_values_immutable BEFORE UPDATE OF value_id,task_id,revision,task_occurrence_id,checkpoint_sequence,position,name,role,value_kind,content,text_value,sensitivity,source,source_ref,source_version,task_revision_id,checkpoint_id,value_digest ON memory_task_values
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_task_attempts_immutable BEFORE UPDATE OF task_occurrence_id,task_id,ordinal,resumes_task_occurrence_id,source,source_stream_id,opened_at_ms,opened_at_revision,task_revision_id ON memory_task_attempts
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_task_checkpoints_immutable BEFORE UPDATE OF checkpoint_id,task_occurrence_id,sequence,checkpoint_kind,task_id,revision,recorded_at_ms,declared_status,note,task_revision_id ON memory_task_checkpoints
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_task_call_revisions_immutable BEFORE UPDATE OF event_id,task_occurrence_id,task_id,revision,task_revision_id ON memory_task_call_revisions
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_call_effects_immutable BEFORE UPDATE OF event_id,performed,substitute,not_sent_reason,target_element_id,target_role,target_label,target_section,checked ON memory_call_effects
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_call_routes_immutable BEFORE UPDATE OF event_id,route,handoff_reason ON memory_call_routes
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_call_adapter_dispatches_immutable BEFORE UPDATE OF event_id,adapter,verb ON memory_call_adapter_dispatches
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_call_rungs_immutable BEFORE UPDATE OF event_id,rung,how,skipped ON memory_call_rungs
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_call_route_advice_immutable BEFORE UPDATE OF event_id,decision,route,message ON memory_call_route_advice
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_operation_verifications_immutable BEFORE UPDATE OF event_id,call_event_id,contract_version,condition_kind,method_version,performed,substitute,target_element_id,target_role,target_label,target_section ON memory_operation_verifications
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_operation_verification_limits_immutable BEFORE UPDATE OF event_id,position,limit_kind ON memory_operation_verification_limits
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_operation_verification_samples_immutable BEFORE UPDATE OF event_id,position,sample_observation_id,sample_event_id,sample_phase,sample_ordinal,sample_kind ON memory_operation_verification_samples
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_value_redactions_immutable BEFORE UPDATE OF redaction_id,event_id,location_kind,argument_name,argument_position,condition_kind,sample_phase,sample_ordinal,element_position,reason,set_id,set_position ON memory_value_redactions
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_value_redactions_kept BEFORE DELETE ON memory_value_redactions
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_call_recording_gaps_immutable BEFORE UPDATE OF event_id,part,reason,detail ON memory_call_recording_gaps
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_call_recording_gaps_kept BEFORE DELETE ON memory_call_recording_gaps
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_origin_events_immutable BEFORE UPDATE OF origin_id,source_event_id,event_id,disposition ON memory_origin_events
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_origin_brain_contributions_immutable BEFORE UPDATE OF origin_id,bundle_id,element_kind,element_key,disposition,withheld ON memory_origin_brain_contributions
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_origin_brain_contributions_kept BEFORE DELETE ON memory_origin_brain_contributions
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_procedure_candidates_immutable BEFORE UPDATE OF candidate_id,task_id,task_occurrence_id,policy_version,structure_digest,checkpoint_sequence,built_at_ms,step_count,block_count,checkpoint_id ON memory_procedure_candidates
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_procedure_candidates_kept BEFORE DELETE ON memory_procedure_candidates
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_candidate_steps_immutable BEFORE UPDATE OF candidate_id,position,step_occurrence_id,call_event_id,block_index,app_id,step_kind,actor,segment_id,person_evidence ON memory_candidate_steps
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_candidate_steps_kept BEFORE DELETE ON memory_candidate_steps
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_procedure_interpretations_immutable BEFORE UPDATE OF interpretation_id,candidate_id,revision,contract_version,payload_digest,source,source_stream_id,task_revision,attempt_state,recorded_at_ms ON memory_procedure_interpretations
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_procedure_interpretations_kept BEFORE DELETE ON memory_procedure_interpretations
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_interpretation_findings_immutable BEFORE UPDATE OF interpretation_id,position,finding,step_position,argument_name,argument_position ON memory_interpretation_findings
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_interpretation_findings_kept BEFORE DELETE ON memory_interpretation_findings
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_procedure_versions_immutable BEFORE UPDATE OF route_id,interpretation_id,candidate_id,task_id,task_occurrence_id,contract_version,variant_of_route_id,divergence_position,built_at_ms ON memory_procedure_versions
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_procedure_versions_kept BEFORE DELETE ON memory_procedure_versions
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_procedure_parts_immutable BEFORE UPDATE OF part_id,part_uuid,route_id,part_kind,parent_part_id,first_position,last_position,step_id,app_id,label,declared_outcome ON memory_procedure_parts
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_procedure_parts_kept BEFORE DELETE ON memory_procedure_parts
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_part_contract_items_immutable BEFORE UPDATE OF part_id,position,route_id,item_kind,parameter_id,app_id,scene_id ON memory_part_contract_items
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_parameter_details_immutable BEFORE UPDATE OF parameter_id,route_id,role,value_kind,unit,sensitivity,produced_by_part_id ON memory_parameter_details
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_operation_argument_segments_immutable BEFORE UPDATE OF route_id,operation_id,argument_name,argument_position,argument_index,segment_position,segment_kind,literal_text,parameter_id ON memory_operation_argument_segments
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_parameter_bindings_immutable BEFORE UPDATE OF parameter_id,route_id,task_occurrence_id,content,text_value,source,source_ref,source_version,value_digest ON memory_parameter_bindings
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_procedure_step_occurrences_immutable BEFORE UPDATE OF route_id,step_id,step_occurrence_id ON memory_procedure_step_occurrences
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_part_qualifications_immutable BEFORE UPDATE OF qualification_id,part_id,sequence,policy_id,verdict,evaluated_at_ms ON memory_part_qualifications
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_part_qualifications_kept BEFORE DELETE ON memory_part_qualifications
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_part_qualification_reasons_immutable BEFORE UPDATE OF part_id,sequence,position,reason,step_position,call_event_id,qualification_id ON memory_part_qualification_reasons
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_part_qualification_evidence_immutable BEFORE UPDATE OF part_id,sequence,step_position,call_event_id,verification_event_id,origin,qualification_id ON memory_part_qualification_evidence
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_part_states_immutable BEFORE UPDATE OF part_id,sequence,state,reason_code,recorded_at_ms,recorded_by,origin_id ON memory_part_states
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_part_states_kept BEFORE DELETE ON memory_part_states
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_qualification_policies_kept BEFORE DELETE ON memory_qualification_policies
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_relations_identity_immutable BEFORE UPDATE OF relation_id,relation_uuid,app_id,context_id,from_scene_id,scene_element_id,verb,arguments_key,to_scene_id,outcome,effect_kind,first_seen_ms,kind_id,element_key_id ON brain_relations
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER brain_relations_kept BEFORE DELETE ON brain_relations
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_relation_proofs_immutable BEFORE UPDATE OF relation_id,call_event_id,relation,verification_event_id,policy_version,assessed_at_ms,to_scene_id ON brain_relation_proofs
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER brain_relation_proofs_kept BEFORE DELETE ON brain_relation_proofs
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_relation_applications_immutable BEFORE UPDATE OF call_event_id,app_id,policy_version,outcome,reason,applied_at_ms ON brain_relation_applications
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER brain_relation_applications_kept BEFORE DELETE ON brain_relation_applications
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_scene_shapes_immutable BEFORE UPDATE OF scene_id,app_id,role_key ON brain_scene_shapes
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER brain_relation_evaluations_immutable BEFORE UPDATE OF evaluation_id,call_event_id,sequence,app_id,policy_version,cause,outcome,reason,recoverable,group_key,expected_effect_kind,evaluated_at_ms ON brain_relation_evaluations
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER brain_relation_evaluations_kept BEFORE DELETE ON brain_relation_evaluations
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_relation_evidence_immutable BEFORE UPDATE OF relation_id,call_event_id,sequence,relation,verification_event_id,policy_version,assessed_at_ms,evaluation_id ON brain_relation_evidence
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER brain_relation_evidence_kept BEFORE DELETE ON brain_relation_evidence
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_variant_prefixes_immutable BEFORE UPDATE OF route_id,status,compared_steps,reason,checked_at_ms ON memory_variant_prefixes
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_variant_prefixes_kept BEFORE DELETE ON memory_variant_prefixes
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_variant_prefix_checks_immutable BEFORE UPDATE OF route_id,status,compared_steps,reason,checked_at_ms ON memory_variant_prefix_checks
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_variant_prefix_checks_kept BEFORE DELETE ON memory_variant_prefix_checks
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

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

CREATE TRIGGER memory_recall_spaces_immutable BEFORE UPDATE OF space_int_id,space_id,model_id,model_revision,weights_digest,tokenizer_digest,dimensions,pooling,normalization,precision,query_prefix,document_prefix,maximum_tokens,recorded_at_ms ON memory_recall_spaces
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_recall_spaces_kept BEFORE DELETE ON memory_recall_spaces
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
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

CREATE TRIGGER memory_recall_queries_immutable BEFORE UPDATE OF query_id,task_id,task_occurrence_id,task_revision,source,source_stream_id,reason,remaining_work,generation_id,channel,search_status,search_note,candidate_limit,candidates_considered,coverage,delivery,delivery_bytes,selector_version,recorded_at_ms,duration_us ON memory_recall_queries
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_recall_queries_kept BEFORE DELETE ON memory_recall_queries
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_recall_needs_immutable BEFORE UPDATE OF need_id,query_id,position,text,bundle_id,coverage,reason ON memory_recall_needs
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_recall_needs_kept BEFORE DELETE ON memory_recall_needs
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_recall_selections_immutable BEFORE UPDATE OF selection_id,query_id,need_position,position,role,route_id,first_position,last_position,whole_part_id,relevance,preparations,need_id ON memory_recall_selections
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_recall_selections_kept BEFORE DELETE ON memory_recall_selections
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_recall_requirements_immutable BEFORE UPDATE OF query_id,need_position,selection_position,position,kind,step_position,parameter_id,scene_id,bundle_id,task_value_name,binding_match,constraint_position,selection_id ON memory_recall_requirements
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_recall_requirements_kept BEFORE DELETE ON memory_recall_requirements
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_recall_links_immutable BEFORE UPDATE OF query_id,need_position,call_event_id,step_position,confirmed,undetermined,linked_at_ms,need_id ON memory_recall_links
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_recall_links_kept BEFORE DELETE ON memory_recall_links
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_recall_reports_immutable BEFORE UPDATE OF query_id,need_position,sequence,declared,cause,note,recorded_at_ms,need_id ON memory_recall_reports
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_recall_reports_kept BEFORE DELETE ON memory_recall_reports
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_recall_proposals_immutable BEFORE UPDATE OF proposal_id,task_id,task_occurrence_id,task_revision,source,source_stream_id,reason,remaining_work,generation_id,channel,search_status,search_note,candidates_considered,proposal_bytes,format_version,recorded_at_ms,duration_us ON memory_recall_proposals
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_recall_proposals_kept BEFORE DELETE ON memory_recall_proposals
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_recall_proposal_needs_immutable BEFORE UPDATE OF proposal_need_id,proposal_id,position,text,bundle_id ON memory_recall_proposal_needs
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_recall_proposal_needs_kept BEFORE DELETE ON memory_recall_proposal_needs
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_recall_proposal_sources_immutable BEFORE UPDATE OF proposal_id,need_position,position,source_key,route_id,relevance,suggested_first,suggested_last,proposal_need_id ON memory_recall_proposal_sources
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_recall_proposal_sources_kept BEFORE DELETE ON memory_recall_proposal_sources
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_recall_choices_immutable BEFORE UPDATE OF query_id,proposal_id,recorded_at_ms ON memory_recall_choices
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_recall_choices_kept BEFORE DELETE ON memory_recall_choices
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_recall_choice_needs_immutable BEFORE UPDATE OF query_id,need_position,declared,uncovered,settled_by,need_id ON memory_recall_choice_needs
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_recall_choice_needs_kept BEFORE DELETE ON memory_recall_choice_needs
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_recall_choice_links_immutable BEFORE UPDATE OF query_id,need_position,selection_position,call_event_id,step_position,confirmed,undetermined,linked_at_ms,need_id,selection_id ON memory_recall_choice_links
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_recall_choice_links_kept BEFORE DELETE ON memory_recall_choice_links
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_call_argument_fields_immutable BEFORE UPDATE OF event_id,field_path,value_kind,field_kind,text_value,withheld_reason,source_event_id,source_path ON memory_call_argument_fields
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_call_argument_fields_kept BEFORE DELETE ON memory_call_argument_fields
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_call_result_fields_immutable BEFORE UPDATE OF event_id,field_path,value_kind,text_value,withheld_reason ON memory_call_result_fields
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_call_result_fields_kept BEFORE DELETE ON memory_call_result_fields
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_call_data_contexts_immutable BEFORE UPDATE OF event_id,service,route,profile_ref,account_ref,account_source,resource_kind,resource_ref ON memory_call_data_contexts
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_call_data_contexts_kept BEFORE DELETE ON memory_call_data_contexts
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_operation_argument_fields_immutable BEFORE UPDATE OF route_id,operation_id,argument_name,argument_position,field_path,field_kind,value_kind,text_value,parameter_id,source_step_position,source_path ON memory_operation_argument_fields
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_operation_argument_fields_kept BEFORE DELETE ON memory_operation_argument_fields
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_identity_salts_immutable BEFORE UPDATE OF salt_id,salt ON memory_identity_salts
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_identity_salts_kept BEFORE DELETE ON memory_identity_salts
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_executors_immutable BEFORE UPDATE OF executor_id,source,process_id,started_at_ms ON memory_executors
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_executors_kept BEFORE DELETE ON memory_executors
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_call_executors_immutable BEFORE UPDATE OF event_id,executor_id ON memory_call_executors
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_call_executors_kept BEFORE DELETE ON memory_call_executors
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_call_reconciliations_immutable BEFORE UPDATE OF event_id,sequence,kind,finding,evidence_event_id,declared_by,recorded_at_ms,detail ON memory_call_reconciliations
BEGIN
    SELECT RAISE(ABORT, 'history identity is immutable');
END;

CREATE TRIGGER memory_call_reconciliations_kept BEFORE DELETE ON memory_call_reconciliations
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_apps_history_immutable BEFORE UPDATE OF app_id,bundle_id ON brain_apps
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER brain_apps_history_kept BEFORE DELETE ON brain_apps
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_app_window_epochs_history_immutable BEFORE UPDATE OF app_id,window_family ON brain_app_window_epochs
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER brain_app_contexts_history_immutable BEFORE UPDATE OF context_id,app_id,app_version,app_locale ON brain_app_contexts
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER brain_app_contexts_history_kept BEFORE DELETE ON brain_app_contexts
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_scenes_history_kept BEFORE DELETE ON brain_scenes
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_scene_roles_history_immutable BEFORE UPDATE OF scene_id,role,count_bucket ON brain_scene_roles
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER brain_scene_roles_history_kept BEFORE DELETE ON brain_scene_roles
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_scene_labels_history_immutable BEFORE UPDATE OF scene_id,label_token ON brain_scene_labels
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER brain_scene_labels_history_kept BEFORE DELETE ON brain_scene_labels
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_anchors_history_immutable BEFORE UPDATE OF anchor_id,app_id,insertion_order,kind,label,label_source,anchor_scope,typical_x,typical_y,typical_width,typical_height,window_family,first_seen_ms,last_seen_ms,seen_count,last_seen_epoch,current_group_id,retired_at_ms,retired_epoch,retirement_cause ON brain_anchors
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER brain_anchors_history_kept BEFORE DELETE ON brain_anchors
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_anchors_frozen BEFORE INSERT ON brain_anchors
BEGIN
    SELECT RAISE(ABORT, 'historical projection is frozen');
END;

CREATE TRIGGER brain_anchor_aliases_history_immutable BEFORE UPDATE OF anchor_id,alias,position ON brain_anchor_aliases
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER brain_anchor_aliases_history_kept BEFORE DELETE ON brain_anchor_aliases
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_anchor_aliases_frozen BEFORE INSERT ON brain_anchor_aliases
BEGIN
    SELECT RAISE(ABORT, 'historical projection is frozen');
END;

CREATE TRIGGER brain_anchor_states_history_immutable BEFORE UPDATE OF anchor_id,state,seen_count ON brain_anchor_states
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER brain_anchor_states_history_kept BEFORE DELETE ON brain_anchor_states
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_anchor_states_frozen BEFORE INSERT ON brain_anchor_states
BEGIN
    SELECT RAISE(ABORT, 'historical projection is frozen');
END;

CREATE TRIGGER brain_scene_elements_history_immutable BEFORE UPDATE OF scene_element_id,app_id,scene_id,element_key,element_scope,parent_element_id,edge_hash,cursor_affordance,label,label_origin,role,kind,source,bounds_x,bounds_y,bounds_width,bounds_height,first_seen_ms,last_seen_ms,observation_count,replaced_by_id ON brain_scene_elements
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER brain_scene_elements_history_kept BEFORE DELETE ON brain_scene_elements
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_groups_history_immutable BEFORE UPDATE OF group_id,app_id,insertion_order,axis,shared_kind,cell_width,cell_height,name,last_seen_ms,seen_count,last_seen_epoch,retired_at_ms,retired_epoch,retirement_cause ON brain_groups
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER brain_groups_history_kept BEFORE DELETE ON brain_groups
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_groups_frozen BEFORE INSERT ON brain_groups
BEGIN
    SELECT RAISE(ABORT, 'historical projection is frozen');
END;

CREATE TRIGGER brain_group_members_history_immutable BEFORE UPDATE OF app_id,group_id,anchor_id,position ON brain_group_members
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER brain_group_members_history_kept BEFORE DELETE ON brain_group_members
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_group_members_frozen BEFORE INSERT ON brain_group_members
BEGIN
    SELECT RAISE(ABORT, 'historical projection is frozen');
END;

CREATE TRIGGER brain_menu_commands_history_immutable BEFORE UPDATE OF menu_command_id,app_id,path_key,first_seen_ms ON brain_menu_commands
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER brain_menu_commands_history_kept BEFORE DELETE ON brain_menu_commands
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_menu_path_segments_history_immutable BEFORE UPDATE OF menu_command_id,position,title ON brain_menu_path_segments
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER brain_menu_path_segments_history_kept BEFORE DELETE ON brain_menu_path_segments
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_transitions_history_immutable BEFORE UPDATE OF transition_id,app_id,insertion_order,from_scene_id,anchor_id,scene_element_id,menu_command_id,trigger_kind,to_scene_id,effect_kind,effect_text,required_target_state,resulting_target_state,effect_label,effect_value,last_observed_epoch,status,first_seen_ms,last_seen_ms,evidence_count,retired_at_ms,retired_epoch,retirement_cause ON brain_transitions
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER brain_transitions_history_kept BEFORE DELETE ON brain_transitions
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_transitions_frozen BEFORE INSERT ON brain_transitions
BEGIN
    SELECT RAISE(ABORT, 'historical projection is frozen');
END;

CREATE TRIGGER brain_transition_menu_items_history_immutable BEFORE UPDATE OF transition_id,position,title ON brain_transition_menu_items
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER brain_transition_menu_items_history_kept BEFORE DELETE ON brain_transition_menu_items
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_transition_menu_items_frozen BEFORE INSERT ON brain_transition_menu_items
BEGIN
    SELECT RAISE(ABORT, 'historical projection is frozen');
END;

CREATE TRIGGER memory_events_history_kept BEFORE DELETE ON memory_events
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_input_events_history_immutable BEFORE UPDATE OF event_id,event_kind,input_kind,sequence_number,target_pid,source_pid,window_number,window_title,window_x,window_y,window_width,window_height,point_x,point_y,delta_x,delta_y,started_at_ns,ended_at_ns,preceding_revision,revision,gap_first_sequence,gap_last_sequence,lost_critical,lost_coalescible,before_status,after_status,difference_status ON memory_input_events
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_input_events_history_kept BEFORE DELETE ON memory_input_events
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_agent_actions_history_kept BEFORE DELETE ON memory_agent_actions
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_agent_action_effect_labels_history_immutable BEFORE UPDATE OF event_id,position,label ON memory_agent_action_effect_labels
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_agent_action_effect_labels_history_kept BEFORE DELETE ON memory_agent_action_effect_labels
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_agent_action_status_history_immutable BEFORE UPDATE OF event_id,session_id,screen_recording,accessibility,post_event ON memory_agent_action_status
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_agent_action_status_history_kept BEFORE DELETE ON memory_agent_action_status
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_agent_action_listings_history_immutable BEFORE UPDATE OF event_id,listing_kind,hidden_count ON memory_agent_action_listings
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_agent_action_listings_history_kept BEFORE DELETE ON memory_agent_action_listings
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_agent_action_applications_history_immutable BEFORE UPDATE OF listing_application_id,event_id,position,name,bundle_id,pid,app_version,is_running,location,is_default_browser ON memory_agent_action_applications
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_agent_action_applications_history_kept BEFORE DELETE ON memory_agent_action_applications
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_agent_action_windows_history_immutable BEFORE UPDATE OF event_id,application_position,position,window_number,title,listing_application_id ON memory_agent_action_windows
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_agent_action_windows_history_kept BEFORE DELETE ON memory_agent_action_windows
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_agent_action_observations_history_immutable BEFORE UPDATE OF event_id,session_id,session_revision,observed_at_ms,sample_event_id,sample_phase,sample_ordinal,sample_observation_id,sample_kind ON memory_agent_action_observations
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_agent_action_observations_history_kept BEFORE DELETE ON memory_agent_action_observations
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_event_observations_history_immutable BEFORE UPDATE OF observation_id,event_id,phase,sample_ordinal,observation_kind,observation_contract_version,field_name,text_value,integer_value,real_value,boolean_value,observation_group,parent_observation_id,window_title,session_revision,surface_kind,status,candidate_rank,label,label_origin,container_path,role,element_kind,old_state,new_state,bounds_x,bounds_y,bounds_width,bounds_height,scene_age_ms,name_resolution,label_source,set_id,window_number,window_subrole,reject_reason ON memory_event_observations
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_event_observations_history_kept BEFORE DELETE ON memory_event_observations
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_event_scenes_history_immutable BEFORE UPDATE OF event_id,app_id,phase,sample_ordinal,scene_id,match_status,matched_by,matcher_version,confidence ON memory_event_scenes
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_event_scenes_history_kept BEFORE DELETE ON memory_event_scenes
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_verifications_history_immutable BEFORE UPDATE OF event_id,event_kind,scope,method,verdict,expected_text,observed_text ON memory_verifications
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_verifications_history_kept BEFORE DELETE ON memory_verifications
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_action_correlations_history_immutable BEFORE UPDATE OF watcher_event_id,agent_event_id,basis_kind,time_offset_ms,explanation ON memory_action_correlations
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_action_correlations_history_kept BEFORE DELETE ON memory_action_correlations
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_applications_frozen BEFORE INSERT ON brain_applications
BEGIN
    SELECT RAISE(ABORT, 'historical projection is frozen');
END;

CREATE TRIGGER brain_evidence_history_immutable BEFORE UPDATE OF evidence_id,app_id,event_id,relation,assessed_by,assessment_version,assessed_at_ms,scene_id,anchor_id,scene_element_id,group_id,menu_command_id,transition_id ON brain_evidence
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER brain_evidence_history_kept BEFORE DELETE ON brain_evidence
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_task_occurrences_history_immutable BEFORE UPDATE OF task_occurrence_id,task_occurrence_uuid,trace_id,started_at_ms ON memory_task_occurrences
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_task_occurrences_history_kept BEFORE DELETE ON memory_task_occurrences
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_task_events_history_immutable BEFORE UPDATE OF task_occurrence_id,event_id,position,role ON memory_task_events
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_task_events_history_kept BEFORE DELETE ON memory_task_events
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_task_labels_history_immutable BEFORE UPDATE OF label_id,task_occurrence_id,label,assigned_by,confidence,status,assigned_at_ms ON memory_task_labels
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_task_labels_history_kept BEFORE DELETE ON memory_task_labels
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_routes_history_immutable BEFORE UPDATE OF route_id,route_uuid,name,supersedes_route_id,created_at_ms ON memory_routes
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_routes_history_kept BEFORE DELETE ON memory_routes
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_route_parameters_history_immutable BEFORE UPDATE OF parameter_id,route_id,name,direction,value_type,is_required ON memory_route_parameters
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_route_parameters_history_kept BEFORE DELETE ON memory_route_parameters
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_route_steps_history_kept BEFORE DELETE ON memory_route_steps
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_step_checks_history_immutable BEFORE UPDATE OF check_id,route_id,step_id,app_id,position,check_kind,expected_scene_id,expected_anchor_id,expected_state,expected_text,expected_integer,expected_real,expected_bool,expected_parameter_id,comparison ON memory_step_checks
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_step_checks_history_kept BEFORE DELETE ON memory_step_checks
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_step_operations_history_immutable BEFORE UPDATE OF operation_id,route_id,step_id,parent_operation_id,position,tool_kind,contract_version,app_id ON memory_step_operations
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_step_operations_history_kept BEFORE DELETE ON memory_step_operations
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_operation_arguments_history_immutable BEFORE UPDATE OF argument_id,operation_id,event_id,brain_application_id,route_id,app_id,argument_name,position,value_kind,integer_value,real_value,boolean_value,parameter_id,anchor_id,menu_command_id ON memory_operation_arguments
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_operation_arguments_history_kept BEFORE DELETE ON memory_operation_arguments
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_route_call_bindings_history_immutable BEFORE UPDATE OF step_id,route_id,called_route_id,called_parameter_id,source_parameter_id,literal_text,literal_integer,literal_real,literal_bool ON memory_route_call_bindings
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_route_call_bindings_history_kept BEFORE DELETE ON memory_route_call_bindings
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_step_occurrences_history_immutable BEFORE UPDATE OF step_occurrence_id,started_at_ms ON memory_step_occurrences
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_step_occurrences_history_kept BEFORE DELETE ON memory_step_occurrences
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_step_events_history_immutable BEFORE UPDATE OF step_occurrence_id,event_id,position,attempt_number,role ON memory_step_events
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_step_events_history_kept BEFORE DELETE ON memory_step_events
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_route_evidence_history_immutable BEFORE UPDATE OF route_id,task_occurrence_id,relation,assessed_by,assessed_at_ms ON memory_route_evidence
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_route_evidence_history_kept BEFORE DELETE ON memory_route_evidence
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_step_evidence_history_immutable BEFORE UPDATE OF step_id,step_occurrence_id,relation,assessed_by,assessed_at_ms ON memory_step_evidence
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_step_evidence_history_kept BEFORE DELETE ON memory_step_evidence
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_experiences_history_immutable BEFORE UPDATE OF experience_id,phrase,route_id,step_id,created_at_ms ON memory_experiences
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_experiences_history_kept BEFORE DELETE ON memory_experiences
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_experience_bindings_history_immutable BEFORE UPDATE OF experience_id,route_id,parameter_id,value_type,binding_kind,binding_contract_version,slot_name,literal_text,literal_integer,literal_real,literal_boolean ON memory_experience_bindings
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_experience_bindings_history_kept BEFORE DELETE ON memory_experience_bindings
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_experience_uses_history_immutable BEFORE UPDATE OF experience_id,event_id,verdict ON memory_experience_uses
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_experience_uses_history_kept BEFORE DELETE ON memory_experience_uses
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_schema_migrations_history_immutable BEFORE UPDATE OF to_version,from_version,migrated_at_ms,copy_name ON memory_schema_migrations
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_schema_migrations_history_kept BEFORE DELETE ON memory_schema_migrations
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_task_revisions_history_kept BEFORE DELETE ON memory_task_revisions
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_task_constraints_history_kept BEFORE DELETE ON memory_task_constraints
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_task_message_refs_history_kept BEFORE DELETE ON memory_task_message_refs
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_task_attempts_history_kept BEFORE DELETE ON memory_task_attempts
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_task_checkpoints_history_kept BEFORE DELETE ON memory_task_checkpoints
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_task_values_history_kept BEFORE DELETE ON memory_task_values
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_task_call_revisions_history_kept BEFORE DELETE ON memory_task_call_revisions
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_call_effects_history_kept BEFORE DELETE ON memory_call_effects
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_call_routes_history_kept BEFORE DELETE ON memory_call_routes
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_call_adapter_dispatches_history_kept BEFORE DELETE ON memory_call_adapter_dispatches
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_call_rungs_history_kept BEFORE DELETE ON memory_call_rungs
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_call_route_advice_history_kept BEFORE DELETE ON memory_call_route_advice
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_operation_verifications_history_kept BEFORE DELETE ON memory_operation_verifications
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_operation_verification_limits_history_kept BEFORE DELETE ON memory_operation_verification_limits
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_operation_verification_samples_history_kept BEFORE DELETE ON memory_operation_verification_samples
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_archive_origins_history_immutable BEFORE UPDATE OF origin_id,origin_uuid,origin_kind,location,first_seen_at_ms ON memory_archive_origins
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_archive_origins_history_kept BEFORE DELETE ON memory_archive_origins
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_origin_events_history_kept BEFORE DELETE ON memory_origin_events
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_part_contract_items_history_kept BEFORE DELETE ON memory_part_contract_items
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_parameter_details_history_kept BEFORE DELETE ON memory_parameter_details
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_operation_argument_segments_history_kept BEFORE DELETE ON memory_operation_argument_segments
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_parameter_bindings_history_kept BEFORE DELETE ON memory_parameter_bindings
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_procedure_step_occurrences_history_kept BEFORE DELETE ON memory_procedure_step_occurrences
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_qualification_policies_history_immutable BEFORE UPDATE OF policy_id,policy_version ON memory_qualification_policies
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_part_qualification_reasons_history_kept BEFORE DELETE ON memory_part_qualification_reasons
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_part_qualification_evidence_history_kept BEFORE DELETE ON memory_part_qualification_evidence
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_relation_applications_frozen BEFORE INSERT ON brain_relation_applications
BEGIN
    SELECT RAISE(ABORT, 'historical projection is frozen');
END;

CREATE TRIGGER brain_scene_shapes_history_kept BEFORE DELETE ON brain_scene_shapes
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_anchor_label_keys_history_immutable BEFORE UPDATE OF label_key_id,anchor_id,app_id,label_key,replaced_by_id ON brain_anchor_label_keys
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER brain_anchor_label_keys_history_kept BEFORE DELETE ON brain_anchor_label_keys
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_anchor_label_keys_frozen BEFORE INSERT ON brain_anchor_label_keys
BEGIN
    SELECT RAISE(ABORT, 'historical projection is frozen');
END;

CREATE TRIGGER memory_variant_prefixes_frozen BEFORE INSERT ON memory_variant_prefixes
BEGIN
    SELECT RAISE(ABORT, 'historical projection is frozen');
END;

CREATE TRIGGER memory_todo_revisions_history_immutable BEFORE UPDATE OF todo_revision_id,task_id,revision,task_revision_id,reason_kind,reason_text,recorded_at_ms ON memory_todo_revisions
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_todo_revisions_history_kept BEFORE DELETE ON memory_todo_revisions
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_todo_items_history_immutable BEFORE UPDATE OF item_id,item_uuid,task_id,first_revision,row_key,origin ON memory_todo_items
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_todo_items_history_kept BEFORE DELETE ON memory_todo_items
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_todo_item_states_history_immutable BEFORE UPDATE OF item_id,todo_revision_id,position,title,app_name,linked_part_id,status,closed_by,check_verdict,expectation_revision_id ON memory_todo_item_states
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_todo_item_states_history_kept BEFORE DELETE ON memory_todo_item_states
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_todo_item_expectations_history_immutable BEFORE UPDATE OF item_id,todo_revision_id,predicate_position,kind,operand,parameter_name,second_parameter_name,app_id,subject_key,expected_state,presence ON memory_todo_item_expectations
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_todo_item_expectations_history_kept BEFORE DELETE ON memory_todo_item_expectations
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_call_steps_history_immutable BEFORE UPDATE OF event_id,item_id ON memory_call_steps
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_call_steps_history_kept BEFORE DELETE ON memory_call_steps
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_task_end_checks_history_immutable BEFORE UPDATE OF task_occurrence_id,verdict,scope,goal_match ON memory_task_end_checks
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_task_end_checks_history_kept BEFORE DELETE ON memory_task_end_checks
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_gesture_evidence_history_immutable BEFORE UPDATE OF event_id,comparable,looked_again,settle_kind,settle_ending,settle_detail,settle_waited_ms,settle_cap_ms,settle_channels,settle_surfaces,readback,verdict_change_position,verdict_differs_from_learning ON memory_gesture_evidence
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_gesture_evidence_history_kept BEFORE DELETE ON memory_gesture_evidence
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_gesture_changes_history_immutable BEFORE UPDATE OF event_id,position,kind,subject_key,scope,stability,family ON memory_gesture_changes
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_gesture_changes_history_kept BEFORE DELETE ON memory_gesture_changes
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_batch_stops_history_immutable BEFORE UPDATE OF event_id,stopped_at_position,reason ON memory_batch_stops
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_batch_stops_history_kept BEFORE DELETE ON memory_batch_stops
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_operation_argument_links_history_immutable BEFORE UPDATE OF event_id,argument_name,position,link_kind,parameter_name,template,derivation,field_role,value_digest ON memory_operation_argument_links
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_operation_argument_links_history_kept BEFORE DELETE ON memory_operation_argument_links
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_step_signatures_history_immutable BEFORE UPDATE OF signature_id,app_id,signature_digest,verb,element_key_id,arguments_shape ON memory_step_signatures
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_step_signatures_history_kept BEFORE DELETE ON memory_step_signatures
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_step_signature_members_history_immutable BEFORE UPDATE OF signature_id,step_id ON memory_step_signature_members
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_step_signature_members_history_kept BEFORE DELETE ON memory_step_signature_members
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_recall_calibration_history_immutable BEFORE UPDATE OF query_id,need_position,part_id,rank,cosine,lexical,score,threshold,delivered ON memory_recall_calibration
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_recall_calibration_history_kept BEFORE DELETE ON memory_recall_calibration
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_part_misses_history_immutable BEFORE UPDATE OF miss_id,item_id,query_id,part_id,similarity,recorded_at_ms ON memory_part_misses
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_part_misses_history_kept BEFORE DELETE ON memory_part_misses
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_attempt_reused_parts_history_immutable BEFORE UPDATE OF reuse_id,task_occurrence_id,part_id,item_id,recorded_at_ms ON memory_attempt_reused_parts
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_attempt_reused_parts_history_kept BEFORE DELETE ON memory_attempt_reused_parts
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_elements_history_immutable BEFORE UPDATE OF element_id,digest,role,kind,label,label_origin,container_path,state,replaced_by_id ON memory_elements
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_elements_history_kept BEFORE DELETE ON memory_elements
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_element_sets_history_immutable BEFORE UPDATE OF set_id,digest,members,replaced_by_id ON memory_element_sets
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_element_sets_history_kept BEFORE DELETE ON memory_element_sets
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_element_keys_history_immutable BEFORE UPDATE OF element_key_id,app_id,key_text,digest,first_seen_ms,replaced_by_id ON brain_element_keys
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER brain_element_keys_history_kept BEFORE DELETE ON brain_element_keys
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_screen_kinds_history_immutable BEFORE UPDATE OF kind_id,kind_uuid,app_id,method_name ON brain_screen_kinds
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER brain_screen_kinds_history_kept BEFORE DELETE ON brain_screen_kinds
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_scene_kind_members_history_immutable BEFORE UPDATE OF membership_id,scene_id,kind_id,since_ms,merge_id ON brain_scene_kind_members
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER brain_scene_kind_members_history_kept BEFORE DELETE ON brain_scene_kind_members
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER brain_scene_merges_history_immutable BEFORE UPDATE OF merge_id,app_id,subject,from_scene_id,into_scene_id,from_kind_id,into_kind_id,action,recorded_by,reason_code,origin_id,recorded_at_ms ON brain_scene_merges
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER brain_scene_merges_history_kept BEFORE DELETE ON brain_scene_merges
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_consolidation_queue_history_immutable BEFORE UPDATE OF seq,job_kind,ref_id,enqueued_at_ms ON memory_consolidation_queue
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_consolidation_cursors_history_immutable BEFORE UPDATE OF job_kind ON memory_consolidation_cursors
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_consolidation_cursors_history_kept BEFORE DELETE ON memory_consolidation_cursors
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_part_judgments_history_immutable BEFORE UPDATE OF judgment_id,part_id,family_root_route_id,judgment,recorded_by,reason_code,origin_id,recorded_at_ms ON memory_part_judgments
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_part_judgments_history_kept BEFORE DELETE ON memory_part_judgments
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_forget_tombstones_history_immutable BEFORE UPDATE OF tombstone_id,tombstone_uuid,bundle_id,key_kind,method_key,verb,recorded_at_ms,reason_code ON memory_forget_tombstones
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_forget_tombstones_history_kept BEFORE DELETE ON memory_forget_tombstones
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_part_origins_history_immutable BEFORE UPDATE OF part_id,origin_id,source_part_uuid,recorded_at_ms ON memory_part_origins
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_part_origins_history_kept BEFORE DELETE ON memory_part_origins
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_procedure_provenance_history_immutable BEFORE UPDATE OF route_id,third_party_content,exit_point,person_episode,learned_via,client_ref,confirmed,confirmed_by_attempt ON memory_procedure_provenance
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_procedure_provenance_history_kept BEFORE DELETE ON memory_procedure_provenance
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_procedure_exit_points_history_immutable BEFORE UPDATE OF route_id,step_position,exit_point ON memory_procedure_exit_points
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_procedure_exit_points_history_kept BEFORE DELETE ON memory_procedure_exit_points
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_person_segments_history_immutable BEFORE UPDATE OF segment_id,task_occurrence_id,before_event_id,after_event_id,started_at_ms,ended_at_ms,reason,person_only_kind,coverage ON memory_person_segments
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_person_segments_history_kept BEFORE DELETE ON memory_person_segments
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_segment_checks_history_immutable BEFORE UPDATE OF segment_id,position,kind,app_id,window_number,subject_key,operand,parameter_name,expected_state,coverage ON memory_segment_checks
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_segment_checks_history_kept BEFORE DELETE ON memory_segment_checks
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_person_commands_history_immutable BEFORE UPDATE OF command_id,segment_id,position,kind,element_key_id,menu_path,key_code,modifiers,effect_kind,coverage,cause,scene_before_id,scene_after_id,arrival_kind,arrival_state,arrival_parameter ON memory_person_commands
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_person_commands_history_kept BEFORE DELETE ON memory_person_commands
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_call_capabilities_history_immutable BEFORE UPDATE OF event_id,capability_id,effect_class,channel,origin,origin_name ON memory_call_capabilities
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_call_capabilities_history_kept BEFORE DELETE ON memory_call_capabilities
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_step_capabilities_history_immutable BEFORE UPDATE OF step_id,position,capability_id ON memory_step_capabilities
BEGIN
    SELECT RAISE(ABORT, 'history is immutable');
END;

CREATE TRIGGER memory_step_capabilities_history_kept BEFORE DELETE ON memory_step_capabilities
BEGIN
    SELECT RAISE(ABORT, 'history is kept');
END;

CREATE TRIGGER memory_part_qualifications_publish_once BEFORE UPDATE OF complete ON memory_part_qualifications WHEN NOT (OLD.complete = 0 AND NEW.complete = 1)
BEGIN
    SELECT RAISE(ABORT, 'qualification publishes once');
END;

CREATE TRIGGER memory_recall_calibration_used_once BEFORE UPDATE OF used ON memory_recall_calibration WHEN OLD.used IS NOT NULL OR NEW.used IS NULL
BEGIN
    SELECT RAISE(ABORT, 'use is recorded once');
END;

CREATE TRIGGER memory_task_attempts_takeover_forward BEFORE UPDATE OF takeover ON memory_task_attempts WHEN OLD.takeover = 'person_episode' AND NEW.takeover <> OLD.takeover
BEGIN
    SELECT RAISE(ABORT, 'takeover only moves forward');
END;

CREATE TRIGGER memory_operation_arguments_non_event_immutable BEFORE UPDATE OF text_value ON memory_operation_arguments WHEN OLD.event_id IS NULL
BEGIN
    SELECT RAISE(ABORT, 'only event argument text may change');
END;
