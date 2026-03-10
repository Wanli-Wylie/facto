# scope table — design notes (v0.1.1)

## Purpose

The `scope` table is the **fact table** of Fortran's structural scoping system. Each row is one **structural scope** — a program unit or subprogram that introduces a complete namespace boundary with its own specification part. All other scope-related structures (declarations, associations, implicit rules, generic bindings, COMMON/EQUIVALENCE groups) will be dimension tables keyed back to `scope.scope_id`.

Internal sub-scoping constructs (BLOCK, FORALL, DO CONCURRENT) and specification-level scoping units (derived-type definitions, interface bodies) are excluded from this table. See `schema-design.md` for rationale.

## Schema

| Column | Type | Nullable | Description |
|---|---|---|---|
| `scope_id` | BIGINT (identity) | PK | Surrogate key |
| `parent_scope_id` | BIGINT | YES | Self-ref FK → `scope`. The containing (host) scoping unit. NULL only for the global scope. |
| `kind` | TEXT | NOT NULL | Structural scope kind. Enumerated below. |
| `name` | TEXT | YES | The declared name of this scope (module name, procedure name, etc.). NULL for the global scope. |
| `filename` | TEXT | YES | Source file. Join key to `source_code.filename`. |
| `start_line` | INTEGER | YES | First line of this scoping unit in source. |
| `end_line` | INTEGER | YES | Last line (inclusive) of this scoping unit in source. |
| `implicit_typing` | TEXT | NOT NULL | Implicit typing regime. Default `'inherit'`. |
| `ancestor_scope_id` | BIGINT | YES | Self-ref FK → `scope`. For submodules only: the parent module/submodule being extended. |
| `default_accessibility` | TEXT | YES | Module-scope default: `'public'` or `'private'`. NULL for non-module scopes. |

## Self-referential structure

Two self-referential FKs:

```
scope
  ├── parent_scope_id  → scope.scope_id   (containment tree)
  └── ancestor_scope_id → scope.scope_id   (submodule lineage)
```

**`parent_scope_id`** forms a **shallow tree** (at most ~3 levels). It encodes lexical nesting and, implicitly, **host association** — a child scope can see its parent's names unless locally shadowed.

**`ancestor_scope_id`** is orthogonal to the parent tree. It links a `submodule` scope to the `module` or `submodule` it extends. A submodule's parent in the containment tree is `global` (it is a separate program unit), but its ancestor is the module whose internals it can access.

```
global (root)
  ├── module linalg_mod               parent=global
  │     ├── function dot              parent=linalg_mod
  │     ├── subroutine matvec         parent=linalg_mod
  │     └── (derived_type matrix_t)   → declaration dim table, not a scope row
  ├── submodule linalg_impl           parent=global, ancestor=linalg_mod
  │     └── separate_mp solve_impl    parent=linalg_impl
  └── program main_prog               parent=global
        └── subroutine helper          parent=main_prog (internal)
```

### Nesting depth is bounded

Structural scopes nest at most ~3 levels:

| Depth | Example |
|---|---|
| 0 | `global` |
| 1 | `program`, `module`, `submodule`, `block_data`, external `function`/`subroutine` |
| 2 | Module procedure, internal procedure, `separate_mp` |

Fortran's CONTAINS nesting is exactly one level — an internal procedure cannot itself contain internal procedures. This bounded depth means the self-referential `parent_scope_id` tree has no left-recursion problem.

## `kind` enumeration

Eight structural kinds, corresponding to Fortran's program units and subprograms:

| Kind | Fortran construct | Standard category |
|---|---|---|
| `global` | (implicit) | Not in standard; the program-wide namespace for global entities |
| `program` | `PROGRAM name` | Program unit |
| `module` | `MODULE name` | Program unit |
| `submodule` | `SUBMODULE (parent) name` | Program unit (F2008+) |
| `block_data` | `BLOCK DATA [name]` | Program unit |
| `function` | `FUNCTION name(...)` | Subprogram (external, module, or internal) |
| `subroutine` | `SUBROUTINE name(...)` | Subprogram (external, module, or internal) |
| `separate_mp` | `MODULE PROCEDURE name` (body) | Separate module procedure body (F2008+) |

### What was removed (and where it goes)

| Former kind | Nature | New home |
|---|---|---|
| `derived_type` | Specification construct | `declaration` dimension table |
| `interface_body` | Specification construct | `declaration` dimension table |
| `block` | Execution-internal, unbounded nesting | Future control-region table |
| `forall` | Execution-internal | Future control-region table |
| `do_concurrent` | Execution-internal | Future control-region table |

## `implicit_typing` enumeration

Fortran's implicit typing rules are **inherited** down the scope tree, with overrides at any level.

| Value | Meaning |
|---|---|
| `default` | Standard F77 rule: names starting with I–N are INTEGER, all others are REAL. Applied to the global scope and any scope that doesn't override. |
| `none` | `IMPLICIT NONE` declared in this scope. All names must be explicitly declared. |
| `inherit` | This scope inherits its parent's implicit rules unchanged. This is the default and the common case. |
| `custom` | This scope has its own `IMPLICIT` statements (e.g., `IMPLICIT DOUBLE PRECISION (A-H,O-Z)`). A future dimension table `implicit_rule` will store the letter→type mappings. |

Resolution algorithm (for downstream consumers):

```
resolve_implicit(scope_id):
    s = lookup(scope_id)
    if s.implicit_typing != 'inherit':
        return s.implicit_typing   -- 'default', 'none', or 'custom'
    else:
        return resolve_implicit(s.parent_scope_id)
```

## `default_accessibility`

Only meaningful for `module` and `submodule` scopes. Determines whether declarations in the module are PUBLIC or PRIVATE by default.

| Value | Meaning |
|---|---|
| NULL | Not a module scope (column is inapplicable) |
| `public` | Default. Declarations are visible to USErs unless marked PRIVATE. |
| `private` | `PRIVATE` statement at module level. Declarations are hidden unless marked PUBLIC. |

## Relationship to source_code

The columns `(filename, start_line, end_line)` link each scope back to the `source_code` view:

```sql
SELECT sc.filename, sc.lineno, sc.line
FROM   source_code sc
JOIN   scope s ON sc.filename = s.filename
WHERE  sc.lineno BETWEEN s.start_line AND s.end_line
  AND  s.scope_id = ?;
```

This retrieves the full source text of any structural scope.

## Planned dimension tables

| Future table | FK to scope | What it adds |
|---|---|---|
| `declaration` | `scope_id` | Named entities (variables, procedures, types, interface bodies) introduced in each scope |
| `association` | `scope_id` | Cross-scope visibility links (USE, host exceptions, storage, argument, pointer, inheritance) |
| `implicit_rule` | `scope_id` | Per-scope IMPLICIT letter→type mappings (when `implicit_typing = 'custom'`) |
| `generic_binding` | via declaration | Specific procedures bound under a generic name |
| `common_member` | via declaration | Ordered member lists of COMMON blocks |
| `equivalence_set` | `scope_id` | EQUIVALENCE groups sharing storage |
