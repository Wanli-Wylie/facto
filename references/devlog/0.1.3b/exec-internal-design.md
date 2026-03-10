# execution-part internal structure — design notes (v0.1.3b)

## What this version adds

Two new tables decompose the execution part's internal structure:

| Table | Role | Structure |
|---|---|---|
| `control_region` | Control construct tree (CCT) — the nesting of IF, DO, BLOCK, etc. | Self-referential tree (unbounded depth) |
| `semantic_basic_block` | Flat partition of the execution part into uniform-environment, straight-line segments | Flat table (one row per SBB) |
| `sbb_edge` | CFG edges between SBBs | Edge table keyed to SBB |

These resolve the deferral from v0.1.1 (schema-design.md §deferred): "Internal sub-scoping (BLOCK, FORALL, DO CONCURRENT) → Control-region tree or object model."

## How the tables fit the existing schema

The full table hierarchy is now:

```
source_code (v0.1.0)          ← source text, the universal coordinate system
  ↑ join via (filename, lineno)
scope (v0.1.1)                ← structural scopes (8 kinds, bounded depth ~3)
  ├── scope_part (v0.1.2)    ← spec / exec / subprogram line extents
  ├── control_region (v0.1.3b) ← CCT within each execution part
  │     └── (self-referential: parent_region_id)
  └── semantic_basic_block (v0.1.3b) ← flat partition of each execution part
        └── sbb_edge (v0.1.3b)       ← CFG edges between SBBs
```

Containment between any two entities across these tables is determined by line-range inclusion:

```
A contains B  ⟺  A.filename = B.filename
                  AND A.start_line ≤ B.start_line
                  AND B.end_line ≤ A.end_line
```

The explicit FKs (`scope_id`, `parent_region_id`, `region_id`) are optimizations for efficient joins. The line ranges are the ground truth.

## Design decisions

### 1. Two tables, not one

The execution part's internal structure has two useful representations:

- **Tree** (control_region): preserves nesting, supports environment composition along root-to-leaf paths, needed by Stages 2–3 (call graph, driver generation)
- **Flat partition** (semantic_basic_block + sbb_edge): linearized CFG, directly usable by Stage 4 (data flow) and pattern mining (bipartite BB × OBJ graph)

Neither subsumes the other. The tree captures nesting structure that the flat partition loses; the flat partition provides CFG edges that the tree does not encode. Maintaining both follows the same pattern as `scope` (tree) + `scope_part` (flat annotation).

### 2. control_region stores constructs, not statements

Each `control_region` row is one control construct (IF, DO, BLOCK, etc.). Action statements (assignment, CALL, I/O, etc.) are NOT rows in this table — they live within SBBs.

Rationale: action statements are the leaves of the CCT, and they number in the thousands per procedure. Storing each as a control_region row would inflate the table with leaf nodes that have no children, no binding changes, and no structural role. The SBB table already partitions the execution part into leaf-level segments; individual statements within an SBB can be extracted from the source text via line ranges.

### 3. binding_kind is explicit despite being determined by kind

The mapping `kind → binding_kind` is a functional dependency:

| kind | binding_kind |
|---|---|
| `block` | `full_scope` |
| `do_concurrent`, `forall` | `construct_index` |
| `associate`, `select_type`, `select_rank` | `construct_entity` |
| all others | `none` |

We store `binding_kind` explicitly because it is the primary query axis for name-resolution: "which ancestors of this SBB change bindings?" is `WHERE binding_kind != 'none'` without enumerating kinds. The functional dependency is documented; the application layer or a CHECK trigger can enforce it.

### 4. construct_name on control_region

Fortran constructs can be named (`outer: DO i = 1, n`). The name is used by CYCLE/EXIT to target specific enclosing loops. It has construct scope — visible only within the construct.

`construct_name` is nullable (most constructs are unnamed). It participates in the naming system: resolving `EXIT outer` requires finding the control_region with `construct_name = 'outer'` that encloses the EXIT statement.

