"""Tests for parse_scopes processor.

parse_scopes: file_residual → (scope_df, scope_residual_df)
"""

import textwrap

import pandas as pd
import pytest

from facto.parse_scopes import parse_scopes
from tests.conftest import make_file_residual


# ── Single scope ──


class TestSingleScope:
    def test_standalone_program(self):
        src = textwrap.dedent("""\
            PROGRAM main
              IMPLICIT NONE
              INTEGER :: x
              x = 42
            END PROGRAM main
        """)
        scope, res = parse_scopes(make_file_residual(src, ast_kind="Program"))

        assert len(scope) == 1
        assert scope["kind"].iloc[0] == "program"
        assert scope["name"].iloc[0] == "main"
        assert scope["scope_id"].iloc[0] == 0
        assert pd.isna(scope["parent_scope_id"].iloc[0])
        assert scope["start_line"].iloc[0] == 1
        assert scope["end_line"].iloc[0] == 5

    def test_module(self):
        src = textwrap.dedent("""\
            MODULE physics
              IMPLICIT NONE
              REAL, PARAMETER :: gravity = 9.81
            END MODULE physics
        """)
        scope, _ = parse_scopes(make_file_residual(src, ast_kind="Module"))

        assert len(scope) == 1
        assert scope["kind"].iloc[0] == "module"
        assert scope["name"].iloc[0] == "physics"

    def test_external_subroutine(self):
        src = textwrap.dedent("""\
            SUBROUTINE solve(a, b, x)
              IMPLICIT NONE
              REAL, INTENT(IN) :: a, b
              REAL, INTENT(OUT) :: x
              x = -b / a
            END SUBROUTINE solve
        """)
        scope, _ = parse_scopes(make_file_residual(src, ast_kind="Subroutine_Subprogram"))

        assert scope["kind"].iloc[0] == "subroutine"
        assert scope["name"].iloc[0] == "solve"

    def test_external_function_with_result(self):
        src = textwrap.dedent("""\
            FUNCTION magnitude(x, y) RESULT(mag)
              IMPLICIT NONE
              REAL, INTENT(IN) :: x, y
              REAL :: mag
              mag = SQRT(x**2 + y**2)
            END FUNCTION magnitude
        """)
        scope, _ = parse_scopes(make_file_residual(src, ast_kind="Function_Subprogram"))

        assert scope["kind"].iloc[0] == "function"
        assert scope["name"].iloc[0] == "magnitude"

    def test_block_data(self):
        src = textwrap.dedent("""\
            BLOCK DATA init_globals
              IMPLICIT NONE
              COMMON /shared/ counter
              INTEGER :: counter
              DATA counter / 0 /
            END BLOCK DATA init_globals
        """)
        scope, _ = parse_scopes(make_file_residual(src, ast_kind="Block_Data"))

        assert scope["kind"].iloc[0] == "block_data"
        assert scope["name"].iloc[0] == "init_globals"

    def test_submodule(self):
        src = textwrap.dedent("""\
            SUBMODULE (parent_mod) child_impl
              IMPLICIT NONE
            CONTAINS
              MODULE PROCEDURE compute
                ! body
              END PROCEDURE compute
            END SUBMODULE child_impl
        """)
        scope, _ = parse_scopes(make_file_residual(src, ast_kind="Submodule"))

        assert scope["kind"].iloc[0] == "submodule"
        assert scope["name"].iloc[0] == "child_impl"


# ── Nesting via CONTAINS ──


