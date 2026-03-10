"""Processor 0: parse_source — split raw text into numbered lines."""

import pandas as pd


def parse_source(text: str, filename: str) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Split raw file text into source_line rows and file_residual.

    Args:
        text: raw source file content
        filename: file path

    Returns:
        (source_line_df, file_residual_df)
    """
    raise NotImplementedError("parse_source not yet implemented")
