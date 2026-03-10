# extraction pipeline — parser combinator design

## 1. The observation

The coordinate system (v0.1.4) is **file-local**. Every fact table row references a single file via `(filename, start_line, end_line)`. No table requires cross-file information to populate:

- `scope` — identified from program unit / subprogram boundaries within one file
- `scope_part` — line ranges within one scope
- `use_stmt` — records the module *name* as a string, doesn't need the module parsed
- `declaration_construct` — line spans within one specification part
- `control_region` — construct nesting within one execution part
- `semantic_basic_block` — partition of one execution part
- `sbb_edge` — edges between SBBs within one scope

Cross-file relationships (USE → module resolution, IMPORT → host scope, submodule → parent) are **second-pass concerns** — they use the fact table data after all files are populated.

**Consequence**: the ETL pipeline can process every file independently, in parallel. No file ordering, no dependency graph, no coordination. Each file → set of DataFrames → concatenate across files → load into database.

## 2. The parser combinator pattern

### The analogy

A parser combinator takes input, consumes structure, returns `(result, remaining)`:

```
Parser[A] = Input → (A, Input)
```

Our extraction modules follow the same pattern:

```
Extractor[T] = Residual → (FactDF[T], Residual)
```

where:
- `FactDF[T]` — a pandera-validated DataFrame matching a database table schema. The **consumed** structure. Ready for INSERT.
- `Residual` — an ad-hoc DataFrame carrying the **remaining** source material (text + AST subtrees) for the next module to process.

### Composition

Extractors chain sequentially within a layer dependency:

```
scope_extract → part_extract → use_extract → import_extract → implicit_extract → decl_extract
```

Each module receives the previous module's residual. The residual threads through; fact DataFrames accumulate.

```python
ExtractResult = tuple[dict[str, pd.DataFrame], pd.DataFrame]
#                     table_name → fact_df       residual

Extractor = Callable[[pd.DataFrame], ExtractResult]
```

### The two outputs

Each module produces exactly two things:

**1. Pandera-schematized DataFrame** — the structured extraction. Columns match the database table. Validated at the boundary via `@pa.check_types` or explicit `Schema.validate()`. This is the contract: if validation passes, the data is ready for the database.

**2. Ad-hoc residual DataFrame** — joinable with the fact DataFrame via shared key columns (e.g., `scope_id`), plus two additional columns:
- `text`: the raw source text of this segment (the lines within `[start_line, end_line]`)
- `ast`: the CST subtree (fcst `Node`) covering this segment

The residual carries forward exactly the material the next module needs. Each module narrows the residual — either by segmenting rows into finer pieces (scope → scope_parts) or by consuming recognized constructs and leaving the rest.

### Why this works

The parser combinator pattern is a natural fit because the coordinate system itself is layered:

| Layer | Consumes | Produces fact table | Residual for next |
|---|---|---|---|
| scope | File CST | `scope` | Per-scope body text + AST |
| scope_part | Scope bodies | `scope_part` | Per-part text + AST |
| use | Spec-part segments | `use_stmt`, `use_entity` | Spec-part minus USE lines |
| import | Spec-part remainder | `import_stmt`, `import_entity` | Spec-part minus IMPORT lines |
| implicit | Spec-part remainder | `implicit_rule` | Spec-part minus IMPLICIT lines |
| declaration | Spec-part remainder | `declaration_construct` | Per-construct text + AST |
| region | Exec-part segments | `control_region` | Per-region text + AST |
| sbb | Exec regions | `semantic_basic_block` | Per-SBB text + AST |
| edge | SBBs | `sbb_edge` | Per-SBB text + AST (terminal) |

Each layer peels off one level of structure, exactly matching the database's layered dependency order (Condition 3).

## 3. Module catalog

### 3.0 source_load

```
Input:  file path
Output: fact:     source_line_df (file_version, source_line)
        residual: (filename, text, ast_kind)
                   one row per file, full text + root CST node
```

Parses the file via fparser → fcst `str_to_cst()`. Produces the `source_line` rows and a single residual row containing the entire file's text and CST root node.

