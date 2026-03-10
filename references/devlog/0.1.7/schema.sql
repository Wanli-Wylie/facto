-- ============================================================
-- Coordinate system schema (v0.1.7)
-- ============================================================
-- Structural file system for Fortran source code.
-- 6 fact tables + 3 storage tables + 2 views.
--
-- Principle: fact tables store containment coordinates only —
-- WHERE things are and WHAT TYPE they are. Everything semantic
-- is recovered on demand via parse_as(text, kind).
--
-- Delta from v0.1.4:
--   scope:           drop implicit_typing, ancestor_scope_id,
--                    default_accessibility (process outputs)
--   scope_part:      specification → environment + declarations;
--                    subprogram dropped (absorbed by scope.parent_scope_id);
--                    scope_part now also covers block_scope units
--   control_region:  drop binding_kind, construct_name (process outputs);
--                    drop 'block' kind (moved to block_scope table)
--   block_scope:     NEW — BLOCK constructs as scoping units
--   scoping_unit:    NEW VIEW — union of scope + block_scope
--   DROP tables:     use_stmt, use_entity, import_stmt, import_entity,
--                    implicit_rule, declaration_construct, sbb_edge
--                    (all become computed tables / processes)
--
-- Supersedes v0.1.4/schema.sql.
-- ============================================================


-- ============================================================
-- LAYER 0: Source text (unchanged from v0.1.4)
-- ============================================================

CREATE TABLE IF NOT EXISTS file_version (
    version_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    file_path   TEXT NOT NULL,
    parent_id   BIGINT,
    line_count  INTEGER NOT NULL,
    created_at  TEXT NOT NULL,
    CONSTRAINT fk_file_version_parent
        FOREIGN KEY (parent_id) REFERENCES file_version (version_id)
);

CREATE INDEX IF NOT EXISTS idx_fv_file_path ON file_version (file_path);
CREATE INDEX IF NOT EXISTS idx_fv_parent    ON file_version (parent_id);

CREATE TABLE IF NOT EXISTS source_line (
    version_id  BIGINT  NOT NULL,
    line_no     INTEGER NOT NULL,
    line_text   TEXT    NOT NULL,
    PRIMARY KEY (version_id, line_no),
    CONSTRAINT fk_source_line_version
        FOREIGN KEY (version_id) REFERENCES file_version (version_id)
);

CREATE TABLE IF NOT EXISTS edit_event (
    event_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    version_id  BIGINT  NOT NULL,
    op          TEXT    NOT NULL,
    line_start  INTEGER NOT NULL,
    line_end    INTEGER NOT NULL,
    new_text    TEXT,
    ordinal     INTEGER NOT NULL,
    CONSTRAINT fk_edit_event_version
        FOREIGN KEY (version_id) REFERENCES file_version (version_id),
    CONSTRAINT chk_edit_op
        CHECK (op IN ('insert', 'delete', 'replace'))
);

CREATE VIEW IF NOT EXISTS source_code AS
SELECT fv.file_path AS filename,
       sl.line_no   AS lineno,
       sl.line_text AS line
FROM   source_line sl
JOIN   file_version fv ON fv.version_id = sl.version_id
WHERE  fv.version_id = (
           SELECT MAX(fv2.version_id)
           FROM   file_version fv2
           WHERE  fv2.file_path = fv.file_path
       )
ORDER  BY fv.file_path, sl.line_no;


-- ============================================================
-- LAYER 1: Structural scopes
-- ============================================================
-- One row per program unit or subprogram. 8 structural kinds.
-- These are the "directories" created by mkfs — the top-level
-- structural decomposition found by walking the CST.
--
-- BLOCK constructs are NOT in this table — they are scoping
-- units found inside execution parts, stored in block_scope.
-- Use the scoping_unit view to operate on all namespaces.

CREATE TABLE IF NOT EXISTS scope (
    scope_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parent_scope_id  BIGINT,
    kind             TEXT NOT NULL,
    name             TEXT,
    filename         TEXT,
    start_line       INTEGER,
    end_line         INTEGER,

    CONSTRAINT fk_scope_parent
        FOREIGN KEY (parent_scope_id) REFERENCES scope (scope_id),
    CONSTRAINT chk_scope_kind CHECK (kind IN (
        'global', 'program', 'module', 'submodule', 'block_data',
        'function', 'subroutine', 'separate_mp'
    ))
);

