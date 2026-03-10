# specification and execution parts — design notes (v0.1.2)

## The three-part structure

Every structural scope in Fortran has up to three sequential parts:

```
[specification-part]        ← defines the name-binding environment
[execution-part]            ← consumes the environment
[internal-subprogram-part]  ← CONTAINS section (new structural scopes)
```

Not every scope kind has all three. The Fortran grammar (F2018 R504, R509, R511) defines this precisely.

## Per-scope-kind structure

| scope.kind | Specification | Execution | Internal subprograms | Notes |
|---|---|---|---|---|
| `global` | — | — | — | Implicit namespace; no syntactic realization |
| `program` | YES | YES | YES | Full three-part structure |
| `module` | YES | **NO** | YES (module-subprogram-part) | Purely declarative container |
| `submodule` | YES | **NO** | YES (module-subprogram-part) | Extends a module; purely declarative |
| `block_data` | YES | **NO** | **NO** | Most restricted: spec only, obsolescent |
| `function` | YES | YES | YES | Full three-part structure |
| `subroutine` | YES | YES | YES | Full three-part structure |
| `separate_mp` | YES | YES | YES | Full three-part structure |

Two distinct groups emerge:

- **Declarative scopes** (module, submodule, block_data): specification part only, no execution. They define environments for others to use.
- **Executable scopes** (program, function, subroutine, separate_mp): all three parts. They both define and consume environments.

The `global` scope is neither — it is an implicit container with no syntactic body.

### Module vs internal subprogram part

Modules and submodules use `module-subprogram-part` (R1407), which additionally allows `separate-module-subprogram` as a child. Internal subprogram parts (R511) in program/function/subroutine/separate_mp allow only `function-subprogram` and `subroutine-subprogram`.

This distinction matters for `separate_mp` scopes: they can only appear under a module-subprogram-part, never under an internal-subprogram-part.

## Specification part: layered ordering

The specification part (R504) has a strict internal ordering enforced by the grammar:

```
Layer 1:  USE statements                     [use-stmt]...
Layer 2:  IMPORT statements                  [import-stmt]...
Layer 3:  IMPLICIT part                      [implicit-part]
            (IMPLICIT, interspersed with PARAMETER, FORMAT, ENTRY)
Layer 4:  Declaration constructs             [declaration-construct]...
            (type declarations, interface blocks, derived type defs,
             enum defs, attribute statements, COMMON, EQUIVALENCE,
             DATA, procedure declarations — freely ordered)
```

