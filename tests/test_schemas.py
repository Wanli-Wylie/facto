"""Tests for pandera schema validation.

These tests run NOW — they don't depend on processor implementations.
They verify that schemas accept valid data and reject invalid data.
"""

import pandas as pd
import pandera
import pytest

from facto.schemas import (
    ControlRegionSchema,
    REGION_KINDS,
    SBB_KINDS,
    ScopePartSchema,
    ScopeSchema,
    SemanticBasicBlockSchema,
    SourceLineSchema,
)


# ── SourceLineSchema ──


class TestSourceLineSchema:
    def test_valid(self):
        df = pd.DataFrame({
            "filename": ["test.f90", "test.f90"],
            "line_no": [1, 2],
            "line_text": ["PROGRAM hello", "END PROGRAM"],
        })
        SourceLineSchema.validate(df)

    def test_rejects_zero_line_no(self):
        df = pd.DataFrame({
            "filename": ["test.f90"],
            "line_no": [0],
            "line_text": ["PROGRAM hello"],
        })
        with pytest.raises(pandera.errors.SchemaError):
            SourceLineSchema.validate(df)

    def test_rejects_extra_column(self):
        df = pd.DataFrame({
            "filename": ["test.f90"],
            "line_no": [1],
            "line_text": ["x"],
            "extra": [True],
        })
        with pytest.raises(pandera.errors.SchemaError):
            SourceLineSchema.validate(df)


# ── ScopeSchema ──


class TestScopeSchema:
    def test_valid_program(self):
        df = pd.DataFrame({
            "scope_id": [0],
            "parent_scope_id": pd.array([pd.NA], dtype=pd.Int64Dtype()),
            "kind": ["program"],
            "name": ["main"],
            "filename": ["test.f90"],
            "start_line": pd.array([1], dtype=pd.Int64Dtype()),
            "end_line": pd.array([10], dtype=pd.Int64Dtype()),
        })
        ScopeSchema.validate(df)

    def test_valid_all_8_kinds(self):
        kinds = [
            "global", "program", "module", "submodule",
            "block_data", "function", "subroutine", "separate_mp",
        ]
        df = pd.DataFrame({
            "scope_id": list(range(len(kinds))),
            "parent_scope_id": pd.array([pd.NA] * len(kinds), dtype=pd.Int64Dtype()),
            "kind": kinds,
            "name": [None] * len(kinds),
            "filename": ["test.f90"] * len(kinds),
            "start_line": pd.array([1] * len(kinds), dtype=pd.Int64Dtype()),
            "end_line": pd.array([10] * len(kinds), dtype=pd.Int64Dtype()),
        })
        ScopeSchema.validate(df)

    def test_rejects_invalid_kind(self):
        df = pd.DataFrame({
            "scope_id": [0],
            "parent_scope_id": pd.array([pd.NA], dtype=pd.Int64Dtype()),
            "kind": ["block"],  # invalid — not one of 8
            "name": [None],
            "filename": ["test.f90"],
            "start_line": pd.array([1], dtype=pd.Int64Dtype()),
            "end_line": pd.array([10], dtype=pd.Int64Dtype()),
        })
        with pytest.raises(pandera.errors.SchemaError):
            ScopeSchema.validate(df)

    def test_nullable_name(self):
        df = pd.DataFrame({
            "scope_id": [0],
            "parent_scope_id": pd.array([pd.NA], dtype=pd.Int64Dtype()),
            "kind": ["program"],
            "name": [None],
            "filename": ["test.f90"],
            "start_line": pd.array([1], dtype=pd.Int64Dtype()),
            "end_line": pd.array([5], dtype=pd.Int64Dtype()),
        })
        ScopeSchema.validate(df)

    def test_parent_scope_id_nullable(self):
        df = pd.DataFrame({
            "scope_id": [0, 1],
            "parent_scope_id": pd.array([pd.NA, 0], dtype=pd.Int64Dtype()),
            "kind": ["module", "subroutine"],
            "name": ["mymod", "mysub"],
            "filename": ["test.f90", "test.f90"],
            "start_line": pd.array([1, 5], dtype=pd.Int64Dtype()),
            "end_line": pd.array([20, 15], dtype=pd.Int64Dtype()),
        })
        ScopeSchema.validate(df)

    def test_rejects_start_after_end(self):
        df = pd.DataFrame({
            "scope_id": [0],
            "parent_scope_id": pd.array([pd.NA], dtype=pd.Int64Dtype()),
            "kind": ["program"],
            "name": ["main"],
            "filename": ["test.f90"],
            "start_line": pd.array([10], dtype=pd.Int64Dtype()),
            "end_line": pd.array([5], dtype=pd.Int64Dtype()),
        })
        with pytest.raises(pandera.errors.SchemaError):
            ScopeSchema.validate(df)

    def test_rejects_duplicate_scope_id(self):
        df = pd.DataFrame({
            "scope_id": [0, 0],
            "parent_scope_id": pd.array([pd.NA, pd.NA], dtype=pd.Int64Dtype()),
            "kind": ["program", "module"],
            "name": ["a", "b"],
            "filename": ["test.f90", "test.f90"],
            "start_line": pd.array([1, 5], dtype=pd.Int64Dtype()),
            "end_line": pd.array([4, 10], dtype=pd.Int64Dtype()),
        })
        with pytest.raises(pandera.errors.SchemaError):
            ScopeSchema.validate(df)


# ── ScopePartSchema ──


