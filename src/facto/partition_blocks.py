"""Processor 4: partition_blocks — partition residual segments into SBBs."""

import pandas as pd


def partition_blocks(region_residual: pd.DataFrame) -> tuple[pd.DataFrame, None]:
    """Partition each residual segment into semantic basic blocks.

    Convention B: every construct boundary starts a new SBB.
    BLOCK constructs become kind='block_scope'; statement sequences
    become kind='statements'.

    Args:
        region_residual: one row per segment from parse_regions

    Returns:
        (sbb_df, None) — terminal processor, no residual
    """
    raise NotImplementedError("partition_blocks not yet implemented")
