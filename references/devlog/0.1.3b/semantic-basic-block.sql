-- ============================================================
-- semantic_basic_block: flat partition of each execution part
-- ============================================================
-- The semantic basic block (SBB) is the maximal contiguous
-- statement sequence sharing both:
--   1. The same control flow context (no internal branch/target)
--   2. The same name-binding environment
--
-- SBBs are derived from the control construct tree (CCT):
-- linearize the tree's leaves and partition at every control
-- flow or binding boundary. Under the construct-aware CFG
-- convention (every construct opening/closing is a BB boundary),
-- conditions 1 and 2 coincide.
--
-- Each SBB belongs to exactly one structural scope (scope_id)
-- and sits inside at most one control_region (region_id).
-- NULL region_id = top-level code in the execution part,
-- not nested inside any control construct.
--
-- Containment chain:
--   scope ⊇ scope_part(execution) ⊇ control_region ⊇ sbb
-- All verifiable via line-range inclusion.

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

-- ============================================================
-- sbb_edge: control flow edges between semantic basic blocks
-- ============================================================
-- CFG edges connecting SBBs within a single structural scope.
--
-- edge_kind classifies the transfer:
--   fallthrough  — sequential (next statement)
--   branch_true  — conditional true path
--   branch_false — conditional false path
--   case_select  — multi-way branch (one selected arm)
--   loop_back    — back-edge to loop header
--   loop_exit    — normal exit from loop
--   jump         — non-local transfer (GOTO, CYCLE, EXIT)
--   return       — procedure exit (RETURN, STOP, ERROR STOP)
--
-- Convention: each executable scope has a synthetic ENTRY SBB
-- (start_line = end_line = scope's first executable line) and
-- EXIT SBB (start_line = end_line = scope's END line).
-- RETURN/STOP edges target the EXIT SBB; the ENTRY SBB has a
-- fallthrough edge to the first real SBB.

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
        'fallthrough', 'branch_true', 'branch_false', 'case_select',
        'loop_back', 'loop_exit', 'jump', 'return'
    ))
);

CREATE INDEX IF NOT EXISTS idx_edge_from ON sbb_edge (from_sbb_id);
CREATE INDEX IF NOT EXISTS idx_edge_to   ON sbb_edge (to_sbb_id);
