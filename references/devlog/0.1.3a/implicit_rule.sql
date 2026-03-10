-- ============================================================
-- Layer 3: IMPLICIT typing rules
-- ============================================================
-- Extends the scope table's implicit_typing column. When
-- implicit_typing = 'custom', this table stores the letter-
-- range → type mappings declared by IMPLICIT statements.
--
-- When implicit_typing = 'default': standard F77 rules apply
--   (I-N → INTEGER, everything else → REAL). No rows needed.
-- When implicit_typing = 'none': all names must be declared.
--   No rows needed.
-- When implicit_typing = 'inherit': parent's rules apply.
--   No rows needed.
-- When implicit_typing = 'custom': one or more rows define
--   the letter → type mapping for this scope.
--
-- Multiple IMPLICIT statements in one scope are merged: each
-- maps a disjoint set of letter ranges to types. The standard
-- requires that no letter is mapped more than once per scope.

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

-- ============================================================
-- Examples:
--
--   IMPLICIT DOUBLE PRECISION (A-H, O-Z)
--   → two rows:
--     (scope_id, 'A', 'H', 'DOUBLE PRECISION')
--     (scope_id, 'O', 'Z', 'DOUBLE PRECISION')
--
--   IMPLICIT INTEGER (I-N)
--   → one row:
--     (scope_id, 'I', 'N', 'INTEGER')
--
--   IMPLICIT COMPLEX(KIND=8) (C)
--   → one row:
--     (scope_id, 'C', 'C', 'COMPLEX(KIND=8)')
-- ============================================================
