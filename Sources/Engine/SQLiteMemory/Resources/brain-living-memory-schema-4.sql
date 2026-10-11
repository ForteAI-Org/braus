-- Mecum Brain and living memory: schema 4, the additions to schema 3 (G76, plan D2 after its independent review).
-- Schema 4 is the schema 3 text, unchanged, followed by this text. A new archive runs the four in its bootstrap
-- transaction; an archive at the exact shape of schema 1, 2 or 3 runs the texts it lacks in the transaction that
-- migrates it, after a verified copy. No table of an earlier schema is altered or dropped: schema 3's register of
-- what each call taught under brain-relations-1 (brain_relation_applications, brain_relation_proofs) stays as it
-- was, the history of the first policy, and is written no more.
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
-- The one data statement states the variants built before this schema as suggested: their prefix was
-- declared and never verified. The anchors' label keys are filled in the migration's transaction by the store,
-- which normalizes labels as the projection does.
-- Same conventions: STRICT tables, no JSON column, no PRAGMA/BEGIN/COMMIT of its own.

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
        'stateFlip', 'menuOpened', 'elementsAppeared', 'elementsDisappeared', 'textSelectionChanged')),
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

INSERT INTO memory_variant_prefixes (route_id, status, compared_steps, reason, checked_at_ms)
SELECT route_id, 'suggested', 0, 'declared_before_verification', built_at_ms
FROM memory_procedure_versions WHERE variant_of_route_id IS NOT NULL;

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
