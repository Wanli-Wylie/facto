"""Pandera schemas for coordinate system fact tables.

Each schema matches one database table from schema.sql (v0.1.8).
Schemas validate DataFrame outputs at processor boundaries.
"""

from __future__ import annotations

import pandas as pd
import pandera.pandas as pa
from pandera.typing import Series


# -- Layer 0: Source text --


class SourceLineSchema(pa.DataFrameModel):
    filename: Series[str]
    line_no: Series[int] = pa.Field(ge=1)
    line_text: Series[str]

    class Config:
        strict = True
        coerce = True


# -- Layer 1: Structural scopes --


class ScopeSchema(pa.DataFrameModel):
    scope_id: Series[int] = pa.Field(ge=0, unique=True)
    parent_scope_id: Series[pd.Int64Dtype] = pa.Field(nullable=True)
    kind: Series[str] = pa.Field(
        isin=[
            "global",
            "program",
            "module",
            "submodule",
            "block_data",
            "function",
            "subroutine",
            "separate_mp",
        ]
    )
    name: Series[str] = pa.Field(nullable=True)
    filename: Series[str] = pa.Field(nullable=True)
    start_line: Series[pd.Int64Dtype] = pa.Field(nullable=True, ge=1)
    end_line: Series[pd.Int64Dtype] = pa.Field(nullable=True, ge=1)

    @pa.dataframe_check
    def start_before_end(cls, df: pd.DataFrame) -> Series[bool]:
        mask = df["start_line"].notna() & df["end_line"].notna()
        return ~mask | (df["start_line"] <= df["end_line"])

    class Config:
        strict = True
        coerce = True


# -- Layer 2: Scope parts --


class ScopePartSchema(pa.DataFrameModel):
    scope_id: Series[int] = pa.Field(ge=0)
    part: Series[str] = pa.Field(
        isin=["environment", "declarations", "execution"]
    )
    start_line: Series[int] = pa.Field(ge=1)
    end_line: Series[int] = pa.Field(ge=1)

    @pa.dataframe_check
    def start_before_end(cls, df: pd.DataFrame) -> Series[bool]:
        return df["start_line"] <= df["end_line"]

    class Config:
        strict = True
        coerce = True


# -- Layer 3: Control regions --


REGION_KINDS = [
    "if",
    "select_case",
    "select_type",
    "select_rank",
    "do",
    "do_while",
    "do_concurrent",
    "forall",
    "where",
    "associate",
    "critical",
    "change_team",
]


class ControlRegionSchema(pa.DataFrameModel):
    region_id: Series[int] = pa.Field(ge=0, unique=True)
    parent_region_id: Series[pd.Int64Dtype] = pa.Field(nullable=True)
    scope_id: Series[int] = pa.Field(ge=0)
    kind: Series[str] = pa.Field(isin=REGION_KINDS)
    filename: Series[str]
    start_line: Series[int] = pa.Field(ge=1)
    end_line: Series[int] = pa.Field(ge=1)

    @pa.dataframe_check
    def start_before_end(cls, df: pd.DataFrame) -> Series[bool]:
        return df["start_line"] <= df["end_line"]

    class Config:
        strict = True
        coerce = True


# -- Layer 4: Semantic basic blocks --


SBB_KINDS = ["statements", "block_scope"]


class SemanticBasicBlockSchema(pa.DataFrameModel):
    sbb_id: Series[int] = pa.Field(ge=0, unique=True)
    scope_id: Series[int] = pa.Field(ge=0)
    region_id: Series[pd.Int64Dtype] = pa.Field(nullable=True)
    kind: Series[str] = pa.Field(isin=SBB_KINDS)
    filename: Series[str]
    start_line: Series[int] = pa.Field(ge=1)
    end_line: Series[int] = pa.Field(ge=1)

    @pa.dataframe_check
    def start_before_end(cls, df: pd.DataFrame) -> Series[bool]:
        return df["start_line"] <= df["end_line"]

    class Config:
        strict = True
        coerce = True
