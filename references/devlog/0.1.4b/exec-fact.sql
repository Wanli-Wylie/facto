-- ============================================================
-- Execution-part fact tables (v0.1.4b)
-- ============================================================
-- These three tables complete the coordinate system for the
-- execution part. Together with source_code (v0.1.0),
-- scope (v0.1.1), and scope_part (v0.1.2), they satisfy
-- the three coordinate system conditions:
--
--   1. Complete partition       — SBBs tile each execution part
--   2. Kind-determined grammar  — region kind → production; SBB → action-stmt sequence
--   3. Layered dependency order — tree-compositional env recovery via ancestor chain
--
-- All semantic properties (read/write sets, call edges, I/O,
-- allocation, construct entities) are computed tables derived
-- from source text at the coordinates these tables define.
-- The fact tables stop here.
--
-- Supersedes: control-region.sql and semantic-basic-block.sql
-- from v0.1.3b (same schemas, consolidated with coordinate
-- system documentation).

-- ============================================================
-- control_region: control construct tree (CCT)
-- ============================================================
-- One row per control construct in the execution part.
-- Self-referential parent FK encodes the nesting tree.
-- NULL parent = top-level construct (directly in execution part).
--
-- kind: which control construct (13 values matching F2018 R514).
-- binding_kind: name-binding change introduced by this construct.
--   Functionally determined by kind, but explicit for filtering:
--     block           → full_scope       (own specification part)
--     do_concurrent   → construct_index  (index variables)
--     forall          → construct_index
--     associate       → construct_entity (associate-names)
--     select_type     → construct_entity (type narrowing)
--     select_rank     → construct_entity (rank narrowing)
--     all others      → none
--
-- construct_name: optional Fortran construct name (for named
--   CYCLE/EXIT targeting). Has construct scope.

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

-- ============================================================
-- semantic_basic_block: leaf-level partition of execution parts
-- ============================================================
-- The SBB is the finest-grained fact table row — a maximal
-- contiguous statement sequence sharing:
--   1. The same control flow context (no internal branch/target)
--   2. The same name-binding environment
--
-- Under Convention B (every construct boundary is a BB boundary),
-- these two conditions coincide: the SBB equals the basic block
-- of the construct-aware CFG.
--
-- region_id: FK to innermost enclosing control_region.
-- NULL = top-level code not inside any construct.
-- The full ancestor chain is walkable via parent_region_id.
--
-- Convention: each executable scope has synthetic ENTRY and EXIT
-- SBBs (start_line = end_line = scope's first/last executable
-- line). RETURN/STOP edges target the EXIT SBB.

CREATE TABLE IF NOT EXISTS semantic_basic_block (
    sbb_id      BIGINT  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    scope_id    BIGINT  NOT NULL,
    region_id   BIGINT,
    filename    TEXT    NOT NULL,
    start_line  INTEGER NOT NULL,
    end_line    INTEGER NOT NULL,

    CONSTRAINT fk_sbb_scope
        FOREIGN KEY (scope_id) REFERENCES scope (scope_id),
    CONSTRAINT fk_sbb_region
        FOREIGN KEY (region_id) REFERENCES control_region (region_id),
    CONSTRAINT chk_sbb_range CHECK (start_line <= end_line)
);

CREATE INDEX IF NOT EXISTS idx_sbb_scope  ON semantic_basic_block (scope_id);
CREATE INDEX IF NOT EXISTS idx_sbb_region ON semantic_basic_block (region_id);
CREATE INDEX IF NOT EXISTS idx_sbb_file   ON semantic_basic_block (filename);

-- ============================================================
-- sbb_edge: control flow edges between SBBs
-- ============================================================
-- Intraprocedural CFG edges. All edges connect SBBs within
-- the same structural scope.
--
-- edge_kind classifies the transfer:
--   fallthrough  — sequential (next statement)
--   branch_true  — conditional true path (IF condition true)
--   branch_false — conditional false path (IF condition false)
--   case_select  — multi-way branch (one selected arm)
--   loop_back    — back-edge to loop header
--   loop_exit    — normal exit from loop
--   jump         — non-local transfer (GOTO, CYCLE, EXIT)
--   return       — procedure exit (RETURN, STOP, ERROR STOP)

CREATE TABLE IF NOT EXISTS sbb_edge (
    from_sbb_id  BIGINT NOT NULL,
    to_sbb_id    BIGINT NOT NULL,
    edge_kind    TEXT   NOT NULL,

    PRIMARY KEY (from_sbb_id, to_sbb_id, edge_kind),

    CONSTRAINT fk_edge_from
        FOREIGN KEY (from_sbb_id) REFERENCES semantic_basic_block (sbb_id),
    CONSTRAINT fk_edge_to
        FOREIGN KEY (to_sbb_id) REFERENCES semantic_basic_block (sbb_id),
    CONSTRAINT chk_edge_kind CHECK (edge_kind IN (
        'fallthrough', 'branch_true', 'branch_false', 'case_select',
        'loop_back', 'loop_exit', 'jump', 'return'
    ))
);

CREATE INDEX IF NOT EXISTS idx_edge_from ON sbb_edge (from_sbb_id);
CREATE INDEX IF NOT EXISTS idx_edge_to   ON sbb_edge (to_sbb_id);

-- ============================================================
-- Coordinate system queries
-- ============================================================
-- The fact tables enable pure relational queries at every level.

-- 1. Source text of any SBB (the "plain sequence of statements"):
--
--   SELECT sc.lineno, sc.line
--   FROM   semantic_basic_block sbb
--   JOIN   source_code sc ON sc.filename = sbb.filename
--   WHERE  sc.lineno BETWEEN sbb.start_line AND sbb.end_line
--     AND  sbb.sbb_id = ?
--   ORDER  BY sc.lineno;

-- 2. All SBBs inside a control region (e.g., a DO loop body):
--
--   SELECT sbb.*
--   FROM   semantic_basic_block sbb
--   JOIN   control_region cr ON cr.scope_id = sbb.scope_id
--   WHERE  cr.region_id = ?
--     AND  sbb.start_line >= cr.start_line
--     AND  sbb.end_line   <= cr.end_line;

-- 3. Binding-changing ancestors of an SBB (for environment recovery):
--
--   WITH RECURSIVE ancestors AS (
--       SELECT region_id, parent_region_id, kind, binding_kind
--       FROM   control_region
--       WHERE  region_id = (SELECT region_id FROM semantic_basic_block WHERE sbb_id = ?)
--     UNION ALL
--       SELECT cr.region_id, cr.parent_region_id, cr.kind, cr.binding_kind
--       FROM   control_region cr
--       JOIN   ancestors a ON cr.region_id = a.parent_region_id
--   )
--   SELECT * FROM ancestors WHERE binding_kind != 'none';

-- 4. CFG successors of an SBB:
--
--   SELECT e.edge_kind, succ.*
--   FROM   sbb_edge e
--   JOIN   semantic_basic_block succ ON succ.sbb_id = e.to_sbb_id
--   WHERE  e.from_sbb_id = ?;
