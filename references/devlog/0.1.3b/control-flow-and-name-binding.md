# control flow and name-binding structure within the execution part

## The problem

The execution part has two orthogonal internal structures:

1. **Control flow** — branching, looping, and sequential composition determine which statements execute and in what order
2. **Name bindings** — certain constructs change the name-resolution environment, introducing new names or shadowing existing ones

These two structures are independent: some constructs change control flow without affecting bindings (IF, DO), some change bindings without affecting control flow (BLOCK), and some change both (DO CONCURRENT). The execution part's internal representation must capture both dimensions.

v0.1.1 deferred this problem: BLOCK, FORALL, and DO CONCURRENT were removed from the structural scope table and assigned to a "future control-region table" (schema-design.md §3, §deferred). The semantic basic block concept (v0.1.0) identified the issue — the name-binding environment can change mid-basic-block — but defined the solution abstractly (the meet of two partitions). This document drills down into the concrete structure.

## The control construct tree

### Grammar foundation

The execution part (F2018 R509) is a sequence of executable constructs (plus FORMAT, DATA, ENTRY). Each executable construct (R514) is either an **action statement** (leaf) or one of twelve **control constructs** (subtree):

```
executable-construct =
    action-stmt
  | if-construct         | case-construct          ← conditional / multi-way
  | select-type-construct | select-rank-construct   ← dispatch
  | do-construct         | forall-construct         ← loop / iteration
  | where-construct                                 ← masked assignment
  | block-construct      | associate-construct      ← sequential + binding
  | critical-construct   | change-team-construct    ← sequential (coarray)
```

Control constructs nest within control constructs to arbitrary depth. The result is a tree.

### Definition

The **control construct tree** (CCT) of an execution part is a rooted, ordered tree where:

- **Root**: the execution part itself (a sequence node)
- **Internal nodes**: control constructs, each containing one or more **arms** (ordered child sequences)
- **Leaves**: action statements (plus FORMAT, DATA, ENTRY)

Reading the leaves left-to-right recovers the source statement sequence. The tree encodes the nesting.

### Arm structure

Each control construct organizes its children into one or more **arms** — the distinct child sequences it contains. At runtime, control flow determines which arms execute.

| Construct | Arms | Runtime semantics |
|---|---|---|
| IF | then, [elseif₁, ...], [else] | Exactly one arm executes |
| SELECT CASE | case₁, case₂, ..., [default] | Exactly one arm executes |
| SELECT TYPE | type-guard₁, ..., [class-default] | Exactly one arm executes |
| SELECT RANK | rank-case₁, ..., [rank-default] | Exactly one arm executes |
| DO / DO WHILE | body | Body repeats zero or more times |
| DO CONCURRENT | body | Body executes for each index combination, unordered |
| FORALL | body | Body executes for each index combination (array semantics) |
| WHERE | where-body, [elsewhere₁, ...] | Element-wise: each array element takes one arm |
| BLOCK | body | Body executes once |
| ASSOCIATE | body | Body executes once |
| CRITICAL | body | Body executes once (mutual exclusion across images) |
| CHANGE TEAM | body | Body executes once (in new team context) |

Multi-arm constructs (IF, SELECT *, WHERE) are **branching nodes** — control flow selects among their arms. Single-arm constructs (DO, BLOCK, ASSOCIATE, CRITICAL, CHANGE TEAM) are **sequence/loop nodes** — control flow enters and exits through a single body.

### Nesting depth

The CCT has **unbounded depth**. This is the left-recursion property identified in v0.1.1:

```fortran
DO i = 1, n              ! depth 1
  IF (mask(i)) THEN      ! depth 2
    BLOCK                 ! depth 3
      DO CONCURRENT (j = 1:m)  ! depth 4
        IF (a(i,j) > 0) THEN   ! depth 5
          ...                    ! arbitrary further nesting
```

This contrasts with the structural scope tree (bounded at ~3 levels). Practical depths in scientific codes range from 3–8 (typical) to 15+ (deeply nested legacy).

## Name-binding changes within the execution part

### The standard's hierarchy

The Fortran 2018 standard defines a hierarchy of name-introduction mechanisms relevant to the execution part:

**1. Scoping unit (F2018 §19.2)**

A scoping unit has its own specification part — it can introduce USE statements, IMPLICIT rules, and arbitrary declarations. Within the execution part, only **BLOCK** is a scoping unit.