This is a **syntactic** constraint (the grammar's production rules enforce it), not a semantic one. Statements in each layer must precede all statements in later layers.

### Layer 1: USE statements

```fortran
USE module_name [, rename-list]
USE module_name, ONLY: [only-list]
USE, INTRINSIC :: iso_fortran_env
USE, NON_INTRINSIC :: my_module
```

Must appear before everything else. Establishes module association — makes the module's public names visible in this scope.

### Layer 2: IMPORT statements (F2003+)

```fortran
IMPORT :: name_list          ! import specific names from host
IMPORT, ALL                  ! import everything from host (F2018)
IMPORT, NONE                 ! block all host association (F2018)
IMPORT, ONLY :: name_list    ! import only these (F2018)
```

Controls host association. Restricted to scopes that have a host:
- Interface bodies, internal/module subprograms, BLOCK constructs, submodules
- **Cannot** appear at top level of program, module, external procedure, or block_data

### Layer 3: IMPLICIT part

```fortran
IMPLICIT NONE
IMPLICIT NONE (TYPE, EXTERNAL)           ! F2018
IMPLICIT DOUBLE PRECISION (A-H, O-Z)
IMPLICIT INTEGER (I-N)
```

Within the implicit part, only PARAMETER, FORMAT, and ENTRY may be interspersed with IMPLICIT statements. Once the last IMPLICIT statement is reached, the implicit part ends and Layer 4 begins.

### Layer 4: Declaration constructs

Everything else in the specification part. These are freely ordered among themselves:

**Type declarations and attributes:**
- `type-declaration-stmt` — `INTEGER :: x`, `REAL, INTENT(IN) :: arr(:)`
- Attribute statements — ALLOCATABLE, ASYNCHRONOUS, BIND(C), CODIMENSION, CONTIGUOUS, DIMENSION, EXTERNAL, INTENT, INTRINSIC, NAMELIST, OPTIONAL, POINTER, PROTECTED, SAVE, TARGET, VALUE, VOLATILE
- PARAMETER, COMMON, EQUIVALENCE, DATA

**Structured declarations:**
- Interface blocks — `INTERFACE ... END INTERFACE`
- Derived type definitions — `TYPE ... END TYPE`
- Enum definitions — `ENUM, BIND(C) ... END ENUM`
- Generic statement — `GENERIC :: operator(.add.) => add_int, add_real`
- Procedure declaration — `PROCEDURE(interface) :: name`

**Module-only:**
- ACCESS statements — `PUBLIC :: name` / `PRIVATE :: name` / `PRIVATE` (default)
- PROTECTED — `PROTECTED :: module_var`

**Subprogram-only:**
- INTENT — `INTENT(IN) :: x`
- OPTIONAL — `OPTIONAL :: flag`
- VALUE — `VALUE :: c_arg`

### Cross-boundary statements

Three statement types can appear in both specification and execution parts:

| Statement | Spec part | Exec part | Status |
|---|---|---|---|
| FORMAT | YES | YES | Active |
| DATA | YES | YES | Exec-part placement obsolescent (F2018) |
| ENTRY | YES | YES | Obsolescent |

## Specification statements by scope kind

Restrictions on which specification statements may appear in which structural scope:

| Category | program | module | submodule | block_data | function/subroutine | separate_mp |
|---|---|---|---|---|---|---|
| **USE** | yes | yes | yes | yes | yes | yes |
| **IMPORT** | no | no | yes | no | yes | yes |
| **IMPLICIT** | yes | yes | yes | yes | yes | yes |
| **Type declarations** | yes | yes | yes | yes | yes | yes |
| **PARAMETER** | yes | yes | yes | yes | yes | yes |
| **Interface blocks** | yes | yes | yes | no | yes | yes |
| **Derived type defs** | yes | yes | yes | yes | yes | yes |
| **Enum defs** | yes | yes | yes | yes | yes | yes |
| **Generic stmt** | yes | yes | yes | no | yes | yes |
| **Procedure decl** | yes | yes | yes | no | yes | yes |
| **ACCESS (PUBLIC/PRIVATE)** | no | **yes** | **yes** | no | no | no |
| **PROTECTED** | no | **yes** | **yes** | no | no | no |
| **INTENT** | no | no | no | no | **yes** | **yes** |
| **OPTIONAL** | no | no | no | no | **yes** | **yes** |
| **VALUE** | no | no | no | no | **yes** | **yes** |
| **SAVE** | yes | yes | yes | yes | yes | yes |
| **COMMON** | yes | yes | yes | yes | yes | yes |
| **EQUIVALENCE** | yes | yes | yes | yes | yes | yes |
| **DATA** | yes | yes | yes | yes | yes | yes |
| **EXTERNAL** | yes | yes | yes | no | yes | yes |
| **INTRINSIC** | yes | yes | yes | no | yes | yes |
| **NAMELIST** | yes | yes | yes | no | yes | yes |
| **ENTRY** | no | no | no | no | ext. only | no |
| **Stmt function** | no | no | no | no | yes | yes |

Key patterns:
- **Universal**: USE, IMPLICIT, type declarations, PARAMETER, derived types, SAVE, COMMON, EQUIVALENCE, DATA
- **Module-only**: ACCESS, PROTECTED (control visibility to USErs)
- **Subprogram-only**: INTENT, OPTIONAL, VALUE (apply to dummy arguments)
- **Excluded from block_data**: almost everything besides basic declarations and COMMON/EQUIVALENCE/DATA

## Execution part: boundary and contents

The execution part (R509) begins with the first executable construct. Once it begins, no further specification statements may appear (only FORMAT, DATA, ENTRY may still intersperse).

Executable constructs (R514):
- Action statements (37 types): assignment, CALL, I/O, allocation, control transfers, synchronization
- Control constructs: IF, SELECT CASE/TYPE/RANK, DO, BLOCK, ASSOCIATE, WHERE, FORALL, CRITICAL, CHANGE TEAM

The boundary is syntactically unambiguous: the first statement that is neither a specification statement nor a FORMAT/DATA/ENTRY marks the start of execution.

## Relationship to the scope table

The specification part is a **property of the structural scope**, not a separate entity. It defines the name-binding environment that the scope's `scope_id` represents. Concretely:

- The specification part's declarations populate the `declaration` dimension table (keyed to `scope_id`)
- USE statements populate the `association` dimension table (USE association entries)
- IMPLICIT statements set the `implicit_typing` column on the scope row (or populate `implicit_rule` for custom rules)
- ACCESS statements set `default_accessibility` on the scope row, and per-entity accessibility on declaration rows
- The specification part's derived type definitions and interface blocks become declaration entries with structured sub-content

The execution part, when present, contains the code that the pipeline's later stages analyze (CFG, basic blocks, data flow). It is the scope's "body" — the code that runs.

## Design implications

### The specification part is the scope's environment

Each structural scope's specification part fully determines its name-binding environment. This means:
1. The scope table row (with `implicit_typing`, `default_accessibility`) captures the top-level environment properties
2. The `declaration` dimension table captures the individual names introduced
3. The `association` dimension table captures cross-scope visibility (USE, host)
4. Together, these three tables reconstruct the complete specification part semantically

No separate "specification part" table is needed — the specification part is distributed across the scope row and its dimension tables.

### The execution part is the scope's body

For executable scopes (program, function, subroutine, separate_mp), the execution part is the content that downstream pipeline stages process:
- Stage 2 (call graph): scan for CALL statements and function references
- Stage 3 (driver generation): the code to be isolated and driven
- Later stages: CFG construction, data flow, pattern mining

The execution part's statements are the eventual leaf-level entities. Their representation (as a table or otherwise) depends on decisions about control flow nesting and the specification/execution divide — deferred per the schema-design methodology.

### The internal subprogram part creates child scopes

CONTAINS introduces new structural scopes (function/subroutine children). These are already modeled by the `parent_scope_id` FK in the scope table — an internal procedure's parent is its containing scope. No additional table is needed for the CONTAINS relationship itself.

### block_data is nearly dead

block_data exists solely to initialize COMMON block variables. It has no execution part, no CONTAINS, and most specification statements are prohibited. It is obsolescent in F2018. For practical purposes, it contributes rows to the scope table and a few declarations, but needs no special handling.

## The layered ordering as a parsing guide

The 4-layer ordering within the specification part (USE → IMPORT → IMPLICIT → declarations) provides a natural parsing strategy for populating the dimension tables:

```
For each structural scope:
  1. Process USE statements → association table (USE association rows)
  2. Process IMPORT statements → association table (host association control)
  3. Process IMPLICIT statements → scope.implicit_typing + implicit_rule table
  4. Process declarations → declaration table entries
```

Each layer depends on the previous: declarations may reference USE-imported types, IMPLICIT rules affect undeclared names, and IMPORT controls which host names are visible. The grammar's ordering constraint matches the semantic dependency order.