class TestNesting:
    def test_module_with_internal_subroutine(self):
        src = textwrap.dedent("""\
            MODULE math_utils
              IMPLICIT NONE
              REAL, PARAMETER :: pi = 3.14159
            CONTAINS
              SUBROUTINE circle_area(r, area)
                REAL, INTENT(IN) :: r
                REAL, INTENT(OUT) :: area
                area = pi * r * r
              END SUBROUTINE circle_area
            END MODULE math_utils
        """)
        scope, res = parse_scopes(make_file_residual(src, ast_kind="Module"))

        assert len(scope) == 2
        mod = scope[scope["kind"] == "module"].iloc[0]
        sub = scope[scope["kind"] == "subroutine"].iloc[0]
        assert mod["name"] == "math_utils"
        assert sub["name"] == "circle_area"
        assert sub["parent_scope_id"] == mod["scope_id"]

    def test_module_with_function_and_subroutine(self):
        src = textwrap.dedent("""\
            MODULE linalg
              IMPLICIT NONE
            CONTAINS
              FUNCTION dot(a, b, n) RESULT(d)
                INTEGER, INTENT(IN) :: n
                REAL, INTENT(IN) :: a(n), b(n)
                REAL :: d
                INTEGER :: i
                d = 0.0
                DO i = 1, n
                  d = d + a(i) * b(i)
                END DO
              END FUNCTION dot

              SUBROUTINE axpy(a, x, y, n)
                INTEGER, INTENT(IN) :: n
                REAL, INTENT(IN) :: a, x(n)
                REAL, INTENT(INOUT) :: y(n)
                INTEGER :: i
                DO i = 1, n
                  y(i) = a * x(i) + y(i)
                END DO
              END SUBROUTINE axpy
            END MODULE linalg
        """)
        scope, _ = parse_scopes(make_file_residual(src, ast_kind="Module"))

        assert len(scope) == 3
        kinds = set(scope["kind"])
        assert kinds == {"module", "function", "subroutine"}

        mod_id = scope[scope["kind"] == "module"]["scope_id"].iloc[0]
        children = scope[scope["parent_scope_id"] == mod_id]
        assert len(children) == 2

    def test_program_with_internal_procedures(self):
        src = textwrap.dedent("""\
            PROGRAM driver
              IMPLICIT NONE
              REAL :: result
              CALL compute(result)
              PRINT *, result
            CONTAINS
              SUBROUTINE compute(r)
                REAL, INTENT(OUT) :: r
                r = helper(3.0)
              END SUBROUTINE compute
              FUNCTION helper(x) RESULT(y)
                REAL, INTENT(IN) :: x
                REAL :: y
                y = x * x
              END FUNCTION helper
            END PROGRAM driver
        """)
        scope, _ = parse_scopes(make_file_residual(src, ast_kind="Program"))

        assert len(scope) == 3
        prog_id = scope[scope["kind"] == "program"]["scope_id"].iloc[0]
        children = scope[scope["parent_scope_id"] == prog_id]
        assert len(children) == 2
        assert set(children["kind"]) == {"subroutine", "function"}

    def test_deeply_nested_contains(self):
        """module → contains → subroutine → contains → function"""
        src = textwrap.dedent("""\
            MODULE deep
              IMPLICIT NONE
            CONTAINS
              SUBROUTINE outer_sub()
                INTEGER :: a
                a = inner_func(1)
              CONTAINS
                FUNCTION inner_func(x) RESULT(r)
                  INTEGER, INTENT(IN) :: x
                  INTEGER :: r
                  r = x + 1
                END FUNCTION inner_func
              END SUBROUTINE outer_sub
            END MODULE deep
        """)
        scope, _ = parse_scopes(make_file_residual(src, ast_kind="Module"))

        assert len(scope) == 3
        mod = scope[scope["kind"] == "module"].iloc[0]
        sub = scope[scope["kind"] == "subroutine"].iloc[0]
        func = scope[scope["kind"] == "function"].iloc[0]
        assert sub["parent_scope_id"] == mod["scope_id"]
        assert func["parent_scope_id"] == sub["scope_id"]


# ── Unnamed program ──


class TestUnnamedProgram:
    def test_unnamed_program(self):
        src = textwrap.dedent("""\
              IMPLICIT NONE
              INTEGER :: x
              x = 42
              PRINT *, x
              END
        """)
        scope, _ = parse_scopes(make_file_residual(src, ast_kind="Program"))

        assert len(scope) == 1
        assert scope["kind"].iloc[0] == "program"
        assert pd.isna(scope["name"].iloc[0]) or scope["name"].iloc[0] is None


# ── Residual ──


class TestScopeResidual:
    def test_residual_excludes_header_and_end(self):
        src = textwrap.dedent("""\
            SUBROUTINE simple()
              INTEGER :: x
              x = 1
            END SUBROUTINE simple
        """)
        _, res = parse_scopes(make_file_residual(src, ast_kind="Subroutine_Subprogram"))

        assert len(res) == 1
        body = res["text"].iloc[0]
        assert "SUBROUTINE simple" not in body
        assert "END SUBROUTINE" not in body
        assert "INTEGER :: x" in body

    def test_residual_has_ast_kind(self):
        src = textwrap.dedent("""\
            MODULE mymod
              INTEGER :: n
            END MODULE mymod
        """)
        _, res = parse_scopes(make_file_residual(src, ast_kind="Module"))

        assert res["ast_kind"].iloc[0] in ("Module", "Module_Stmt")

    def test_residual_scope_id_matches_fact(self):
        src = textwrap.dedent("""\
            PROGRAM test
              INTEGER :: a
              a = 1
            END PROGRAM test
        """)
        scope, res = parse_scopes(make_file_residual(src, ast_kind="Program"))

        assert set(res["scope_id"]) == set(scope["scope_id"])


# ── ID assignment ──


class TestIdAssignment:
    def test_ids_sequential(self):
        src = textwrap.dedent("""\
            MODULE m
              IMPLICIT NONE
            CONTAINS
              SUBROUTINE s1()
              END SUBROUTINE s1
              SUBROUTINE s2()
              END SUBROUTINE s2
              FUNCTION f1() RESULT(r)
                INTEGER :: r
                r = 0
              END FUNCTION f1
            END MODULE m
        """)
        scope, _ = parse_scopes(make_file_residual(src, ast_kind="Module"))

        ids = sorted(scope["scope_id"].tolist())
        assert ids == list(range(len(ids)))
