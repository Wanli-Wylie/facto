# semantic recovery — what the coordinate system leaves to the parser

The fact tables establish WHERE to look and WHAT grammar production to apply. Everything below is the semantic content that a parser extracts from the source lines within each fact-table-indexed region. These are **computed tables**, not fact tables — they are deterministically derivable from (fact table row + raw source).

## Criterion: fact table vs. computed table

| Aspect | Fact table | Computed table |
|---|---|---|
| Content | Structural index — WHERE and WHAT kind | Semantic content — names, types, values |
| Derivation | Requires structural parsing (scope boundaries, construct nesting) | Follows deterministically from fact tables + source |
| Stability | Changes only when source changes | Can be re-derived at any time |
| Role | Primary key for downstream analysis | Convenience / performance materialization |

The boundary matches the **parsing complexity cliff**: populating fact tables requires keyword-level structural parsing; populating computed tables requires full Fortran grammar parsing within bounded regions.

## Recovery by construct kind

### Block constructs (multi-line, have internal structure)

**derived_type_def** (R726) — parse lines within `[start_line, end_line]`:

| Semantic content | Description |
|---|---|
| Type parameters | KIND and LEN parameter names with ordering |
| Type-level attributes | ABSTRACT, BIND(C), SEQUENCE, EXTENDS(parent-type) |
| Data components | Name, type-spec, attributes (ALLOCATABLE, POINTER, CODIMENSION, ...), initialization |
| Procedure components | Name, interface, PASS/NOPASS, access |
| Type-bound procedures | Binding name, implementation name, DEFERRED/NON_OVERRIDABLE, access |
| Generic bindings | Generic-spec → specific binding list |
| Final procedures | Subroutine name list |

**interface_block** (R1501) — parse lines within `[start_line, end_line]`:

| Semantic content | Description |
|---|---|
| Interface form | Unnamed, named/generic, OPERATOR(...), ASSIGNMENT(=), defined-I/O, ABSTRACT |
| Interface body signatures | For each body: procedure name, argument names, argument types/intents, result type |
| Module procedure references | Names of specific procedures (MODULE PROCEDURE list) |
| TKR resolution data | Argument type-kind-rank patterns for generic dispatch |

**enum_def** (R759) — parse lines within `[start_line, end_line]`:

| Semantic content | Description |
|---|---|
| Enumerators | Name-value pairs with ordinal position |
| BIND(C) | Always present (F2008/F2018 enums are C-interoperable) |

### Statement constructs (single-line, declare or modify entities)

**type_declaration** (R801) — the richest single-line construct:

| Semantic content | Description |
|---|---|
| Type specification | Intrinsic type + kind/len, or derived type reference, or CLASS (polymorphic) |
| Entity names | List of declared variable/constant names |
| Per-entity array spec | Shape: explicit, assumed-shape, deferred, assumed-size, assumed-rank, implied-shape |
| Per-entity initialization | `= expr` or `=> target` |
| Attributes | Up to 18 boolean/parametric attributes: ALLOCATABLE, POINTER, TARGET, INTENT(IN/OUT/INOUT), DIMENSION(...), OPTIONAL, SAVE, PARAMETER, VOLATILE, ASYNCHRONOUS, CONTIGUOUS, VALUE, PROTECTED, BIND(C), CODIMENSION, EXTERNAL, INTRINSIC, ACCESS |

**generic_stmt** (R1510):

| Semantic content | Description |
|---|---|
| Generic name/spec | Name, OPERATOR, ASSIGNMENT, or defined-I/O spec |
| Specific list | Procedure names this generic resolves to |
| Access | PUBLIC/PRIVATE if specified |

**procedure_decl** (R1512):

| Semantic content | Description |
|---|---|
| Procedure interface | Named interface or implicit |
| Entity names | Declared procedure names |
| Attributes | POINTER, PASS/NOPASS, access, INTENT, OPTIONAL |
| Initialization | `=> NULL()` or `=> procedure-name` |

