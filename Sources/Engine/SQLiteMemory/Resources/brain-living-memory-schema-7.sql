-- Mecum Brain and living memory: schema 7, the additions to schema 6 (G76, plan D3: the experiment of the Recall by
-- the agent's choice, Documentation/Engine/RecallAgentChoice.md).
-- Schema 7 is the schema 6 text, unchanged, followed by this text. A new archive runs the seven in its bootstrap
-- transaction; an archive at the exact shape of schema 1 to 6 runs the texts it lacks in the transaction that
-- migrates it, after a verified copy. No table of an earlier schema is altered or dropped; one trigger is added on a
-- schema 6 table, and schema 6's check of a requirement's step is replaced by the same checks with one case admitted.
--   - A proposal: the few versions a query shortlisted per need for the agent to choose from, with the automatic
--     selector's suggestion, before anything is delivered. A proposal is not a delivery.
--   - A choice: the delivered query (schema 6's rows, unchanged in meaning) that answers one proposal, the agent's
--     own declaration of how much of each need its tracts cover, kept apart from the coverage Engine derives, and the
--     links of the calls that followed to the tract and step each carried out.
-- No data statement. Same conventions: STRICT tables, no JSON column, no PRAGMA/BEGIN/COMMIT of its own.

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
-- rows, in order) and requirements are schema 6's rows; `input_produced` names a producer the need's plan includes
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

-- A choice's calls are linked to the tract they carried out, never through the links of schema 6, which name no tract.
CREATE TRIGGER memory_recall_links_not_of_choices BEFORE INSERT ON memory_recall_links
BEGIN
    SELECT RAISE(ABORT, 'a choice''s links name their tract')
    WHERE EXISTS (SELECT 1 FROM memory_recall_choices c WHERE c.query_id = NEW.query_id);
END;

-- ---------------------------------------------------------------------------------------------
-- A requirement of a chosen tract. A choice may hold several tracts of one version for a need, and an input of a later
-- tract may be produced in an earlier one: that `input_produced` names the producer's step, outside its own selection,
-- inside an earlier selected tract of the same version and need. Schema 6's trigger is replaced by the same checks with
-- that one case admitted; every other requirement is checked as before.
-- ---------------------------------------------------------------------------------------------

DROP TRIGGER memory_recall_requirements_valid;

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