### 3.1 scope_extract

```
Input:  file residual (filename, text, ast_kind)
Output: fact:     scope_df
        residual: (scope_id, kind, filename, start_line, end_line, text, ast_kind)
                   one row per scope, scope's CST subtree
```

Walks the CST (from the initial full parse) to identify program units and subprograms. Each structural scope becomes one fact row and one residual row. The residual's `ast_kind` is the scope's CST node type (e.g., `'Module'`, `'Subroutine_Subprogram'`), and `text` is the scope's source text.

Scope nesting (parent_scope_id) is determined during this walk — if scope B appears within scope A's source range, then B is contained in A.

### 3.2 part_extract

```
Input:  scope residual
Output: fact:     scope_part_df
        residual: (scope_id, part, start_line, end_line, text, ast_kind)
                   one row per scope part
```

Segments each scope body into specification / execution / subprogram parts. The Fortran grammar guarantees strict ordering and non-overlap. The residual decomposes each scope into up to 3 rows.

**Fork point**: after this module, the spec-part rows and exec-part rows feed into independent pipelines.

### 3.3 use_extract (Spec Layer 1)

```
Input:  spec-part residual rows
Output: fact:     use_stmt_df, use_entity_df
        residual: spec-part rows with USE line ranges narrowed out
```

Scans the CST subtree for `Use_Stmt` nodes. Each USE statement produces one `use_stmt` row. ONLY/rename lists produce `use_entity` rows. The residual advances `start_line` past the last USE statement (or removes USE subtrees from the AST column).

### 3.4 import_extract (Spec Layer 2)

```
Input:  spec-part residual (post-USE)
Output: fact:     import_stmt_df, import_entity_df
        residual: spec-part rows with IMPORT line ranges narrowed out
```

Same pattern as use_extract, for `Import_Stmt` nodes.

### 3.5 implicit_extract (Spec Layer 3)

```
Input:  spec-part residual (post-IMPORT)
Output: fact:     implicit_rule_df, scope_implicit_update_df
        residual: spec-part rows with IMPLICIT line ranges narrowed out
```

Extracts `Implicit_Stmt` and `Implicit_None_Stmt` nodes. Produces `implicit_rule` rows for custom rules and updates `scope.implicit_typing`. The residual is the declaration region — only Layer 4 constructs remain.

### 3.6 declaration_extract (Spec Layer 4)

```
Input:  spec-part residual (post-IMPLICIT, = declaration region only)
Output: fact:     declaration_construct_df
        residual: (construct_id, scope_id, construct, start_line, end_line, text, ast_kind)
                   one row per declaration construct, with its CST subtree
```

Segments the remaining specification part into individual declaration constructs. Each construct is classified by its leading keyword into one of 18 kinds. The residual is the **terminal residual** for the spec pipeline — each row is one construct with its text and AST, ready for computed table extraction downstream.

### 3.7 region_extract (Exec: CCT)

```
Input:  exec-part residual rows
Output: fact:     control_region_df
        residual: (region_id, scope_id, kind, start_line, end_line, text, ast_kind)
                   one row per control region + top-level (non-construct) segments
```

Identifies control constructs by keyword scanning of the text (or by calling `parse_as` on the exec-part text) and builds the CCT. Self-referential `parent_region_id` is determined by line-range nesting. `binding_kind` is functionally determined from `kind`. The residual includes both control region interiors and top-level statement segments not inside any construct, each with its `ast_kind` tag.

### 3.8 sbb_extract (Exec: SBBs)

```
Input:  region residual
Output: fact:     semantic_basic_block_df
        residual: (sbb_id, scope_id, region_id, start_line, end_line, text, ast_kind)
                   one row per SBB, with its statement sequence
```

Partitions each control region (and top-level segments) into semantic basic blocks. Convention B: every construct boundary starts a new SBB. The residual is the **terminal residual** for the exec pipeline — each row is one SBB with its action statement text and an `ast_kind` of `'Execution_Part'` (or finer if individual statements are split), ready for computed table extraction via `parse_as`.

### 3.9 edge_extract (Exec: CFG)

