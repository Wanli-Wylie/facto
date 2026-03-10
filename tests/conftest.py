"""Shared fixtures and helpers for facto tests."""

import pandas as pd
import pytest


def make_file_residual(text: str, filename: str = "test.f90", ast_kind: str = "Program") -> pd.DataFrame:
    """Create a file_residual DataFrame (output of parse_source)."""
    return pd.DataFrame([{"filename": filename, "text": text, "ast_kind": ast_kind}])


def make_scope_residual(
    scope_id: int,
    text: str,
    filename: str = "test.f90",
    start_line: int = 2,
    end_line: int = 10,
    ast_kind: str = "Subroutine_Subprogram",
) -> pd.DataFrame:
    """Create a scope_residual DataFrame (output of parse_scopes)."""
    return pd.DataFrame([{
        "scope_id": scope_id,
        "filename": filename,
        "start_line": start_line,
        "end_line": end_line,
        "text": text,
        "ast_kind": ast_kind,
    }])


def make_part_residual(
    scope_id: int,
    part: str,
    text: str,
    filename: str = "test.f90",
    start_line: int = 2,
    end_line: int = 10,
    ast_kind: str = "Execution_Part",
) -> pd.DataFrame:
    """Create a part_residual DataFrame (output of segment_parts)."""
    return pd.DataFrame([{
        "scope_id": scope_id,
        "part": part,
        "filename": filename,
        "start_line": start_line,
        "end_line": end_line,
        "text": text,
        "ast_kind": ast_kind,
    }])


def make_region_residual(
    scope_id: int,
    region_id,
    text: str,
    filename: str = "test.f90",
    start_line: int = 1,
    end_line: int = 1,
    ast_kind: str = "Execution_Part",
) -> pd.DataFrame:
    """Create a region_residual DataFrame (output of parse_regions)."""
    return pd.DataFrame([{
        "scope_id": scope_id,
        "region_id": region_id,
        "filename": filename,
        "start_line": start_line,
        "end_line": end_line,
        "text": text,
        "ast_kind": ast_kind,
    }])
