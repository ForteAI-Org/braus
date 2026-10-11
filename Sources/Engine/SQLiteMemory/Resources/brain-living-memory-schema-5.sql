-- Mecum Brain and living memory: schema 5, the additions to schema 4 (G76, plan D2 after its second review).
-- Schema 5 is the schema 4 text, unchanged, followed by this text. A new archive runs the five in its bootstrap
-- transaction; an archive at the exact shape of schema 1, 2, 3 or 4 runs the texts it lacks in the transaction that
-- migrates it, after a verified copy. No table of an earlier schema is altered or dropped.
--   - Memory: a variant's common prefix is checked with the two versions' parameters matched one to one across it,
--     with the same contract, so a parameter shared by two steps is not taken for two independent ones. Schema 4's
--     memory_variant_prefixes cannot say why such a prefix is only suggested; it stays as written, the record of the
--     first check, and is written no more. memory_variant_prefix_checks takes every check from now on.
-- The one data statement copies schema 4's suggested prefixes as they are: a check that could not prove a prefix
-- proves no more now. A prefix schema 4 stated verified was checked without its parameters' correspondence: the
-- store checks it again in the migration's transaction, from the two versions' definitions, which this text
-- cannot compare.
-- Same conventions: STRICT tables, no JSON column, no PRAGMA/BEGIN/COMMIT of its own.

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

INSERT INTO memory_variant_prefix_checks (route_id, status, compared_steps, reason, checked_at_ms)
SELECT route_id, status, compared_steps, reason, checked_at_ms FROM memory_variant_prefixes WHERE status = 'suggested';

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
