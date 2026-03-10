"""Pipeline composition: process_file chains all 5 processors."""

from pathlib import Path

import pandas as pd

from facto.parse_source import parse_source
from facto.parse_scopes import parse_scopes
from facto.segment_parts import segment_parts
from facto.parse_regions import parse_regions
from facto.partition_blocks import partition_blocks


def process_file(filepath: str) -> dict[str, pd.DataFrame]:
    """Extract all structural facts from a single Fortran source file.

    Returns dict with keys: source_line, scope, scope_part,
    control_region, semantic_basic_block.
    """
    text = Path(filepath).read_text()

    source_line, file_res = parse_source(text, filepath)
    scope, scope_res = parse_scopes(file_res)
    scope_part, part_res = segment_parts(scope_res)

    exec_res = part_res[part_res["part"] == "execution"]
    control_region, region_res = parse_regions(exec_res)
    sbb, _ = partition_blocks(region_res)

    return {
        "source_line": source_line,
        "scope": scope,
        "scope_part": scope_part,
        "control_region": control_region,
        "semantic_basic_block": sbb,
    }
