"""Tests for parse_regions processor.

parse_regions: exec_residual → (control_region_df, region_residual_df)
"""

import textwrap

import pandas as pd
import pytest

from facto.parse_regions import parse_regions
from tests.conftest import make_part_residual


# ── Helpers ──


def exec_residual(text: str, scope_id: int = 0, start_line: int = 5, end_line: int = 20):
    return make_part_residual(scope_id, "execution", text, start_line=start_line, end_line=end_line)


# ── IF constructs ──


class TestIfConstruct:
    def test_simple_if_then_endif(self):
        text = textwrap.dedent("""\
              IF (x > 0) THEN
                y = x
              END IF
        """)
        cr, res = parse_regions(exec_residual(text, start_line=5, end_line=7))

        assert len(cr) == 1
        assert cr["kind"].iloc[0] == "if"
        assert cr["scope_id"].iloc[0] == 0
        assert pd.isna(cr["parent_region_id"].iloc[0])

    def test_if_then_else_endif(self):
        text = textwrap.dedent("""\
              IF (x > 0) THEN
                y = x
              ELSE
                y = -x
              END IF
        """)
        cr, _ = parse_regions(exec_residual(text, start_line=5, end_line=9))

        assert len(cr) == 1
        assert cr["kind"].iloc[0] == "if"

    def test_if_elseif_else_endif(self):
        text = textwrap.dedent("""\
              IF (x > 0) THEN
                y = 1
              ELSE IF (x == 0) THEN
                y = 0
              ELSE
                y = -1
              END IF
        """)
        cr, _ = parse_regions(exec_residual(text, start_line=5, end_line=11))

        assert len(cr) == 1
        assert cr["kind"].iloc[0] == "if"


# ── DO constructs ──


class TestDoConstruct:
    def test_counted_do(self):
        text = textwrap.dedent("""\
              DO i = 1, 100
                sum = sum + a(i)
              END DO
        """)
        cr, _ = parse_regions(exec_residual(text, start_line=5, end_line=7))

        assert len(cr) == 1
        assert cr["kind"].iloc[0] == "do"

    def test_do_while(self):
        text = textwrap.dedent("""\
              DO WHILE (err > tol)
                CALL iterate(err)
              END DO
        """)
        cr, _ = parse_regions(exec_residual(text, start_line=5, end_line=7))

        assert len(cr) == 1
        assert cr["kind"].iloc[0] == "do_while"

    def test_do_concurrent(self):
        text = textwrap.dedent("""\
              DO CONCURRENT (i = 1:n)
                b(i) = a(i) * 2.0
              END DO
        """)
        cr, _ = parse_regions(exec_residual(text, start_line=5, end_line=7))

        assert len(cr) == 1
        assert cr["kind"].iloc[0] == "do_concurrent"

    def test_nested_do_loops(self):
        text = textwrap.dedent("""\
              DO i = 1, m
                DO j = 1, n
                  c(i,j) = a(i,j) + b(i,j)
                END DO
              END DO
        """)
        cr, _ = parse_regions(exec_residual(text, start_line=5, end_line=9))

        assert len(cr) == 2
        outer = cr[cr["kind"] == "do"].iloc[0]
        inner = cr[cr["kind"] == "do"].iloc[1]
        # inner DO's parent should be outer DO
        assert inner["parent_region_id"] == outer["region_id"]


# ── SELECT constructs ──


class TestSelectConstruct:
    def test_select_case(self):
        text = textwrap.dedent("""\
              SELECT CASE (code)
                CASE (1)
                  CALL handle_one()
                CASE (2)
                  CALL handle_two()
                CASE DEFAULT
                  CALL handle_default()
              END SELECT
        """)
        cr, _ = parse_regions(exec_residual(text, start_line=5, end_line=12))

        assert len(cr) == 1
        assert cr["kind"].iloc[0] == "select_case"

    def test_select_type(self):
        text = textwrap.dedent("""\
              SELECT TYPE (obj)
                TYPE IS (integer)
                  PRINT *, 'integer'
                TYPE IS (real)
                  PRINT *, 'real'
                CLASS DEFAULT
                  PRINT *, 'unknown'
              END SELECT
        """)
        cr, _ = parse_regions(exec_residual(text, start_line=5, end_line=12))

        assert len(cr) == 1
        assert cr["kind"].iloc[0] == "select_type"


# ── WHERE construct ──


