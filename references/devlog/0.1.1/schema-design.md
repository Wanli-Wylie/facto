# table schema design — methodology and decisions

## Design principles

### 1. Relational first, objects when left-recursive

The primary representation is relational tables. When a structure exhibits left-recursive nesting (expression trees, nested control constructs), it is treated as an **object** — either via self-referential FK (shallow, bounded nesting) or deferred to a later stage that can handle tree/graph structures.

**Self-referential FK is appropriate when**: nesting is bounded and shallow (e.g., structural scope containment: global → module → function is at most 3 levels).

**Object/deferred treatment is appropriate when**: nesting is unbounded (e.g., expression trees `a + (b * (c - d))`, nested IF/DO constructs of arbitrary depth).

### 2. Fact table + dimension tables

Each major concept gets one **fact table** that establishes identity and core relationships. Surrounding detail is captured in **dimension tables** keyed back to the fact table's surrogate key. This avoids wide tables with many nullable columns and keeps each table focused.

### 3. Structural before internal

Tables are designed coarse-to-fine. Start with **structural** entities (program units, subprograms — the callable/containable units) before modeling **internal** structure (control flow, sub-scoping, statements). This reflects both the pipeline order (scope graph → call graph → internal analysis) and the layering principle (WHAT before HOW).

### 4. Specification / execution separation

Fortran program units have a rigid three-part structure:

```
[specification part]   ← defines the name-binding environment
[execution part]       ← consumes the environment
[internal subprograms] ← CONTAINS section (new structural scopes)
```

Specification statements (USE, IMPLICIT, declarations) define the environment; executable statements use it. These are different layers and should not be conflated in one table. The specification part is a **property of the structural scope** — captured as columns and dimension tables on the scope row, not as separate statement rows.

## Scope table: structural-only design (v0.1.1)

### What changed from v0.1.0

The scope table is narrowed from 13 kinds to **8 structural kinds**:

| Kept (structural) | Removed (internal) |
|---|---|
| `global`, `program`, `module`, `submodule`, `block_data`, `function`, `subroutine`, `separate_mp` | `derived_type`, `interface_body`, `block`, `forall`, `do_concurrent` |

### Rationale for each removed kind

| Kind | Why removed | Where it goes |
|---|---|---|
| `derived_type` | Specification construct — defines a type, not a callable unit. Components are names in the type's namespace, but the type definition itself is a declaration within its containing structural scope. | `declaration` dimension table. Component names keyed to the containing scope. |
| `interface_body` | Specification construct — declares a procedure interface. Its special "no host association" rule can be modeled as a property of the declaration, not as a separate scope row. | `declaration` dimension table, with an attribute marking the interface body's isolation from host scope. |
| `block` | Execution-internal construct. Introduces local declarations within a procedure but does not create a callable or containable program unit. Nesting is unbounded (blocks inside blocks). | Future internal-scope or control-region table, keyed to the containing structural scope. |
| `forall` | Execution-internal construct. Index variable has construct scope, but the construct is internal to a procedure. | Same as `block`. |
| `do_concurrent` | Execution-internal construct. Same reasoning as `forall`. | Same as `block`. |

### Why this granularity is right for the pipeline

Stages 1–3 of the pipeline (scope graph → call graph → driver generation) operate on callable entities and their containers:

- **Scope graph**: which modules, programs, functions, subroutines exist, and how they nest
- **Call graph**: which callable entities invoke which others
- **Driver generation**: craft a driver for each callable entity

None of these stages need to see BLOCK, FORALL, or DO CONCURRENT — those are internal to a procedure's implementation. Derived types and interface bodies contribute to the specification part, handled through dimension tables.

### Nesting depth is bounded

Structural scopes nest at most ~3 levels deep:

```
global → module → function       (module procedure)
global → program → subroutine    (internal procedure)
global → submodule → separate_mp (separate module procedure)
```

A function cannot CONTAINS another function that CONTAINS another function — Fortran's CONTAINS nesting is exactly one level. This means `parent_scope_id` forms a **shallow, bounded tree** — no left-recursion problem.

Contrast with the removed kinds: BLOCK can nest inside BLOCK inside BLOCK to arbitrary depth. IF can nest inside IF inside IF. These exhibit the unbounded left-recursive nesting that our methodology flags for object treatment.

## Tables in v0.1.1

### `source_code` layer (unchanged from v0.1.0)

| Table | Role |
|---|---|
| `file_version` | Versioned file snapshots |
| `source_line` | Line content per version |
| `edit_event` | Edit operations between versions |
| `source_code` (view) | Public interface: `(filename, lineno, line)` |

### `scope` layer (narrowed in v0.1.1)

| Table | Role |
|---|---|
| `scope` | Fact table: 8 structural scope kinds, self-referential containment tree + submodule lineage |

### Planned dimension tables (future versions)

| Table | FK to | What it captures |
|---|---|---|
| `declaration` | `scope.scope_id` | Named entities introduced in each structural scope (variables, procedures, types, interfaces) |
| `association` | `scope.scope_id` | Cross-scope visibility (USE, host, argument, pointer, storage association) |
| `implicit_rule` | `scope.scope_id` | IMPLICIT letter → type mappings (when `implicit_typing = 'custom'`) |
| `generic_binding` | via `declaration` | Specific procedures under a generic name |
| `common_member` | via `declaration` | Ordered members of COMMON blocks |
| `equivalence_set` | `scope.scope_id` | EQUIVALENCE storage groups |

### Deferred to later stages (internal structure)

| Concept | Why deferred | Approach when addressed |
|---|---|---|
| Internal sub-scoping (BLOCK, FORALL, DO CONCURRENT) | Unbounded nesting; internal to procedures | Control-region tree or object model |
| Derived-type scope | Specification construct; component names | Part of `declaration` dimension table |
| Interface body scope | Specification construct; host-isolation rule | Part of `declaration` dimension table |
| Statements | Specification/execution divide | Separate layer after scope + declaration are stable |
| Control flow graph / semantic basic blocks | Depends on statements + internal sub-scoping | Separate layer; see `cfg.md` and `semantic-basic-block.md` |

## Version history

| Version | Changes |
|---|---|
| 0.1.0 | Initial design. `source_code` layer (3 tables + 1 view). `scope` fact table with 13 kinds. |
| 0.1.1 | Narrow scope to 8 structural kinds. Document schema design methodology. Separate specification from execution concerns. |