```
Input:  SBB residual + region structure
Output: fact:     sbb_edge_df
        residual: same as input (edges don't consume text)
```

Computes control flow edges between SBBs based on the CCT structure and statement analysis (branch targets, loop back-edges, jump targets). May call `parse_as` on SBB text to identify branch/jump statements. This module doesn't narrow the residual — it's a derived computation, not a text consumption.

## 4. Pandera schemas

Each fact table maps to a pandera `DataFrameModel`. Schemas enforce column types, constraints, and cross-column invariants at pipeline boundaries.

```python
import pandera.pandas as pa
from pandera.typing import Series

# -- Layer 1: Structural scopes --

class ScopeSchema(pa.DataFrameModel):
    scope_id:              Series[int] = pa.Field(ge=0, unique=True)
    parent_scope_id:       Series[pd.Int64Dtype] = pa.Field(nullable=True)
    kind:                  Series[str] = pa.Field(isin=[
        'global', 'program', 'module', 'submodule', 'block_data',
        'function', 'subroutine', 'separate_mp'
    ])
    name:                  Series[str] = pa.Field(nullable=True)
    filename:              Series[str] = pa.Field(nullable=True)
    start_line:            Series[pd.Int64Dtype] = pa.Field(nullable=True, ge=1)
    end_line:              Series[pd.Int64Dtype] = pa.Field(nullable=True, ge=1)
    implicit_typing:       Series[str] = pa.Field(isin=[
        'default', 'none', 'inherit', 'custom'
    ])
    ancestor_scope_id:     Series[pd.Int64Dtype] = pa.Field(nullable=True)
    default_accessibility: Series[str] = pa.Field(nullable=True, isin=[
        'public', 'private'
    ])

    @pa.dataframe_check
    def start_before_end(cls, df):
        mask = df['start_line'].notna() & df['end_line'].notna()
        return ~mask | (df['start_line'] <= df['end_line'])

    class Config:
        strict = True
        coerce = True


class ScopePartSchema(pa.DataFrameModel):
    scope_id:   Series[int] = pa.Field(ge=0)
    part:       Series[str] = pa.Field(isin=[
        'specification', 'execution', 'subprogram'
    ])
    start_line: Series[int] = pa.Field(ge=1)
    end_line:   Series[int] = pa.Field(ge=1)

    @pa.dataframe_check
    def start_before_end(cls, df):
        return df['start_line'] <= df['end_line']

    class Config:
        strict = True
        coerce = True


# -- Spec Layer 1: USE --

class UseStmtSchema(pa.DataFrameModel):
    use_id:      Series[int] = pa.Field(ge=0, unique=True)
    scope_id:    Series[int] = pa.Field(ge=0)
    module_name: Series[str]
    nature:      Series[str] = pa.Field(isin=[
        'unspecified', 'intrinsic', 'non_intrinsic'
    ])
    only_clause: Series[bool]
    start_line:  Series[pd.Int64Dtype] = pa.Field(nullable=True, ge=1)

    class Config:
        strict = True
        coerce = True


class UseEntitySchema(pa.DataFrameModel):
    use_id:             Series[int] = pa.Field(ge=0)
    module_entity_name: Series[str]
    local_name:         Series[str] = pa.Field(nullable=True)

    class Config:
        strict = True
        coerce = True


# -- Spec Layer 2: IMPORT --

class ImportStmtSchema(pa.DataFrameModel):
    import_id:  Series[int] = pa.Field(ge=0, unique=True)
    scope_id:   Series[int] = pa.Field(ge=0)
    mode:       Series[str] = pa.Field(isin=[
        'explicit', 'all', 'none', 'only'
    ])
    start_line: Series[pd.Int64Dtype] = pa.Field(nullable=True, ge=1)

    class Config:
        strict = True
        coerce = True


class ImportEntitySchema(pa.DataFrameModel):
    import_id: Series[int] = pa.Field(ge=0)
    name:      Series[str]

    class Config:
        strict = True
        coerce = True


# -- Spec Layer 3: IMPLICIT --

class ImplicitRuleSchema(pa.DataFrameModel):
    scope_id:     Series[int] = pa.Field(ge=0)
    letter_start: Series[str] = pa.Field(str_length={'min_value': 1, 'max_value': 1})
    letter_end:   Series[str] = pa.Field(str_length={'min_value': 1, 'max_value': 1})
    type_spec:    Series[str]

    @pa.dataframe_check
    def start_before_end(cls, df):
        return df['letter_start'] <= df['letter_end']

    class Config:
        strict = True
        coerce = True


# -- Spec Layer 4: Declarations --

DECLARATION_KINDS = [
    'derived_type_def', 'interface_block', 'enum_def',
    'type_declaration', 'generic_stmt', 'procedure_decl',
    'parameter_stmt', 'access_stmt', 'attribute_stmt',
    'common_stmt', 'equivalence_stmt', 'namelist_stmt',
    'external_stmt', 'intrinsic_stmt', 'data_stmt',
    'format_stmt', 'entry_stmt', 'stmt_function',
]

class DeclarationConstructSchema(pa.DataFrameModel):
    construct_id: Series[int] = pa.Field(ge=0, unique=True)
    scope_id:     Series[int] = pa.Field(ge=0)
    construct:    Series[str] = pa.Field(isin=DECLARATION_KINDS)
    name:         Series[str] = pa.Field(nullable=True)
    ordinal:      Series[int] = pa.Field(ge=1)
    start_line:   Series[int] = pa.Field(ge=1)
    end_line:     Series[int] = pa.Field(ge=1)

    @pa.dataframe_check
    def start_before_end(cls, df):
        return df['start_line'] <= df['end_line']

    class Config:
        strict = True
        coerce = True


# -- Exec: Control regions --

REGION_KINDS = [
    'if', 'select_case', 'select_type', 'select_rank',
    'do', 'do_while', 'do_concurrent', 'forall',
    'where', 'block', 'associate', 'critical', 'change_team',
]
BINDING_KINDS = ['none', 'full_scope', 'construct_index', 'construct_entity']

class ControlRegionSchema(pa.DataFrameModel):
    region_id:        Series[int] = pa.Field(ge=0, unique=True)
    parent_region_id: Series[pd.Int64Dtype] = pa.Field(nullable=True)
    scope_id:         Series[int] = pa.Field(ge=0)
    kind:             Series[str] = pa.Field(isin=REGION_KINDS)
    binding_kind:     Series[str] = pa.Field(isin=BINDING_KINDS)
    construct_name:   Series[str] = pa.Field(nullable=True)
    filename:         Series[str]
    start_line:       Series[int] = pa.Field(ge=1)
    end_line:         Series[int] = pa.Field(ge=1)

    @pa.dataframe_check
    def start_before_end(cls, df):
        return df['start_line'] <= df['end_line']

    class Config:
        strict = True
        coerce = True


# -- Exec: SBBs and edges --

class SemanticBasicBlockSchema(pa.DataFrameModel):
    sbb_id:     Series[int] = pa.Field(ge=0, unique=True)
    scope_id:   Series[int] = pa.Field(ge=0)
    region_id:  Series[pd.Int64Dtype] = pa.Field(nullable=True)
    filename:   Series[str]
    start_line: Series[int] = pa.Field(ge=1)
    end_line:   Series[int] = pa.Field(ge=1)

    @pa.dataframe_check
    def start_before_end(cls, df):
        return df['start_line'] <= df['end_line']

    class Config:
        strict = True
        coerce = True


EDGE_KINDS = [
    'fallthrough', 'branch_true', 'branch_false', 'case_select',
    'loop_back', 'loop_exit', 'jump', 'return',
]

class SbbEdgeSchema(pa.DataFrameModel):
    from_sbb_id: Series[int] = pa.Field(ge=0)
    to_sbb_id:   Series[int] = pa.Field(ge=0)
    edge_kind:   Series[str] = pa.Field(isin=EDGE_KINDS)

    class Config:
        strict = True
        coerce = True
```

