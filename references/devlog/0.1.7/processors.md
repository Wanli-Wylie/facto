# v0.1.7: processor specifications

4 processors + 1 recursive orchestrator. Each processor is a pure function: text in, two DataFrames out.

## Contract

```python
Processor = (residual_df) → (fact_df, residual_df)
```

- **fact_df**: matches a schema table. Columns are structural coordinates only.
- **residual_df**: carries `text` + context columns for the next processor.

The residual is the threading mechanism: each processor receives text (via residual rows), recognizes structure, emits fact rows, and passes narrowed text segments downstream.

## Composition

```python
def process_file(filepath: str) -> dict[str, pd.DataFrame]:
    text = Path(filepath).read_text()

    source_line, file_res = parse_source(text, filepath)
    scope, scope_res      = parse_scopes(file_res)

    # recursive: each scoping unit → segment → parse execution → discover blocks → recurse
    scope_part, block_scope, control_region, sbb = process_scoping_units(
        scope_res, unit_source='scope'
    )

    return {
        "source_line": source_line,
        "scope": scope,
        "block_scope": block_scope,
        "scope_part": scope_part,
        "control_region": control_region,
        "semantic_basic_block": sbb,
    }
```

### Recursive orchestrator

```python
def process_scoping_units(
    unit_residual: pd.DataFrame,
    unit_source: str,
) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    """
    For each scoping unit (scope or block_scope):
      1. segment_parts → scope_part rows + part residuals
      2. filter execution parts → parse_execution → regions + SBBs + block_scope discoveries
      3. For each discovered block_scope: recurse (segment_parts → parse_execution → ...)

    Returns accumulated (scope_part, block_scope, control_region, sbb) across all units.
    """
    scope_part, part_res = segment_parts(unit_residual, unit_source)

    exec_res = part_res[part_res["part"] == "execution"]
    if exec_res.empty:
        empty = pd.DataFrame()
        return scope_part, empty, empty, empty

    control_region, sbb, block_res = parse_execution(exec_res, unit_source)

    # base case: no BLOCK constructs found
    if block_res.empty:
        return scope_part, block_res, control_region, sbb

    # recursive case: each block_scope is a new scoping unit
    inner_sp, inner_bs, inner_cr, inner_sbb = process_scoping_units(
        block_res, unit_source='block'
    )

    return (
        pd.concat([scope_part, inner_sp]),
        pd.concat([block_res, inner_bs]),      # block_scope facts accumulate
        pd.concat([control_region, inner_cr]),
        pd.concat([sbb, inner_sbb]),
    )
```

