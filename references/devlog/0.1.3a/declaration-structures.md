# declaration constructs — research notes (Layer 4)

## Grammar overview

The declaration-construct region (F2018 R507) is the fourth and final layer of the specification part, after USE, IMPORT, and IMPLICIT. Statements within this region are freely ordered relative to each other.

```
R507  declaration-construct →
        specification-construct
      | data-stmt
      | format-stmt
      | entry-stmt           (obsolescent)
      | stmt-function-stmt   (obsolescent)

R508  specification-construct →
        derived-type-def
      | enum-def
      | generic-stmt
      | interface-block
      | parameter-stmt
      | procedure-declaration-stmt
      | other-specification-stmt
      | type-declaration-stmt
```

## 1. Type declaration statements

### Grammar

```
R801  type-declaration-stmt →
        declaration-type-spec [[, attr-spec]... ::] entity-decl-list
```

### Declaration type specifiers

```
R703  declaration-type-spec →
        intrinsic-type-spec              ! INTEGER, REAL, etc.
      | TYPE ( intrinsic-type-spec )     ! TYPE(INTEGER)
      | TYPE ( derived-type-spec )       ! TYPE(matrix_t)
      | CLASS ( derived-type-spec )      ! polymorphic
      | CLASS ( * )                      ! unlimited polymorphic
      | TYPE ( * )                       ! assumed type (F2018)
```

### Intrinsic types

| Type | KIND parameter | LEN parameter | Notes |
|---|---|---|---|
| INTEGER | Selects precision/range | — | Default kind is processor-dependent |
| REAL | Selects precision | — | |
| DOUBLE PRECISION | (fixed, no selector) | — | Legacy; typically kind=8 |
| COMPLEX | Selects precision of both parts | — | |
| CHARACTER | Selects encoding | Yes: length of string | LEN=* (assumed), LEN=: (deferred) |
| LOGICAL | Selects representation | — | |

### All attributes (attr-spec, R802)

```
access-spec (PUBLIC | PRIVATE)    ALLOCATABLE    ASYNCHRONOUS
BIND(C [, NAME=...])              CODIMENSION    CONTIGUOUS
DIMENSION(array-spec)             EXTERNAL       INTENT(IN|OUT|INOUT)
INTRINSIC                         OPTIONAL       PARAMETER
POINTER                           PROTECTED      SAVE
TARGET                            VALUE          VOLATILE
```

### Key attribute incompatibilities

| Attribute | Incompatible with |
|---|---|
| PARAMETER | ALLOCATABLE, POINTER, INTENT, OPTIONAL, SAVE, TARGET, VALUE, VOLATILE, ASYNCHRONOUS, CODIMENSION, PROTECTED |
| POINTER | ALLOCATABLE, TARGET, VALUE, CODIMENSION |
| ALLOCATABLE | POINTER, PARAMETER, EXTERNAL, INTRINSIC, VALUE |
| EXTERNAL | INTRINSIC, ALLOCATABLE, TARGET, SAVE, PARAMETER, VALUE, VOLATILE |
| INTRINSIC | EXTERNAL, and essentially all data attributes |
| VALUE | ALLOCATABLE, POINTER, INTENT(OUT), INTENT(INOUT), CODIMENSION, ASYNCHRONOUS |
| CONTIGUOUS | Only meaningful with POINTER or assumed-shape array |
| PROTECTED | Only in modules; not for COMMON block members |

### Array specifications (7 forms)

| Form | Syntax | Where allowed | Requires |
|---|---|---|---|
| Explicit-shape | `(10)`, `(0:n, m)` | Anywhere | — |
| Assumed-shape | `(:)`, `(0:, :)` | Dummy arguments | Not ALLOCATABLE, not POINTER |
| Deferred-shape | `(:)`, `(:,:)` | Anywhere | ALLOCATABLE or POINTER |
| Assumed-size | `(*)`, `(10, *)` | Dummy arguments (last dim) | Legacy |
| Implied-shape | `(*)` | Named constants | PARAMETER |
| Assumed-rank | `(..)` | Dummy arguments (F2018) | Not ALLOCATABLE, not POINTER |

### Coarray specifications

- Explicit coshape: `[10, *]` — last upper cobound is always `*`
- Deferred coshape: `[:, :]` — requires ALLOCATABLE

### Initialization

- `= constant-expr` — value initialization (implies SAVE in procedures)
- `=> null()` — pointer nullification
- `=> initial-data-target` — pointer initialization to SAVE/TARGET entity

## 2. Derived type definitions

### Grammar

```
R726  derived-type-def →
        derived-type-stmt
        [type-param-def-stmt]...
        [private-or-sequence]...
        [component-part]
        [type-bound-procedure-part]
        end-type-stmt

R727  derived-type-stmt →
        TYPE [[, type-attr-spec-list] ::] type-name [(type-param-name-list)]

R728  type-attr-spec → ABSTRACT | access-spec | BIND(C) | EXTENDS(parent-type-name)
```

### Type attributes

