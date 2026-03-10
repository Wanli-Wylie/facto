"""Tests for segment_parts processor.

segment_parts: scope_residual → (scope_part_df, part_residual_df)
"""

import textwrap

import pytest

from facto.segment_parts import segment_parts
from tests.conftest import make_scope_residual


# ── All three parts ──


class TestAllThreeParts:
    def test_env_decl_exec(self):
        """Subroutine with USE + declarations + executable statements."""
        body = textwrap.dedent("""\
              USE iso_fortran_env
              IMPLICIT NONE
              INTEGER :: x, y
              REAL :: result
              x = 10
              y = 20
              result = REAL(x + y)
        """)
        sp, res = segment_parts(make_scope_residual(0, body, start_line=2, end_line=9))

        parts = set(sp["part"])
        assert parts == {"environment", "declarations", "execution"}

        # ordering: env < decl < exec
        env = sp[sp["part"] == "environment"]
        decl = sp[sp["part"] == "declarations"]
        exe = sp[sp["part"] == "execution"]
        assert env["end_line"].iloc[0] < decl["start_line"].iloc[0]
        assert decl["end_line"].iloc[0] < exe["start_line"].iloc[0]

    def test_use_import_implicit_then_decl_then_exec(self):
        """Full environment: USE + IMPORT + IMPLICIT."""
        body = textwrap.dedent("""\
              USE some_module
              IMPORT :: some_type
              IMPLICIT NONE
              INTEGER :: counter
              counter = 0
        """)
        sp, _ = segment_parts(make_scope_residual(0, body, start_line=2, end_line=6))

        env = sp[sp["part"] == "environment"]
        assert len(env) == 1
        # environment covers USE + IMPORT + IMPLICIT


# ── Two parts ──


class TestTwoParts:
    def test_env_and_decl_only(self):
        """Module with USE + declarations, no execution."""
        body = textwrap.dedent("""\
              USE iso_fortran_env
              IMPLICIT NONE
              INTEGER, PARAMETER :: max_size = 100
              REAL :: buffer(max_size)
        """)
        sp, _ = segment_parts(make_scope_residual(0, body, start_line=2, end_line=5, ast_kind="Module"))

        parts = set(sp["part"])
        assert "environment" in parts
        assert "declarations" in parts
        assert "execution" not in parts

    def test_decl_and_exec_no_env(self):
        """Subroutine with no USE/IMPORT/IMPLICIT."""
        body = textwrap.dedent("""\
              INTEGER :: i, sum
              sum = 0
              DO i = 1, 10
                sum = sum + i
              END DO
        """)
        sp, _ = segment_parts(make_scope_residual(0, body, start_line=2, end_line=6))

        parts = set(sp["part"])
        assert "environment" not in parts
        assert "declarations" in parts
        assert "execution" in parts


# ── Single part ──


class TestSinglePart:
    def test_exec_only(self):
        """Subroutine with no declarations at all."""
        body = textwrap.dedent("""\
              CALL setup()
              CALL compute()
              CALL teardown()
        """)
        sp, _ = segment_parts(make_scope_residual(0, body, start_line=2, end_line=4))

        assert len(sp) == 1
        assert sp["part"].iloc[0] == "execution"

    def test_decl_only(self):
        """Module with only declarations, no environment."""
        body = textwrap.dedent("""\
              INTEGER, PARAMETER :: nx = 100
              INTEGER, PARAMETER :: ny = 200
              REAL :: grid(nx, ny)
        """)
        sp, _ = segment_parts(make_scope_residual(0, body, start_line=2, end_line=4, ast_kind="Module"))

        assert len(sp) == 1
        assert sp["part"].iloc[0] == "declarations"

    def test_env_only(self):
        """Subroutine with only environment statements."""
        body = textwrap.dedent("""\
              USE mpi
              USE iso_c_binding
              IMPLICIT NONE
        """)
        sp, _ = segment_parts(make_scope_residual(0, body, start_line=2, end_line=4))

        assert len(sp) == 1
        assert sp["part"].iloc[0] == "environment"


# ── CONTAINS handling ──


class TestContains:
    def test_contains_excluded(self):
        """Subroutine with CONTAINS: internal procedures excluded from parts."""
        body = textwrap.dedent("""\
              USE math_lib
              IMPLICIT NONE
              INTEGER :: n
              CALL work(n)
            CONTAINS
              SUBROUTINE work(x)
                INTEGER, INTENT(IN) :: x
              END SUBROUTINE work
        """)
        sp, _ = segment_parts(make_scope_residual(0, body, start_line=2, end_line=9))

        parts = set(sp["part"])
        # CONTAINS and internal procedures should NOT produce a part row
        assert "subprogram" not in parts
        # should have env, decl, exec — but NOT the CONTAINS region
        assert "execution" in parts
        # execution part should end before CONTAINS
        exec_part = sp[sp["part"] == "execution"]
        assert exec_part["end_line"].iloc[0] < 7  # before CONTAINS line


# ── Block data ──


