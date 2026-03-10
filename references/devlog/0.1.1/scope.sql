CREATE TABLE IF NOT EXISTS scope (
    scope_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parent_scope_id  BIGINT,
    kind             TEXT NOT NULL,
    name             TEXT,
    filename         TEXT,
    start_line       INTEGER,
    end_line         INTEGER,
    implicit_typing  TEXT NOT NULL DEFAULT 'inherit',
    ancestor_scope_id    BIGINT,
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
