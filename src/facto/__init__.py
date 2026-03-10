"""facto — structural fact extraction from Fortran source code.

5 processors decompose Fortran source into a coordinate system
of 5 fact tables: source_line, scope, scope_part, control_region,
semantic_basic_block.

Each processor is a pure function: residual in, (fact_df, residual_df) out.
"""
