# v0.1.6: two-table contract + explicit composition

## Delta from v0.1.5

v0.1.5 defined the parser combinator pattern with signature:

```python
Extractor = DataFrame → (dict[str, DataFrame], DataFrame)
```

Two changes:

1. **Drop the dict.** Each step returns `(DataFrame, DataFrame)` — one fact table, one residual. Compound tables (use_entity, import_entity) are separate leaf steps.

2. **Drop the orchestration framework.** The pipeline is a compiler (source → structured tables), not a data pipeline (stream → warehouse). Compilers compose passes explicitly. The DAG is a function body, not a framework graph.

## Naming convention

Function names use **domain verbs**, not ETL vocabulary (`extract`, `transform`, `load`, `derive`).

| Action | Verb | Example |
|---|---|---|
| Break source into structural units | `parse` | `parse_source`, `parse_use` |
| Divide a scope into ordered sections | `segment` | `segment_parts` |
| Split execution part into basic blocks | `partition` | `partition_blocks` |
| Follow control flow to compute edges | `trace` | `trace_edges` |

## 1. The two-table contract

Each pipeline step returns exactly two DataFrames:

```python
Step = DataFrame → (DataFrame, DataFrame)
#                   fact        residual
```

- **Fact**: pandera-validated, matches one database table schema.
- **Residual**: ad-hoc, carries `(text, ast_kind)` for the next step.

No dict. No string keys. Positionally clear: first is structure recognized, second is material remaining.

### Compound tables

Two cases produce child tables: USE → use_entity, IMPORT → import_entity.

These are separate leaf steps: `DataFrame → DataFrame` (parent fact → child fact). They re-parse the relevant source lines via `parse_as`. Cheap — USE/IMPORT statements are single lines.

## 2. The pipeline is a function

The entire DAG is one function body. No framework, no decorators, no graph definition language:

```python
def process_file(filepath: str) -> dict[str, pd.DataFrame]:
    """Full pipeline: source file → coordinate system tables."""

    source_line, file_res       = parse_source(filepath)
    scope, scope_res            = parse_scopes(file_res)
    scope_part, part_res        = segment_parts(scope_res)

    # spec branch
    spec_res = part_res[part_res["part"] == "specification"]
    use_stmt, post_use          = parse_use(spec_res)
    import_stmt, post_import    = parse_import(post_use)
    implicit_rule, post_impl    = parse_implicit(post_import)
    declaration, spec_terminal  = parse_declarations(post_impl)

    # exec branch
    exec_res = part_res[part_res["part"] == "execution"]
    control_region, region_res  = parse_regions(exec_res)
    sbb, sbb_res                = partition_blocks(region_res)
    sbb_edge                    = trace_edges(sbb_res, control_region)

    # entity refinements
    use_entity    = parse_use_entities(use_stmt, source_line)
    import_entity = parse_import_entities(import_stmt, source_line)

    return {
        "source_line": source_line,
        "scope": scope,
        "scope_part": scope_part,
        "use_stmt": use_stmt,
        "use_entity": use_entity,
        "import_stmt": import_stmt,
        "import_entity": import_entity,
        "implicit_rule": implicit_rule,
        "declaration_construct": declaration,
        "control_region": control_region,
        "semantic_basic_block": sbb,
        "sbb_edge": sbb_edge,
    }
```

~25 lines. The dependency graph is the code. Adding a step means adding a line. The spec/exec fork is a filter. The join point is the return dict.

### Why no framework

The pipeline is:
- **Fixed** — 12 steps, known at design time, won't change at runtime
- **Bounded** — processes a finite set of source files, then stops
- **Stateless** — no scheduling, no retries, no materialization tracking
- **Fast** — each file is a few thousand lines of Fortran; parsing is sub-second

This is a compiler pass chain, not a data pipeline. Dagster, Prefect, and Airflow are designed for the opposite case: dynamic graphs, streaming inputs, long-running jobs, cross-run caching. Their asset/task indexing systems add indirection that makes the graph harder to read and maintain for a fixed topology.

If the graph were dynamic (steps added/removed at runtime) or the execution were long-running (minutes per file, need checkpointing), a framework would pay for itself. Neither applies here.

## 3. File-level parallelism

Each file is independent (Condition: file locality). Parallelism is `map`:

```python
from concurrent.futures import ProcessPoolExecutor

def process_codebase(filepaths: list[str]) -> dict[str, pd.DataFrame]:
    with ProcessPoolExecutor() as pool:
        per_file = list(pool.map(process_file, filepaths))

    # concat across files, assign global IDs
    tables = {}
    for table_name in per_file[0]:
        combined = pd.concat([r[table_name] for r in per_file], ignore_index=True)
        tables[table_name] = combined

    assign_global_ids(tables)
    return tables
```

No partition definitions, no asset materialization. Just `map` + `concat`.

### Global ID assignment

Within each file, IDs start from 0. After concat, `assign_global_ids` offsets them to be globally unique and patches foreign key references. This is a single post-processing pass over the concatenated tables.

## 4. Module catalog

### Pipeline steps: (fact, residual)

| # | Function | Input | Fact output | Residual output |
|---|---|---|---|---|
| 0 | `parse_source` | file path | `source_line` | `file_residual` |
| 1 | `parse_scopes` | `file_residual` | `scope` | `scope_residual` |
| 2 | `segment_parts` | `scope_residual` | `scope_part` | `part_residual` |
| 3 | `parse_use` | `part_residual` (spec rows) | `use_stmt` | `post_use_residual` |
| 4 | `parse_import` | `post_use_residual` | `import_stmt` | `post_import_residual` |
| 5 | `parse_implicit` | `post_import_residual` | `implicit_rule` | `post_implicit_residual` |
| 6 | `parse_declarations` | `post_implicit_residual` | `declaration_construct` | `spec_terminal` |
| 7 | `parse_regions` | `part_residual` (exec rows) | `control_region` | `region_residual` |
| 8 | `partition_blocks` | `region_residual` | `sbb` | `sbb_residual` |

### Leaf steps: fact only

| # | Function | Input(s) | Output |
|---|---|---|---|
| 9 | `trace_edges` | `sbb_residual`, `control_region` | `sbb_edge` |
| 10 | `parse_use_entities` | `use_stmt`, `source_line` | `use_entity` |
| 11 | `parse_import_entities` | `import_stmt`, `source_line` | `import_entity` |

### Terminal residuals

| Residual | Content | Consumer |
|---|---|---|
| `spec_terminal` | per-construct `(text, ast_kind)` | Computed table analysis (future) |
| `sbb_residual` | per-SBB `(text, ast_kind)` | `trace_edges` + computed table analysis (future) |

## 5. What stays from v0.1.5

- **Two-table contract**: each step → (fact, residual)
- **Residual structure**: key columns + `text` + `ast_kind` (strings, no tree objects)
- **Narrowing**: segmentation (1 row → N rows) and consumption (remove recognized lines)
- **Terminal residuals**: bridge to computed table analysis via `parse_as(text, ast_kind)`
- **Pandera validation**: at step output boundaries
- **fcst integration**: `str_to_cst` for initial parse, `parse_as` for on-demand re-parsing
- **File locality**: all fact tables depend only on single-file information

## 6. Dependencies

```toml
[project]
dependencies = [
    "fcst",
    "pandas>=2.0",
    "pandera>=0.20",
]
```

No orchestration framework. The pipeline is 25 lines of function composition.
