# cfg — Fortran control flow graph concepts

## Purpose

This document catalogs every Fortran construct that introduces a **control flow edge** — a branch, jump, or transfer of control that breaks sequential execution. It serves as the reference for identifying basic block boundaries when building CFGs from Fortran source.

## What is a CFG?

A **control flow graph** G = (V, E) where:
- V = set of **basic blocks** (maximal sequences of straight-line statements with no internal branches or branch targets)
- E ⊆ V × V = directed edges representing possible transfers of control
- Distinguished ENTRY and EXIT nodes

A new basic block begins at:
1. The first statement of a program unit
2. Any statement that is the target of a branch (labeled statement, ELSE, CASE, etc.)
3. Any statement immediately following a branch (IF, GOTO, EXIT, etc.)

## Modern structured constructs (Fortran 90+)

### IF construct

```fortran
IF (cond1) THEN        ! branch: cond1 → then-block | elseif/else/endif
  ...
ELSE IF (cond2) THEN   ! branch: cond2 → elseif-block | else/endif
  ...
ELSE                    ! fallthrough from failed conditions
  ...
END IF                  ! join point
```

CFG edges: one conditional edge per condition (true → block, false → next condition or else or end if). All block exits merge at END IF.

### SELECT CASE

```fortran
SELECT CASE (expr)
  CASE (value1)         ! branch: expr matches → block
    ...
  CASE (lo:hi)          ! range match
    ...
  CASE DEFAULT          ! no match
    ...
END SELECT              ! join point
```

CFG edges: one edge per CASE selector, plus default. Fall-through between cases is **not** permitted (unlike C switch). All cases merge at END SELECT.

### SELECT TYPE (F2003+)

```fortran
SELECT TYPE (x => poly_var)
  TYPE IS (integer)
    ...
  CLASS IS (base_t)
    ...
  CLASS DEFAULT
    ...
END SELECT
```

Same CFG topology as SELECT CASE — multi-way branch with no fall-through.

### SELECT RANK (F2018+)

```fortran
SELECT RANK (arr)
  RANK (0)
    ...
  RANK (1)
    ...
  RANK DEFAULT
    ...
END SELECT
```

Same multi-way branch topology.

### DO loop

```fortran
DO i = 1, n           ! loop header: evaluate bounds, branch to body or exit
  ...                  ! body
END DO                 ! back edge to header
```

CFG edges: header → body (enter loop), header → after-loop (skip/exit), end-do → header (back edge).

### DO WHILE

```fortran
DO WHILE (cond)        ! conditional: cond → body | exit
  ...
END DO                 ! back edge
```

Same topology as DO with iteration control, but condition is arbitrary logical expression.

### DO CONCURRENT (F2008+)

```fortran
DO CONCURRENT (i = 1:n, j = 1:m, mask(i,j))
  ...                  ! iterations are independent (no ordering guarantees)
END DO
```

For CFG purposes, treated as a loop with one back edge. Semantically, iterations are unordered — no inter-iteration data dependencies are permitted. This is relevant for the semantic basic block concept: each iteration body is independent.

### CYCLE and EXIT

```fortran
DO i = 1, n
  IF (skip_cond) CYCLE    ! edge → loop header (skip rest of body)
  ...
  IF (done_cond) EXIT     ! edge → after loop (break out)
  ...
END DO
```

CYCLE creates an edge from the current point to the loop header. EXIT creates an edge to the statement after the loop. Both break the current basic block.

Named constructs allow targeting outer loops:

```fortran
outer: DO i = 1, n
  inner: DO j = 1, m
    IF (cond) EXIT outer   ! edge → after outer loop
  END DO inner
END DO outer
```

## Scope-introducing constructs (control flow + scope boundary)

These constructs both alter control flow AND introduce new scoping units. They are critical for the semantic basic block concept.

### BLOCK (F2008+)

```fortran
BLOCK
  INTEGER :: temp       ! local declaration — new scope
  temp = x + y
  ...
END BLOCK
```

CFG: sequential (no branch) — BLOCK does not introduce a control flow branch. It is a straight-line scope boundary. Entry flows in, exit flows out.

However, BLOCK introduces a **new scoping unit** (kind `block` in our scope table). Variables declared inside are local. This means statements inside and outside a BLOCK have different name-binding environments even when there is no control flow branch.

### ASSOCIATE (F2003+)

```fortran
ASSOCIATE (a => expr1, b => expr2)
  ...                   ! a and b are aliases within this construct
END ASSOCIATE
```

CFG: sequential (no branch). Like BLOCK, it is straight-line control flow but introduces new name bindings (construct association). The standard says ASSOCIATE does NOT create a scoping unit, but it does create construct entities (the associate names) with construct scope.

### CHANGE TEAM (F2018+, coarray)

```fortran
CHANGE TEAM (team_var)
  ...                   ! execute in new team context
END TEAM
```

CFG: sequential for single-image flow. Introduces synchronization semantics but not a local branch.

### CRITICAL (F2008+, coarray)

```fortran
CRITICAL
  ...                   ! mutual exclusion across images
END CRITICAL
```

CFG: sequential (no branch in single-image CFG). Serialization construct for coarray programs.

## Legacy constructs (Fortran 77 and earlier)

These constructs produce **unstructured** control flow — arbitrary edges that may not nest properly.

### Unconditional GOTO

```fortran
      GOTO 100          ! unconditional edge → label 100
      ...
 100  CONTINUE           ! branch target
```

Creates one unconditional edge. Breaks the current basic block; the target label starts a new one.