| Attribute | Effect | Incompatible with |
|---|---|---|
| ABSTRACT | Cannot instantiate; allows DEFERRED bindings | BIND(C), SEQUENCE |
| BIND(C) | C-interoperable struct | EXTENDS, SEQUENCE, type parameters, type-bound procedures |
| EXTENDS(parent) | Inherits components and bindings | BIND(C), SEQUENCE |
| SEQUENCE | Components in declaration order; enables EQUIVALENCE/COMMON | BIND(C), EXTENDS, ALLOCATABLE/POINTER components |

### Type parameters

```
R732  type-param-def-stmt → integer-type-spec , type-param-attr-spec :: type-param-decl-list
R734  type-param-attr-spec → KIND | LEN
```

- KIND parameters: compile-time. Parameterize component types.
- LEN parameters: runtime. Parameterize deferred-length components.
- Can have defaults: `integer, kind :: k = kind(0.0)`

### Data components

```
R737  data-component-def-stmt →
        declaration-type-spec [[, component-attr-spec-list] ::] component-decl-list

R738  component-attr-spec →
        access-spec | ALLOCATABLE | CODIMENSION | CONTIGUOUS | DIMENSION | POINTER
```

Allowed attributes: ALLOCATABLE, POINTER, DIMENSION, CODIMENSION, CONTIGUOUS, access-spec.

**Not allowed on components**: INTENT, OPTIONAL, SAVE, PARAMETER, TARGET, EXTERNAL, INTRINSIC, VALUE, VOLATILE, ASYNCHRONOUS, PROTECTED, BIND(C).

Component arrays: explicit-shape or deferred-shape only (no assumed-shape, assumed-size, assumed-rank).

Default initialization: `integer :: count = 0` or `real, pointer :: ptr => null()`.

### Procedure components

```
R741  proc-component-def-stmt →
        PROCEDURE ([proc-interface]) , proc-component-attr-spec-list :: proc-decl-list

R742  proc-component-attr-spec → access-spec | NOPASS | PASS [(arg-name)] | POINTER
```

Procedure components always require POINTER. PASS (default) means the first argument receives the invoking object as `CLASS(type)`. NOPASS means no implicit argument.

### Type-bound procedure part

```
R746  type-bound-procedure-part →
        contains-stmt [binding-private-stmt] [type-bound-proc-binding]...

R748  type-bound-proc-binding →
        type-bound-procedure-stmt | type-bound-generic-stmt | final-procedure-stmt
```

**Specific bindings:**
```fortran
PROCEDURE :: binding_name => implementation_name
PROCEDURE, DEFERRED :: binding_name        ! ABSTRACT type only
PROCEDURE, NON_OVERRIDABLE :: binding_name ! cannot override in extensions
```

Bind attributes: access-spec, DEFERRED, NON_OVERRIDABLE, NOPASS, PASS.

**Generic bindings:**
```fortran
GENERIC :: generic_name => specific1, specific2
GENERIC :: OPERATOR(.add.) => add_int, add_real
GENERIC :: ASSIGNMENT(=) => assign_from_int
```

Dispatches by TKR of arguments.

**Final procedures:**
```fortran
FINAL :: destructor_rank0, destructor_rank1
```

Called automatically on finalization. Each takes one dummy argument of the type, differing by rank.

### Nesting rule

Derived type definitions **cannot nest** inside other type definitions. A component's type must reference a previously defined type. Self-reference is allowed through POINTER or ALLOCATABLE components (recursive types).

## 3. Interface blocks

### Grammar

```
R1501  interface-block →
         interface-stmt [interface-specification]... end-interface-stmt

R1503  interface-stmt →
         INTERFACE [generic-spec]
       | ABSTRACT INTERFACE

R1506  procedure-stmt → [MODULE] PROCEDURE [::] specific-procedure-list

R1508  generic-spec →
         generic-name
       | OPERATOR ( defined-operator )
       | ASSIGNMENT ( = )
       | defined-io-generic-spec
```

### Forms

| Form | Purpose |
|---|---|
| `INTERFACE` (unnamed) | Provide explicit interface for external/dummy procedures |
| `INTERFACE generic-name` | Create generic name dispatching to specific procedures |
| `INTERFACE OPERATOR(.op.)` | Define/extend operator for user types |
| `INTERFACE ASSIGNMENT(=)` | Define custom assignment |
| `INTERFACE READ/WRITE(FORMATTED/UNFORMATTED)` | Define I/O for user types |
| `ABSTRACT INTERFACE` | Define interface template for PROCEDURE declarations and DEFERRED bindings |

### Contents

- **Interface bodies**: full procedure header + argument declarations (a copy of the signature). Represent external procedures.
- **MODULE PROCEDURE**: references an already-accessible module procedure by name. Only allowed when generic-spec is present.

### Generic resolution rules (TKR)

Specific procedures under a generic must be distinguishable by at least one argument position where dummy arguments differ in **T**ype, **K**ind, or **R**ank. ALLOCATABLE vs POINTER does not contribute to disambiguation. Any ambiguity is a compile-time error.

### Standalone GENERIC statement (F2018)

```
R1510  generic-stmt → GENERIC [, access-spec] :: generic-spec => specific-procedure-list
```

