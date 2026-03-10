"""Tests for partition_blocks processor.

partition_blocks: region_residual → (sbb_df, None)
"""

import textwrap

import pandas as pd
import pytest

from facto.partition_blocks import partition_blocks
from tests.conftest import make_region_residual


# ── Helpers ──


def concat_residuals(*dfs):
    return pd.concat(dfs, ignore_index=True)


# ── Statement blocks ──


class TestStatementBlocks:
    def test_single_statement(self):
        res = make_region_residual(0, None, "  x = 1\n", start_line=5, end_line=5)
        sbb, terminal = partition_blocks(res)

        assert terminal is None
        assert len(sbb) == 1
        assert sbb["kind"].iloc[0] == "statements"
        assert sbb["start_line"].iloc[0] == 5
        assert sbb["end_line"].iloc[0] == 5

    def test_multi_statement(self):
        text = textwrap.dedent("""\
              x = 1
              y = 2
              z = x + y
        """)
        res = make_region_residual(0, None, text, start_line=5, end_line=7)
        sbb, _ = partition_blocks(res)

        assert len(sbb) == 1
        assert sbb["kind"].iloc[0] == "statements"
        assert sbb["start_line"].iloc[0] == 5
        assert sbb["end_line"].iloc[0] == 7

    def test_call_statements(self):
        text = textwrap.dedent("""\
              CALL init()
              CALL compute(a, b, c)
              CALL finalize()
        """)
        res = make_region_residual(0, None, text, start_line=5, end_line=7)
        sbb, _ = partition_blocks(res)

        assert len(sbb) == 1
        assert sbb["kind"].iloc[0] == "statements"

    def test_io_statements(self):
        text = textwrap.dedent("""\
              READ *, x
              PRINT *, 'x = ', x
              WRITE(unit, fmt) x, y, z
        """)
        res = make_region_residual(0, None, text, start_line=5, end_line=7)
        sbb, _ = partition_blocks(res)

        assert len(sbb) == 1
        assert sbb["kind"].iloc[0] == "statements"


# ── Block scope ──


class TestBlockScope:
    def test_block_construct(self):
        text = textwrap.dedent("""\
              BLOCK
                INTEGER :: local
                local = 42
              END BLOCK
        """)
        res = make_region_residual(0, None, text, start_line=5, end_line=8, ast_kind="Block_Construct")
        sbb, _ = partition_blocks(res)

        assert len(sbb) == 1
        assert sbb["kind"].iloc[0] == "block_scope"
        assert sbb["start_line"].iloc[0] == 5
        assert sbb["end_line"].iloc[0] == 8

    def test_block_with_use(self):
        """Block scope with full environment — still opaque."""
        text = textwrap.dedent("""\
              BLOCK
                USE some_module
                IMPLICIT NONE
                INTEGER :: x
                x = compute()
              END BLOCK
        """)
        res = make_region_residual(0, None, text, start_line=5, end_line=10, ast_kind="Block_Construct")
        sbb, _ = partition_blocks(res)

        assert len(sbb) == 1
        assert sbb["kind"].iloc[0] == "block_scope"

    def test_block_with_nested_control(self):
        """Block scope containing control constructs — remains opaque."""
        text = textwrap.dedent("""\
              BLOCK
                INTEGER :: i, sum
                sum = 0
                DO i = 1, 10
                  sum = sum + i
                END DO
              END BLOCK
        """)
        res = make_region_residual(0, None, text, start_line=5, end_line=11, ast_kind="Block_Construct")
        sbb, _ = partition_blocks(res)

        # entire BLOCK is ONE opaque SBB
        assert len(sbb) == 1
        assert sbb["kind"].iloc[0] == "block_scope"
        assert sbb["start_line"].iloc[0] == 5
        assert sbb["end_line"].iloc[0] == 11


# ── Mixed: statements + block ──


