-- ============================================================
-- Coordinate system schema (v0.1.4)
-- ============================================================
-- Complete fact table schema for structural indexing of Fortran
-- source code. 12 tables + 1 view, organized in dependency
-- order. Run this file to create an empty coordinate system
-- database; populate by parsing a Fortran codebase.
--
-- Three coordinate system conditions (all satisfied):
--   1. Complete partition   — every statement belongs to exactly one leaf row
--   2. Kind-determined grammar — row kind → grammar production (deterministic)
--   3. Layered dependency   — environment recoverable in processing order
--
-- Supersedes all prior per-version SQL files.
-- ============================================================


-- ============================================================
-- LAYER 0: Source text
-- ============================================================
-- Three storage tables + one public view. Downstream stages
-- consume only the view; storage internals are encapsulated.

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

-- Public view: the only interface downstream stages consume.
-- Maps (filename, lineno) → line for the latest version of each file.

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
-- Nesting depth bounded (~3 levels: global → module → function).
-- parent_scope_id: containment (function inside module).
-- ancestor_scope_id: submodule lineage (submodule → parent module).

CREATE TABLE IF NOT EXISTS scope (
    scope_id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parent_scope_id       BIGINT,
    kind                  TEXT NOT NULL,
    name                  TEXT,
    filename              TEXT,
    start_line            INTEGER,
    end_line              INTEGER,
    implicit_typing       TEXT NOT NULL DEFAULT 'inherit',
    ancestor_scope_id     BIGINT,
    default_accessibility TEXT,

    CONSTRAINT fk_scope_parent
        FOREIGN KEY (parent_scope_id) REFERENCES scope (scope_id),
    CONSTRAINT fk_scope_ancestor
        FOREIGN KEY (ancestor_scope_id) REFERENCES scope (scope_id),
    CONSTRAINT chk_scope_kind CHECK (kind IN (
        'global', 'program', 'module', 'submodule', 'block_data',
        'function', 'subroutine', 'separate_mp'
    )),
    CONSTRAINT chk_implicit CHECK (implicit_typing IN (
        'default', 'none', 'inherit', 'custom'
    )),
    CONSTRAINT chk_access CHECK (
        default_accessibility IS NULL
        OR default_accessibility IN ('public', 'private')
    )
);

CREATE INDEX IF NOT EXISTS idx_scope_parent   ON scope (parent_scope_id);
CREATE INDEX IF NOT EXISTS idx_scope_ancestor ON scope (ancestor_scope_id);
CREATE INDEX IF NOT EXISTS idx_scope_kind     ON scope (kind);
CREATE INDEX IF NOT EXISTS idx_scope_name     ON scope (name);
CREATE INDEX IF NOT EXISTS idx_scope_file     ON scope (filename);


-- ============================================================
-- LAYER 2: Scope parts
-- ============================================================
-- Each structural scope decomposes into up to 3 sequential parts:
--   specification → execution → subprogram (CONTAINS)
-- Grammar enforces strict ordering. No overlap, no interleaving.
--
-- Which scope kinds have which parts:
--   module/submodule:  specification + subprogram (no execution)
--   block_data:        specification only
--   program/function/subroutine/separate_mp: all three
--   global:            none (no syntactic body)

CREATE TABLE IF NOT EXISTS scope_part (
    scope_id    BIGINT  NOT NULL,
    part        TEXT    NOT NULL,
    start_line  INTEGER NOT NULL,
    end_line    INTEGER NOT NULL,

    PRIMARY KEY (scope_id, part),

    CONSTRAINT fk_scope_part_scope
        FOREIGN KEY (scope_id) REFERENCES scope (scope_id),
    CONSTRAINT chk_part CHECK (part IN (
        'specification', 'execution', 'subprogram'
    )),
    CONSTRAINT chk_part_range CHECK (start_line <= end_line)
);

CREATE INDEX IF NOT EXISTS idx_scope_part_scope ON scope_part (scope_id);


-- ============================================================
-- SPECIFICATION PART: Layers 1–4
-- ============================================================
-- The specification part builds the name-binding environment
-- in four grammar-ordered layers:
--   Layer 1: USE    (module association)
--   Layer 2: IMPORT (host association control)
--   Layer 3: IMPLICIT (typing rules)
--   Layer 4: Declarations (all other specification constructs)
--
-- Each layer depends only on the layers before it.
-- ============================================================


-- ------------------------------------------------------------
-- Layer 1: USE association
-- ------------------------------------------------------------
-- Each USE statement imports names from a module into the
-- current scope. use_stmt (one row per USE statement) and
-- use_entity (one row per explicitly named entity).
--
-- When only_clause = FALSE and no rename entries exist,
-- ALL public names from the module are imported.

CREATE TABLE IF NOT EXISTS use_stmt (
    use_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    scope_id     BIGINT  NOT NULL,
    module_name  TEXT    NOT NULL,
    nature       TEXT    NOT NULL DEFAULT 'unspecified',
    only_clause  BOOLEAN NOT NULL DEFAULT FALSE,
    start_line   INTEGER,

    CONSTRAINT fk_use_scope
        FOREIGN KEY (scope_id) REFERENCES scope (scope_id),
    CONSTRAINT chk_use_nature CHECK (nature IN (
        'unspecified',       -- USE module_name
        'intrinsic',         -- USE, INTRINSIC :: module_name
        'non_intrinsic'      -- USE, NON_INTRINSIC :: module_name
    ))
);