class TestBlockData:
    def test_block_data_spec_only(self):
        """Block data: only specification, no execution."""
        body = textwrap.dedent("""\
              COMMON /shared/ a, b, c
              REAL :: a, b, c
              DATA a, b, c / 1.0, 2.0, 3.0 /
        """)
        sp, _ = segment_parts(make_scope_residual(0, body, start_line=2, end_line=4, ast_kind="Block_Data"))

        parts = set(sp["part"])
        assert "execution" not in parts
        assert "declarations" in parts


# ── Environment boundary ──


class TestEnvironmentBoundary:
    def test_use_then_declaration(self):
        """USE followed immediately by declarations."""
        body = textwrap.dedent("""\
              USE mod_a
              USE mod_b
              INTEGER :: x
        """)
        sp, _ = segment_parts(make_scope_residual(0, body, start_line=2, end_line=4))

        env = sp[sp["part"] == "environment"]
        decl = sp[sp["part"] == "declarations"]
        assert len(env) == 1
        assert len(decl) == 1
        assert env["end_line"].iloc[0] < decl["start_line"].iloc[0]

    def test_implicit_none_only_env(self):
        """IMPLICIT NONE is the only environment statement."""
        body = textwrap.dedent("""\
              IMPLICIT NONE
              REAL :: x
              x = 1.0
        """)
        sp, _ = segment_parts(make_scope_residual(0, body, start_line=2, end_line=4))

        env = sp[sp["part"] == "environment"]
        assert len(env) == 1

    def test_multiple_use_statements(self):
        """Multiple USE statements form the environment."""
        body = textwrap.dedent("""\
              USE iso_fortran_env
              USE iso_c_binding
              USE mpi_f08
              IMPLICIT NONE
              INTEGER :: rank
              CALL MPI_COMM_RANK(MPI_COMM_WORLD, rank)
        """)
        sp, _ = segment_parts(make_scope_residual(0, body, start_line=2, end_line=7))

        env = sp[sp["part"] == "environment"]
        assert len(env) == 1
        # environment should cover all USE + IMPLICIT lines


# ── Residual ──


class TestPartResidual:
    def test_residual_has_text_per_part(self):
        body = textwrap.dedent("""\
              USE my_mod
              INTEGER :: x
              x = 1
        """)
        _, res = segment_parts(make_scope_residual(0, body, start_line=2, end_line=4))

        assert len(res) >= 2  # at least env/decl or decl/exec
        for _, row in res.iterrows():
            assert len(row["text"].strip()) > 0

    def test_residual_ast_kind(self):
        body = textwrap.dedent("""\
              USE my_mod
              INTEGER :: x
              x = 1
        """)
        _, res = segment_parts(make_scope_residual(0, body, start_line=2, end_line=4))

        exec_res = res[res["part"] == "execution"]
        if len(exec_res) > 0:
            assert exec_res["ast_kind"].iloc[0] == "Execution_Part"


# ── Non-overlapping invariant ──


class TestNonOverlapping:
    def test_parts_non_overlapping(self):
        body = textwrap.dedent("""\
              USE mod_a
              IMPLICIT NONE
              INTEGER :: i
              REAL :: sum
              sum = 0.0
              DO i = 1, 100
                sum = sum + REAL(i)
              END DO
        """)
        sp, _ = segment_parts(make_scope_residual(0, body, start_line=2, end_line=9))

        rows = sp.sort_values("start_line")
        for i in range(len(rows) - 1):
            assert rows.iloc[i]["end_line"] < rows.iloc[i + 1]["start_line"]

    def test_parts_cover_body(self):
        """Parts should cover the scope body completely (excluding CONTAINS)."""
        body = textwrap.dedent("""\
              USE mod_a
              INTEGER :: x
              x = 1
        """)
        sp, _ = segment_parts(make_scope_residual(0, body, start_line=2, end_line=4))

        min_start = sp["start_line"].min()
        max_end = sp["end_line"].max()
        assert min_start == 2
        assert max_end == 4


# ── Multiple scopes ──


class TestMultipleScopes:
    def test_two_scopes(self):
        """Process two scope residual rows at once."""
        import pandas as pd
        body1 = textwrap.dedent("""\
              USE mod_a
              INTEGER :: x
              x = 1
        """)
        body2 = textwrap.dedent("""\
              REAL :: y
              y = 2.0
        """)
        residual = pd.DataFrame([
            {"scope_id": 0, "filename": "test.f90", "start_line": 2, "end_line": 4,
             "text": body1, "ast_kind": "Subroutine_Subprogram"},
            {"scope_id": 1, "filename": "test.f90", "start_line": 7, "end_line": 8,
             "text": body2, "ast_kind": "Subroutine_Subprogram"},
        ])
        sp, _ = segment_parts(residual)

        scope_0_parts = sp[sp["scope_id"] == 0]
        scope_1_parts = sp[sp["scope_id"] == 1]
        assert len(scope_0_parts) >= 2
        assert len(scope_1_parts) >= 1
