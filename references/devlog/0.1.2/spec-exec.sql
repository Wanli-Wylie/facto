-- ============================================================
-- scope_part: structural decomposition of each scope
-- ============================================================
-- Each structural scope decomposes into up to 3 sequential parts:
--   specification → execution → subprogram (CONTAINS)
-- Not all scope kinds have all parts:
--   module/submodule:  specification + subprogram (no execution)
--   block_data:        specification only
--   program/function/subroutine/separate_mp: all three
--   global:            none (no syntactic body)
--
-- The grammar enforces strict ordering: specification before
-- execution before subprogram. No overlap, no interleaving.

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

