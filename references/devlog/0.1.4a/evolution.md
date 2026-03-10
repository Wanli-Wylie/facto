# system evolution — building the coordinate system

How the fact table system evolved from v0.1.0 to v0.1.4a, and how each step addresses the three coordinate system conditions (complete partition, kind-determined grammar, layered dependency order).

## v0.1.0: source lines and raw scope

**Tables**: `source_code` (view), `scope` (13 kinds)

**What it established**:
- Every source line has a unique address: `(filename, lineno)`
- Every line belongs to exactly one scope via `[start_line, end_line]`

**Condition status**:
- Partition: scopes cover all lines, but **internal constructs mixed with structural ones** — 13 kinds included derived_type, interface_body, block, forall, do_concurrent alongside the 8 structural kinds
- Grammar: scope kind alone does not determine a grammar production for the lines within it
- Dependency: no layering — everything is flat

**Gap**: the 5 internal kinds (block, forall, do_concurrent, derived_type, interface_body) introduce **unbounded nesting** via left-recursion, violating the relational-first methodology.

## v0.1.1: structural scope only

**Changes**: scope narrowed from 13 to **8 structural kinds**. Schema design methodology documented.

**What it established**:
- Structural scopes nest at most ~3 levels (global → module → function). Bounded. No left-recursion.
- Internal constructs deferred: derived_type → declaration dimension, interface_body → declaration dimension, block/forall/do_concurrent → control region table.

**Condition status**:
- Partition: structural scopes partition all lines. But lines within a scope are undifferentiated — the scope's specification vs execution content is not indexed.
- Grammar: still no production dispatch within a scope
- Dependency: parent_scope_id gives containment, but no semantic layering yet

**Progress**: the unbounded-nesting problem is solved. The scope table is now a clean fact table with bounded self-reference.

## v0.1.2: specification / execution split

**New table**: `scope_part` — segments each scope into specification, execution, and subprogram regions.

**What it established**:
- Within each scope, every line belongs to one of three parts
- The specification part is now a named, bounded region with line ranges

**Condition status**:
- Partition: scope × part covers all lines. But within the specification part, individual statements are not indexed.
- Grammar: `part` tells you "this is spec" but not which grammar production applies to each statement
- Dependency: the three parts (spec → exec → subprogram) have an implicit ordering, but no semantic layering within the spec part

**Progress**: the target region (specification part) is now identifiable by line range. Ready for internal structuring.

## v0.1.3a: specification layers 1–3

**New tables**: `use_stmt` + `use_entity` (Layer 1), `import_stmt` + `import_entity` (Layer 2), `implicit_rule` (Layer 3).

**What it established**:
- Every USE statement has a unique row with line range and module name
- Every IMPORT statement has a unique row with mode and optional name list
- Implicit typing rules are recorded as letter→type mappings (or `scope.implicit_typing = 'none'/'default'`)

**Condition status**:
- Partition: Layers 1–3 are covered. **Layer 4 (declarations) is still a gap** — declaration statements within the spec part have no fact table rows.
- Grammar: `use_stmt` → R1409, `import_stmt` → R1514, `implicit_rule` → R863. Each table identity uniquely determines its production. **Condition 2 holds for Layers 1–3.**
- Dependency: USE → IMPORT → IMPLICIT matches the grammar ordering (R504) and the semantic dependency chain. **Condition 3 holds for Layers 1–3.**

**Progress**: three of four layers satisfy all three conditions. One layer remains.

## v0.1.3b: execution part (parallel branch)

**New tables**: `control_region` (CCT), `semantic_basic_block` + `sbb_edge` (CFG).

**What it established**:
- The execution part's unbounded control construct nesting is modeled as a self-referential tree (control_region)
- The CFG is derived as a flat partition of execution lines into basic blocks with typed edges

**Relevance to spec coordinate system**: none directly. This branch addresses the execution part. But it completes the picture: both halves of the scope (spec and exec) now have structural indexing.

## v0.1.3: merge

**Contents**: MERGE file listing parents 0.1.3a and 0.1.3b.