```fortran
BLOCK
  USE special_mod, ONLY: helper    ! new USE association
  IMPLICIT NONE                     ! override implicit rules
  REAL :: temp                      ! new local variable
  temp = compute(x)
  CALL helper(temp)
END BLOCK
! temp and helper are gone
```

BLOCK is a **full binding reset**: the environment inside is the host environment extended (and potentially shadowed) by the BLOCK's own specification part. Every kind of declaration permitted in a procedure is permitted in a BLOCK.

**2. Construct scope (F2018 §19.4)**

Certain construct entities have "construct scope" — they exist only within the construct body. Unlike scoping units, no specification part is permitted; only the specific entities named by the construct are introduced.

- **DO CONCURRENT / FORALL index variables**: the index variable is a new entity that may shadow a host variable of the same name.

```fortran
INTEGER :: i = 42
DO CONCURRENT (i = 1:n)
  ! this i is a DIFFERENT entity from the outer i
  a(i) = b(i) + 1.0
END DO
! i is still 42 — the construct's i was a distinct entity
```

- **ASSOCIATE associate-names**: each associate-name is a new entity aliasing an expression.

```fortran
ASSOCIATE (norm => SQRT(DOT_PRODUCT(v, v)))
  ! norm exists only here, aliasing the expression
  PRINT *, norm
END ASSOCIATE
! norm is gone
```

- **SELECT TYPE / SELECT RANK selector**: within each type-guard or rank-case block, the selector variable has a narrowed type or specific rank. The standard treats this as a construct entity.

```fortran
SELECT TYPE (x => polymorphic_var)
  TYPE IS (INTEGER)
    ! x is known to be INTEGER — its type is narrowed
  CLASS IS (base_t)
    ! x is known to be CLASS(base_t)
END SELECT
```

**3. No binding change**

All other constructs (IF, SELECT CASE, DO, DO WHILE, WHERE, CRITICAL, CHANGE TEAM) do not introduce any new names. The environment inside is identical to the environment outside.

### Summary of the hierarchy

| Level | Mechanism | Constructs | What changes |
|---|---|---|---|
| Full scoping unit | Own specification part | BLOCK | Anything: USE, IMPLICIT, variables, types, interfaces |
| Construct scope | Named construct entities | DO CONCURRENT, FORALL (index); ASSOCIATE (alias); SELECT TYPE, SELECT RANK (narrowing) | Only the specific construct entities |
| None | — | IF, SELECT CASE, DO, DO WHILE, WHERE, CRITICAL, CHANGE TEAM | Nothing |

The difference between levels 1 and 2 is significant:
- BLOCK can contain arbitrary declarations — the binding change is open-ended
- Construct-scope entities are fixed by the construct header — the binding change is closed-form (enumerable from the construct's syntax)

## Two-dimensional classification

Every control construct is classified along both dimensions independently:

| Construct | Control flow | Name-binding change |
|---|---|---|
| IF | Conditional branch | None |
| SELECT CASE | Multi-way branch | None |
| SELECT TYPE | Multi-way branch | Construct entity (type narrowing, per arm) |
| SELECT RANK | Multi-way branch | Construct entity (rank narrowing, per arm) |
| DO | Loop | None |
| DO WHILE | Loop | None |
| DO CONCURRENT | Unordered loop | Construct-scoped index |
| FORALL | Array iteration | Construct-scoped index |
| WHERE | Element-wise mask | None |
| BLOCK | Sequential | **Full scope** |
| ASSOCIATE | Sequential | Construct entity (alias) |
| CRITICAL | Sequential | None |
| CHANGE TEAM | Sequential | None |

Regrouped as a 2D matrix:

|  | No binding change | Construct entity | Full scope |
|---|---|---|---|
| **Sequential** | CRITICAL, CHANGE TEAM | ASSOCIATE | **BLOCK** |
| **Conditional** | IF | — | — |
| **Multi-way** | SELECT CASE | SELECT TYPE, SELECT RANK | — |
| **Loop** | DO, DO WHILE | DO CONCURRENT, FORALL | — |
| **Masked** | WHERE | — | — |

Key observation: **BLOCK is the only construct that changes bindings without changing control flow.** Every other binding-changing construct also introduces a control flow boundary (loop header, multi-way branch). This makes BLOCK the critical case that forces the two-dimensional analysis — without BLOCK, control flow boundaries alone would suffice as semantic basic block boundaries.

## Environment composition along CCT paths

The name-binding environment at any leaf (statement) in the CCT is determined **compositionally** by the path from root to leaf.

```
env(leaf) = spec_env(structural_scope)
             ∘ Δ(ancestor₁)
             ∘ Δ(ancestor₂)
             ∘ ...
             ∘ Δ(ancestorₖ)
```

where ancestor₁, ..., ancestorₖ are the CCT nodes on the path from root to leaf, and Δ(node) is the binding change:

| Node kind | Δ(node) |
|---|---|
| BLOCK | Extend with BLOCK's specification part (may shadow host names) |
| DO CONCURRENT | Add index variables (may shadow host names) |
| FORALL | Add index variables (may shadow host names) |
| ASSOCIATE | Add associate-names (may shadow host names) |
| SELECT TYPE arm | Narrow selector's type |
| SELECT RANK arm | Narrow selector's rank |
| All others | Identity (no change) |

This is Frege's principle applied within the execution part: the environment at a point is determined by the environments of the parts (each ancestor's contribution) and the rule of combination (sequential composition of binding changes along the path).

