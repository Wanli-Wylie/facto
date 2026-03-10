# semantic basic block — design notes

## Motivation

A traditional **basic block** is defined purely by control flow: a maximal sequence of statements with no internal branches and no branch targets. This is sufficient for compiler optimizations but insufficient for program understanding, because two adjacent statements in the same basic block may resolve the same name to different entities.

Consider:

```fortran
SUBROUTINE example(x)
  REAL :: x, y
  y = x + 1.0           ! (1) y, x resolve in subroutine scope
  BLOCK
    INTEGER :: y         ! shadows outer y
    y = INT(x)           ! (2) y resolves to local INTEGER y
    PRINT *, y           ! (3) same local y
  END BLOCK
  PRINT *, y             ! (4) y resolves back to outer REAL y
END SUBROUTINE
```

Statements (1)–(4) form a single traditional basic block (no branches). But the name `y` refers to different entities at (1)/(4) versus (2)/(3). A name-resolution analysis that treats this as one block will conflate two distinct bindings.

The **semantic basic block** refines the traditional basic block by additionally breaking at scope boundaries, so that every statement in a semantic basic block shares both:
1. The same **control flow context** — no internal branches or branch targets
2. The same **name-binding environment** — identical name resolution rules

## Definition

> A **semantic basic block** is a maximal contiguous sequence of statements such that:
> - No statement (except possibly the first) is a branch target or the entry point of a control construct
> - No statement (except possibly the last) transfers control to a non-successor statement
> - All statements share the same **scoping unit** (i.e., they resolve names against the same scope in the scope table)

Equivalently: take the traditional CFG basic blocks and split them at every scope boundary.

## Formal construction

Given:
- The traditional CFG basic blocks B = {b₁, b₂, ...} for a program unit
- The scope tree S from the scope table (parent_scope_id hierarchy)

The semantic basic blocks are computed as:

```
SBB = { b ∩ s | b ∈ B, s ∈ S, b ∩ s ≠ ∅ }
```

where b ∩ s means the subset of statements in basic block b that belong to scoping unit s (determined by line ranges `[start_line, end_line]`).

This is a **refinement** of both partitions:
- Every semantic basic block is contained within exactly one traditional basic block
- Every semantic basic block is contained within exactly one scoping unit
- The total number of semantic basic blocks ≥ max(|B|, |S|)

## What introduces scope boundaries?

From the scope table's `kind` enumeration, the constructs that introduce scope boundaries within a procedure are:

| Construct | scope.kind | Also a CFG boundary? |
|---|---|---|
| BLOCK | `block` | **No** — sequential control flow |
| DO CONCURRENT | `do_concurrent` | Yes — loop back-edge |
| FORALL | `forall` | Yes — loop-like |
| Nested subprogram (CONTAINS) | `function` / `subroutine` | Yes — separate CFG |
| Derived type definition | `derived_type` | N/A — not executable |

The critical case is **BLOCK**: it introduces a scope boundary but NOT a control flow boundary. This is the only case where semantic basic blocks differ from traditional basic blocks within straight-line code.

ASSOCIATE, SELECT TYPE, and SELECT RANK introduce construct entities (new name bindings) but the standard does not classify them as separate scoping units. For a conservative semantic basic block definition, we could treat them as scope boundaries too; the scope table currently does not, but a future refinement could add them.

## The partition in practice

For modern, well-structured Fortran code, the semantic basic block partition typically adds very few extra splits beyond the traditional CFG, because:

1. Most scope boundaries coincide with control flow boundaries (DO CONCURRENT, FORALL, internal procedures)
2. BLOCK constructs in straight-line code are the main source of "extra" splits
3. Legacy Fortran (F77) has no BLOCK construct, so traditional and semantic basic blocks are identical

For modern Fortran with heavy use of BLOCK (common in refactored scientific codes), the refinement is significant.

## Properties

### Uniform name resolution
Every statement in a semantic basic block resolves names against the same scope. This means:
- A single symbol table snapshot suffices for the entire block
- No mid-block re-resolution is needed
- Host association, USE association, and IMPLICIT rules are fixed within the block

### Composability with the scope table
Each semantic basic block maps to exactly one `scope_id` in the scope table. This gives a clean join:

```sql
SELECT sbb.block_id, s.scope_id, s.kind, s.name, s.implicit_typing
FROM   semantic_basic_block sbb
JOIN   scope s ON sbb.scope_id = s.scope_id;
```

### Refinement ordering
The three partitions form a refinement lattice:

```
statements (finest)
    ↑ refines
semantic basic blocks
    ↑ refines
traditional basic blocks    ∧    scoping units
    ↑ refines                    ↑ refines
program unit (coarsest)
```