## 5. The residual DataFrame

The residual is the "remaining input" in the parser combinator. It is an ad-hoc DataFrame — not schema-validated, not persisted to the database — serving only as the interface between adjacent modules.

### Structure

Every residual has:

| Column | Type | Purpose |
|---|---|---|
| *key columns* | int / str | FKs joining to the fact DataFrame from the same or parent module |
| `text` | str | Raw source text of this segment (the lines within start_line..end_line) |
| `ast_kind` | str | The AST node type tag (e.g., `'Module'`, `'Use_Stmt'`, `'If_Construct'`) |

The key columns match the fact table's primary/foreign keys so the residual is joinable. For example, after `scope_extract`, the residual has `scope_id` matching `scope_df.scope_id`.

### The (text, ast_kind) pair

The residual carries `text` and `ast_kind`, both strings — no tree objects. This pair is sufficient for on-demand re-parsing:

```python
node = fcst.parse_as(row.text, row.ast_kind)
# → invokes the specific fparser production for that kind
# → returns a fcst Node (CST subtree)
```

This is **Condition 2 in action**: `ast_kind` determines the grammar production, `text` provides the source content. Together they enable deterministic recovery of the full AST at any time, without carrying tree data through the pipeline.

**Why not store the tree itself:**
- **Serializable**: both columns are plain strings — the residual can be persisted, shipped across processes, inspected in a debugger
- **Lightweight**: no Python objects in DataFrame columns, no pickle, no memory pressure from holding large CSTs across pipeline stages
- **On-demand**: re-parsing is cheap and targeted — you parse exactly the fragment you need, using the exact production you know applies
- **Decoupled**: the pipeline doesn't depend on fcst's in-memory Node representation; any parser that understands the kind → production mapping can process the residual

