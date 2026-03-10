"""Processor 3: parse_regions — identify control constructs in execution parts."""

import pandas as pd


def parse_regions(exec_residual: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Identify control constructs and build nesting tree.

    BLOCK constructs are recognized as boundaries but NOT emitted as
    control regions. They appear in the residual with ast_kind='Block_Construct'.

    Args:
        exec_residual: rows from part_residual where part == 'execution'

    Returns:
        (control_region_df, region_residual_df)
    """
    raise NotImplementedError("parse_regions not yet implemented")