CREATE INDEX IF NOT EXISTS idx_scope_parent ON scope (parent_scope_id);
CREATE INDEX IF NOT EXISTS idx_scope_kind   ON scope (kind);
CREATE INDEX IF NOT EXISTS idx_scope_name   ON scope (name);
CREATE INDEX IF NOT EXISTS idx_scope_file   ON scope (filename);


-- ============================================================
-- LAYER 1b: Block scopes
-- ============================================================
-- One row per BLOCK construct. BLOCK is the only control
-- construct with a full specification part (USE, IMPORT,
-- IMPLICIT, declarations). It cannot have CONTAINS.
--
-- Structurally different from program-unit scopes:
--   - Found inside execution parts, not at program-unit level
--   - Nested within control regions (DO, IF, etc.)
--   - Anonymous (no name)
--
-- Semantically identical: has its own namespace with
-- environment + declarations + execution parts, handled
-- by segment_parts like any scoping unit.
--
-- scope_id:  the program-unit scope this BLOCK belongs to.
-- region_id: innermost enclosing control region, or NULL
--            if the BLOCK is at the top level of the exec part.

CREATE TABLE IF NOT EXISTS block_scope (
    block_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    scope_id    BIGINT  NOT NULL,
    region_id   BIGINT,
    filename    TEXT    NOT NULL,
    start_line  INTEGER NOT NULL,
    end_line    INTEGER NOT NULL,

    CONSTRAINT fk_block_scope
        FOREIGN KEY (scope_id) REFERENCES scope (scope_id),
    CONSTRAINT fk_block_region
        FOREIGN KEY (region_id) REFERENCES control_region (region_id),
    CONSTRAINT chk_block_range CHECK (start_line <= end_line)
);

CREATE INDEX IF NOT EXISTS idx_block_scope  ON block_scope (scope_id);
CREATE INDEX IF NOT EXISTS idx_block_region ON block_scope (region_id);


-- ============================================================
-- Scoping unit view
-- ============================================================
-- Unified view over all scoping units: program-unit scopes
-- and BLOCK scopes. Consumers that need to traverse all
-- namespaces (name resolution, environment composition)
-- operate on this view.

CREATE VIEW IF NOT EXISTS scoping_unit AS
SELECT 'scope' AS source,
       scope_id AS unit_id,
       parent_scope_id AS parent_unit_id,
       kind,
       name,
       filename,
       start_line,
       end_line
FROM   scope
UNION ALL
SELECT 'block' AS source,
       block_id AS unit_id,
       NULL     AS parent_unit_id,
       'block'  AS kind,
       NULL     AS name,
       filename,
       start_line,
       end_line
FROM   block_scope;


-- ============================================================
-- LAYER 2: Scope parts
-- ============================================================
-- Each scoping unit (scope or block_scope) decomposes into
-- up to 3 parts:
--   environment  — USE, IMPORT, IMPLICIT statements
--   declarations — all other specification constructs
--   execution    — executable statements and control constructs
--
-- The unit_source column distinguishes which physical table
-- the unit_id refers to ('scope' or 'block').
--
-- Grammar enforces strict ordering. No overlap, no interleaving.
-- Parts that are absent are simply omitted — no row.
--
-- Which scope kinds have which parts:
--   module/submodule:  environment + declarations
--   block_data:        environment + declarations
--   block:             environment + declarations + execution (no CONTAINS)
--   program/function/subroutine/separate_mp: environment + declarations + execution

CREATE TABLE IF NOT EXISTS scope_part (
    unit_source TEXT    NOT NULL,
    unit_id     BIGINT  NOT NULL,
    part        TEXT    NOT NULL,
    start_line  INTEGER NOT NULL,
    end_line    INTEGER NOT NULL,

    PRIMARY KEY (unit_source, unit_id, part),

    CONSTRAINT chk_unit_source CHECK (unit_source IN ('scope', 'block')),
    CONSTRAINT chk_part CHECK (part IN (
        'environment', 'declarations', 'execution'
    )),
    CONSTRAINT chk_part_range CHECK (start_line <= end_line)
);

CREATE INDEX IF NOT EXISTS idx_scope_part_unit
    ON scope_part (unit_source, unit_id);


-- ============================================================
-- LAYER 3: Control regions (exec containment tree)
-- ============================================================
-- One row per control construct in the execution part.
-- Self-referential parent FK encodes the nesting tree.
-- NULL parent = top-level construct (directly in execution part).
--
-- 12 kinds (BLOCK removed — it's a scoping unit, not a
-- control flow construct). BLOCK doesn't branch or loop;
-- it introduces a namespace.
--
-- unit_source + unit_id: which scoping unit's execution part
-- this region belongs to (scope or block_scope).