Compact alternative to a full generic interface block.

## 4. Procedure declarations

### PROCEDURE declaration (F2003+)

```
R1512  procedure-declaration-stmt →
         PROCEDURE ([proc-interface]) [[, proc-attr-spec]... ::] proc-decl-list

R1514  proc-attr-spec → access-spec | BIND(C) | INTENT | OPTIONAL | POINTER | PROTECTED | SAVE
```

- `PROCEDURE(interface_name)` — explicit interface from abstract interface or procedure
- `PROCEDURE(type_spec)` — function returning that type (implicit interface otherwise)
- Adding POINTER makes it a procedure pointer
- Initialization: `=> NULL()` or `=> proc_name`

### EXTERNAL and INTRINSIC statements

- EXTERNAL: declares a name as an external procedure (implicit interface). Required when passing as actual argument.
- INTRINSIC: declares a name as an intrinsic procedure. Required when passing as actual argument.
- Mutually exclusive.
- EXTERNAL is legacy; modern Fortran prefers interface blocks or PROCEDURE.

## 5. Group entities

### COMMON blocks

```
R873  common-stmt → COMMON [/ [common-block-name] /] common-block-object-list ...
```

- Blank common: `COMMON // x, y` or `COMMON x, y`
- Named common: `COMMON /block_name/ a, b, c`
- Storage association by position across program units
- Members cannot be ALLOCATABLE, POINTER, or have such components
- Obsolescent; replaced by module variables

### EQUIVALENCE

```
R870  equivalence-stmt → EQUIVALENCE equivalence-set-list
R871  equivalence-set → ( equivalence-object , equivalence-object-list )
```

- Variables share same storage location
- Cannot equivalence ALLOCATABLE, POINTER, or TARGET entities
- Obsolescent; replaced by derived types and proper data design

### NAMELIST

```
R868  namelist-stmt → NAMELIST / group-name / variable-list ...
```

- Named groups of variables for NAMELIST-directed I/O
- Used with `READ(unit, NML=group_name)` and `WRITE(unit, NML=group_name)`

## 6. Enum definitions

```
R759  enum-def → ENUM, BIND(C) enumerator-def-stmt... END ENUM
R762  enumerator → named-constant [= scalar-int-constant-expr]
```

- Always BIND(C) — exists for C interoperability
- Values default to 0, then increment by 1
- All enumerators have kind C_INT
- **Not a named type** in F2018 — enumerators are just named integer constants with no type safety
- Named/typed enums proposed for future standards

## 7. Obsolescent constructs

### Statement functions

```
R1544  stmt-function-stmt → function-name ( [dummy-arg-name-list] ) = scalar-expr
```

Single-expression inline function. Superseded by internal functions.

### ENTRY

```
R1541  entry-stmt → ENTRY entry-name [( [dummy-arg-list] ) [suffix]]
```

Alternate entry point with its own argument list. Only in external function/subroutine. Superseded by separate procedures.

## 8. DATA statements (in specification part)

```
R837  data-stmt → DATA data-stmt-set [[,] data-stmt-set]...
```

- Provides initial values for variables
- Supports implied-DO for arrays: `DATA (a(i), i=1,10) /10*0.0/`
- Implies SAVE for local procedure variables
- Cannot initialize ALLOCATABLE, POINTER, or dummy arguments

## 9. Scope restrictions

| Construct | program | module | submodule | block_data | function/subroutine | separate_mp |
|---|---|---|---|---|---|---|
| type-declaration-stmt | yes | yes | yes | yes | yes | yes |
| derived-type-def | yes | yes | yes | no | yes | yes |
| interface-block | yes | yes | yes | no | yes | yes |
| enum-def | yes | yes | yes | no | yes | yes |
| generic-stmt | yes | yes | yes | no | yes | yes |
| procedure-declaration-stmt | yes | yes | yes | no | yes | yes |
| ACCESS (PUBLIC/PRIVATE) | no | yes | yes | no | no | no |
| PROTECTED | no | yes | yes | no | no | no |
| INTENT / OPTIONAL / VALUE | no | no | no | no | yes | yes |
| COMMON | yes | yes | yes | yes | yes | yes |
| EQUIVALENCE | yes | yes | yes | yes | yes | yes |
| NAMELIST | yes | yes | yes | no | yes | yes |
| ENTRY | no | no | no | no | ext. only | no |
| stmt-function | no | no | no | no | yes | yes |

## 10. Structural relationships

Key entity relationships within the declaration layer:

1. **Derived type HAS** data components + procedure components + type-bound procedures + type parameters + final procedures
2. **Generic interface HAS** specific procedures. Resolution by TKR.
3. **Type extension INHERITS** all components and bindings from parent; can add/override
4. **ABSTRACT type HAS** DEFERRED bindings that extensions must implement
5. **COMMON block HAS** ordered member list (storage association by position)
6. **NAMELIST group REFERENCES** existing variables
7. **Procedure pointer** (PROCEDURE with POINTER, or proc-component) can be dynamically reassigned
8. **No nesting** of type definitions — avoids left-recursion in the declaration layer
