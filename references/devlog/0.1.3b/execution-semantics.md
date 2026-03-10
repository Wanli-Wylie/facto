# execution part — semantic characterization

## What the execution part defines

The execution part contains the **computation** — the statements that read, transform, and write data within the name-binding environment established by the specification part. It is present only in executable scopes: `program`, `function`, `subroutine`, `separate_mp`.

The execution part is the primary subject of downstream pipeline stages: call graph extraction, driver generation, data flow analysis, and pattern mining.

## Statement taxonomy

Every statement in the execution part is either an **executable construct** or one of three cross-boundary statements (FORMAT, DATA, ENTRY). Executable constructs divide into **action statements** and **control constructs**.

### Action statements (leaf-level computation)

Action statements perform a single operation. They are the atomic units of execution.

| Category | Statements | Semantic content |
|---|---|---|
| **Assignment** | `=`, pointer assignment `=>` | Target name, source expression, type compatibility |
| **Procedure call** | `CALL sub(args)`, function reference `f(args)` | Callee identity, actual argument list, argument association |
| **I/O** | READ, WRITE, PRINT, OPEN, CLOSE, INQUIRE, REWIND, BACKSPACE, ENDFILE, FLUSH, WAIT | Unit, format, variable list, I/O specifiers (IOSTAT, ERR, END, EOR) |
| **Allocation** | ALLOCATE, DEALLOCATE, NULLIFY | Object identity, shape/bounds, STAT/ERRMSG |
| **Control transfer** | GOTO, CYCLE, EXIT, RETURN, STOP, ERROR STOP, CONTINUE | Target label or construct name, termination kind |
| **Synchronization** | SYNC ALL, SYNC IMAGES, SYNC MEMORY, SYNC TEAM, LOCK, UNLOCK, EVENT POST, EVENT WAIT, FORM TEAM, CHANGE TEAM | Coarray coordination semantics |

### Control constructs (structured nesting)

Control constructs introduce **branching, looping, or scoping** — they contain other executable constructs.

| Construct | Semantic content | Introduces scope? |
|---|---|---|
| **IF** | Conditional branch: condition expression → then/elseif/else blocks | No |
| **SELECT CASE** | Multi-way branch: selector expression → case blocks | No |
| **SELECT TYPE** | Type-based dispatch: polymorphic variable → type-guarded blocks | No |
| **SELECT RANK** | Rank-based dispatch: assumed-rank array → rank-guarded blocks | No |
| **DO** | Counted loop: index variable, bounds, step → body | No (index is host-scoped) |
| **DO WHILE** | Condition-controlled loop: condition → body | No |
| **DO CONCURRENT** | Unordered loop: index, bounds, mask → body. Iterations independent. | Yes (index has construct scope) |
| **FORALL** | Array index space: index, bounds, mask → body. Obsolescent. | Yes (index has construct scope) |
| **WHERE** | Masked array assignment: mask expression → assignment blocks | No |
| **BLOCK** | Scoped region: local declarations + executable statements | Yes (new scoping unit) |
| **ASSOCIATE** | Name aliasing: associate-name => expression → body | Partial (construct entities) |
| **CRITICAL** | Mutual exclusion: body executes atomically across images | No |
| **CHANGE TEAM** | Coarray team switch: body executes in new team context | No |

### Cross-boundary statements

| Statement | Role in execution part |
|---|---|
| **FORMAT** | Defines format specification at a label. Referenced by I/O statements. |
| **DATA** | Provides initial values for variables. Obsolescent when in execution part. |
| **ENTRY** | Alternate entry point into the procedure. Obsolescent. |

## Semantic information carried by the execution part

### 1. Data flow: reads and writes

Each action statement has a set of **read references** (names whose values are consumed) and **write references** (names whose values are defined).

```fortran
y = a * x + b
!  writes: y
!  reads:  a, x, b
```

This read/write information is the foundation for:
- **Def-use chains** — which definition of a variable reaches which use
- **Live variable analysis** — which variables hold needed values at each point
- **The bipartite access graph** — BB × memory object with read/write edges

### 2. Call graph edges

Procedure calls and function references establish **call edges**:

```fortran
CALL solve(A, b, x)          ! call edge: current scope → solve
result = dot_product(u, v)    ! call edge: current scope → dot_product
```

Semantic information per call:
- **Callee identity** — resolved name (may require USE/host/generic resolution from the spec part)
- **Actual arguments** — expressions passed, positional or keyword
- **Argument association** — actual ↔ dummy pairing (positional, keyword, or optional)

### 3. Control flow structure