Semantic basic blocks are the **meet** (greatest lower bound) of the traditional basic block partition and the scoping unit partition.

## Relationship to the bipartite access graph

The bipartite access graph G_BA = (BB, OBJ, E_R, E_W) from the pipeline design uses basic blocks as one vertex set. Replacing traditional basic blocks with semantic basic blocks strengthens the analysis:

1. **Sharper read/write attribution**: when a name `y` refers to different objects in different scopes, traditional basic blocks would conflate the accesses. Semantic basic blocks correctly separate them.

2. **Cleaner FCA contexts**: each semantic basic block has an unambiguous set of accessed objects, making formal concept analysis more precise.

3. **Pattern mining**: frequent patterns mined within semantic basic blocks are guaranteed to operate under consistent name bindings, so extracted idioms are semantically coherent.

## Proposed schema

```sql
CREATE TABLE IF NOT EXISTS semantic_basic_block (
    sbb_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    scope_id     BIGINT NOT NULL,
    filename     TEXT   NOT NULL,
    start_line   INTEGER NOT NULL,
    end_line     INTEGER NOT NULL,
    predecessor_count INTEGER,     -- in-degree in CFG (for analysis)
    successor_count   INTEGER,     -- out-degree in CFG

    CONSTRAINT fk_sbb_scope
        FOREIGN KEY (scope_id) REFERENCES scope (scope_id)
);

CREATE INDEX IF NOT EXISTS idx_sbb_scope ON semantic_basic_block (scope_id);
CREATE INDEX IF NOT EXISTS idx_sbb_file  ON semantic_basic_block (filename);
```

The CFG edges between semantic basic blocks:

```sql
CREATE TABLE IF NOT EXISTS sbb_edge (
    from_sbb_id  BIGINT NOT NULL,
    to_sbb_id    BIGINT NOT NULL,
    edge_kind    TEXT NOT NULL,   -- 'fallthrough', 'branch_true', 'branch_false',
                                  -- 'loop_back', 'loop_exit', 'jump', 'return'
    PRIMARY KEY (from_sbb_id, to_sbb_id, edge_kind),

    CONSTRAINT fk_edge_from FOREIGN KEY (from_sbb_id)
        REFERENCES semantic_basic_block (sbb_id),
    CONSTRAINT fk_edge_to   FOREIGN KEY (to_sbb_id)
        REFERENCES semantic_basic_block (sbb_id)
);
```

## Worked example

```fortran
SUBROUTINE process(a, n)
  IMPLICIT NONE
  INTEGER, INTENT(IN) :: n
  REAL, INTENT(INOUT) :: a(n)
  INTEGER :: i
  REAL :: total

  total = 0.0                          ! SBB-1: scope=process
  DO i = 1, n                         !         (loop header is CFG boundary)
    IF (a(i) > 0.0) THEN              ! SBB-2: scope=process (loop body, before branch)
      BLOCK                            !
        REAL :: scaled                 !
        scaled = a(i) * 2.0           ! SBB-3: scope=block (new scope, straight-line)
        a(i) = scaled                  !         (same SBB — no branch, same scope)
      END BLOCK                        !
    ELSE                               !
      a(i) = 0.0                       ! SBB-4: scope=process (else branch)
    END IF                             !
  END DO                               ! SBB-5: scope=process (after loop)
  PRINT *, total                       !         (same SBB — sequential, same scope)
END SUBROUTINE
```

Traditional basic blocks: 5 (split at DO, IF, ELSE, END IF/END DO, after loop)
Semantic basic blocks: 5 (same count here because the BLOCK is inside an IF branch that already creates a block boundary)

But if the BLOCK were in straight-line code:

```fortran
  total = 0.0                          ! SBB-A: scope=process
  BLOCK
    REAL :: temp
    temp = total + 1.0                 ! SBB-B: scope=block (split! same trad. BB)
  END BLOCK
  PRINT *, total                       ! SBB-C: scope=process (split! same trad. BB)
```

Traditional basic blocks: 1 (all straight-line)
Semantic basic blocks: 3 (split at BLOCK entry and exit)

## Summary

| Concept | Boundary criterion | Granularity |
|---|---|---|
| Traditional basic block | Control flow edges | Coarser |
| Scoping unit | Name-binding environment changes | Orthogonal |
| **Semantic basic block** | Either of the above | **Finer (meet of both)** |

The semantic basic block is the natural unit of analysis for a system that needs to understand both what a piece of code *does* (data flow, accessed objects) and what names *mean* (scope, binding). It is the right vertex set for the bipartite access graph when precise name resolution matters.
