-- ============================================================
-- Internal tables (storage + versioning)
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

-- ============================================================
-- Public view: the only interface downstream stages consume
-- ============================================================

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
