# exec-part coordinate system — verifying the three conditions

The three conditions for a complete coordinate system — (1) complete partition, (2) kind-determined grammar, (3) layered dependency order — are defined in `0.1.4a/coordinate-system.md`. This document verifies them for the execution part.

## Condition 1: Complete partition

Every source line in the execution part must belong to exactly one leaf-level fact table row.

**Verification.** The `semantic_basic_block` table partitions each execution part exhaustively. Every line in `scope_part WHERE part = 'execution'` belongs to exactly one SBB row via `[start_line, end_line]`. No gaps, no overlaps.

Convention B (every construct boundary starts a new SBB) ensures that construct headers and trailers are SBB boundaries, preventing any line from falling between SBBs.

**Weakened form applies:** blank lines and comments need not be covered. Every executable statement is indexed.

**Status: satisfied.**

## Condition 2: Kind-determined grammar

For each fact table row, its kind must uniquely determine the grammar production that governs the content within that row's line range.

**Verification at two levels:**

**Control regions.** Each `control_region` row has a `kind` that maps to exactly one grammar production:

| Kind | Production |
|---|---|
| `if` | R1042 (IF construct) |
| `select_case` | R1148 (CASE construct) |
| `select_type` | R1152 (SELECT TYPE construct) |
| `select_rank` | R1156 (SELECT RANK construct) |
| `do` | R1120 (DO construct) |
| `do_while` | R1120 (DO WHILE form) |
| `do_concurrent` | R1120 (DO CONCURRENT form) |
| `forall` | R1050 (FORALL construct) |
| `where` | R1043 (WHERE construct) |
| `block` | R1107 (BLOCK construct) |
| `associate` | R1103 (ASSOCIATE construct) |
| `critical` | R1116 (CRITICAL construct) |
| `change_team` | R1111 (CHANGE TEAM construct) |

The mapping is injective. Each kind uniquely determines how to parse the construct's header, body structure, and trailer.

**Semantic basic blocks.** An SBB does not have a per-row `kind` — it is always a maximal sequence of action statements. The applicable grammar production is `executable-stmt` (R213), with per-statement keyword dispatch among the 38 action statement types (R214–R515).

This is analogous to `attribute_stmt` in the spec part: one kind that requires bounded, deterministic sub-dispatch. The leading keyword of each statement (CALL, READ, WRITE, assignment-target, etc.) determines the specific production. No lookahead or trial-and-error is needed.

**Structural difference from the spec part:** in the spec part, each `declaration_construct` row is one construct with one production (18 kinds → 18 productions). In the exec part, each SBB row contains a *sequence* of statements, each with its own production. The partition is coarser — the SBB is a group, not an individual statement.

This is deliberate. Finer partitioning (one row per statement) would not add structural information — it would only subdivide already-located text. The SBB is the natural leaf because it is the unit where control flow context and name-binding environment are uniform.

**Status: satisfied** (with the noted structural asymmetry).

## Condition 3: Layered dependency order

The fact tables must be organized so that the name-binding environment at any point can be reconstructed by processing layers in order.

**Verification.** The exec part's dependency structure is **tree-compositional** rather than linearly layered:

```
env(SBB) = spec_env(scope) ∘ Δ(ancestor₁) ∘ ... ∘ Δ(ancestorₖ)
```

where the ancestors are the binding-changing `control_region` rows along the containment path from the SBB to the scope root.

The dependency is acyclic (tree-shaped — each region has at most one parent). The environment at any SBB is recoverable by:

1. Start with the scope's specification-part environment (Layers 1–4 from v0.1.4a)
2. Walk the `control_region` ancestor chain via `parent_region_id`
3. At each binding-changing ancestor, compose its name-binding delta:
   - `full_scope` (BLOCK): own specification part (USE, IMPLICIT, declarations)
   - `construct_index` (DO CONCURRENT, FORALL): index variable bindings
   - `construct_entity` (ASSOCIATE, SELECT TYPE/RANK): construct entity bindings

No circular dependencies. Each delta depends only on the region's own header/body and the ancestor environments above it.

**Structural difference from the spec part:** the spec part has four linear layers (USE → IMPORT → IMPLICIT → declarations) processed in sequence. The exec part has tree-compositional layers processed along the containment path. Both are acyclic; the exec form is a generalization.

**Status: satisfied** (in tree-compositional form).

## Summary

| Condition | Spec part (0.1.4a) | Exec part (0.1.4b) |
|---|---|---|
| 1. Complete partition | `declaration_construct` (one row per construct) | `semantic_basic_block` (one row per basic block) |
| 2. Kind-determined grammar | 18 construct kinds → 18 productions | 13 region kinds → 13 productions; SBB → action-stmt sequence with keyword dispatch |
| 3. Layered dependency | 4 linear layers (USE → IMPORT → IMPLICIT → decl) | Tree-compositional (scope env + ancestor chain deltas) |

All three conditions are satisfied for the execution part. The fact tables — `source_code`, `scope`, `scope_part`, `control_region`, `semantic_basic_block`, `sbb_edge` — form a complete coordinate system. Everything beyond is a computed table derived from source text at these coordinates.
