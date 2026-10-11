-- Mecum Brain and living memory: schema 3, the additions to schema 2 (G76, plan D2).
-- Schema 3 is the schema 2 text (schema 1 and its first additions), unchanged, followed by this text. A
-- new archive runs the three in its bootstrap transaction; an archive at the exact shape of schema 1 or
-- schema 2 runs the texts it lacks in the transaction that migrates it, after a verified copy. No table
-- of an earlier schema is altered and no column is reused with another meaning: what D2 builds from the
-- facts D1 keeps has tables of its own, and the indexes and triggers below that concern earlier tables
-- add to them without changing them. The one data statement fills the shapes of the structural scenes
-- an archive already holds, from its own rows.
--   - Memory: the system's segmentation of an attempt (a candidate), the agent's interpretations of it,
--     the procedure versions they produce over the Route tables, their parts (procedure, subprocedure,
--     step) with contracts, parameters' roles, templated arguments and episodic bindings, the link of
--     each definition step to the one occurrence of its call, and the qualification and operational
--     state of every part.
--   - Brain: relations from a functional state (a structural scene) through an element, a precise verb
--     and its relevant arguments to an outcome and a destination, each supported or contradicted by
--     one verified call at most once, with the register of what each call taught or why it taught
--     nothing.
-- Same conventions: STRICT tables, no JSON column, no PRAGMA/BEGIN/COMMIT of its own.

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
        'use_mismatch', 'unverifiable_use', 'missing_input', 'withheld_literal')),
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
        'elementsAppeared', 'elementsDisappeared', 'textSelectionChanged')),
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

INSERT INTO brain_scene_shapes (scene_id, app_id, role_key)
SELECT s.scene_id, s.app_id,
       ifnull((SELECT group_concat(r.role, char(31) ORDER BY r.role) FROM brain_scene_roles r WHERE r.scene_id = s.scene_id), '')
FROM brain_scenes s WHERE s.scene_kind <> 'app';

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
-- Triggers E (schema 3)
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
    SELECT RAISE(ABORT, 'a candidate step is a started UI operation')
    WHERE (SELECT tool_kind FROM memory_agent_actions WHERE event_id = NEW.call_event_id) NOT IN
              ('act', 'select', 'type_text', 'insert_text', 'press_key', 'scroll', 'drag', 'context_menu', 'menu', 'press')
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
