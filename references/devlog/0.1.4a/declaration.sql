-- ============================================================
-- declaration_construct: top-level segmentation of Layer 4
-- ============================================================
-- Each row is one declaration construct in a scope's
-- specification part. This is STRUCTURAL segmentation only —
-- we identify and classify each construct with its line span,
-- but do NOT drill into internal structure.
--
-- The declaration part of a specification is a sequence of
-- constructs from grammar rule R507/R508. This table records
-- that sequence.

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
        'derived_type_def',     -- TYPE ... END TYPE
        'interface_block',      -- INTERFACE ... END INTERFACE
        'enum_def',             -- ENUM, BIND(C) ... END ENUM

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
        'format_stmt',          -- FORMAT (...)
        'entry_stmt',           -- ENTRY name(args) (obsolescent)
        'stmt_function'         -- f(x) = expr (obsolescent)
    )),
    CONSTRAINT chk_dcon_span CHECK (start_line <= end_line),
    CONSTRAINT chk_dcon_ord  CHECK (ordinal >= 1)
);

CREATE INDEX IF NOT EXISTS idx_dcon_scope ON declaration_construct (scope_id);
CREATE INDEX IF NOT EXISTS idx_dcon_kind  ON declaration_construct (construct);

-- name: the construct's primary name, when it has one.
--   derived_type_def  → type name (e.g., 'matrix_t')
--   interface_block   → generic name, or NULL if unnamed
--   generic_stmt      → generic name
--   common_stmt       → block name, or NULL for blank common
--   namelist_stmt     → group name
--   entry_stmt        → entry point name
--   stmt_function     → function name
--   enum_def          → NULL (F2018 enums have no name)
--   type_declaration  → NULL (entities are next layer)
--   attribute_stmt    → NULL (targets are next layer)
--   others            → NULL
--
-- ordinal: position in the declaration construct sequence
--   (1-based). Preserves source order within the scope.
