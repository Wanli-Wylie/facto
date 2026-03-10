# specification part — semantic characterization

## What the specification part defines

The specification part of a structural scope establishes the **name-binding environment** — the complete set of rules for resolving names within that scope. It answers: what names exist, what do they refer to, and what are their properties?

This environment is consumed by the execution part (if present), by internal subprograms (via host association), and by other scopes (via USE association).

## Four semantic layers

The specification part has four ordered layers, each contributing a distinct class of semantic information. The ordering is enforced by the grammar (F2018 R504) and matches the semantic dependency chain.

### Layer 1: Module association (USE)

```fortran
USE iso_fortran_env, ONLY: REAL64, INT32
USE linalg_mod, solve => linear_solve
```

**Semantic content:** imports names from other modules into this scope.

| Information | Description |
|---|---|
| Source module | Which module is being used |
| Imported names | Which names are brought in (ONLY list, or all public names) |
| Renaming | Local name ↔ module name mappings |
| Nature | INTRINSIC vs NON_INTRINSIC module |

**Dependency:** none — USE is the first layer, establishing the base set of externally-sourced names.

**Semantic effect:** after Layer 1, the scope has a set of names that are visible via USE association. These names may be variables, types, procedures, interfaces, operators, or generic names from the source module.

### Layer 2: Host association control (IMPORT)

```fortran
IMPORT :: matrix_t, vector_t       ! import specific host names
IMPORT, NONE                       ! block all host names
IMPORT, ONLY :: base_type          ! import only these, block rest
```

**Semantic content:** controls which names from the host (parent) scope are visible.

| Information | Description |
|---|---|
| Mode | ALL (default), NONE, ONLY, or explicit list |
| Imported names | Which host names are accessible (when ONLY or explicit) |

**Dependency:** logically independent of Layer 1, but must be processed after USE to avoid ambiguity.

**Semantic effect:** after Layer 2, the scope knows which host-associated names are accessible. Combined with Layer 1, the set of externally-visible names is fully determined.

**Scope restriction:** IMPORT can only appear in scopes that have a host — interface bodies, internal/module subprograms, BLOCK constructs, submodules. It cannot appear in main programs, external procedures, modules, or block_data.

### Layer 3: Implicit typing rules (IMPLICIT)

```fortran
IMPLICIT NONE
IMPLICIT NONE (TYPE, EXTERNAL)
IMPLICIT DOUBLE PRECISION (A-H, O-Z)
IMPLICIT INTEGER (I-N)
```

**Semantic content:** defines how undeclared names receive types.

| Information | Description |
|---|---|
| Mode | NONE (all names must be declared), DEFAULT (I-N integer, rest real), or CUSTOM |
| Letter→type map | For CUSTOM: which first-letter ranges map to which types |
| External rule | Whether IMPLICIT NONE applies to EXTERNAL attribute (F2018) |

**Dependency:** must follow USE and IMPORT so that the type names used in IMPLICIT mappings can resolve.

**Semantic effect:** after Layer 3, the scope has a complete rule for typing any name — either it must be explicitly declared (NONE), or it gets a type from its first letter (DEFAULT/CUSTOM). This is already captured by `scope.implicit_typing` and the planned `implicit_rule` table.

### Layer 4: Declarations

```fortran
INTEGER, INTENT(IN) :: n
REAL, ALLOCATABLE :: work(:)
TYPE(matrix_t) :: A
INTERFACE solve
  MODULE PROCEDURE solve_real, solve_complex
END INTERFACE
```

**Semantic content:** introduces named entities into the scope with their properties.

This is the richest layer. It introduces:

**Data objects:**

| Entity | Semantic information |
|---|---|
| Variable | Name, type, kind, rank, shape, attributes (INTENT, ALLOCATABLE, POINTER, TARGET, SAVE, VOLATILE, ASYNCHRONOUS, CONTIGUOUS, CODIMENSION, VALUE) |
| Dummy argument | Same as variable, plus argument position and OPTIONAL |
| Function result | Same as variable, tied to function name or RESULT clause |
| Named constant | Name, type, value expression (PARAMETER) |