### 5. region_id on semantic_basic_block

Each SBB has a nullable FK to the **innermost** enclosing control_region. NULL means the SBB is at the top level of the execution part (not inside any construct).

This FK is an optimization: the innermost enclosing region is also determinable by line-range containment, but a direct FK avoids the range scan. The full ancestor chain is recoverable by walking `parent_region_id` from the pointed-to region.

### 6. ENTRY and EXIT SBBs

Each executable scope has two synthetic SBBs:

- **ENTRY SBB**: `start_line = end_line = scope's first executable line`. Has a `fallthrough` edge to the first real SBB. For procedures with ENTRY statements, additional ENTRY SBBs exist (one per ENTRY point).
- **EXIT SBB**: `start_line = end_line = scope's END line`. Receives `return` edges from RETURN/STOP/ERROR STOP statements and the implicit return at END.

This avoids nullable `to_sbb_id` in the edge table and makes the CFG complete (single entry, single exit per scope, except for ENTRY-using procedures).

### 7. sbb_edge is within a single scope

All edges in `sbb_edge` connect SBBs within the same structural scope (intraprocedural CFG). Interprocedural edges (call → callee) will be in the future `call_edge` table (Stage 2).

## Relationship to the naming system

The naming system operates in parallel:

| Named entities | Introduced by | Future table | Keyed to |
|---|---|---|---|
| Variables, types, interfaces, procedures | Structural scope's specification part | `declaration` | `scope.scope_id` |
| BLOCK-local declarations | BLOCK's specification part | `declaration` (extended) | `control_region.region_id` where `binding_kind = 'full_scope'` |
| DO CONCURRENT / FORALL index variables | Construct header | construct entity record | `control_region.region_id` where `binding_kind = 'construct_index'` |
| ASSOCIATE names, SELECT TYPE/RANK selector | Construct header | construct entity record | `control_region.region_id` where `binding_kind = 'construct_entity'` |

Name resolution at any source line walks outward through containing line ranges: innermost binding-changing control_region first, then upward through parent regions, then the structural scope's declarations.

The exact table design for construct entities (BLOCK locals, index variables, associate-names) is deferred. Options:

1. Extend the future `declaration` table to accept `region_id` as an alternative key (for BLOCK locals)
2. Create a separate `construct_entity` table keyed to `region_id`
3. Store construct entities as properties of the control_region row (for the closed-form cases: index variables and associate-names are enumerable from the construct header)

This decision depends on the `declaration` table design, which belongs to the specification-semantics branch (v0.1.3a).

## What is deferred

| Concept | Why deferred | When addressed |
|---|---|---|
| Multi-arm modeling (IF then/else, CASE blocks) | Arms are implicit in the line ranges and CFG edges; explicit arm rows add complexity without clear need yet | When Stage 4 (data flow) requires arm-level granularity |
| Statement-level rows | Action statements within SBBs are not individual rows; extracted from source via line ranges | When pattern mining needs per-statement access patterns |
| Declaration/construct entity tables | Depends on specification-semantics branch (v0.1.3a) designing the `declaration` table | v0.1.4 merge or later |
| Non-local jump resolution | GOTO targets, named CYCLE/EXIT resolution require label/name lookup | When CFG construction is implemented |

## Version history

| Version | Changes |
|---|---|
| 0.1.0 | `source_code` layer. `scope` with 13 kinds. `cfg.md`, `semantic-basic-block.md` concepts. |
| 0.1.1 | Narrow scope to 8 structural kinds. Defer BLOCK/FORALL/DO_CONCURRENT to control-region table. |
| 0.1.2 | Add `scope_part` (spec/exec/subprogram line extents). |
| 0.1.3a | Specification-semantics characterization (4 layers). |
| 0.1.3b | Execution-semantics characterization. **`control_region`** (CCT), **`semantic_basic_block`** + **`sbb_edge`** (flat CFG partition). |