The merged state has structural indexing for both the specification part (Layers 1–3) and the execution part (CCT + CFG). The specification part still has a gap at Layer 4.

## v0.1.4a: Layer 4 — declaration constructs

**New table**: `declaration_construct` — 18 construct kinds, each with line span and ordinal.

**What it established**:
- Every declaration in the specification part has a unique row: `(construct_id, scope_id, construct, name, ordinal, start_line, end_line)`
- The 18 construct kinds cover all grammar productions under R507/R508

**Condition 1 — Complete partition**: with this table, every line in the specification part belongs to exactly one of:
- The scope's opening statement
- A `use_stmt` row (Layer 1)
- An `import_stmt` row (Layer 2)
- An implicit statement (Layer 3, addressed by `scope.implicit_typing`)
- A `declaration_construct` row (Layer 4)

The partition is complete. No semantically significant statement is unindexed.

**Condition 2 — Kind-determined grammar**: every construct kind maps to exactly one grammar production:

| Kind | Production |
|---|---|
| `derived_type_def` | R726 |
| `interface_block` | R1501 |
| `enum_def` | R759 |
| `type_declaration` | R801 |
| `generic_stmt` | R1510 |
| `procedure_decl` | R1512 |
| `parameter_stmt` | R855 |
| `access_stmt` | R827 |
| `attribute_stmt` | R813 (one-token sub-dispatch) |
| `common_stmt` | R873 |
| `equivalence_stmt` | R870 |
| `namelist_stmt` | R868 |
| `external_stmt` | R1519 |
| `intrinsic_stmt` | R1519 |
| `data_stmt` | R837 |
| `format_stmt` | R1001 |
| `entry_stmt` | R1541 |
| `stmt_function` | R1544 |

The mapping is injective. `attribute_stmt` requires one-token sub-dispatch among R813's sub-productions, which is bounded and deterministic.

**Condition 3 — Layered dependency order**: the four layers respect semantic dependency:
- Layer 1 (USE) depends on nothing within this scope
- Layer 2 (IMPORT) depends on Layer 1
- Layer 3 (IMPLICIT) depends on Layers 1–2
- Layer 4 (declarations) depends on Layers 1–3

This matches the grammar's syntactic ordering (R504). No circular dependencies.

**All three conditions are satisfied.** The fact table system is a complete coordinate system for the specification part.

## Summary: condition fulfillment by version

| Version | Partition | Grammar | Dependency | Status |
|---|---|---|---|---|
| 0.1.0 | Scope-level only | No dispatch | No layering | Incomplete |
| 0.1.1 | Structural scopes (bounded) | No dispatch | Containment only | Incomplete |
| 0.1.2 | + spec/exec/subprogram split | Part-level only | Implicit ordering | Incomplete |
| 0.1.3 | + Layers 1–3 indexed | Layers 1–3 OK | Layers 1–3 OK | 3/4 layers done |
| 0.1.4a | + Layer 4 indexed | All layers OK | All layers OK | **Complete** |

## The complete fact table stack

```
source_code (view)                    raw lines: (filename, lineno, line)
  │
  └─ scope                            structural scopes: 8 kinds, containment tree
       │
       ├─ scope_part                   spec / exec / subprogram line ranges
       │    │
       │    ├─ [spec] use_stmt         Layer 1: USE associations
       │    │           └─ use_entity       per-entity rename/only
       │    │
       │    ├─ [spec] import_stmt      Layer 2: IMPORT controls
       │    │           └─ import_entity    per-name import list
       │    │
       │    ├─ [spec] implicit_rule    Layer 3: letter→type mappings
       │    │
       │    ├─ [spec] declaration_construct   Layer 4: 18 construct kinds
       │    │
       │    └─ [exec] control_region   control construct tree (CCT)
       │                └─ semantic_basic_block + sbb_edge   CFG partition
       │
       └─ (parent_scope_id, ancestor_scope_id)   containment + submodule lineage
```

**12 tables + 1 view.** Every table has line ranges back to `source_code`. The specification part is fully indexed.
