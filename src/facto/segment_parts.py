"""Processor 2: segment_parts — segment scope bodies into env/decl/exec."""

import pandas as pd


def segment_parts(scope_residual: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Segment each scope body into environment / declarations / execution parts.

    Args:
        scope_residual: one row per scope with body text + ast_kind

    Returns:
        (scope_part_df, part_residual_df)
    """
    raise NotImplementedError("segment_parts not yet implemented")