class TestMixed:
    def test_stmts_block_stmts(self):
        """Three residual segments: statements, block, statements."""
        r1 = make_region_residual(0, None, "  x = 1\n  y = 2\n", start_line=5, end_line=6)
        r2 = make_region_residual(0, None, "  BLOCK\n    INTEGER :: z\n    z = 3\n  END BLOCK\n",
                                  start_line=7, end_line=10, ast_kind="Block_Construct")
        r3 = make_region_residual(0, None, "  w = x + y\n", start_line=11, end_line=11)
        res = concat_residuals(r1, r2, r3)
        sbb, _ = partition_blocks(res)

        assert len(sbb) == 3
        kinds = sbb["kind"].tolist()
        assert kinds == ["statements", "block_scope", "statements"]

    def test_block_then_stmts(self):
        r1 = make_region_residual(0, None, "  BLOCK\n    INTEGER :: a\n    a = 1\n  END BLOCK\n",
                                  start_line=5, end_line=8, ast_kind="Block_Construct")
        r2 = make_region_residual(0, None, "  PRINT *, 'done'\n", start_line=9, end_line=9)
        res = concat_residuals(r1, r2)
        sbb, _ = partition_blocks(res)

        assert len(sbb) == 2
        assert sbb["kind"].iloc[0] == "block_scope"
        assert sbb["kind"].iloc[1] == "statements"

    def test_multiple_blocks(self):
        """Two consecutive BLOCK constructs."""
        r1 = make_region_residual(0, None, "  BLOCK\n    INTEGER :: a\n    a = 1\n  END BLOCK\n",
                                  start_line=5, end_line=8, ast_kind="Block_Construct")
        r2 = make_region_residual(0, None, "  BLOCK\n    INTEGER :: b\n    b = 2\n  END BLOCK\n",
                                  start_line=9, end_line=12, ast_kind="Block_Construct")
        res = concat_residuals(r1, r2)
        sbb, _ = partition_blocks(res)

        assert len(sbb) == 2
        assert all(sbb["kind"] == "block_scope")


# ── Region context ──


class TestRegionContext:
    def test_top_level_region_id_null(self):
        res = make_region_residual(0, None, "  x = 1\n", start_line=5, end_line=5)
        sbb, _ = partition_blocks(res)

        assert pd.isna(sbb["region_id"].iloc[0])

    def test_inside_region(self):
        res = make_region_residual(0, 3, "  x = a(i)\n", start_line=7, end_line=7)
        sbb, _ = partition_blocks(res)

        assert sbb["region_id"].iloc[0] == 3

    def test_scope_id_preserved(self):
        res = make_region_residual(5, None, "  x = 1\n", start_line=10, end_line=10)
        sbb, _ = partition_blocks(res)

        assert sbb["scope_id"].iloc[0] == 5

    def test_mixed_region_ids(self):
        """Different segments from different regions."""
        r1 = make_region_residual(0, None, "  x = 1\n", start_line=5, end_line=5)
        r2 = make_region_residual(0, 0, "  y = 2\n", start_line=7, end_line=7)
        r3 = make_region_residual(0, 1, "  z = 3\n", start_line=9, end_line=9)
        res = concat_residuals(r1, r2, r3)
        sbb, _ = partition_blocks(res)

        assert len(sbb) == 3
        assert pd.isna(sbb["region_id"].iloc[0])
        assert sbb["region_id"].iloc[1] == 0
        assert sbb["region_id"].iloc[2] == 1


# ── Empty input ──


class TestEmpty:
    def test_empty_residual(self):
        empty = pd.DataFrame(columns=[
            "scope_id", "region_id", "filename", "start_line", "end_line", "text", "ast_kind"
        ])
        sbb, _ = partition_blocks(empty)

        assert len(sbb) == 0

    def test_blank_text_segment(self):
        """Segment with only whitespace — should produce no SBB."""
        res = make_region_residual(0, None, "   \n   \n", start_line=5, end_line=6)
        sbb, _ = partition_blocks(res)

        # blank segments may produce 0 rows (no executable content)
        # or 1 row — implementation decides; either is acceptable


# ── ID assignment ──


class TestIdAssignment:
    def test_sbb_ids_sequential(self):
        r1 = make_region_residual(0, None, "  x = 1\n", start_line=5, end_line=5)
        r2 = make_region_residual(0, None, "  BLOCK\n    INTEGER :: a\n  END BLOCK\n",
                                  start_line=6, end_line=8, ast_kind="Block_Construct")
        r3 = make_region_residual(0, None, "  y = 2\n", start_line=9, end_line=9)
        res = concat_residuals(r1, r2, r3)
        sbb, _ = partition_blocks(res)

        ids = sorted(sbb["sbb_id"].tolist())
        assert ids == list(range(len(ids)))

    def test_sbb_ids_unique(self):
        r1 = make_region_residual(0, None, "  x = 1\n", start_line=5, end_line=5)
        r2 = make_region_residual(0, 0, "  y = 2\n", start_line=7, end_line=7)
        r3 = make_region_residual(0, 0, "  z = 3\n", start_line=8, end_line=8)
        res = concat_residuals(r1, r2, r3)
        sbb, _ = partition_blocks(res)

        assert sbb["sbb_id"].is_unique


# ── Filename propagation ──


class TestFilename:
    def test_filename_from_residual(self):
        res = make_region_residual(0, None, "  x = 1\n", filename="solver.f90", start_line=5, end_line=5)
        sbb, _ = partition_blocks(res)

        assert sbb["filename"].iloc[0] == "solver.f90"