CREATE INDEX IF NOT EXISTS idx_use_scope  ON use_stmt (scope_id);
CREATE INDEX IF NOT EXISTS idx_use_module ON use_stmt (module_name);

CREATE TABLE IF NOT EXISTS use_entity (
    use_id             BIGINT NOT NULL,
    module_entity_name TEXT   NOT NULL,
    local_name         TEXT,

    PRIMARY KEY (use_id, module_entity_name),

    CONSTRAINT fk_use_entity_stmt
        FOREIGN KEY (use_id) REFERENCES use_stmt (use_id)
);

CREATE INDEX IF NOT EXISTS idx_use_entity_stmt ON use_entity (use_id);


-- ------------------------------------------------------------
-- Layer 2: IMPORT control (host association)
-- ------------------------------------------------------------
-- IMPORT statements control which names from the host (parent)
-- scope are visible. import_stmt (one row per IMPORT statement)
-- and import_entity (one row per named entity).
--
-- Default host association (no IMPORT statement): all host
-- names visible. IMPORT modifies this default.

CREATE TABLE IF NOT EXISTS import_stmt (
    import_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    scope_id    BIGINT NOT NULL,
    mode        TEXT   NOT NULL,
    start_line  INTEGER,

    CONSTRAINT fk_import_scope
        FOREIGN KEY (scope_id) REFERENCES scope (scope_id),
    CONSTRAINT chk_import_mode CHECK (mode IN (
        'explicit',   -- IMPORT :: name_list       (add listed names)
        'all',        -- IMPORT, ALL               (all host names)
        'none',       -- IMPORT, NONE              (block all host names)
        'only'        -- IMPORT, ONLY :: name_list (only listed names)
    ))
);

CREATE INDEX IF NOT EXISTS idx_import_scope ON import_stmt (scope_id);

CREATE TABLE IF NOT EXISTS import_entity (
    import_id  BIGINT NOT NULL,
    name       TEXT   NOT NULL,

    PRIMARY KEY (import_id, name),

    CONSTRAINT fk_import_entity_stmt
        FOREIGN KEY (import_id) REFERENCES import_stmt (import_id)
);

CREATE INDEX IF NOT EXISTS idx_import_entity_stmt ON import_entity (import_id);


-- ------------------------------------------------------------
-- Layer 3: IMPLICIT typing rules
-- ------------------------------------------------------------
-- Extends scope.implicit_typing. When implicit_typing = 'custom',
-- this table stores the letter-range → type mappings.
--
-- 'default': standard I-N → INTEGER, else → REAL. No rows.
-- 'none':    IMPLICIT NONE. All names must be declared. No rows.
-- 'inherit': parent's rules apply. No rows.
-- 'custom':  one or more rows define the mapping.

CREATE TABLE IF NOT EXISTS implicit_rule (
    scope_id     BIGINT NOT NULL,
    letter_start TEXT   NOT NULL,
    letter_end   TEXT   NOT NULL,
    type_spec    TEXT   NOT NULL,

    PRIMARY KEY (scope_id, letter_start),

    CONSTRAINT fk_implicit_scope
        FOREIGN KEY (scope_id) REFERENCES scope (scope_id),
    CONSTRAINT chk_letter_start CHECK (length(letter_start) = 1),
    CONSTRAINT chk_letter_end   CHECK (length(letter_end) = 1),
    CONSTRAINT chk_letter_order CHECK (letter_start <= letter_end)
);


-- ------------------------------------------------------------
-- Layer 4: Declaration constructs
-- ------------------------------------------------------------
-- Each row is one declaration construct in a scope's
-- specification part. 18 construct kinds covering all grammar
-- productions under R507/R508.
--
-- name: the construct's primary name when it has one.
--   derived_type_def → type name; interface_block → generic name
--   or NULL if unnamed; common_stmt → block name or NULL for
--   blank common; others → NULL.
--
-- ordinal: position in the declaration sequence (1-based).
--   Preserves source order within the scope.