class TestWhereConstruct:
    def test_where(self):
        text = textwrap.dedent("""\
              WHERE (a > 0.0)
                b = SQRT(a)
              ELSEWHERE
                b = 0.0
              END WHERE
        """)
        cr, _ = parse_regions(exec_residual(text, start_line=5, end_line=9))

        assert len(cr) == 1
        assert cr["kind"].iloc[0] == "where"


# ── ASSOCIATE construct ──


class TestAssociateConstruct:
    def test_associate(self):
        text = textwrap.dedent("""\
              ASSOCIATE (nx => grid%dims(1), ny => grid%dims(2))
                ALLOCATE(buffer(nx, ny))
                buffer = 0.0
              END ASSOCIATE
        """)
        cr, _ = parse_regions(exec_residual(text, start_line=5, end_line=8))

        assert len(cr) == 1
        assert cr["kind"].iloc[0] == "associate"


# ── FORALL construct ──


class TestForallConstruct:
    def test_forall(self):
        text = textwrap.dedent("""\
              FORALL (i = 1:n, j = 1:n, i /= j)
                a(i,j) = 0.0
              END FORALL
        """)
        cr, _ = parse_regions(exec_residual(text, start_line=5, end_line=7))

        assert len(cr) == 1
        assert cr["kind"].iloc[0] == "forall"


# ── CRITICAL construct ──


class TestCriticalConstruct:
    def test_critical(self):
        text = textwrap.dedent("""\
              CRITICAL
                shared_counter = shared_counter + 1
              END CRITICAL
        """)
        cr, _ = parse_regions(exec_residual(text, start_line=5, end_line=7))

        assert len(cr) == 1
        assert cr["kind"].iloc[0] == "critical"


# ── BLOCK construct (key v0.1.8 test) ──


class TestBlockPassthrough:
    """BLOCK must NOT appear in control_region. It goes to residual."""

    def test_block_not_in_control_region(self):
        text = textwrap.dedent("""\
              a = 1
              BLOCK
                INTEGER :: b
                b = 2
              END BLOCK
              a = a + 1
        """)
        cr, res = parse_regions(exec_residual(text, start_line=5, end_line=10))

        assert len(cr) == 0  # BLOCK is NOT a control region
        block_rows = res[res["ast_kind"] == "Block_Construct"]
        assert len(block_rows) == 1

    def test_block_inside_do(self):
        text = textwrap.dedent("""\
              DO i = 1, n
                x = a(i)
                BLOCK
                  REAL :: temp
                  temp = x * x
                  b(i) = temp
                END BLOCK
              END DO
        """)
        cr, res = parse_regions(exec_residual(text, start_line=5, end_line=12))

        # Only DO should be a control region
        assert len(cr) == 1
        assert cr["kind"].iloc[0] == "do"

        # BLOCK should be in the residual
        block_rows = res[res["ast_kind"] == "Block_Construct"]
        assert len(block_rows) == 1

    def test_block_with_use_import(self):
        """BLOCK with full specification part — still opaque."""
        text = textwrap.dedent("""\
              BLOCK
                USE some_module
                IMPORT :: some_type
                IMPLICIT NONE
                INTEGER :: local_var
                local_var = 42
              END BLOCK
        """)
        cr, res = parse_regions(exec_residual(text, start_line=5, end_line=11))

        assert len(cr) == 0
        block_rows = res[res["ast_kind"] == "Block_Construct"]
        assert len(block_rows) == 1

    def test_block_between_statements(self):
        """BLOCK creates SBB boundaries in the residual."""
        text = textwrap.dedent("""\
              x = 1
              y = 2
              BLOCK
                INTEGER :: z
                z = x + y
              END BLOCK
              w = x - y
        """)
        cr, res = parse_regions(exec_residual(text, start_line=5, end_line=11))

        assert len(cr) == 0
        # should have: stmt segment, BLOCK, stmt segment
        exec_rows = res[res["ast_kind"] == "Execution_Part"]
        block_rows = res[res["ast_kind"] == "Block_Construct"]
        assert len(exec_rows) == 2
        assert len(block_rows) == 1


# ── Named constructs ──


class TestNamedConstruct:
    def test_named_do(self):
        text = textwrap.dedent("""\
              outer: DO i = 1, n
                inner: DO j = 1, m
                  c(i,j) = a(i,j) * b(i,j)
                END DO inner
              END DO outer
        """)
        cr, _ = parse_regions(exec_residual(text, start_line=5, end_line=9))

        # construct_name is a process output, not in fact table
        assert len(cr) == 2
        assert all(cr["kind"] == "do")


# ── Nesting ──


