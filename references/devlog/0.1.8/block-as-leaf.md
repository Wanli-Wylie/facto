# v0.1.8: BLOCK as opaque leaf node

## Delta from v0.1.7

v0.1.7 treated BLOCK constructs as recursive scoping units: a separate `block_scope` physical table, a `scoping_unit` view, `unit_source`/`unit_id` threading through scope_part, control_region, and sbb, and a recursive orchestrator in the pipeline. This added substantial complexity for a construct that is rare in practice and unreferenceable by design.

v0.1.8 treats BLOCK as an **opaque leaf node** — a semantic basic block with `kind = 'block_scope'`, alongside normal `kind = 'statements'` SBBs. BLOCK's internal structure (environment, declarations, nested execution) is recoverable on demand from its source text, same as any other deferred content.

## The argument

### BLOCK is a let-binding region

BLOCK is Fortran's analog of C's `{ }` compound statement: it introduces lexical scope for local declarations with restricted visibility.

```
C:       { int b = 2; a += b; }
Rust:    { let b = 2; a += b; }
Fortran: BLOCK; INTEGER :: b; b = 2; a = a + b; END BLOCK
```

Key properties:
- **Anonymous** — no callable name (construct name is for EXIT only)
- **Unreferenceable** — cannot be USEd, CALLed, or type-referenced from outside
- **No escape** — executes inline, dies before parent scope
- **Purely lexical** — just a scope boundary, not a control flow mechanism

### What BLOCK adds beyond C's `{ }`

Fortran BLOCK has a full specification part: USE (mount external namespaces), IMPORT (filter inherited names), IMPLICIT (change typing rules), and declarations. C's `{ }` only has declarations. But this extra capability is a property of the BLOCK's *content*, not its *structural position*. The pipeline only needs to know WHERE the BLOCK is and WHAT KIND it is — the content is a process concern.

### The opaque leaf treatment

At the leaf level of the execution tree, there are two kinds of text blocks:

| kind | content | grammar production | on-demand analysis |
|---|---|---|---|
| `statements` | action statement sequence | `Action_Stmt*` | data_access, call_edge, trace_edges |
| `block_scope` | let-binding region with spec + exec | `Block_Construct` | environment, declarations, nested execution |

Both are contiguous text regions at known coordinates with known grammar productions. The pipeline records them. Processes analyze them.

## What changed

### Dropped from schema

| artifact | rationale |
|---|---|
| `block_scope` table | BLOCK is a leaf SBB, not a separate entity |
| `scoping_unit` view | no second physical table to unify |
| `unit_source` column (everywhere) | back to plain `scope_id` |

### Added to schema

| artifact | rationale |
|---|---|
| `semantic_basic_block.kind` | distinguishes `'statements'` from `'block_scope'` leaves |

### Pipeline changes

| v0.1.7 | v0.1.8 | rationale |
|---|---|---|
| `parse_execution` (3-table output) | `parse_regions` + `partition_blocks` (both 2-table) | no recursion → two-table contract restored |
| recursive `process_scoping_units` | linear `process_file` | BLOCK is a leaf, not a recursive entry point |
| `unit_source`/`unit_id` threading | plain `scope_id` | one physical scope table |

### Impact on processes

Processes that need BLOCK internals (name resolution, implicit typing) read the `block_scope` SBB's source text and parse it as `Block_Construct`. This is the same pattern used for environment content (USE/IMPORT/IMPLICIT) and declaration content — structural coordinates in, semantic content out, on demand.

## Revised counts

- **5 fact tables**: source_line, scope, scope_part, control_region, semantic_basic_block
- **5 processors**: parse_source, parse_scopes, segment_parts, parse_regions, partition_blocks
- **0 recursive steps**
- **3 storage tables**: file_version, source_line, edit_event
- **1 view**: source_code
