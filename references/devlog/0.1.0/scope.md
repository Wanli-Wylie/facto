# scope table — design notes

## Purpose

The `scope` table is the **fact table** of Fortran's scoping system. Each row is one scoping unit — a region of source code that introduces a namespace boundary. All other scope-related structures (declarations, associations, implicit rules, generic bindings, COMMON/EQUIVALENCE groups) will be dimension tables keyed back to `scope.scope_id`.

## Schema

| Column | Type | Nullable | Description |
|---|---|---|---|
| `scope_id` | BIGINT (identity) | PK | Surrogate key |
| `parent_scope_id` | BIGINT | YES | Self-ref FK → `scope`. The containing (host) scoping unit. NULL only for the global scope. |
| `kind` | TEXT | NOT NULL | Scoping unit kind. Enumerated below. |
| `name` | TEXT | YES | The declared name of this scope (module name, procedure name, type name, etc.). NULL for anonymous scopes (unnamed BLOCK, global). |
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

**`parent_scope_id`** forms a **tree** (or forest across files). It encodes lexical nesting and, implicitly, **host association** — a child scope can see its parent's names unless locally shadowed.

**`ancestor_scope_id`** is orthogonal to the parent tree. It links a `submodule` scope to the `module` or `submodule` it extends. A submodule's parent in the containment tree is `global` (it is a separate program unit), but its ancestor is the module whose internals it can access.

```
global (root)
  ├── module linalg_mod               parent=global
  │     ├── function dot              parent=linalg_mod
  │     ├── subroutine matvec         parent=linalg_mod
  │     └── derived_type matrix_t     parent=linalg_mod
  ├── submodule linalg_impl           parent=global, ancestor=linalg_mod
  │     └── separate_mp solve_impl    parent=linalg_impl
  └── program main_prog               parent=global
        ├── block (unnamed)            parent=main_prog
        └── subroutine helper          parent=main_prog (internal)
```

## `kind` enumeration

The Fortran standard (§19.2) defines three categories of scoping unit. We refine these into 13 concrete kinds:

### Category A — Program units and subprograms

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

### Category B — Derived-type definitions

| Kind | Fortran construct | Standard category |
|---|---|---|
| `derived_type` | `TYPE :: name` | Derived-type definition |

### Category C — Interface bodies

| Kind | Fortran construct | Standard category |
|---|---|---|
| `interface_body` | `INTERFACE` / `ABSTRACT INTERFACE` body | Interface body |

### Pragmatic additions (sub-scoping units)

| Kind | Fortran construct | Notes |
|---|---|---|
| `block` | `BLOCK ... END BLOCK` | F2008+. Creates a local scope; variables declared inside are local. |
| `forall` | `FORALL (idx = ...)` | Index-name has construct scope. |
| `do_concurrent` | `DO CONCURRENT (idx = ...)` | Index-name has construct scope. |

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

## Interface body scoping rule

The Fortran standard states that an interface body **does not** access its host's names via host association (unlike every other nested scoping unit). This is modeled structurally:

- `interface_body` scopes have `parent_scope_id` pointing to `global`, **not** to the containing procedure/module.

This means a name-resolution walk up the `parent_scope_id` chain from an interface body skips directly to global scope, exactly as the standard requires. The interface body can still access module entities via USE association (to be modeled in a dimension table).

## Relationship to source_code

The columns `(filename, start_line, end_line)` link each scope back to the `source_code` view:

```sql
SELECT sc.filename, sc.lineno, sc.line
FROM   source_code sc
JOIN   scope s ON sc.filename = s.filename
WHERE  sc.lineno BETWEEN s.start_line AND s.end_line
  AND  s.scope_id = ?;
```

This retrieves the full source text of any scoping unit.

## Planned dimension tables

The following will be designed as separate dimension tables around this fact table:

| Future table | FK to scope | What it adds |
|---|---|---|
| `declaration` | `scope_id` | Named entities (variables, procedures, types, etc.) introduced in each scope |
| `association` | `scope_id` | Cross-scope visibility links (USE, host exceptions, storage, argument, pointer, inheritance) |
| `implicit_rule` | `scope_id` | Per-scope IMPLICIT letter→type mappings (when `implicit_typing = 'custom'`) |
| `generic_binding` | via declaration | Specific procedures bound under a generic name |
| `common_member` | via declaration | Ordered member lists of COMMON blocks |
| `equivalence_set` | `scope_id` | EQUIVALENCE groups sharing storage |