### Computed GOTO (obsolescent in F95, deleted in F2018)

```fortran
      GOTO (100, 200, 300), idx   ! multi-way branch based on idx
```

Equivalent to SELECT CASE on idx. Creates edges to each label plus a fall-through (if idx is out of range, behavior is undefined in older standards).

### Assigned GOTO (deleted in F95)

```fortran
      ASSIGN 200 TO jmp           ! store label in variable
      ...
      GOTO jmp, (100, 200, 300)   ! indirect branch
```

Creates edges to every label in the list. This is the most problematic for CFG construction — it is essentially an indirect jump. The label list constrains possible targets.

### Arithmetic IF (obsolescent in F90, deleted in F2018)

```fortran
      IF (expr) 100, 200, 300     ! three-way branch: <0, =0, >0
```

Three outgoing edges from one statement. Creates a basic block boundary.

### Alternate RETURN (obsolescent)

```fortran
      SUBROUTINE foo(x, *, *)     ! * = alternate return labels
      ...
      RETURN 1                     ! return to first alternate label at call site
      ...
      CALL foo(x, *100, *200)     ! call site provides label targets
```

RETURN n creates edges to different labels at the call site. For intraprocedural CFG, the subroutine has multiple exit points. For interprocedural analysis, the call site fans out to multiple successors.

### Statement-function and entry points

**ENTRY statement** (obsolescent):
```fortran
      SUBROUTINE foo(x)
        ...
      ENTRY bar(x, y)             ! alternate entry point into same procedure
        ...
      END
```

Multiple entry points mean the procedure's CFG has multiple ENTRY nodes. Each ENTRY starts a basic block. Control flow from any entry point can reach shared code.

### Labeled DO loops (obsolete form)

```fortran
      DO 100 I = 1, N
        ...
 100  CONTINUE                    ! loop terminator at label
```

Equivalent to DO/END DO for CFG purposes, but the shared terminator label allows multiple loops to terminate at the same statement, complicating block identification.

## Exception-like control transfers

### STOP and ERROR STOP

```fortran
STOP [stop-code]                  ! terminate program
ERROR STOP [stop-code]            ! terminate with error (F2008+)
```

Edge to EXIT node. No successor basic block — this is a CFG sink.

### RETURN

```fortran
RETURN                            ! return from subprogram to caller
```

Edge to the procedure's EXIT node.

### END statement (of a program unit)

Implicit RETURN (for subprograms) or STOP (for main program). Always terminates the CFG.

## I/O-triggered control flow

Several I/O statements have specifiers that create conditional branches:

```fortran
READ(unit, fmt, IOSTAT=ios, ERR=100, END=200) var
!                                ERR=100  → label 100 on error
!                                END=200  → label 200 on end-of-file
```

Specifiers that introduce CFG edges:
- `ERR=label` — branch on I/O error
- `END=label` — branch on end-of-file
- `EOR=label` — branch on end-of-record (F90+)

When these specifiers are present, the I/O statement has multiple outgoing edges: normal continuation plus one edge per specifier label. When `IOSTAT=` is used instead, control returns normally and the status variable must be tested — no implicit branch.

## Summary table: constructs and CFG impact

| Construct | Edges | Structured? | Introduces scope? |
|---|---|---|---|
| IF/ELSE IF/ELSE/END IF | 2+ conditional | Yes | No |
| SELECT CASE | N-way | Yes | No |
| SELECT TYPE | N-way | Yes | No |
| SELECT RANK | N-way | Yes | No |
| DO / DO WHILE | loop (back edge) | Yes | No |
| DO CONCURRENT | loop (back edge) | Yes | Yes (index scope) |
| CYCLE | jump to header | Yes (within loop) | No |
| EXIT | jump past loop | Yes (within loop) | No |
| BLOCK | none (sequential) | Yes | **Yes** |
| ASSOCIATE | none (sequential) | Yes | Partial (construct entities) |
| FORALL | loop-like | Yes | Yes (index scope) |
| WHERE | conditional mask | Yes | No |
| GOTO | 1 unconditional | No | No |
| Computed GOTO | N-way | No | No |
| Assigned GOTO | N-way indirect | No | No |
| Arithmetic IF | 3-way | No | No |
| Alternate RETURN | multi-exit | No | No |
| ENTRY | multi-entry | No | No |
| STOP / ERROR STOP | edge to EXIT | — | No |
| RETURN | edge to EXIT | — | No |
| ERR=/END=/EOR= | conditional | Partially | No |

## Implications for basic block construction

1. **Modern structured Fortran** produces reducible CFGs (all loops have single entry points, all branches are structured). Basic blocks align naturally with construct boundaries.

2. **Legacy Fortran** (GOTO, computed GOTO, arithmetic IF, ENTRY, alternate RETURN) can produce **irreducible** CFGs. Node splitting or other transformations may be needed for some analyses.

3. **Scope-introducing constructs** (BLOCK, DO CONCURRENT, FORALL) create basic block boundaries even without control flow branches, because the name-binding environment changes. This motivates the semantic basic block concept.

## Relationship to scope table

The scope table's `kind` enumeration includes three constructs that are both scoping units and control flow constructs:

| scope.kind | Control flow? | Name-binding change? |
|---|---|---|
| `block` | No (sequential) | Yes (new local scope) |
| `do_concurrent` | Yes (loop) | Yes (index has construct scope) |
| `forall` | Yes (loop-like) | Yes (index has construct scope) |

These are exactly the constructs where traditional CFG basic blocks and scope boundaries intersect — the motivation for the semantic basic block concept documented separately.