### Shadowing is well-defined

When a construct introduces a name that already exists in the host environment, the new name **shadows** the host name within the construct body. On exit, the host name is restored. The shadowing follows the same "most closely nested scope" rule used for structural scopes — the CCT path replaces the scope tree path for this purpose.

```fortran
REAL :: x = 1.0, y = 2.0         ! structural scope environment
BLOCK
  INTEGER :: x = 10               ! shadows outer x (different type!)
  PRINT *, x                      ! prints 10 (INTEGER)
  PRINT *, y                      ! prints 2.0 (from host — not shadowed)
END BLOCK
PRINT *, x                        ! prints 1.0 (REAL — host x restored)
```

### Environment depth along CCT paths

The number of binding changes on any root-to-leaf path is bounded by the number of binding-changing ancestors. In practice, this is much smaller than the CCT depth, because most constructs (IF, DO, SELECT CASE) do not change bindings. A typical path through 6 levels of nesting might have only 1–2 binding changes.

## Deriving the semantic basic block from the CCT

v0.1.0 defined the semantic basic block abstractly as the meet of CFG basic blocks and scoping units. The CCT gives a constructive derivation.

### Step 1: Linearize

Reading the CCT's leaves left-to-right gives the statement sequence.

### Step 2: Mark boundaries

A semantic basic block boundary occurs between two adjacent leaves when either:

1. **Control flow boundary**: the leaves belong to different arms of a branching or looping construct (the transition requires a control flow edge — branch, loop back-edge, or jump)
2. **Binding boundary**: the leaves have different environments (their root-to-leaf paths diverge at a binding-changing node)

### Step 3: Partition

The maximal runs of leaves with no internal boundaries are the semantic basic blocks. Each semantic basic block has:
- A single control flow context (no internal branches or targets)
- A single name-binding environment (all names resolve identically within the block)

### Why BLOCK is the only source of "extra" splits

For every binding-changing construct other than BLOCK, the binding change coincides with a control flow boundary:
- DO CONCURRENT / FORALL: the loop header is a CFG boundary (back-edge)
- ASSOCIATE: although sequential, its opening statement is a construct boundary that creates a new basic block entry point (the associate-names must be evaluated before the body)
- SELECT TYPE / SELECT RANK: the multi-way branch already splits the CFG

BLOCK is different: its body is straight-line continuation of the surrounding code. There is no branch, no loop, no dispatch. The ONLY reason to split is the binding change. This confirms the observation from v0.1.0's semantic-basic-block.md: BLOCK in straight-line code is the one case where semantic basic blocks are strictly finer than traditional basic blocks.

```fortran
x = 1.0                  ! SBB-1: env = subroutine scope
BLOCK
  REAL :: y
  y = x + 1.0            ! SBB-2: env = subroutine scope + {y}
END BLOCK
z = x + 2.0              ! SBB-3: env = subroutine scope (y gone)
```

Traditional basic blocks: 1 (all straight-line). Semantic basic blocks: 3.

### A subtlety: ASSOCIATE

ASSOCIATE is also sequential, like BLOCK. Does it create extra splits? The answer depends on whether we treat the ASSOCIATE statement itself as a control flow boundary.