**Type definitions:**

| Entity | Semantic information |
|---|---|
| Derived type | Name, type parameters, components (name + type + attributes), type-bound procedures, ABSTRACT/EXTENDS/BIND(C)/SEQUENCE attributes, accessibility of components |

**Procedure declarations:**

| Entity | Semantic information |
|---|---|
| Procedure | Name, interface (explicit or implicit), EXTERNAL/INTRINSIC attribute, BIND(C) |
| Interface block | Name (or operator/assignment), set of specific procedure signatures |
| Generic name | Name, set of specific procedures it resolves to |

**Group entities:**

| Entity | Semantic information |
|---|---|
| COMMON block | Name, ordered list of member variables, storage layout |
| NAMELIST group | Name, ordered list of member variables |
| EQUIVALENCE set | Set of variables sharing storage, with offset relationships |

**Dependency:** depends on all previous layers — declarations use types imported via USE (Layer 1), types visible via host association (Layer 2), and implicitly-typed names follow Layer 3 rules.

## Semantic summary: what the specification part produces

After processing all four layers, the specification part has established:

1. **Name table** — every name visible in this scope, with its origin:
   - USE-associated (from Layer 1)
   - Host-associated (controlled by Layer 2, inherited from parent)
   - Locally declared (from Layer 4)

2. **Type environment** — every name has a type, either:
   - Explicitly declared (Layer 4)
   - Implicitly typed (Layer 3 rules)
   - Inherited from association source

3. **Attribute map** — each entity's properties:
   - Storage: ALLOCATABLE, POINTER, TARGET, SAVE, COMMON, EQUIVALENCE
   - Interface: INTENT, OPTIONAL, VALUE (dummy arguments only)
   - Visibility: PUBLIC, PRIVATE, PROTECTED (modules only)
   - Interop: BIND(C), ASYNCHRONOUS, VOLATILE, CONTIGUOUS

4. **Procedure interfaces** — for each known procedure:
   - Argument count, names, types, intents
   - Whether the interface is explicit (declared) or implicit (undeclared external)
   - Generic resolution rules

5. **Type definitions** — for each derived type:
   - Component structure (names, types, attributes)
   - Type-bound procedures and their bindings
   - Inheritance chain (EXTENDS)

## Per-scope-kind: what each scope's specification part defines

| scope.kind | Primary semantic role of its specification part |
|---|---|
| `global` | (none — implicit namespace) |
| `program` | Declares program-local variables and types. USEs modules. Hosts internal procedures. |
| `module` | Defines the public API: types, interfaces, module variables, generic bindings. The specification part IS the module's content (no execution part). |
| `submodule` | Extends a module's implementation: provides bodies for deferred procedures, adds private types and variables. |
| `block_data` | Initializes COMMON block variables via DATA. No interfaces, no execution. Obsolescent. |
| `function` | Declares arguments (with types, intents), result variable, local variables, and any types/interfaces needed for the computation. |
| `subroutine` | Same as function, minus the result variable. |
| `separate_mp` | Same as function/subroutine. May additionally USE the parent module's private entities via host association. |

## Mapping to tables

The specification part's semantic content maps to the table structure:

```
scope row
  ├── implicit_typing        ← Layer 3 summary
  ├── default_accessibility  ← module PUBLIC/PRIVATE default
  │
  ├── association (future)   ← Layers 1-2
  │     USE links, IMPORT controls
  │
  ├── declaration (future)   ← Layer 4 entities
  │     named entities with kind classification
  │     │
  │     ├── sub-tables for type info, attributes
  │     ├── sub-tables for type components
  │     └── sub-tables for interface specifics
  │
  └── implicit_rule (future) ← Layer 3 detail (when custom)
        letter → type mappings
```

The `scope_part` table (from `spec-exec.sql`) records the line extent of the specification part, enabling extraction of its source text via join to `source_code`.