### Narrowing

Each module narrows the residual in one of two ways:

**Segmentation** — one input row becomes multiple output rows at finer granularity:
- `scope_extract`: 1 file row → N scope rows, each with its own `(text, ast_kind)`
- `part_extract`: 1 scope row → up to 3 part rows
- `declaration_extract`: 1 spec-part row → M declaration construct rows

**Consumption** — recognized constructs are removed from the text, leaving the remainder:
- `use_extract`: spec-part text shrinks as USE lines are consumed
- `import_extract`: text shrinks as IMPORT lines are consumed
- `implicit_extract`: text shrinks as IMPLICIT lines are consumed

In both cases, the invariant holds: `residual.text` contains exactly the source material the next module needs, and `residual.ast_kind` tells it which production to use if re-parsing is needed.

### Terminal residuals

The spec pipeline's terminal residual (after `declaration_extract`) has one row per declaration construct — each carrying the construct's text and `ast_kind` (e.g., `'Type_Declaration_Stmt'`, `'Derived_Type_Def'`). This is the input for **computed table extraction**: call `parse_as(text, ast_kind)` to get the full AST, then extract entity names, type specs, attributes.

The exec pipeline's terminal residual (after `sbb_extract`) has one row per SBB — each carrying the SBB's action statement text. This is the input for **computed table extraction**: parse each statement to extract data_access, call_edge, io_operation, allocation_event.

The terminal residuals are the bridge between the coordinate system (fact tables) and semantic analysis (computed tables). The `(text, ast_kind)` pair is the contract: you know WHERE (from the fact table FK), WHAT kind (from `ast_kind`), and have the raw material (`text`).

## 6. Integration with fcst

### What fcst currently provides

fcst converts Fortran source to a uniform, immutable CST:

```
source text → fparser AST → fcst CST (Node tree)
```

Current API:
- `str_to_cst(source)` — parse full Fortran program → CST root Node
- `str_to_ast(source)` — parse full Fortran program → fparser AST
- `ast_to_cst(node)` — convert fparser AST → fcst CST

The CST `Node` has:
- `kind`: constructor tag (maps to fparser class name, e.g., `'Module'`, `'Use_Stmt'`)
- `value`: literal text for leaf nodes
- `span`: byte offset range in source
- `edges`: labeled children (structured or container mode)

### What the pipeline needs from fcst (enrichment required)

The `(text, ast_kind)` residual design requires a new capability: **targeted parsing by production kind**. Given a text fragment and the name of the grammar production that governs it, parse just that fragment.

