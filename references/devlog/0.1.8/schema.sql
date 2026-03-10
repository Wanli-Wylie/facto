-- ============================================================
-- Coordinate system schema (v0.1.8)
-- ============================================================
-- Structural file system for Fortran source code.
-- 5 fact tables + 3 storage tables + 1 view.
--
-- Principle: fact tables store containment coordinates only —
-- WHERE things are and WHAT TYPE they are. Everything semantic
-- is recovered on demand via parse_as(text, kind).
--
-- Delta from v0.1.7:
--   DROP block_scope table    (BLOCK is a leaf SBB, not a scoping unit)
--   DROP scoping_unit view    (no second physical table to unify)
--   scope_part:               back to plain scope_id (no unit_source)
--   control_region:           back to plain scope_id (no unit_source)
--   semantic_basic_block:     back to scope_id; ADD kind column
--                             ('statements' | 'block_scope')
--
-- Supersedes v0.1.7/schema.sql.
-- ============================================================


-- ============================================================
-- LAYER 0: Source text (unchanged)
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
-- These are the "directories" — the top-level structural
-- decomposition found by walking the CST.

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
-- LAYER 2: Scope parts
-- ============================================================
-- Each scope decomposes into up to 3 parts:
--   environment  — USE, IMPORT, IMPLICIT statements
--   declarations — all other specification constructs
--   execution    — executable statements and control constructs
--
-- Grammar enforces strict ordering. No overlap, no interleaving.
-- Parts that are absent are simply omitted — no row.
--
-- Which scope kinds have which parts:
--   module/submodule/block_data:  environment + declarations
--   program/function/subroutine/separate_mp: all three

CREATE TABLE IF NOT EXISTS scope_part (
    scope_id    BIGINT  NOT NULL,
    part        TEXT    NOT NULL,
    start_line  INTEGER NOT NULL,
    end_line    INTEGER NOT NULL,

    PRIMARY KEY (scope_id, part),

    CONSTRAINT fk_scope_part_scope
        FOREIGN KEY (scope_id) REFERENCES scope (scope_id),
    CONSTRAINT chk_part CHECK (part IN (
        'environment', 'declarations', 'execution'
    )),
    CONSTRAINT chk_part_range CHECK (start_line <= end_line)
);

CREATE INDEX IF NOT EXISTS idx_scope_part_scope
    ON scope_part (scope_id);


-- ============================================================
-- LAYER 3: Control regions (exec containment tree)
-- ============================================================
-- One row per control construct in the execution part.
-- Self-referential parent FK encodes the nesting tree.
-- NULL parent = top-level construct (directly in execution part).
--
-- 12 kinds. BLOCK is NOT here — it is a leaf SBB with
-- kind = 'block_scope' (see semantic_basic_block).

CREATE TABLE IF NOT EXISTS control_region (
    region_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parent_region_id  BIGINT,
    scope_id          BIGINT  NOT NULL,
    kind              TEXT    NOT NULL,
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
        'where', 'associate',
        'critical', 'change_team'
    )),
    CONSTRAINT chk_region_range CHECK (start_line <= end_line)
);

CREATE INDEX IF NOT EXISTS idx_region_parent ON control_region (parent_region_id);
CREATE INDEX IF NOT EXISTS idx_region_scope  ON control_region (scope_id);
CREATE INDEX IF NOT EXISTS idx_region_kind   ON control_region (kind);


-- ============================================================
-- LAYER 4: Semantic basic blocks (exec leaf partition)
-- ============================================================
-- Finest-grained structural partition of the execution part.
-- Two kinds of leaves:
--
--   'statements'  — maximal contiguous action statement sequence
--   'block_scope' — BLOCK construct (opaque let-binding region)
--
-- Convention B: every construct boundary (control region or
-- BLOCK scope) starts a new SBB. SBBs tile the gaps between
-- control regions and BLOCK scopes.
--
-- BLOCK scopes are opaque at the pipeline level. Their internal
-- structure (environment, declarations, nested execution) is
-- recovered on demand via parse_as(text, 'Block_Construct').

CREATE TABLE IF NOT EXISTS semantic_basic_block (
    sbb_id       BIGINT  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    scope_id     BIGINT  NOT NULL,
    region_id    BIGINT,
    kind         TEXT    NOT NULL,
    filename     TEXT    NOT NULL,
    start_line   INTEGER NOT NULL,
    end_line     INTEGER NOT NULL,

    CONSTRAINT fk_sbb_scope
        FOREIGN KEY (scope_id) REFERENCES scope (scope_id),
    CONSTRAINT fk_sbb_region
        FOREIGN KEY (region_id) REFERENCES control_region (region_id),
    CONSTRAINT chk_sbb_kind CHECK (kind IN ('statements', 'block_scope')),
    CONSTRAINT chk_sbb_range CHECK (start_line <= end_line)
);

CREATE INDEX IF NOT EXISTS idx_sbb_scope  ON semantic_basic_block (scope_id);
CREATE INDEX IF NOT EXISTS idx_sbb_region ON semantic_basic_block (region_id);
CREATE INDEX IF NOT EXISTS idx_sbb_kind   ON semantic_basic_block (kind);


-- ============================================================
-- Table summary
-- ============================================================
--
-- Storage (3 tables):
--   file_version, source_line, edit_event
--
-- Views (1):
--   source_code    →  (filename, lineno, line)
--
-- Fact tables (5):
--   scope                  program-unit scopes (8 kinds)
--   scope_part             environment / declarations / execution
--   control_region         exec: control construct nesting (12 kinds)
--   semantic_basic_block   exec: leaf partition (2 kinds)
--
-- Total: 8 tables + 1 view
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
--                  └─ sbb                   leaf nodes (2 kinds)
--                       ├─ statements       action statement sequence
--                       └─ block_scope      opaque let-binding region
--
-- Processes (computed on demand via parse_as):
--   use_stmt, use_entity                    ← from environment lines
--   import_stmt, import_entity              ← from environment lines
--   implicit_rule                           ← from environment lines
--   declaration_construct                   ← from declarations lines
--   block_internals                         ← from block_scope SBB text
--   sbb_edge (CFG)                          ← from sbb + region structure
--   binding_kind                            ← f(control_region.kind)
--   construct_name                          ← from region header line
--   implicit_typing                         ← from environment content
--   ancestor_scope_id                       ← cross-file resolution
--   default_accessibility                   ← from declarations content
--   data_access, call_edge, ...             ← from sbb content (future)
-- ============================================================
