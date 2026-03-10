"""Tests for parse_source processor.

parse_source: (text, filename) → (source_line_df, file_residual_df)
"""

import textwrap

import pytest

from facto.parse_source import parse_source


class TestSingleProgramUnit:
    """Simplest case: one program unit."""

    def test_minimal_program(self):
        src = textwrap.dedent("""\
            PROGRAM hello
              PRINT *, 'hello world'
            END PROGRAM hello
        """)
        sl, res = parse_source(src, "hello.f90")

        assert len(sl) == 3
        assert list(sl["line_no"]) == [1, 2, 3]
        assert sl["filename"].unique().tolist() == ["hello.f90"]
        assert "PROGRAM hello" in sl["line_text"].iloc[0]

        assert len(res) == 1
        assert res["filename"].iloc[0] == "hello.f90"
        assert res["text"].iloc[0] == src
        assert res["ast_kind"].iloc[0] == "Program"

    def test_minimal_module(self):
        src = textwrap.dedent("""\
            MODULE mymod
              IMPLICIT NONE
              INTEGER :: x
            END MODULE mymod
        """)
        sl, res = parse_source(src, "mymod.f90")

        assert len(sl) == 4
        assert res["ast_kind"].iloc[0] == "Module"

    def test_external_subroutine(self):
        src = textwrap.dedent("""\
            SUBROUTINE compute(a, b, c)
              IMPLICIT NONE
              REAL, INTENT(IN) :: a, b
              REAL, INTENT(OUT) :: c
              c = a + b
            END SUBROUTINE compute
        """)
        sl, res = parse_source(src, "compute.f90")

        assert len(sl) == 6
        assert res["ast_kind"].iloc[0] in ("Subroutine_Subprogram", "Subroutine")

    def test_external_function(self):
        src = textwrap.dedent("""\
            FUNCTION square(x) RESULT(r)
              IMPLICIT NONE
              REAL, INTENT(IN) :: x
              REAL :: r
              r = x * x
            END FUNCTION square
        """)
        sl, res = parse_source(src, "square.f90")
        assert len(sl) == 6

    def test_block_data(self):
        src = textwrap.dedent("""\
            BLOCK DATA init_data
              IMPLICIT NONE
              COMMON /blk/ a, b
              REAL :: a, b
              DATA a, b / 1.0, 2.0 /
            END BLOCK DATA init_data
        """)
        sl, res = parse_source(src, "init.f90")
        assert len(sl) == 6


class TestMultipleProgramUnits:
    """Multiple program units in one file."""

    def test_module_plus_program(self):
        src = textwrap.dedent("""\
            MODULE constants
              IMPLICIT NONE
              REAL, PARAMETER :: pi = 3.14159
            END MODULE constants

            PROGRAM main
              USE constants
              PRINT *, pi
            END PROGRAM main
        """)
        sl, res = parse_source(src, "multi.f90")

        assert len(sl) == 9  # including blank line
        # should produce residual rows for each program unit
        assert len(res) >= 1

    def test_module_plus_external_subroutine(self):
        src = textwrap.dedent("""\
            MODULE types
              IMPLICIT NONE
              TYPE :: point
                REAL :: x, y
              END TYPE point
            END MODULE types

            SUBROUTINE move_point(p, dx, dy)
              USE types
              IMPLICIT NONE
              TYPE(point), INTENT(INOUT) :: p
              REAL, INTENT(IN) :: dx, dy
              p%x = p%x + dx
              p%y = p%y + dy
            END SUBROUTINE move_point
        """)
        sl, res = parse_source(src, "types_and_move.f90")
        assert len(sl) == 16


class TestEdgeCases:
    """Edge cases: empty files, comments, continuations."""

    def test_comment_only(self):
        src = textwrap.dedent("""\
            ! This is just a comment
            ! No program units here
        """)
        sl, res = parse_source(src, "comments.f90")

        assert len(sl) == 2
        assert len(res) == 0  # no program units

    def test_blank_file(self):
        sl, res = parse_source("", "empty.f90")
        assert len(sl) == 0
        assert len(res) == 0

    def test_single_blank_line(self):
        sl, res = parse_source("\n", "blank.f90")
        assert len(sl) >= 1

    def test_free_form_continuation(self):
        src = textwrap.dedent("""\
            PROGRAM continued
              INTEGER :: very_long_variable_name
              very_long_variable_name = 1 + 2 + 3 + &
                4 + 5 + 6
            END PROGRAM continued
        """)
        sl, res = parse_source(src, "cont.f90")

        # source_line preserves raw physical lines
        assert len(sl) == 5
        assert "&" in sl["line_text"].iloc[2]

    def test_line_numbers_contiguous(self):
        src = textwrap.dedent("""\
            PROGRAM lines
              INTEGER :: a
              INTEGER :: b
              INTEGER :: c
              a = 1
              b = 2
              c = 3
            END PROGRAM lines
        """)
        sl, _ = parse_source(src, "lines.f90")

        line_nos = sl["line_no"].tolist()
        assert line_nos == list(range(1, len(sl) + 1))


class TestSubmodule:
    def test_submodule(self):
        src = textwrap.dedent("""\
            SUBMODULE (parent_mod) child_sub
              IMPLICIT NONE
            CONTAINS
              MODULE PROCEDURE my_proc
                ! implementation
              END PROCEDURE my_proc
            END SUBMODULE child_sub
        """)
        sl, res = parse_source(src, "child.f90")
        assert len(sl) == 7