This is NOT a processor (it doesn't follow the two-table contract). It's the composition logic that threads processors together with recursion for nested BLOCK scopes.

---

## 0. parse_source

```python
def parse_source(text: str, filename: str) -> tuple[pd.DataFrame, pd.DataFrame]:
```

Splits raw file text into numbered lines. Parses via `fcst.str_to_cst()` to identify the root AST kind.

### Input

- `text`: raw source file content (string)
- `filename`: file path (string)

### Fact: source_line

| column | type | description |
|--------|------|-------------|
| filename | str | file path |
| line_no | int | 1-based line number |
| line_text | str | raw text of this line |

One row per physical line.

### Residual: file_residual

| column | type | description |
|--------|------|-------------|
| filename | str | file path |
| text | str | full file text |
| ast_kind | str | fparser root class name (e.g. `'Program'`) |

One row. The entire file text, tagged with its root grammar production.

---

## 1. parse_scopes

```python
def parse_scopes(file_residual: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
```

Identifies program units and subprograms within the file. Walks the CST (obtained via `fcst.parse_as(text, ast_kind)`) to find scope boundaries.

### Input: file_residual

One row per file (from parse_source).

### Fact: scope

| column | type | description |
|--------|------|-------------|
| scope_id | int | locally unique, 0-based |
| parent_scope_id | int? | FK to containing scope; NULL for top-level |
| kind | str | one of 8 values: global, program, module, submodule, block_data, function, subroutine, separate_mp |
| name | str? | scope name from header; NULL if unnamed |
| filename | str | file path |
| start_line | int | first line (scope header) |
| end_line | int | last line (END statement) |

One row per scope found.

### Residual: scope_residual

| column | type | description |
|--------|------|-------------|
| scope_id | int | FK to scope fact |
| filename | str | file path |
| start_line | int | first line of scope body |
| end_line | int | last line of scope body |
| text | str | source text of the scope body (between header and END, exclusive) |
| ast_kind | str | fparser class name (e.g. `'Module'`, `'Subroutine_Subprogram'`) |

One row per scope. Text excludes the scope header and END statement — only the body.

### Logic

1. Parse `file_residual.text` via `fcst.parse_as(text, ast_kind)`
2. Walk CST children to find program unit nodes
3. For each program unit: extract kind, name, line range → scope row
4. Nesting: if a scope contains CONTAINS + internal procedures, those become child scopes with `parent_scope_id` pointing to the container
5. Residual: for each scope, slice the body text (excluding header/END lines)

---

## 2. segment_parts

```python
def segment_parts(
    unit_residual: pd.DataFrame,
    unit_source: str,
) -> tuple[pd.DataFrame, pd.DataFrame]:
```

Segments each scoping unit body into environment / declarations / execution parts by keyword scan. Works identically for both scope and block_scope units — the `unit_source` parameter tags outputs so they reference the correct physical table.

### Input: unit_residual

One row per scoping unit body. For `unit_source='scope'`, this is the scope_residual from parse_scopes. For `unit_source='block'`, this is the block_residual from parse_execution.

| column | type | description |
|--------|------|-------------|
| unit_id | int | FK to scope or block_scope |
| filename | str | file path |
| start_line | int | first line of unit body |
| end_line | int | last line of unit body |
| text | str | source text of the unit body |
| ast_kind | str | fparser class name |

### Fact: scope_part

| column | type | description |
|--------|------|-------------|
| unit_source | str | `'scope'` or `'block'` |
| unit_id | int | FK to scope or block_scope |
| part | str | `'environment'`, `'declarations'`, or `'execution'` |
| start_line | int | first line of this part |
| end_line | int | last line of this part |

Up to 3 rows per scoping unit. Parts absent in the source are omitted.

### Residual: part_residual

| column | type | description |
|--------|------|-------------|
| unit_source | str | `'scope'` or `'block'` |
| unit_id | int | FK to scope or block_scope |
| part | str | which part |
| filename | str | file path |
| start_line | int | first line |
| end_line | int | last line |
| text | str | source text of this part |
| ast_kind | str | `'Specification_Part'` or `'Execution_Part'` |

One row per scope part.

### Logic

1. For each unit body, scan lines by keyword to find boundaries:
   - **Environment**: contiguous group of USE / IMPORT / IMPLICIT lines at the top
   - **Declarations**: remaining specification lines (after environment, before executable statements)
   - **Execution**: executable statements and control constructs
2. Boundary identification:
   - Environment ends at the first line that is not USE / IMPORT / IMPLICIT
   - Declarations end at the first executable statement (or CONTAINS for scopes)
   - CONTAINS and everything after → child scopes (already in scope table, no part row needed)
   - BLOCK scopes cannot have CONTAINS — declarations end at the first executable statement
3. Omit parts with zero lines

### Which scope kinds have which parts

| kind | environment | declarations | execution |
|------|:-----------:|:------------:|:---------:|
| module, submodule, block_data | yes | yes | — |
| program, function, subroutine, separate_mp | yes | yes | yes |
| block (block_scope) | yes | yes | yes |

---

## 3. parse_execution

```python
def parse_execution(
    exec_residual: pd.DataFrame,
    unit_source: str,
) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
```

Decomposes execution parts into control regions (internal nodes) and semantic basic blocks (leaves) in a single pass. Also discovers BLOCK constructs and emits them as block_scope facts.

This is the only processor with a **three-table** output: (control_region, sbb, block_scope). The extra table is necessary because BLOCK discovery is a side effect of execution scanning — BLOCK constructs are syntactically control constructs but semantically scoping units. They're extracted into their own physical table rather than being mixed into control_region.

### Input: exec_residual

Rows from part_residual where `part == 'execution'`.

| column | type | description |
|--------|------|-------------|
| unit_source | str | `'scope'` or `'block'` |
| unit_id | int | FK to scope or block_scope |
| filename | str | file path |
| start_line | int | first line |
| end_line | int | last line |
| text | str | source text of the execution part |
| ast_kind | str | `'Execution_Part'` |

### Fact 1: control_region

| column | type | description |
|--------|------|-------------|
| region_id | int | locally unique, 0-based |
| parent_region_id | int? | FK to enclosing region; NULL for top-level |
| unit_source | str | `'scope'` or `'block'` — which scoping unit |
| unit_id | int | FK to scope or block_scope |
| kind | str | one of 12 values (see below) |
| filename | str | file path |
| start_line | int | construct header line |
| end_line | int | END construct line |

12 control region kinds:
```
if, select_case, select_type, select_rank,
do, do_while, do_concurrent, forall,
where, associate, critical, change_team
```

BLOCK is NOT in this list — it's emitted to block_scope instead.

### Fact 2: semantic_basic_block

| column | type | description |
|--------|------|-------------|
| sbb_id | int | locally unique, 0-based |
| unit_source | str | `'scope'` or `'block'` |
| unit_id | int | FK to scope or block_scope |
| region_id | int? | FK to innermost enclosing region; NULL for top-level |
| filename | str | file path |
| start_line | int | first line |
| end_line | int | last line |

Convention B: every construct boundary (including BLOCK scope boundaries) starts a new SBB. SBBs tile the gaps between nested constructs and BLOCK scopes.

### Fact 3: block_scope

| column | type | description |
|--------|------|-------------|
| block_id | int | locally unique, 0-based |
| scope_id | int | FK to the program-unit scope (always traces back through unit_source/unit_id to the enclosing scope) |
| region_id | int? | FK to innermost enclosing control region; NULL if at top level of exec part |
| filename | str | file path |
| start_line | int | BLOCK statement line |
| end_line | int | END BLOCK line |

One row per BLOCK construct found. These feed back into the recursive orchestrator as new scoping units to process.

### Residual: block_residual (for recursion)

| column | type | description |
|--------|------|-------------|
| unit_id | int | FK to block_scope.block_id |
| filename | str | file path |
| start_line | int | first line of BLOCK body (after BLOCK statement) |
| end_line | int | last line of BLOCK body (before END BLOCK) |
| text | str | source text of the BLOCK body |
| ast_kind | str | `'Block'` |

One row per BLOCK construct. This is NOT a terminal residual — it feeds back into `segment_parts` via the recursive orchestrator.

### Logic

1. Parse or keyword-scan the execution part text to find all construct boundaries
2. Classify each construct:
   - **BLOCK** → emit to block_scope fact (not control_region)
   - **All others** → emit to control_region fact with appropriate kind:
     - `DO` → inspect for `WHILE`, `CONCURRENT` to distinguish do/do_while/do_concurrent
     - `SELECT` → inspect for `CASE`, `TYPE`, `RANK`
     - Others: 1-to-1 keyword-to-kind mapping
3. Nesting: line-range containment determines `parent_region_id` for control regions
4. SBB partitioning (Convention B):
   - Every construct boundary (control region or BLOCK scope) starts a new SBB
   - Within each region body, the text between nested constructs is a straight-line statement sequence → one SBB
   - Top-level gaps (between constructs at the execution part level) → SBBs with `region_id = NULL`
   - Empty gaps (adjacent construct boundaries with no statements) → no SBB
5. Block residual: for each BLOCK construct, slice the body text (excluding BLOCK/END BLOCK lines) for recursive processing

---

## Residual schema summary

Each residual carries the same structure: context FKs + `text` + `ast_kind`.

```
file_residual:    filename, text, ast_kind
scope_residual:   scope_id, filename, start_line, end_line, text, ast_kind
part_residual:    unit_source, unit_id, part, filename, start_line, end_line, text, ast_kind
block_residual:   unit_id, filename, start_line, end_line, text, ast_kind
```

Each step adds context columns and narrows the text. The `ast_kind` tag enables on-demand re-parsing via `parse_as(text, ast_kind)`.

Note: there is no terminal `sbb_residual` in the pipeline. SBBs are leaf nodes whose content is recovered on demand from `source_line` at the SBB's coordinates. Processes that need SBB text (trace_edges, data_access) read directly from fact tables + source_line.

---

## Pipeline graph

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
            ┌─────────────────────────────────────────┐
            │  process_scoping_units (recursive)       │
            │                                          │
            │  segment_parts                           │
            │    ├── scope_part  (fact)                │
            │    └── part_residual                     │
            │          │                               │
            │          │ filter: execution             │
            │          ▼                               │
            │        parse_execution                   │
            │          ├── control_region  (fact)      │
            │          ├── sbb  (fact)                 │
            │          └── block_scope  (fact)         │
            │                │                         │
            │                │ recurse: segment_parts  │
            │                │   → parse_execution     │
            │                │   → discover more       │
            │                │     blocks...           │
            │                ▼                         │
            │              (base case: no blocks)      │
            └─────────────────────────────────────────┘
```

4 processors. Recursion terminates when no BLOCK constructs are found in an execution part. In practice, BLOCK nesting rarely exceeds 1–2 levels.

---

## Process catalog (not part of the pipeline — computed on demand)

These are not pipeline processors. They are independent functions that read from fact tables + source_line to compute semantic properties.

| Process | Input | Output | Reads from |
|---|---|---|---|
| `trace_edges` | sbb + control_region | sbb_edge_df | SBB coordinates + region structure + source text |
| `parse_environment` | scope_part (environment) + source_line | use_stmt, import_stmt, implicit_rule | environment part lines |
| `parse_declarations` | scope_part (declarations) + source_line | declaration_construct | declarations part lines |
| `parse_use_entities` | use_stmt + source_line | use_entity | USE statement lines |
| `parse_import_entities` | import_stmt + source_line | import_entity | IMPORT statement lines |
| `compute_binding_kind` | control_region.kind | binding_kind | pure lookup |
| `parse_construct_name` | control_region + source_line | construct_name | region header line |

---

## Module catalog

| # | Function | Contract | Fact tables produced |
|---|---|---|---|
| 0 | `parse_source` | `(text, filename) → (source_line, file_residual)` | source_line |
| 1 | `parse_scopes` | `(file_residual) → (scope, scope_residual)` | scope |
| 2 | `segment_parts` | `(unit_residual, unit_source) → (scope_part, part_residual)` | scope_part |
| 3 | `parse_execution` | `(exec_residual, unit_source) → (control_region, sbb, block_scope)` | control_region, semantic_basic_block, block_scope |
| — | `process_scoping_units` | orchestrator (not a processor) | accumulates all of segment_parts + parse_execution output |

**4 processors. 6 fact tables. Recursion for BLOCK scopes.**
