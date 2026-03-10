# v0.1.8: processor specifications

5 pure functions. Each takes residual in, produces (fact_df, residual_df) out.

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

    source_line, file_res      = parse_source(text, filepath)
    scope, scope_res           = parse_scopes(file_res)
    scope_part, part_res       = segment_parts(scope_res)

    exec_res = part_res[part_res["part"] == "execution"]
    control_region, region_res = parse_regions(exec_res)
    sbb, _                     = partition_blocks(region_res)

    return {
        "source_line": source_line,
        "scope": scope,
        "scope_part": scope_part,
        "control_region": control_region,
        "semantic_basic_block": sbb,
    }
```

Linear pipeline. No recursion. File-level parallelism via `Pool.map(process_file, files)`.

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
def segment_parts(scope_residual: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
```

Segments each scope body into environment / declarations / execution parts by keyword scan.

### Input: scope_residual

One row per scope (from parse_scopes).

### Fact: scope_part

| column | type | description |
|--------|------|-------------|
| scope_id | int | FK to scope |
| part | str | `'environment'`, `'declarations'`, or `'execution'` |
| start_line | int | first line of this part |
| end_line | int | last line of this part |

Up to 3 rows per scope. Parts absent in the source are omitted.

### Residual: part_residual

| column | type | description |
|--------|------|-------------|
| scope_id | int | FK to scope |
| part | str | which part |
| filename | str | file path |
| start_line | int | first line |
| end_line | int | last line |
| text | str | source text of this part |
| ast_kind | str | `'Specification_Part'` or `'Execution_Part'` |

One row per scope part.

### Logic

1. For each scope body, scan lines by keyword to find boundaries:
   - **Environment**: contiguous group of USE / IMPORT / IMPLICIT lines at the top
   - **Declarations**: remaining specification lines (after environment, before CONTAINS or executable statements)
   - **Execution**: executable statements and control constructs
2. Boundary identification:
   - Environment ends at the first line that is not USE / IMPORT / IMPLICIT
   - Declarations end at the first executable statement (or CONTAINS)
   - CONTAINS and everything after → child scopes (already in scope table, no part row needed)
3. Omit parts with zero lines

### Which scope kinds have which parts

| kind | environment | declarations | execution |
|------|:-----------:|:------------:|:---------:|
| module, submodule, block_data | yes | yes | — |
| program, function, subroutine, separate_mp | yes | yes | yes |

---

## 3. parse_regions

```python
def parse_regions(exec_residual: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
```

Identifies control constructs within execution parts. Builds the nesting tree. BLOCK constructs are recognized as boundaries but NOT emitted as control regions — they are passed through in the residual for partition_blocks to handle.

### Input: exec_residual

Rows from part_residual where `part == 'execution'`.

### Fact: control_region

| column | type | description |
|--------|------|-------------|
| region_id | int | locally unique, 0-based |
| parent_region_id | int? | FK to enclosing region; NULL for top-level |
| scope_id | int | FK to scope |
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

BLOCK is NOT in this list. BLOCK constructs are recognized during scanning (they affect boundaries) but do not produce control_region rows.

### Residual: region_residual

| column | type | description |
|--------|------|-------------|
| scope_id | int | FK to scope |
| region_id | int? | FK to innermost enclosing region; NULL for top-level segments |
| filename | str | file path |
| start_line | int | first line |
| end_line | int | last line |
| text | str | source text of this segment |
| ast_kind | str | see below |

The `ast_kind` column distinguishes segment types:
- `'Execution_Part'` — a statement segment (gap between constructs)
- `'Block_Construct'` — an opaque BLOCK scope (full BLOCK...END BLOCK text)

Rows include: each control region body, top-level statement segments, and BLOCK construct ranges (as opaque units).

### Logic

1. Parse or keyword-scan the execution part text to find all construct boundaries (including BLOCK)
2. For non-BLOCK constructs, match opening keywords with END counterparts:
   - `DO` → inspect for `WHILE`, `CONCURRENT` to distinguish do/do_while/do_concurrent
   - `SELECT` → inspect for `CASE`, `TYPE`, `RANK`
   - Others: 1-to-1 keyword-to-kind mapping
3. Emit control_region rows for non-BLOCK constructs only
4. For BLOCK constructs: do NOT emit a control_region row. Instead, include the full BLOCK...END BLOCK range in the residual with `ast_kind = 'Block_Construct'`
5. Nesting: line-range containment determines `parent_region_id` for control regions
6. Residual: for each region, extract the body text. For top-level segments (gaps between constructs), create rows with `region_id = NULL`. BLOCK constructs appear as opaque residual rows.