class TestScopePartSchema:
    def test_valid_three_parts(self):
        df = pd.DataFrame({
            "scope_id": [0, 0, 0],
            "part": ["environment", "declarations", "execution"],
            "start_line": [2, 4, 7],
            "end_line": [3, 6, 12],
        })
        ScopePartSchema.validate(df)

    def test_valid_single_part(self):
        df = pd.DataFrame({
            "scope_id": [0],
            "part": ["execution"],
            "start_line": [2],
            "end_line": [5],
        })
        ScopePartSchema.validate(df)

    def test_rejects_invalid_part(self):
        df = pd.DataFrame({
            "scope_id": [0],
            "part": ["specification"],  # invalid — not in v0.1.8
            "start_line": [2],
            "end_line": [5],
        })
        with pytest.raises(pandera.errors.SchemaError):
            ScopePartSchema.validate(df)

    def test_rejects_subprogram_part(self):
        df = pd.DataFrame({
            "scope_id": [0],
            "part": ["subprogram"],  # removed in v0.1.7
            "start_line": [10],
            "end_line": [20],
        })
        with pytest.raises(pandera.errors.SchemaError):
            ScopePartSchema.validate(df)

    def test_rejects_start_after_end(self):
        df = pd.DataFrame({
            "scope_id": [0],
            "part": ["execution"],
            "start_line": [10],
            "end_line": [5],
        })
        with pytest.raises(pandera.errors.SchemaError):
            ScopePartSchema.validate(df)


# ── ControlRegionSchema ──


class TestControlRegionSchema:
    def test_valid_all_12_kinds(self):
        df = pd.DataFrame({
            "region_id": list(range(len(REGION_KINDS))),
            "parent_region_id": pd.array([pd.NA] * len(REGION_KINDS), dtype=pd.Int64Dtype()),
            "scope_id": [0] * len(REGION_KINDS),
            "kind": REGION_KINDS,
            "filename": ["test.f90"] * len(REGION_KINDS),
            "start_line": list(range(1, len(REGION_KINDS) + 1)),
            "end_line": list(range(2, len(REGION_KINDS) + 2)),
        })
        ControlRegionSchema.validate(df)

    def test_rejects_block_kind(self):
        df = pd.DataFrame({
            "region_id": [0],
            "parent_region_id": pd.array([pd.NA], dtype=pd.Int64Dtype()),
            "scope_id": [0],
            "kind": ["block"],  # BLOCK is not a control region in v0.1.8
            "filename": ["test.f90"],
            "start_line": [5],
            "end_line": [10],
        })
        with pytest.raises(pandera.errors.SchemaError):
            ControlRegionSchema.validate(df)

    def test_nested_regions(self):
        df = pd.DataFrame({
            "region_id": [0, 1],
            "parent_region_id": pd.array([pd.NA, 0], dtype=pd.Int64Dtype()),
            "scope_id": [0, 0],
            "kind": ["do", "if"],
            "filename": ["test.f90", "test.f90"],
            "start_line": [3, 5],
            "end_line": [12, 8],
        })
        ControlRegionSchema.validate(df)

    def test_rejects_duplicate_region_id(self):
        df = pd.DataFrame({
            "region_id": [0, 0],
            "parent_region_id": pd.array([pd.NA, pd.NA], dtype=pd.Int64Dtype()),
            "scope_id": [0, 0],
            "kind": ["do", "if"],
            "filename": ["test.f90", "test.f90"],
            "start_line": [3, 10],
            "end_line": [8, 15],
        })
        with pytest.raises(pandera.errors.SchemaError):
            ControlRegionSchema.validate(df)


# ── SemanticBasicBlockSchema ──


class TestSemanticBasicBlockSchema:
    def test_valid_statements(self):
        df = pd.DataFrame({
            "sbb_id": [0],
            "scope_id": [0],
            "region_id": pd.array([pd.NA], dtype=pd.Int64Dtype()),
            "kind": ["statements"],
            "filename": ["test.f90"],
            "start_line": [3],
            "end_line": [5],
        })
        SemanticBasicBlockSchema.validate(df)

    def test_valid_block_scope(self):
        df = pd.DataFrame({
            "sbb_id": [0],
            "scope_id": [0],
            "region_id": pd.array([pd.NA], dtype=pd.Int64Dtype()),
            "kind": ["block_scope"],
            "filename": ["test.f90"],
            "start_line": [5],
            "end_line": [10],
        })
        SemanticBasicBlockSchema.validate(df)

    def test_valid_mixed_kinds(self):
        df = pd.DataFrame({
            "sbb_id": [0, 1, 2],
            "scope_id": [0, 0, 0],
            "region_id": pd.array([pd.NA, pd.NA, pd.NA], dtype=pd.Int64Dtype()),
            "kind": ["statements", "block_scope", "statements"],
            "filename": ["test.f90"] * 3,
            "start_line": [2, 4, 8],
            "end_line": [3, 7, 9],
        })
        SemanticBasicBlockSchema.validate(df)

    def test_rejects_invalid_kind(self):
        df = pd.DataFrame({
            "sbb_id": [0],
            "scope_id": [0],
            "region_id": pd.array([pd.NA], dtype=pd.Int64Dtype()),
            "kind": ["control"],  # invalid
            "filename": ["test.f90"],
            "start_line": [3],
            "end_line": [5],
        })
        with pytest.raises(pandera.errors.SchemaError):
            SemanticBasicBlockSchema.validate(df)

    def test_region_id_nullable(self):
        df = pd.DataFrame({
            "sbb_id": [0, 1],
            "scope_id": [0, 0],
            "region_id": pd.array([pd.NA, 0], dtype=pd.Int64Dtype()),
            "kind": ["statements", "statements"],
            "filename": ["test.f90", "test.f90"],
            "start_line": [2, 5],
            "end_line": [3, 8],
        })
        SemanticBasicBlockSchema.validate(df)