**parameter_stmt** (R855):

| Semantic content | Description |
|---|---|
| Name-value pairs | Each named constant and its defining expression |

**access_stmt** (R827):

| Semantic content | Description |
|---|---|
| Access type | PUBLIC or PRIVATE |
| Scope | Default (no name list) or specific names |

**attribute_stmt** (R813 — other-specification-stmt):

| Semantic content | Description |
|---|---|
| Attribute kind | DIMENSION, ALLOCATABLE, ASYNCHRONOUS, BIND(C), CODIMENSION, CONTIGUOUS, EXTERNAL, INTENT, INTRINSIC, OPTIONAL, POINTER, PROTECTED, SAVE, TARGET, VALUE, VOLATILE |
| Target names | Entity names receiving this attribute |
| Attribute parameters | Dimension bounds, INTENT direction, BIND name, CODIMENSION cobounds |

**common_stmt** (R873):

| Semantic content | Description |
|---|---|
| Block name | Named or blank COMMON |
| Members | Ordered list of variable names with optional array specs |

**equivalence_stmt** (R870):

| Semantic content | Description |
|---|---|
| Sets | Groups of variables declared to share storage |
| Subobject references | Substring or array element designators within each set |

**namelist_stmt** (R868):

| Semantic content | Description |
|---|---|
| Group name | NAMELIST group identifier |
| Members | Ordered list of variable names |

**external_stmt** / **intrinsic_stmt** (R1519):

| Semantic content | Description |
|---|---|
| Names | Procedure names given the EXTERNAL or INTRINSIC attribute |

**data_stmt** (R837):

| Semantic content | Description |
|---|---|
| Object lists | Variables, array elements, substrings, implied-do lists |
| Value lists | Constant expressions with optional repeat counts |

### Cross-boundary and obsolescent

**format_stmt** (R1001):

| Semantic content | Description |
|---|---|
| Label | Statement label (required) |
| Format items | Edit descriptors, repeat counts, nested groups |

**entry_stmt** (R1541):

| Semantic content | Description |
|---|---|
| Entry name | Alternate entry point name |
| Argument list | Dummy argument names (may differ from main procedure) |
| Result clause | Optional RESULT variable name |

**stmt_function** (R1544):

| Semantic content | Description |
|---|---|
| Function name | Statement function name |
| Arguments | Dummy argument names |
| Expression | Defining scalar expression |

## Recovery by specification layer

The computed content organizes into five progressive layers beyond the fact tables:

```
fact tables (structural index)          computed tables (parser output)
──────────────────────────              ────────────────────────────
                                        Layer C1: Named entities
declaration_construct              →      entity names, their origin construct
                                          (one entity per row)

                                        Layer C2: Type specifications
                                   →      type category, kind, len, polymorphic status
                                          (one type-spec per entity)

                                        Layer C3: Entity attributes
                                   →      boolean + parametric attributes
                                          array spec (shape kind, rank, bounds)
                                          (attribute set per entity)

                                        Layer C4: Block construct internals
derived_type_def, interface_block, →      components, bindings, parameters,
enum_def                                  interface bodies, enumerators
                                          (internal structure per block construct)

                                        Layer C5: Cross-entity relationships
                                   →      COMMON member ordering
                                          NAMELIST member ordering
                                          EQUIVALENCE set membership
                                          procedure argument ordering
                                          generic resolution (TKR)
```

Each computed layer depends only on the fact tables and the computed layers before it. A parser processes them in order C1 → C2 → C3 → C4 → C5, mirroring the layered dependency principle of the coordinate system itself.

## Materialization decision

Whether to persist these as database tables is a **performance** decision, not a **data modeling** decision:

- **Materialize** when the computed content is frequently queried by downstream analysis stages
- **Compute on demand** when the content is rarely needed or the source region is small
- **Store as CST attributes** when tightly coupled to the concrete syntax tree

The fact tables remain the ground truth. Computed tables are caches.