**New API needed:**

```python
def parse_as(text: str, kind: str) -> Node:
    """Parse a text fragment using a specific grammar production.

    kind: the AST node type tag (e.g., 'Use_Stmt', 'If_Construct',
          'Type_Declaration_Stmt', 'Module')
    text: the raw Fortran source text for that construct

    Returns: a fcst Node (CST subtree) rooted at the given kind.

    Raises: AttributeError if kind is not a valid fparser class.
            ParseError if text doesn't match the production.
    """
```

**Implementation — no registry needed:**

The `kind` string IS the fparser class name — that's how fcst's `_kind()` helper derives it in the first place. So the reverse mapping is just `getattr`:

```python
from fparser.two import Fortran2003 as f03
from fparser.common.readfortran import FortranStringReader

def parse_as(text: str, kind: str) -> Node:
    cls = getattr(f03, kind)              # dynamic class lookup
    reader = FortranStringReader(text)
    ast_node = cls(reader)                # invoke the production
    return ast_to_cst(ast_node)           # convert to fcst Node
```

Three lines. No registry, no introspection sweep, no maintenance. The fparser module namespace IS the registry — `getattr` is the lookup.

This works because fparser's class naming convention is consistent: every grammar rule has a class whose name matches the `kind` string that fcst produces via `type(node).__name__`.

### How the pipeline uses fcst

**Module 3.0 (source_load)**: calls `str_to_cst(source_text)` to do the initial full parse. Walks the CST to identify top-level constructs and their `kind` tags. The initial residual is populated with `(text, ast_kind)` pairs — one per top-level construct.

**Downstream modules**: receive `(text, ast_kind)` strings. When a module needs the AST for detailed extraction, it calls `parse_as(text, ast_kind)` to get the CST subtree on demand. For example:
- `use_extract` receives rows where `ast_kind = 'Use_Stmt'` — calls `parse_as` to extract module name, ONLY list, renames
- `declaration_extract` receives the remaining spec-part text — identifies construct boundaries by keyword, classifies each into an `ast_kind`, produces one residual row per construct
- Computed table extractors receive terminal residual rows — call `parse_as` to get the full AST of each declaration or SBB for semantic analysis

**The initial parse is still a full parse** (via `str_to_cst`). The `parse_as` function is for re-parsing individual fragments during later pipeline stages or in computed table extraction. This is efficient because:
- Fragment parsing is bounded (one construct at a time, not a whole file)
- The `ast_kind` eliminates ambiguity (no trial-and-error dispatch)
- Re-parsing is only done when the AST is actually needed (lazy)

### What fcst needs to implement

| Component | Description | Complexity |
|---|---|---|
| `parse_as(text, kind)` | Targeted parse: `getattr(f03, kind)` + `FortranStringReader` + `ast_to_cst` | Trivial — 3 lines |
| `kind_to_rule` | Optional metadata: kind → F2018 rule number (e.g., `'Use_Stmt' → 'R1409'`) | Low — lookup table |

No registry is needed. The fparser module namespace provides the class lookup via `getattr`. The `kind` string is the class name by construction (fcst derives it via `type(node).__name__`).

## 7. Parallelism model

### File-level parallelism (embarrassingly parallel)

```
files: [f1, f2, ..., fN]
  │
  ├─ process(f1) → fact_dfs_1, terminal_residuals_1
  ├─ process(f2) → fact_dfs_2, terminal_residuals_2
  ...
  └─ process(fN) → fact_dfs_N, terminal_residuals_N
  │
  └─ concat all → load into database
```

Each file is processed by the full pipeline independently. No coordination between files. The concat step assigns globally unique IDs (scope_id, sbb_id, etc.) via either:
- Pre-allocated ID ranges per file (e.g., file 1 gets IDs 0–999, file 2 gets 1000–1999)
- Post-hoc ID assignment after concat (simpler, requires a final renumbering pass)

### Spec/exec parallelism (within one file)

After `part_extract`, the spec-part rows and exec-part rows feed independent pipelines:

