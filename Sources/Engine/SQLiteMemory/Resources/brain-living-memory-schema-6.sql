-- Mecum Brain and living memory: schema 6, the additions to schema 5 (G76, plan D3: the Recall).
-- Schema 6 is the schema 5 text, unchanged, followed by this text. A new archive runs the six in its bootstrap
-- transaction; an archive at the exact shape of schema 1 to 5 runs the texts it lacks in the transaction that
-- migrates it, after a verified copy. No table of an earlier schema is altered or dropped; triggers are added on
-- schema 3 tables so every write that changes what the catalogue offers also records the index work it needs.
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
-- No data statement: an archive migrated from schema 5 gets one index rebuild queued by the store in the same
-- transaction, since a text cannot read the time.
-- Same conventions: STRICT tables, no JSON column, no PRAGMA/BEGIN/COMMIT of its own.

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
        'certain_conflict', 'constraint_excluded')),
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
        'compatibility_unknown', 'unbound_task_input') OR step_position IS NOT NULL)
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

-- Lookups by version that schema 3 left without an index, made for every version a query reads (the version's
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

CREATE TRIGGER memory_recall_requirements_valid BEFORE INSERT ON memory_recall_requirements
BEGIN
    SELECT RAISE(ABORT, 'a requirement names a step of its selection')
    WHERE NEW.step_position IS NOT NULL AND NEW.kind NOT IN ('prerequisite_out_of_catalogue', 'prepared_before', 'output_ready')
      AND NOT EXISTS (
        SELECT 1 FROM memory_recall_selections s WHERE s.query_id = NEW.query_id AND s.need_position = NEW.need_position
          AND s.position = NEW.selection_position AND NEW.step_position BETWEEN s.first_position AND s.last_position);
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