Control constructs define the **branching and looping** topology:

| Information | What it tells us |
|---|---|
| Branch conditions | Expressions that determine which path executes |
| Loop bounds | Index ranges and step for counted loops |
| Loop masks | Logical conditions filtering iterations (DO CONCURRENT, FORALL, WHERE) |
| Nesting depth | How deeply control constructs are nested |
| Construct names | Labels for CYCLE/EXIT targeting |

This maps directly to CFG construction (see `cfg.md`).

### 4. Scope-introducing constructs

Three execution-part constructs introduce sub-scopes within the execution flow:

| Construct | New names introduced | Effect on name resolution |
|---|---|---|
| **BLOCK** | Local variables (full specification part within BLOCK) | New local names shadow host names |
| **DO CONCURRENT** | Index variables | Index names have construct scope |
| **FORALL** | Index variables | Index names have construct scope |

These are exactly the constructs that motivate the semantic basic block concept: they change the name-binding environment within straight-line or looping code.

ASSOCIATE introduces construct entities (the associate-names) but the standard does not classify it as a full scoping unit. Its names are visible only within the construct body.

### 5. I/O operations

I/O statements carry rich semantic information:

| Information | Description |
|---|---|
| Direction | Input (READ) or output (WRITE/PRINT) |
| Unit | File unit number or `*` for default |
| Format | Format string, label reference, list-directed, or namelist |
| Variable list | Which variables are read/written |
| Error handling | IOSTAT, ERR label, END label, EOR label |

For the pipeline, I/O statements matter because they define **observable behavior** — the interface between the program and its environment.

### 6. Allocation dynamics

ALLOCATE/DEALLOCATE statements change the **shape and existence** of data objects at runtime:

```fortran
ALLOCATE(work(n))           ! work becomes defined with shape [n]
DEALLOCATE(work)            ! work becomes undefined
```

This affects:
- Which variables are usable at each point
- Memory footprint estimation for driver generation
- Array shape inference for input distribution estimation

## Relationship to the specification part

The execution part **depends on** the specification part — every name reference in the execution part resolves through the environment the specification part established:

```
specification part          execution part
─────────────────          ──────────────
name table          ──→    name resolution for every reference
type environment    ──→    type checking of expressions
attribute map       ──→    legality checks (INTENT, ALLOCATABLE, ...)
procedure interfaces ──→   call resolution, argument checking
```

This dependency is one-directional: the specification part does not depend on the execution part. The specification part is the **context**; the execution part is the **content**.

## Nesting and the left-recursion problem

Control constructs nest arbitrarily:

```fortran
DO i = 1, n
  IF (mask(i)) THEN
    BLOCK
      REAL :: temp
      DO CONCURRENT (j = 1:m)
        temp = a(i,j) * x(j)
        ...
```

This nesting forms a **tree** — each construct contains other constructs as children. The tree's depth is unbounded. Per the schema design methodology, this left-recursive structure should be treated as an **object** rather than flattened into a relational table of statements.

Possible representations (to be designed in future versions):
- **Control region tree**: self-referential table with parent FK (like scope), one row per construct
- **AST fragment**: the execution part's subtree from the parsed CST
- **CFG**: linearized basic blocks with edges (loses nesting structure but gains data flow properties)

The choice depends on which downstream stage consumes the execution part.

## Per-scope-kind: what each scope's execution part contains

| scope.kind | Has execution part? | Typical content |
|---|---|---|
| `global` | No | — |
| `program` | Yes | Top-level computation: initialization, I/O, calls to procedures |
| `module` | **No** | Modules are purely declarative |
| `submodule` | **No** | Submodules are purely declarative |
| `block_data` | **No** | Only specification (DATA initialization of COMMON) |
| `function` | Yes | Computation that produces the function result |
| `subroutine` | Yes | Computation that modifies arguments and/or module state |
| `separate_mp` | Yes | Same as function/subroutine (body of a separately-defined module procedure) |

## Mapping to future tables

The execution part's semantic information will map to downstream tables:

```
scope_part (part = 'execution')
  │
  ├── call_edge (future)         ← call graph edges from this scope
  │     callee scope_id, argument mapping
  │
  ├── control_region (future)    ← nested control construct tree
  │     kind, condition, bounds, parent region
  │
  ├── data_access (future)       ← read/write references per region
  │     variable, access mode (read/write/readwrite)
  │
  └── io_operation (future)      ← I/O statements
        direction, unit, format, variable list
```

The `scope_part` table records the line extent of the execution part, enabling extraction of its source text. Further decomposition into control regions, data accesses, and call edges belongs in later versions.