```
part_extract
  ├─ spec rows → use → import → implicit → declaration   (sequential)
  └─ exec rows → region → sbb → edge                     (sequential)
```

These two branches are independent and can run in parallel.

### Where parallelism stops

Within each branch, modules are sequential — each depends on the previous module's residual. This is inherent to the layered dependency (Condition 3): USE must be processed before IMPORT before IMPLICIT before declarations.

## 8. Rationale review

### The user's idea: parser combinator with two-output modules

**Evaluation: sound and well-motivated.** The design aligns naturally with three independent properties of the coordinate system:

**Property 1: Layered consumption.** The specification part has 4 layers processed in order; the execution part has hierarchical decomposition. In both cases, structure is peeled off one layer at a time. The parser combinator pattern — consume some input, pass the rest — is the exact computational model for this.

**Property 2: File locality.** No fact table requires cross-file information. This makes file-level parallelism trivial. The parser combinator chain runs identically on each file — no shared state, no synchronization.

**Property 3: Fact/computed boundary.** The two outputs (pandera fact_df + ad-hoc residual_df) mirror the system's architectural boundary. The fact_df IS the coordinate system — validated, ready for the database. The residual IS the input for computed tables — carrying `(text, ast_kind)` at known coordinates, sufficient for on-demand re-parsing via `parse_as`.

### Why pandera schemas work here

Pandera schemas serve as **contracts between pipeline stages**:

1. **Type safety**: column dtypes, nullability, and value constraints are checked at boundaries
2. **Documentation**: the schema IS the specification — no separate docs needed
3. **Composability**: schema inheritance can model progressive enrichment (though for this pipeline, each module produces a distinct table schema, so inheritance is less critical)
4. **Debugging**: `lazy=True` validation reports ALL violations at once, not just the first

The choice to validate at module boundaries (not within modules) is correct — it matches the parser combinator philosophy of trusting internal logic and verifying at interfaces.

### Why the ad-hoc residual should NOT be schema-validated