The ASSOCIATE statement evaluates its selector expressions and establishes the bindings. This is semantically an "entry point" to the construct — the expressions must be evaluated before the body executes. If we treat the ASSOCIATE opening as a basic block boundary (as most CFG constructions would, since it is a construct opening statement), then the binding change does not create additional splits beyond the control flow split. If we do NOT treat it as a boundary, then ASSOCIATE behaves like BLOCK — a pure binding split in straight-line code.

The conservative choice (and the one consistent with Fortran's construct-opening-statement rule) is to treat every construct opening as a basic block boundary. Under this choice, **only BLOCK creates extra semantic splits**, because:
- BLOCK's opening `BLOCK` statement is a construct boundary (starts SBB-2)
- BLOCK's closing `END BLOCK` is a construct boundary (starts SBB-3)
- The binding change is already captured by these construct boundaries

Wait — this applies to BLOCK too. If every construct opening/closing is a CFG boundary, then BLOCK never creates "extra" splits either. The resolution: it depends on the CFG construction convention.

**Convention A** (strict CFG): only branches and branch targets start new basic blocks. BLOCK and ASSOCIATE are sequential, so they do NOT start new basic blocks. → BLOCK creates extra semantic splits.

**Convention B** (construct-aware CFG): every construct opening/closing starts a new basic block. → No extra semantic splits; the semantic basic block equals the construct-aware basic block.

Convention B is simpler but creates more (smaller) basic blocks. Convention A is traditional but requires the semantic refinement. The choice is a design decision; both lead to the same semantic basic blocks. We adopt **Convention B** for this project: treat every construct boundary as a basic block boundary. This makes the CFG construction align with the name-binding structure, eliminating the need for a separate "meet" operation.

**Under Convention B**: the semantic basic block is simply the basic block of the construct-aware CFG. The two dimensions collapse into one in the representation, because the CFG already respects construct boundaries.

## Non-local control flow

The CCT captures nesting structure, but some statements create control flow edges that **escape** the tree — they jump to a target that is not the next sibling or the construct's continuation.

| Statement | Target | Scope of escape |
|---|---|---|
| CYCLE | Enclosing DO loop header | May skip intervening constructs |
| EXIT | Past enclosing DO loop | May skip intervening constructs |
| CYCLE *name* / EXIT *name* | Named outer DO construct | May skip multiple nesting levels |
| GOTO *label* | Labeled statement (arbitrary) | May skip any number of levels |
| RETURN | Procedure exit | Exits all constructs |
| STOP / ERROR STOP | Program termination | Exits everything |
| ERR= / END= / EOR= | Labeled statement on I/O error | May skip any number of levels |

These are **additional edges** beyond the tree structure. The CCT encodes the nesting (which defines the "normal" flow); non-local transfers add edges that short-circuit the tree.

For the CFG: the CCT's tree edges plus these non-local edges give the complete edge set.

For name bindings: a non-local jump that exits a binding-changing construct implicitly **pops** the binding change. Jumping from inside a BLOCK to outside it means leaving the BLOCK's scope. This is handled automatically by the compositional environment model — the target's environment is determined by its own CCT path, not the source's.

### Named constructs and CYCLE/EXIT targeting

Named CYCLE and EXIT target a specific named construct:

```fortran
outer: DO i = 1, n
  inner: DO j = 1, m
    IF (converged(i,j)) EXIT outer    ! skips inner loop AND outer loop
  END DO inner
END DO outer
```

The construct name (`outer`, `inner`) has construct scope — it exists only within the construct. Resolving which construct a named EXIT targets is itself a name-resolution question, but one that operates on construct names rather than variable names. Construct names are visible only within the construct they label.

## Cross-boundary statements

Three statement types can appear in the execution part but are not executable constructs:

| Statement | CCT role | Effect on structure |
|---|---|---|
| FORMAT | Leaf (non-executable) | Provides format specification at a label; referenced by I/O statements. No control flow effect. |
| DATA | Leaf (non-executable) | Provides initial values. Obsolescent in execution part (F2018). No control flow effect. |
| ENTRY | **Additional root** | Creates an alternate entry point into the procedure. The CCT gains additional entry nodes — the procedure's CFG has multiple ENTRY nodes. Obsolescent. |

ENTRY is structurally disruptive: with ENTRY, the execution part no longer has a single entry point, and control flow from different entries can merge. This is rare in modern code and obsolescent.

## Representation analysis

The CCT has unbounded nesting depth — the left-recursion property identified in v0.1.1. Three representation options:

### Option A: Self-referential table (control_region)

```
control_region(region_id, parent_region_id, scope_id, kind, ...)
```

Each control construct is a row; the parent FK encodes the tree. Leaves (action statements) are either leaf rows or omitted.

| Aspect | Assessment |
|---|---|
| **Fidelity** | Full tree structure preserved |
| **Querying** | Requires recursive CTEs for ancestor/descendant queries |
| **Composability** | Natural FK to structural scope table |
| **Granularity** | One row per construct; leaves may or may not be rows |

### Option B: Serialized tree (JSON/AST)

Store the entire CCT as a JSON object per structural scope.

| Aspect | Assessment |
|---|---|
| **Fidelity** | Full tree structure preserved |
| **Querying** | Requires deserialization; not SQL-queryable |
| **Composability** | Must extract fields to join with relational tables |
| **Granularity** | One object per structural scope |

### Option C: Flat table (semantic basic blocks only)

Skip the tree; store only the linearized, partitioned result.

| Aspect | Assessment |
|---|---|
| **Fidelity** | Tree structure lost; only the partition is kept |
| **Querying** | Simple flat queries; no recursion needed |
| **Composability** | Direct FK to scope; each SBB has one environment |
| **Granularity** | One row per semantic basic block |

### Assessment

The pipeline stages need different things:

- **Stage 2 (call graph)**: needs call statements and their callee identity — this is leaf content, accessible from any representation
- **Stage 3 (driver generation)**: needs the binding environment at call sites — compositional along CCT paths (Option A), or pre-computed per SBB (Option C)
- **Data flow analysis**: needs read/write sets per basic block with edges — this is the semantic basic block + CFG edges (Option C)
- **Pattern mining**: needs the bipartite BB × OBJ graph — this is the semantic basic block (Option C)

Stages 2–3 benefit from the tree (environment composition along paths); Stages 4+ benefit from the flat table (efficient joins). This suggests:

**Recommended: Option A + Option C.**

- `control_region` (self-referential table): preserves the CCT for structural queries and environment composition
- `semantic_basic_block` (flat derived table): materialized from the CCT for efficient downstream use

This mirrors the existing pattern: `scope` (tree with parent FK) plus `scope_part` (flat annotation). Here: `control_region` (tree with parent FK) plus `semantic_basic_block` (flat derived from tree).

## Relationship to pipeline stages

| Stage | Consumes | From which table |
|---|---|---|
| Call graph (Stage 2) | Procedure call statements, callee identity, argument lists | `control_region` leaves (call-type actions) |
| Driver generation (Stage 3) | Binding environment at call sites, dummy argument types/intents | `control_region` path → environment composition |
| Data flow (Stage 4) | Read/write references per SBB, CFG edges between SBBs | `semantic_basic_block` + `sbb_edge` |
| Pattern mining (complementary) | Bipartite SBB × memory-object graph | `semantic_basic_block` + `data_access` |

The CCT is the ground truth; the semantic basic block is the derived view optimized for downstream consumption.

## Summary

The execution part's internal structure is characterized by two independent dimensions:

1. **Control flow**: branching (IF, SELECT), looping (DO, DO CONCURRENT, FORALL), masking (WHERE), and sequential (BLOCK, ASSOCIATE, CRITICAL, CHANGE TEAM)
2. **Name bindings**: full scope (BLOCK), construct-scoped entities (DO CONCURRENT, FORALL, ASSOCIATE, SELECT TYPE, SELECT RANK), or none

The **control construct tree** captures both: tree topology encodes control flow; binding annotations on nodes encode name-binding changes. The **name-binding environment** at each statement is determined compositionally by the path from root to leaf in the CCT.

The **semantic basic block** — the natural unit for downstream analysis — is derived by linearizing the CCT and partitioning at control flow or binding boundaries. Under a construct-aware CFG convention (every construct boundary starts a new basic block), the semantic basic block coincides with the basic block, because construct boundaries already capture binding changes.

**BLOCK** is the singular construct that makes the two-dimensional analysis necessary: it is the only construct that changes name bindings without changing control flow. Without BLOCK, control flow structure alone would suffice to partition the execution part for name-correct analysis.