---

## 4. partition_blocks

```python
def partition_blocks(region_residual: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
```

Partitions each residual segment into semantic basic blocks. Convention B: every construct boundary starts a new SBB. BLOCK constructs become `kind = 'block_scope'` SBBs; statement sequences become `kind = 'statements'` SBBs.

### Input: region_residual

One row per segment (from parse_regions).

### Fact: semantic_basic_block

| column | type | description |
|--------|------|-------------|
| sbb_id | int | locally unique, 0-based |
| scope_id | int | FK to scope |
| region_id | int? | FK to innermost enclosing region; NULL for top-level |
| kind | str | `'statements'` or `'block_scope'` |
| filename | str | file path |
| start_line | int | first line |
| end_line | int | last line |

One row per SBB.

### Residual: terminal (None)

partition_blocks is the terminal processor. SBB content is recovered on demand from `source_line` at the SBB's coordinates. Processes that need SBB text read directly from fact tables.

### Logic

1. For each residual segment, check `ast_kind`:
   - **`'Block_Construct'`** → emit one SBB with `kind = 'block_scope'` covering the full BLOCK...END BLOCK range
   - **`'Execution_Part'`** → partition into SBBs with `kind = 'statements'` using Convention B
2. Convention B for statement segments: within a region body, the text is a straight-line statement sequence — it becomes one SBB
3. If a region body has multiple sub-constructs at the same level (gaps between nested constructs), each gap is a separate SBB
4. Empty gaps (adjacent construct boundaries with no statements between them) produce no SBB

---

## Residual schema summary

Each residual carries the same structure: context FKs + `text` + `ast_kind`.

```
file_residual:    filename, text, ast_kind
scope_residual:   scope_id, filename, start_line, end_line, text, ast_kind
part_residual:    scope_id, part, filename, start_line, end_line, text, ast_kind
region_residual:  scope_id, region_id, filename, start_line, end_line, text, ast_kind
```

Each step adds context columns (scope_id → part → region_id) and narrows the text. The `ast_kind` tag serves two purposes:
1. Enables on-demand re-parsing via `parse_as(text, ast_kind)`
2. Distinguishes segment types (statement vs. block_scope) in region_residual

---

## Pipeline graph

```
parse_source
  ├── source_line  (fact)
  └── file_residual
        │
        ▼
      parse_scopes
        ├── scope  (fact: id, parent, kind, name, file, lines)
        └── scope_residual
              │
              ▼
            segment_parts
              ├── scope_part  (fact: environment, declarations, execution)
              └── part_residual
                    │
                    │ filter: execution
                    ▼
                  parse_regions
                    ├── control_region  (fact: 12 kinds)
                    └── region_residual  (tagged: Execution_Part | Block_Construct)
                          │
                          ▼
                        partition_blocks
                          └── sbb  (fact: 2 kinds — statements | block_scope)
```

5 steps. 5 fact tables. Linear. No recursion.

---

## Process catalog (not part of the pipeline — computed on demand)

These are not pipeline processors. They are independent functions that read from fact tables + source_line to compute semantic properties.

| Process | Input | Output | Reads from |
|---|---|---|---|
| `trace_edges` | sbb (kind=statements) + control_region | sbb_edge_df | SBB coordinates + region structure + source text |
| `parse_environment` | scope_part (environment) + source_line | use_stmt, import_stmt, implicit_rule | environment part lines |
| `parse_declarations` | scope_part (declarations) + source_line | declaration_construct | declarations part lines |
| `parse_block_scope` | sbb (kind=block_scope) + source_line | block environment, declarations, nested execution | block_scope SBB text |
| `parse_use_entities` | use_stmt + source_line | use_entity | USE statement lines |
| `parse_import_entities` | import_stmt + source_line | import_entity | IMPORT statement lines |
| `compute_binding_kind` | control_region.kind | binding_kind | pure lookup |
| `parse_construct_name` | control_region + source_line | construct_name | region header line |

---

## Module catalog

| # | Function | Input | Fact table |
|---|---|---|---|
| 0 | `parse_source` | `(text, filename)` | source_line |
| 1 | `parse_scopes` | `file_residual` | scope |
| 2 | `segment_parts` | `scope_residual` | scope_part |
| 3 | `parse_regions` | `exec_residual` | control_region |
| 4 | `partition_blocks` | `region_residual` | semantic_basic_block |

**5 processors. 5 fact tables. All two-table contract.**