class TestNesting:
    def test_do_containing_if(self):
        text = textwrap.dedent("""\
              DO i = 1, n
                IF (a(i) > 0) THEN
                  b(i) = SQRT(a(i))
                ELSE
                  b(i) = 0.0
                END IF
              END DO
        """)
        cr, _ = parse_regions(exec_residual(text, start_line=5, end_line=11))

        assert len(cr) == 2
        do_reg = cr[cr["kind"] == "do"].iloc[0]
        if_reg = cr[cr["kind"] == "if"].iloc[0]
        assert if_reg["parent_region_id"] == do_reg["region_id"]

    def test_triple_nesting(self):
        """DO → IF → DO: three levels."""
        text = textwrap.dedent("""\
              DO i = 1, m
                IF (mask(i)) THEN
                  DO j = 1, n
                    c(i,j) = a(i,j) + b(i,j)
                  END DO
                END IF
              END DO
        """)
        cr, _ = parse_regions(exec_residual(text, start_line=5, end_line=11))

        assert len(cr) == 3
        # check nesting chain
        outer_do = cr[cr["start_line"] == cr["start_line"].min()].iloc[0]
        inner_if = cr[cr["kind"] == "if"].iloc[0]
        inner_do = cr[cr["start_line"] == cr["start_line"].max()].iloc[0]
        assert inner_if["parent_region_id"] == outer_do["region_id"]
        assert inner_do["parent_region_id"] == inner_if["region_id"]

    def test_four_level_nesting(self):
        """IF → DO → IF → DO: deep nesting."""
        text = textwrap.dedent("""\
              IF (active) THEN
                DO i = 1, n
                  IF (a(i) > threshold) THEN
                    DO j = 1, m
                      result(i,j) = process(a(i), b(j))
                    END DO
                  END IF
                END DO
              END IF
        """)
        cr, _ = parse_regions(exec_residual(text, start_line=5, end_line=13))

        assert len(cr) == 4


# ── Siblings ──


class TestSiblings:
    def test_two_siblings(self):
        text = textwrap.dedent("""\
              IF (x > 0) THEN
                y = 1
              END IF
              DO i = 1, 10
                sum = sum + i
              END DO
        """)
        cr, _ = parse_regions(exec_residual(text, start_line=5, end_line=10))

        assert len(cr) == 2
        assert set(cr["kind"]) == {"if", "do"}
        # both should be top-level (no parent)
        assert cr["parent_region_id"].isna().all()

    def test_three_siblings(self):
        text = textwrap.dedent("""\
              DO i = 1, n
                a(i) = i
              END DO
              WHERE (a > 5)
                b = a
              END WHERE
              IF (SUM(b) > 100) THEN
                PRINT *, 'large'
              END IF
        """)
        cr, _ = parse_regions(exec_residual(text, start_line=5, end_line=13))

        assert len(cr) == 3
        assert set(cr["kind"]) == {"do", "where", "if"}


# ── No constructs ──


class TestNoConstructs:
    def test_straight_line(self):
        text = textwrap.dedent("""\
              x = 1
              y = 2
              z = x + y
              PRINT *, z
        """)
        cr, res = parse_regions(exec_residual(text, start_line=5, end_line=8))

        assert len(cr) == 0
        # residual should carry the entire text as one segment
        assert len(res) >= 1

    def test_single_call(self):
        text = "  CALL setup()\n"
        cr, res = parse_regions(exec_residual(text, start_line=5, end_line=5))

        assert len(cr) == 0


# ── Empty input ──


class TestEmptyInput:
    def test_empty_dataframe(self):
        empty = pd.DataFrame(columns=["scope_id", "part", "filename", "start_line", "end_line", "text", "ast_kind"])
        cr, res = parse_regions(empty)

        assert len(cr) == 0


# ── Residual structure ──


class TestResidual:
    def test_residual_has_scope_id(self):
        text = textwrap.dedent("""\
              DO i = 1, 10
                x = i
              END DO
        """)
        _, res = parse_regions(exec_residual(text, scope_id=3, start_line=5, end_line=7))

        assert all(res["scope_id"] == 3)

    def test_residual_region_id_for_nested(self):
        """Residual segments inside a region should carry its region_id."""
        text = textwrap.dedent("""\
              DO i = 1, n
                x = a(i)
              END DO
        """)
        cr, res = parse_regions(exec_residual(text, start_line=5, end_line=7))

        if len(cr) > 0:
            do_id = cr["region_id"].iloc[0]
            inner = res[res["region_id"] == do_id]
            # body of DO should be in residual with region_id = do_id
            assert len(inner) >= 1
