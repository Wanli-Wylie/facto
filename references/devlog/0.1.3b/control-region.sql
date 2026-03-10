-- ============================================================
-- control_region: execution-part control construct tree (CCT)
-- ============================================================
-- Each structural scope's execution part contains a tree of
-- nested control constructs — the control construct tree (CCT).
-- This table stores the tree:
--   - One row per control construct (IF, DO, BLOCK, etc.)
--   - parent_region_id encodes nesting (self-referential FK)
--   - NULL parent = top-level construct in the execution part
--
-- The CCT has unbounded depth (left-recursive), unlike the
-- structural scope tree (bounded ~3 levels). This was the
-- reason BLOCK, FORALL, and DO_CONCURRENT were removed from
-- the scope table in v0.1.1 and deferred to this table.
--
-- Containment relationships:
--   scope ⊇ control_region ⊇ control_region (child)
-- All verifiable via line-range inclusion as well as FKs.
--
-- scope_id links each region to its containing structural
-- scope. parent_region_id links to the immediately enclosing
-- control construct (NULL for top-level constructs).
--
-- binding_kind classifies the name-binding change introduced:
--   none             → no change (IF, SELECT CASE, DO, DO WHILE,
--                      WHERE, CRITICAL, CHANGE TEAM)
--   full_scope       → BLOCK (own specification part, F2018 §19.2)
--   construct_index  → DO CONCURRENT, FORALL (index variables, §19.4)
--   construct_entity → ASSOCIATE, SELECT TYPE, SELECT RANK
--                      (construct entities, §19.4)
--
-- This is functionally determined by kind, but explicit for
-- direct filtering: "which ancestors change bindings?" is
--   WHERE binding_kind != 'none'
-- without needing to enumerate kinds.

CREATE TABLE IF NOT EXISTS control_region (
    region_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parent_region_id  BIGINT,
    scope_id          BIGINT  NOT NULL,
    kind              TEXT    NOT NULL,
    binding_kind      TEXT    NOT NULL DEFAULT 'none',
    construct_name    TEXT,
    filename          TEXT    NOT NULL,
    start_line        INTEGER NOT NULL,
    end_line          INTEGER NOT NULL,

    CONSTRAINT fk_region_parent
        FOREIGN KEY (parent_region_id) REFERENCES control_region (region_id),
    CONSTRAINT fk_region_scope
        FOREIGN KEY (scope_id) REFERENCES scope (scope_id),
    CONSTRAINT chk_region_kind CHECK (kind IN (
        'if', 'select_case', 'select_type', 'select_rank',
        'do', 'do_while', 'do_concurrent', 'forall',
        'where',
        'block', 'associate',
        'critical', 'change_team'
    )),
    CONSTRAINT chk_binding_kind CHECK (binding_kind IN (
        'none', 'full_scope', 'construct_index', 'construct_entity'
    )),
    CONSTRAINT chk_region_range CHECK (start_line <= end_line)
);

CREATE INDEX IF NOT EXISTS idx_region_parent ON control_region (parent_region_id);
CREATE INDEX IF NOT EXISTS idx_region_scope  ON control_region (scope_id);
CREATE INDEX IF NOT EXISTS idx_region_kind   ON control_region (kind);
CREATE INDEX IF NOT EXISTS idx_region_file   ON control_region (filename);
