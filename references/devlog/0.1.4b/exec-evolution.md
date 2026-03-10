# exec-part evolution — building the coordinate system

How the fact table system evolved from v0.1.0 to v0.1.4b for the execution part, and how each step addresses the three coordinate system conditions (complete partition, kind-determined grammar, layered dependency order).

## v0.1.0: source lines and raw scope

**Tables**: `source_code` (view), `scope` (13 kinds)

**What it established**:
- Every source line has a unique address: `(filename, lineno)`
- Every line belongs to exactly one scope via `[start_line, end_line]`
- Conceptual documents: `cfg.md` (control flow construct catalog), `semantic-basic-block.md` (meet of CFG and scoping partitions)

**Condition status**:
- Partition: scopes cover all lines, but execution-part lines are undifferentiated — no internal structure
- Grammar: scope kind does not determine a grammar production for internal executable statements
- Dependency: no layering — everything is flat

**Gap**: the execution part is a black box. The two orthogonal internal structures (control flow and name bindings) are recognized conceptually but not yet modeled.

## v0.1.1: structural scope only

**Changes**: scope narrowed from 13 to **8 structural kinds**. Schema design methodology documented.

**What it established**:
- Structural scopes nest at most ~3 levels (global → module → function). Bounded. No left-recursion.
- Internal constructs (BLOCK, FORALL, DO_CONCURRENT) explicitly deferred to a future control-region table

**Condition status**:
- Partition: structural scopes partition all lines, but execution-part lines within a scope are undifferentiated
- Grammar: still no production dispatch within the execution part
- Dependency: `parent_scope_id` gives structural containment, but no exec-part layering

**Progress**: the unbounded-nesting problem is identified and deferred to a dedicated table, following the left-recursion principle.

## v0.1.2: specification / execution split

**New table**: `scope_part` — segments each scope into specification, execution, and subprogram regions.

**What it established**:
- Within each scope, every line belongs to one of three parts
- The execution part is now a named, bounded region with line ranges
- A parser can locate the execution part: `scope_part WHERE part = 'execution'`

**Condition status**:
- Partition: scope × part covers all lines. But within the execution part, individual statements and constructs are not indexed.
- Grammar: `part = 'execution'` tells you "this is exec" but not which grammar production applies to each construct or statement
- Dependency: the three parts (spec → exec → subprogram) have an implicit ordering, but no internal layering within the exec part

**Progress**: the execution part is locatable by line range. Ready for internal structuring.

## v0.1.3b: execution-part internal structure

**New tables**: `control_region` (CCT), `semantic_basic_block` + `sbb_edge` (CFG).

**What it established**:
- Every control construct in the execution part has a unique `control_region` row with kind, binding_kind, and line range
- The control construct tree (CCT) is encoded as a self-referential table via `parent_region_id`
- Every execution-part line belongs to exactly one SBB (leaf-level partition)
- Control flow edges between SBBs are encoded in `sbb_edge` (8 edge kinds)
- Binding-changing constructs are annotated with `binding_kind` for environment recovery

**Condition status**:
- Partition: **satisfied** — SBBs tile each execution part completely
- Grammar: **satisfied** — control_region kind maps to grammar production; SBBs parse as action-stmt sequences with keyword dispatch
- Dependency: **satisfied** — environment at any SBB recoverable by walking the ancestor chain: `env(SBB) = spec_env(scope) ∘ Δ(ancestor₁) ∘ ... ∘ Δ(ancestorₖ)`

**Progress**: all three conditions are met. The execution part has a complete coordinate system.

## v0.1.4b: completeness verification and computed table catalog

**What this version establishes**:
- Formal verification of the three conditions against the exec-part fact tables
- Catalog of the five computed tables that semantic analysis produces at fact-table coordinates
- Consolidation of v0.1.3b's two SQL files into a single `exec-fact.sql` with coordinate system queries

No new tables are introduced. The fact tables stop at v0.1.3b's schema.

## Summary: condition fulfillment by version

| Version | Partition | Grammar | Dependency | Status |
|---|---|---|---|---|
| 0.1.0 | Scope-level only | No dispatch | No layering | Incomplete |
| 0.1.1 | Structural scopes (bounded) | No dispatch | Containment only | Incomplete |
| 0.1.2 | + spec/exec/subprogram split | Part-level only | Implicit ordering | Incomplete |
| 0.1.3b | + SBBs tile exec part | Region kinds + keyword dispatch | Tree-compositional | **Complete** |
| 0.1.4b | (verification) | (verification) | (verification) | **Verified** |

## The complete fact table stack (execution branch)

```
source_code (view)                    raw lines: (filename, lineno, line)
  │
  └─ scope                            structural scopes: 8 kinds, containment tree
       │
       └─ scope_part                   spec / exec / subprogram line ranges
            │
            └─ [exec] control_region   control construct tree (CCT)
                 │                       13 construct kinds, binding annotations
                 │                       self-referential nesting via parent_region_id
                 │
                 └─ semantic_basic_block   leaf-level partition of execution lines
                      │
                      └─ sbb_edge          control flow edges (8 kinds)
```

**6 tables + 1 view** (shared with the spec branch). Every table has line ranges back to `source_code`. The execution part is fully indexed.