The residual is a transient, internal representation — it exists only between two adjacent modules in the same pipeline run. Schema-validating it would:
- Add overhead with no consumer benefit (the next module is the only reader)
- Constrain the representation (modules might want to store partial AST state that doesn't fit a fixed schema)
- Conflate the fact/computed boundary (the residual is pre-computed, not a fact)

The residual's contract is implicit: "joinable with the fact_df, has `text` and `ast_kind` columns." This is sufficient. If a module produces a bad residual, the next module's fact_df validation will catch the downstream effect.

### Why ast_kind (string tag) instead of storing tree objects

The user's correction is sharper than the original design. Storing `ast_kind` (a string) instead of the full CST Node has several advantages:

1. **Condition 2 made operational.** The coordinate system's Condition 2 says: kind determines grammar production. The `(text, ast_kind)` pair is the runtime encoding of this condition. The residual IS a coordinate — it contains exactly the information needed for deterministic recovery.

2. **Serializable and inspectable.** Both columns are plain strings. The residual can be logged, persisted to parquet, shipped to a worker process, or inspected in a Jupyter notebook. No pickle, no object columns, no hidden state.

3. **Lazy evaluation.** Re-parsing happens only when the AST is actually needed — not when the residual is constructed. Most pipeline modules need only keyword-level inspection of the text (to classify constructs); full AST parsing is deferred to the modules that actually extract semantic content.

4. **Zero infrastructure.** `parse_as` is three lines — `getattr` on the fparser module. No registry to build or maintain. The fparser module namespace IS the lookup table, and `kind` strings are class names by construction.

### Extension: cross-file resolution as a second pipeline

The first pipeline (this design) produces the coordinate system. A second pipeline would consume the fact tables to resolve cross-file relationships:

```
Second pass (cross-file, after all files processed):
  1. Build module table: module_name → scope_id
  2. Resolve USE: use_stmt.module_name → scope_id
  3. Resolve IMPORT: import_stmt → parent scope
  4. Resolve submodule ancestry: scope.ancestor_scope_id
```

This is not a parser combinator — it's a join-heavy relational operation over the populated fact tables. It belongs in a separate module, not in this pipeline. The pipeline's job is: source text → fact table DataFrames. Everything after is queries.

## 9. Complete pipeline diagram

```
┌─────────────────────────────────────────────┐
│  Per-file pipeline (embarrassingly parallel) │
│                                             │
│  source_load(file)                          │
│    │                                        │
│    ▼                                        │
│  scope_extract                              │
│    │  fact: scope_df                        │
│    │  residual: per-scope (text, ast_kind)       │
│    ▼                                        │
│  part_extract                               │
│    │  fact: scope_part_df                   │
│    │  residual: per-part (text, ast_kind)        │
│    │                                        │
│    ├──────────────┬─────────────────┐       │
│    │ spec rows    │ exec rows       │       │
│    ▼              ▼                 │       │
│  use_extract    region_extract      │       │
│    │              │                 │       │
│    ▼              ▼                 │       │
│  import_extract sbb_extract        │       │
│    │              │                 │       │
│    ▼              ▼                 │       │
│  implicit_extract edge_extract     │       │
│    │                                │       │
│    ▼                                │       │
│  declaration_extract                │       │
│                                     │       │
│  ─── terminal residuals ───         │       │
│  spec: per-construct (text, ast_kind)    │       │
│  exec: per-SBB (text, ast_kind)         │       │
└─────────────────────────────────────────────┘
          │
          ▼  concat across files
┌─────────────────────────────────────────────┐
│  Database load                              │
│  - Assign global IDs                        │
│  - INSERT into PostgreSQL tables            │
│  - Run completeness checks (architecture.md §8) │
└─────────────────────────────────────────────┘
          │
          ▼  (future: cross-file resolution)
┌─────────────────────────────────────────────┐
│  Computed table extraction                  │
│  - Input: terminal residuals (text + ast)   │
│  - Output: data_access, call_edge,          │
│    io_operation, allocation_event,          │
│    construct_entity                         │
└─────────────────────────────────────────────┘
```

## 10. Implementation entry points

### fcst enrichment required

The pipeline depends on one new fcst capability: **targeted parsing by production kind**.

| Component | What | Complexity |
|---|---|---|
| `parse_as(text, kind)` | `getattr(f03, kind)` + `FortranStringReader` + `ast_to_cst` | Trivial — 3 lines |

No registry needed. The `kind` string is the fparser class name by construction (`type(node).__name__`). Dynamic lookup via `getattr` on the fparser module namespace is the entire implementation.

### Pipeline module requirements

| Module | Uses `str_to_cst` (full parse) | Uses `parse_as` (targeted) | Notes |
|---|---|---|---|
| source_load | Yes — initial full parse | No | Entry point; produces initial residual |
| scope_extract | Walks initial CST | No | Extracts scope boundaries + kind tags |
| part_extract | Walks initial CST | No | Segments by spec/exec/subprogram |
| use_extract | No | Optional — can use keyword scan of text | Simple enough for text-level extraction |
| import_extract | No | Optional | Same pattern as use_extract |
| implicit_extract | No | Optional | Same pattern |
| declaration_extract | No | Yes — classifies and re-parses each construct | Needs `parse_as` for block constructs |
| region_extract | No | Yes — re-parses exec part by control construct | Needs `parse_as` for construct headers |
| sbb_extract | No | Optional — can partition by line ranges | May use `parse_as` for statement classification |
| edge_extract | No | Yes — analyzes branch/loop structure | Needs `parse_as` for control construct bodies |

**Pattern**: the first three modules (source_load, scope_extract, part_extract) work with the initial full CST. All subsequent modules work with `(text, ast_kind)` residuals and invoke `parse_as` on demand.

### Extraction logic style

Each module is a pure function: `DataFrame → (dict[str, DataFrame], DataFrame)`. No visitor pattern, no subclassing. The logic is:

1. Iterate residual rows
2. For each row, inspect `text` (keyword scan) or call `parse_as(text, ast_kind)` to get the AST
3. Extract facts into the pandera-validated DataFrame
4. Produce narrowed residual rows for the next module

This keeps modules independent, testable, and composable.
