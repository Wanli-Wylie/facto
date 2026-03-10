# v0.1.7: structural segmentation only — defer content to computation

## Delta from v0.1.6

v0.1.6 had the spec branch produce 6 fact tables: use_stmt, use_entity, import_stmt, import_entity, implicit_rule, declaration_construct. v0.1.7 (first draft) collapsed the 4 sequential steps to 2 parallel steps (parse_environment + parse_declarations).

But even that over-extracts. USE/IMPORT/IMPLICIT and declaration constructs are all **trivially recoverable** from their source lines. Storing their parsed content as fact tables is premature materialization — it crosses the structural index boundary into semantic content.

The coordinate system's job is to answer WHERE and WHAT KIND. For the spec part, that means: where is the environment region, and where is the declaration region. The content (which modules, which entities, which types) is computed on demand.

## 1. The principle

Fact tables store **structural coordinates** — the partition of source text into regions with known grammar productions. Anything recoverable from `(source_text, line_range, production)` is a computed table, not a fact table.

For the spec part:
- Environment region (USE + IMPORT + IMPLICIT lines): identified by line range
- Declaration region (everything else): identified by line range
- Content of either region: `parse_as(text, kind)` on demand

The spec content tables (use_stmt, import_stmt, implicit_rule, declaration_construct, use_entity, import_entity) all become **computed tables**. They are not extracted by the pipeline — they are derived on the fly from source_line + scope_part coordinates.

## 2. Revised scope_part

The scope_part table gains finer segmentation. The `'specification'` part splits into `'environment'` and `'declarations'`:

```
scope_part: (scope_id, part, start_line, end_line)

part ∈ { environment, declarations, execution, subprogram }
```

| part | Content | Grammar |
|---|---|---|
| `environment` | USE, IMPORT, IMPLICIT statements | 3 keywords, strict order |
| `declarations` | The 18 declaration construct kinds | Everything else in the spec part |
| `execution` | Executable constructs and statements | Action statements + control constructs |
| `subprogram` | CONTAINS + internal procedures | Internal functions/subroutines |

The boundary between environment and declarations is the first non-USE/IMPORT/IMPLICIT statement in the spec part. `segment_parts` identifies this boundary by keyword scan — no full parse needed.

If a scope has no environment statements (no USE, no IMPORT, no IMPLICIT), the `environment` row is omitted. If all spec-part lines are environment statements, the `declarations` row is omitted.

## 3. Revised pipeline

```python
def process_file(filepath: str) -> dict[str, pd.DataFrame]:
    source_line, file_res      = parse_source(filepath)
    scope, scope_res           = parse_scopes(file_res)
    scope_part, part_res       = segment_parts(scope_res)

    # exec branch
    exec_res = part_res[part_res["part"] == "execution"]
    control_region, region_res = parse_regions(exec_res)
    sbb, sbb_res               = partition_blocks(region_res)
    sbb_edge                   = trace_edges(sbb_res, control_region)

    return {
        "source_line": source_line,
        "scope": scope,
        "scope_part": scope_part,
        "control_region": control_region,
        "semantic_basic_block": sbb,
        "sbb_edge": sbb_edge,
    }
```

**6 fact tables. 6 pipeline steps. No spec content extraction.**

The spec branch is entirely handled by `segment_parts` — it identifies the environment/declarations boundary and records the line ranges. No parse_environment, no parse_declarations, no entity refinement steps.

## 4. Revised pipeline graph

```
parse_source
  ├── source_line  (fact)
  └── file_residual
        │
        ▼
      parse_scopes
        ├── scope  (fact)
        └── scope_residual
              │
              ▼
            segment_parts
              ├── scope_part  (fact: environment, declarations, execution, subprogram)
              └── part_residual
                    │
                    │ filter: execution
                    ▼
                  parse_regions
                    ├── control_region  (fact)
                    └── region_residual
                          │
                          ▼
                        partition_blocks
                          ├── sbb  (fact)
                          └── sbb_residual
                                │
                                ▼
                              trace_edges
                                └── sbb_edge  (fact)
```