CREATE TABLE IF NOT EXISTS declaration_construct (
    construct_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    scope_id      BIGINT  NOT NULL,
    construct     TEXT    NOT NULL,
    name          TEXT,
    ordinal       INTEGER NOT NULL,
    start_line    INTEGER NOT NULL,
    end_line      INTEGER NOT NULL,

    CONSTRAINT fk_dcon_scope
        FOREIGN KEY (scope_id) REFERENCES scope (scope_id),
    CONSTRAINT chk_construct CHECK (construct IN (
        -- block constructs (multi-line, have internal structure)
        'derived_type_def',     -- TYPE ... END TYPE (R726)
        'interface_block',      -- INTERFACE ... END INTERFACE (R1501)
        'enum_def',             -- ENUM, BIND(C) ... END ENUM (R759)

        -- statement constructs (typically single-line)
        'type_declaration',     -- type-declaration-stmt (R801)
        'generic_stmt',         -- GENERIC :: ... (R1510)
        'procedure_decl',       -- PROCEDURE(...) :: ... (R1512)
        'parameter_stmt',       -- PARAMETER (name = expr, ...)
        'access_stmt',          -- PUBLIC/PRIVATE [:: name-list]
        'attribute_stmt',       -- standalone attr (DIMENSION, ALLOCATABLE, ...)
        'common_stmt',          -- COMMON /name/ var-list
        'equivalence_stmt',     -- EQUIVALENCE (var, var, ...)
        'namelist_stmt',        -- NAMELIST /name/ var-list
        'external_stmt',        -- EXTERNAL :: name-list
        'intrinsic_stmt',       -- INTRINSIC :: name-list
        'data_stmt',            -- DATA var-list / value-list /

        -- cross-boundary and obsolescent
        'format_stmt',          -- FORMAT (...) (R1001)
        'entry_stmt',           -- ENTRY name(args) (R1541, obsolescent)
        'stmt_function'         -- f(x) = expr (R1544, obsolescent)
    )),
    CONSTRAINT chk_dcon_span CHECK (start_line <= end_line),
    CONSTRAINT chk_dcon_ord  CHECK (ordinal >= 1)
);

CREATE INDEX IF NOT EXISTS idx_dcon_scope ON declaration_construct (scope_id);
CREATE INDEX IF NOT EXISTS idx_dcon_kind  ON declaration_construct (construct);


-- ============================================================
-- EXECUTION PART: Control structure + leaf partition
-- ============================================================
-- The execution part has two levels of structure:
--   1. control_region: the control construct tree (CCT)
--   2. semantic_basic_block + sbb_edge: the CFG partition
--
-- Together they satisfy all three conditions for the exec part:
--   1. Complete partition   — SBBs tile each execution part
--   2. Kind-determined grammar — region kind → production;
--      SBB → action-stmt sequence with keyword dispatch
--   3. Layered dependency   — tree-compositional env recovery
--      via ancestor chain walk
-- ============================================================


-- ------------------------------------------------------------
-- Control region: control construct tree (CCT)
-- ------------------------------------------------------------
-- One row per control construct in the execution part.
-- Self-referential parent FK encodes the nesting tree.
-- NULL parent = top-level construct (directly in execution part).
--
-- kind: which control construct (13 values matching F2018 R514).
--
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


-- ------------------------------------------------------------
-- Semantic basic block: leaf-level partition of execution parts
-- ------------------------------------------------------------
-- The SBB is the finest-grained fact table row — a maximal
-- contiguous statement sequence sharing:
--   1. The same control flow context (no internal branch/target)
--   2. The same name-binding environment
--
-- Under Convention B (every construct boundary is a BB boundary),
-- these two conditions coincide.
--
-- region_id: FK to innermost enclosing control_region.
--   NULL = top-level code not inside any construct.
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


-- ------------------------------------------------------------
-- SBB edge: control flow edges between SBBs
-- ------------------------------------------------------------
-- Intraprocedural CFG edges. All edges connect SBBs within
-- the same structural scope.

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
        'fallthrough',    -- sequential (next statement)
        'branch_true',    -- conditional true path
        'branch_false',   -- conditional false path
        'case_select',    -- multi-way branch (one selected arm)
        'loop_back',      -- back-edge to loop header
        'loop_exit',      -- normal exit from loop
        'jump',           -- non-local transfer (GOTO, CYCLE, EXIT)
        'return'          -- procedure exit (RETURN, STOP, ERROR STOP)
    ))
);

CREATE INDEX IF NOT EXISTS idx_edge_from ON sbb_edge (from_sbb_id);
CREATE INDEX IF NOT EXISTS idx_edge_to   ON sbb_edge (to_sbb_id);


-- ============================================================
-- Table summary
-- ============================================================
--
-- Storage (3 tables):
--   file_version, source_line, edit_event
--
-- Public view (1):
--   source_code  →  (filename, lineno, line)
--
-- Fact tables (9):
--   scope                  structural scopes (8 kinds)
--   scope_part             spec / exec / subprogram parts
--   use_stmt               Layer 1: USE associations
--   use_entity               per-entity rename/only
--   import_stmt            Layer 2: IMPORT controls
--   import_entity            per-name import list
--   implicit_rule          Layer 3: letter→type mappings
--   declaration_construct  Layer 4: 18 construct kinds
--   control_region         exec: control construct tree (CCT)
--   semantic_basic_block   exec: leaf-level partition
--   sbb_edge               exec: control flow edges
--
-- Total: 12 tables + 1 view
--
-- ============================================================
-- Hierarchy:
--
-- source_code
--   └─ scope
--        └─ scope_part
--             ├─ [spec] use_stmt → use_entity          Layer 1
--             ├─ [spec] import_stmt → import_entity    Layer 2
--             ├─ [spec] implicit_rule                  Layer 3
--             ├─ [spec] declaration_construct           Layer 4
--             └─ [exec] control_region
--                        └─ semantic_basic_block
--                             └─ sbb_edge
-- ============================================================
