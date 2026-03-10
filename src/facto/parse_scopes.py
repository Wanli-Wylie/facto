"""Processor 1: parse_scopes — identify program units and subprograms."""

import pandas as pd


def parse_scopes(file_residual: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Identify program units and subprograms from file residual.

    Args:
        file_residual: one row per file with text + ast_kind

    Returns:
        (scope_df, scope_residual_df)
    """
    raise NotImplementedError("parse_scopes not yet implemented")
