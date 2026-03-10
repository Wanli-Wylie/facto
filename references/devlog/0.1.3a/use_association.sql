-- ============================================================
-- Layer 1: USE association
-- ============================================================
-- Each USE statement imports names from a module into the
-- current scope. Two tables: use_stmt (one row per USE
-- statement) and use_entity (one row per explicitly named
-- entity in an ONLY or rename list).
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
        'unspecified',       -- USE module_name (no qualifier)
        'intrinsic',         -- USE, INTRINSIC :: module_name
        'non_intrinsic'      -- USE, NON_INTRINSIC :: module_name
    ))
);

CREATE INDEX IF NOT EXISTS idx_use_scope  ON use_stmt (scope_id);
CREATE INDEX IF NOT EXISTS idx_use_module ON use_stmt (module_name);

-- ============================================================
-- use_entity: individual names from ONLY or rename lists
-- ============================================================
-- Fortran syntax: USE module, local_name => module_name
--                 USE module, ONLY: name, local => module_name
--
-- When local_name IS NULL, the entity is imported with its
-- original module name. When local_name IS NOT NULL, the
-- module entity is renamed in the current scope.

CREATE TABLE IF NOT EXISTS use_entity (
    use_id             BIGINT NOT NULL,
    module_entity_name TEXT   NOT NULL,
    local_name         TEXT,

    PRIMARY KEY (use_id, module_entity_name),

    CONSTRAINT fk_use_entity_stmt
        FOREIGN KEY (use_id) REFERENCES use_stmt (use_id)
);

CREATE INDEX IF NOT EXISTS idx_use_entity_stmt ON use_entity (use_id);