CREATE TABLE IF NOT EXISTS control_region (
    region_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parent_region_id  BIGINT,
    unit_source       TEXT    NOT NULL,
    unit_id           BIGINT  NOT NULL,
    kind              TEXT    NOT NULL,
    filename          TEXT    NOT NULL,
    start_line        INTEGER NOT NULL,
    end_line          INTEGER NOT NULL,

    CONSTRAINT fk_region_parent
        FOREIGN KEY (parent_region_id) REFERENCES control_region (region_id),
    CONSTRAINT chk_region_unit_source CHECK (unit_source IN ('scope', 'block')),
    CONSTRAINT chk_region_kind CHECK (kind IN (
        'if', 'select_case', 'select_type', 'select_rank',
        'do', 'do_while', 'do_concurrent', 'forall',
        'where', 'associate',
        'critical', 'change_team'
    )),
    CONSTRAINT chk_region_range CHECK (start_line <= end_line)
);

CREATE INDEX IF NOT EXISTS idx_region_parent ON control_region (parent_region_id);
CREATE INDEX IF NOT EXISTS idx_region_unit
    ON control_region (unit_source, unit_id);
CREATE INDEX IF NOT EXISTS idx_region_kind   ON control_region (kind);


-- ============================================================
-- LAYER 4: Semantic basic blocks (exec leaf partition)
-- ============================================================
-- Finest-grained structural partition of the execution part.
-- One SBB = maximal contiguous statement sequence with uniform
-- control flow context.
--
-- Convention B: every construct boundary (including BLOCK scope
-- boundaries) starts a new SBB. The parent scoping unit's SBBs
-- tile around nested BLOCK scopes and control regions.
--
-- unit_source + unit_id: which scoping unit this SBB belongs to.
-- region_id: innermost enclosing control region; NULL for
--   top-level statements.

CREATE TABLE IF NOT EXISTS semantic_basic_block (
    sbb_id       BIGINT  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    unit_source  TEXT    NOT NULL,
    unit_id      BIGINT  NOT NULL,
    region_id    BIGINT,
    filename     TEXT    NOT NULL,
    start_line   INTEGER NOT NULL,
    end_line     INTEGER NOT NULL,

    CONSTRAINT fk_sbb_region
        FOREIGN KEY (region_id) REFERENCES control_region (region_id),
    CONSTRAINT chk_sbb_unit_source CHECK (unit_source IN ('scope', 'block')),
    CONSTRAINT chk_sbb_range CHECK (start_line <= end_line)
);

CREATE INDEX IF NOT EXISTS idx_sbb_unit
    ON semantic_basic_block (unit_source, unit_id);
CREATE INDEX IF NOT EXISTS idx_sbb_region ON semantic_basic_block (region_id);


-- ============================================================
-- Table summary
-- ============================================================
--
-- Storage (3 tables):
--   file_version, source_line, edit_event
--
-- Views (2):
--   source_code    →  (filename, lineno, line)
--   scoping_unit   →  union of scope + block_scope
--
-- Fact tables (6):
--   scope                  program-unit scopes (8 kinds)
--   block_scope            BLOCK construct scopes
--   scope_part             environment / declarations / execution
--   control_region         exec: control construct nesting (12 kinds)
--   semantic_basic_block   exec: leaf-level partition
--
-- Total: 9 tables + 2 views
--
-- ============================================================
-- Containment hierarchy (the file system):
--
-- source_code                               disk blocks
--   └─ scope                                directory tree (program units)
--        └─ scope_part                      file types
--             ├─ [environment]              ← on-demand: USE, IMPORT, IMPLICIT
--             ├─ [declarations]             ← on-demand: 18 construct kinds
--             └─ [execution]
--                  ├─ control_region        subdirectory nesting (12 kinds)
--                  ├─ block_scope           nested directory (BLOCK scope)
--                  │    └─ scope_part       same decomposition, recursive
--                  └─ sbb                   leaf files
--
-- Processes (computed on demand via parse_as):
--   use_stmt, use_entity                    ← from environment lines
--   import_stmt, import_entity              ← from environment lines
--   implicit_rule                           ← from environment lines
--   declaration_construct                   ← from declarations lines
--   sbb_edge (CFG)                          ← from sbb + region structure
--   binding_kind                            ← f(control_region.kind)
--   construct_name                          ← from region header line
--   implicit_typing                         ← from environment content
--   ancestor_scope_id                       ← cross-file resolution
--   default_accessibility                   ← from declarations content
--   data_access, call_edge, ...             ← from sbb content (future)
-- ============================================================