The spec branch has no dedicated pipeline steps. It's fully resolved by segmentation.

## 5. On-the-fly computation

Spec content is recovered from coordinates + source text whenever needed:

```python
def get_use_statements(scope_id: int, scope_part: pd.DataFrame, source_line: pd.DataFrame):
    """Compute USE statements on demand from structural coordinates."""
    env = scope_part[(scope_part["scope_id"] == scope_id) & (scope_part["part"] == "environment")]
    if env.empty:
        return []
    lines = source_line[
        (source_line["line_no"] >= env.iloc[0]["start_line"]) &
        (source_line["line_no"] <= env.iloc[0]["end_line"])
    ]
    text = "\n".join(lines["text"])
    # parse and filter for USE statements
    ...
```

The computed tables (use_stmt, import_stmt, implicit_rule, declaration_construct, use_entity, import_entity) have the same schemas as before — they're just materialized on demand rather than stored as pipeline outputs.

## 6. Why this works

The three conditions from v0.1.4 still hold:

1. **Complete partition**: every spec-part line belongs to either `environment` or `declarations`. Together with `execution` and `subprogram`, every line in the scope is covered.

2. **Kind-determined grammar**: `environment` → USE/IMPORT/IMPLICIT productions. `declarations` → declaration construct productions. The part value determines which grammar rules apply.

3. **Layered dependency**: the environment must be processed before declarations (for name resolution). This ordering is a property of the **consumer** (semantic analysis), not the **pipeline** (structural indexing). The pipeline just records where things are.

## 7. What moved where

| v0.1.6 | v0.1.7 | Rationale |
|---|---|---|
| `parse_environment` (pipeline step) | dropped | Segmentation handles it; content is computed |
| `parse_declarations` (pipeline step) | dropped | Segmentation handles it; content is computed |
| `parse_use_entities` (leaf step) | dropped | Computed from use_stmt, which is itself computed |
| `parse_import_entities` (leaf step) | dropped | Same |
| `use_stmt` (fact table) | computed table | Recoverable from environment line range |
| `import_stmt` (fact table) | computed table | Recoverable from environment line range |
| `implicit_rule` (fact table) | computed table | Recoverable from environment line range |
| `declaration_construct` (fact table) | computed table | Recoverable from declarations line range |
| `use_entity` (fact table) | computed table | Derived from computed use_stmt |
| `import_entity` (fact table) | computed table | Derived from computed import_stmt |
| `scope_part.part = 'specification'` | split into `'environment'` + `'declarations'` | Finer structural index |

## 8. Module catalog

| # | Function | Input | Output |
|---|---|---|---|
| 0 | `parse_source` | file path | `source_line` + `file_residual` |
| 1 | `parse_scopes` | `file_residual` | `scope` + `scope_residual` |
| 2 | `segment_parts` | `scope_residual` | `scope_part` + `part_residual` |
| 3 | `parse_regions` | `part_residual` (exec) | `control_region` + `region_residual` |
| 4 | `partition_blocks` | `region_residual` | `sbb` + `sbb_residual` |
| 5 | `trace_edges` | `sbb_residual`, `control_region` | `sbb_edge` |

**6 steps. 6 fact tables. No leaf steps.**

## 9. Asymmetry explained

The exec branch still has 3 dedicated steps (parse_regions → partition_blocks → trace_edges) because control region nesting, basic block partitioning, and CFG edge computation are **structural** — they define the coordinate system for execution, not semantic content.

The spec branch has 0 dedicated steps because its structural contribution is just a line-range boundary between environment and declarations. The content within those ranges is uniform enough to parse on demand.

This asymmetry is real, not a design flaw: execution structure is a tree (nested constructs, non-trivial CFG), while specification structure is a flat sequence (ordered statement groups).
