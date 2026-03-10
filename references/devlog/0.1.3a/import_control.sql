-- ============================================================
-- Layer 2: IMPORT control (host association)
-- ============================================================
-- IMPORT statements control which names from the host (parent)
-- scope are visible via host association. Two tables:
-- import_stmt (one row per IMPORT statement) and import_entity
-- (one row per named entity, for 'explicit' and 'only' modes).
--
-- Default host association (no IMPORT statement): all host
-- names are visible. IMPORT modifies this default.
--
-- Scope restriction: IMPORT can only appear in scopes that
-- have a host — interface bodies, internal/module subprograms,
-- BLOCK constructs, submodules. Cannot appear in main programs,
-- external procedures, modules, or block_data.

CREATE TABLE IF NOT EXISTS import_stmt (
    import_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    scope_id    BIGINT NOT NULL,
    mode        TEXT   NOT NULL,
    start_line  INTEGER,

    CONSTRAINT fk_import_scope
        FOREIGN KEY (scope_id) REFERENCES scope (scope_id),
    CONSTRAINT chk_import_mode CHECK (mode IN (
        'explicit',   -- IMPORT :: name_list       (F2003: add listed names)
        'all',        -- IMPORT, ALL               (F2018: all host names)
        'none',       -- IMPORT, NONE              (F2018: block all host names)
        'only'        -- IMPORT, ONLY :: name_list (F2018: only listed names)
    ))
);

CREATE INDEX IF NOT EXISTS idx_import_scope ON import_stmt (scope_id);

-- ============================================================
-- import_entity: named entities for 'explicit' and 'only' modes
-- ============================================================
-- Only populated when mode = 'explicit' or mode = 'only'.
-- For 'all' and 'none', no entity list is needed.

CREATE TABLE IF NOT EXISTS import_entity (
    import_id  BIGINT NOT NULL,
    name       TEXT   NOT NULL,

    PRIMARY KEY (import_id, name),

    CONSTRAINT fk_import_entity_stmt
        FOREIGN KEY (import_id) REFERENCES import_stmt (import_id)
);

CREATE INDEX IF NOT EXISTS idx_import_entity_stmt ON import_entity (import_id);
