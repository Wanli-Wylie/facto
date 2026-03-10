# semantic recovery (exec) — what the coordinate system leaves to the parser

## What this document addresses

The fact tables (source_code, scope, scope_part, control_region, semantic_basic_block, sbb_edge) are a complete coordinate system for the execution part. They establish WHERE to look and WHAT grammar production to apply. Everything below is the semantic content that a parser extracts from the source lines within each fact-table-indexed region. These are **computed tables**, not fact tables — they are deterministically derivable from (fact table row + raw source).

## Criterion: fact table vs. computed table

| Aspect | Fact table | Computed table |
|---|---|---|
| Content | Structural index — WHERE and WHAT kind | Semantic content — reads, writes, calls, I/O |
| Derivation | Requires structural parsing (construct nesting, SBB boundaries) | Follows deterministically from fact tables + source |
| Stability | Changes only when source changes | Can be re-derived at any time |
| Role | Primary key for downstream analysis | Convenience / performance materialization |

The boundary matches the **parsing complexity cliff**: populating fact tables requires keyword-level structural parsing; populating computed tables requires full expression parsing and name resolution within bounded regions.

## What is inside each SBB

After factoring out control flow (control_region) and name bindings (binding_kind), the content of a semantic basic block is a sequence of **action statements** — the 38 atomic operation types defined by Fortran 2018 R515.

These 38 types partition into six categories by their role:

| Category | Statements | Count | Role for the pipeline |
|---|---|---|---|
| **Computation** | assignment (`=`), pointer assignment (`=>`) | 2 | Data flow: the read/write core |
| **Delegation** | CALL; function references (embedded in expressions) | 1 + embedded | Call graph edges |
| **I/O** | READ, WRITE, PRINT, OPEN, CLOSE, INQUIRE, REWIND, BACKSPACE, ENDFILE, FLUSH, WAIT | 11 | Observable behavior |
| **Allocation** | ALLOCATE, DEALLOCATE, NULLIFY | 3 | Memory effects: shape/lifetime |
| **Control transfer** | GOTO, computed GOTO, CYCLE, EXIT, RETURN, STOP, ERROR STOP, FAIL IMAGE, CONTINUE | 9 | Already captured in sbb_edge |
| **Synchronization** | SYNC ALL/IMAGES/MEMORY/TEAM, LOCK, UNLOCK, EVENT POST/WAIT, FORM TEAM | 9 | Coarray markers (irrelevant for single-image) |

Plus 3 one-line compound forms (IF-stmt, WHERE-stmt, FORALL-stmt) that expand into implicit control_regions during CCT construction, and 3 cross-boundary statements (FORMAT, DATA, ENTRY).

Control transfer statements are already encoded structurally (as sbb_edge entries). Synchronization is irrelevant for single-image analysis. The computed tables needed are for the remaining four categories: **computation, delegation, I/O, allocation**.

## Five computed tables

Each computed table is keyed to a fact table row (SBB or control_region) and computed by analyzing the source text at those coordinates.

### 1. data_access — reads and writes per SBB

The foundation for the bipartite access graph (SBB × memory object).

| Column | Description |
|---|---|
| sbb_id | FK → semantic_basic_block |
| name | The variable/array name referenced |
| direction | `read`, `write`, or `readwrite` |
| access_pattern | `scalar`, `element`, `section`, `whole_array` |
| lineno | Source line of the access |

**Derived from** all action statements: assignment LHS/RHS, CALL arguments (INTENT-dependent), READ variable list, WRITE expression list, ALLOCATE shape expressions and target, DEALLOCATE target, INQUIRE specifier variables.

**Read set** = all names whose values are consumed (RHS of assignment, subscript expressions in LHS, INTENT(IN/INOUT) arguments, WRITE data items, ALLOCATE shape bounds).

**Write set** = all names whose values are defined (LHS of assignment, INTENT(OUT/INOUT) arguments, READ data items, ALLOCATE target, IOSTAT/STAT/ERRMSG specifiers).

**Requires:** name resolution (which declaration does this name refer to?) and, for CALL arguments, the callee's interface (INTENT attributes). Name resolution uses the context recovered from the containment chain (Condition 3: layered dependency order).

### 2. call_edge — procedure calls per SBB

The raw material for call graph construction (Stage 2).

| Column | Description |
|---|---|
| sbb_id | FK → semantic_basic_block |
| callee_name | Resolved procedure name |
| call_kind | `call_stmt`, `function_ref`, `defined_operator`, `defined_assignment` |
| lineno | Source line of the call |

Argument association (actual ↔ dummy mapping) is a sub-table keyed to call_edge:

| Column | Description |
|---|---|
| position | Argument position (1-based) |
| keyword | Keyword name if keyword association, else NULL |
| actual_expr | Source text of the actual argument expression |

**Derived from** CALL statements and function references embedded in expressions. A single assignment like `y = f(a) + g(b, c)` produces two call_edge rows (one for f, one for g).

**Requires:** name resolution (is `f` a function? which one — generic resolution may be needed) and expression parsing (to find function references within expressions).

### 3. io_operation — I/O statements per SBB

The program's interface with its external environment.

| Column | Description |
|---|---|
| sbb_id | FK → semantic_basic_block |
| kind | `read`, `write`, `print`, `open`, `close`, `inquire`, `rewind`, `backspace`, `endfile`, `flush`, `wait` |
| unit_expr | Unit expression (source text), `*` for default, or variable name for internal I/O |
| format_expr | Format expression, label, `*` for list-directed, or NAMELIST name |
| lineno | Source line |

Data items (the variables/expressions transferred) are a sub-table:

| Column | Description |
|---|---|
| position | Position in I/O list (1-based) |
| item_expr | Source text of the data item |
| direction | `read` (for READ items) or `write` (for WRITE/PRINT items) |

**Derived from** I/O statements. Also extracts specifier information (IOSTAT, ERR/END/EOR labels — though the label-based edges are already in sbb_edge).

**Requires:** minimal semantic analysis — I/O statements are syntactically distinctive. Unit and format expressions may need name resolution for variable references.

### 4. allocation_event — ALLOCATE/DEALLOCATE per SBB

Memory lifecycle events that change the existence and shape of objects.

| Column | Description |
|---|---|
| sbb_id | FK → semantic_basic_block |
| kind | `allocate`, `deallocate`, `nullify` |
| object_name | The ALLOCATABLE/POINTER variable name |
| lineno | Source line |

Shape information (for ALLOCATE) is a sub-table:

| Column | Description |
|---|---|
| dimension | Dimension index (1, 2, ...) |
| lower_bound | Source text of lower bound expression |
| upper_bound | Source text of upper bound expression |

**Derived from** ALLOCATE/DEALLOCATE/NULLIFY statements. Shape bounds are expressions in the ALLOCATE argument list.

**Requires:** parsing the ALLOCATE syntax, name resolution for the allocated variable and bound expressions.

### 5. construct_entity — names introduced by binding-changing control_regions

The naming system within the execution part: BLOCK locals, DO CONCURRENT index variables, ASSOCIATE aliases, SELECT TYPE/RANK selectors.

| Column | Description |
|---|---|
| region_id | FK → control_region (where binding_kind != 'none') |
| entity_name | The introduced name |
| entity_kind | `variable`, `index`, `alias`, `type_narrowing`, `rank_narrowing` |

This table bridges the naming system (currently rooted at scope) into the execution part's internal structure. It is keyed to `control_region`, not `SBB`, because the introduced names have construct scope — they are visible throughout the construct body, not just one SBB.

**Derived from:**
- BLOCK: the BLOCK's specification part (USE, IMPLICIT, declarations) — uses the same analysis as scope-level declarations
- DO CONCURRENT / FORALL: the index variable in the construct header
- ASSOCIATE: the associate-name list in the ASSOCIATE statement
- SELECT TYPE / SELECT RANK: the selector with per-arm type/rank narrowing

**Requires:** for BLOCK, full specification-part analysis (same as structural scopes). For others, parsing the construct header — the entities are enumerable from syntax alone.

## The expression problem

Within computation statements (assignment, CALL arguments), the actual numerical work resides in **expressions** — unbounded-depth trees of arithmetic, relational, logical, and array operations.

```fortran
y = ((a + b) * (c - d)) / sqrt(e**2 + f**2)
```

Expressions are left-recursive. Per the schema-design methodology, they should be treated as objects. The computed tables above handle expressions by extracting **flat properties** (read/write sets, callee names, source text of sub-expressions) without representing the tree structure.

For the pipeline's primary needs (data flow, call graph, bipartite access graph), flat read/write sets are sufficient. The expression tree structure matters only for **pattern mining** (recognizing idioms like dot product, AXPY, GEMM). Pattern mining can use:

- **Abstract tokens**: classify each statement by its operation pattern (`ACCUM_SCALAR(READ_2D, READ_1D)`)
- **Serialized AST**: store the expression tree as JSON per statement for detailed analysis

Both are additional computed tables, computed from source text at SBB coordinates, needed only when the pattern-mining stage runs. They are not required for the pipeline's core stages (1–6).

## Mapping to pipeline stages

| Pipeline stage | Consumes which computed tables |
|---|---|
| Stage 2: Call graph | `call_edge` (callee identity, argument association) |
| Stage 3: Driver generation | `call_edge` + `io_operation` + `allocation_event` + `construct_entity` |
| Stage 4: Observation panel | `io_operation` + `data_access` |
| Stage 5: Input distribution | `allocation_event` (shapes) + `data_access` (constraints) |
| Stage 6: Ground truth | All computed tables, integrated |
| Complementary: Pattern mining | `data_access` (bipartite graph) + abstract tokens / serialized AST |

## Summary

```
FACT TABLES (coordinates — WHERE)
  source_code → scope → scope_part → control_region → SBB → sbb_edge

COMPUTED TABLES (semantics — WHAT, derived from source text at coordinates)
  data_access         read/write sets per SBB               → bipartite access graph
  call_edge           procedure calls per SBB               → call graph
  io_operation        I/O statements per SBB                → observable behavior
  allocation_event    ALLOCATE/DEALLOCATE per SBB           → memory lifecycle
  construct_entity    names per binding-changing region      → naming system extension

  (deferred)
  abstract_token      pattern token per SBB                 → pattern mining
  serialized_ast      expression tree per statement         → idiom recognition
```

Each computed table = `parse(source_lines, grammar_production, environment)`, where all three inputs are determined by the fact tables + raw source.

## Materialization decision

Whether to persist these as database tables is a **performance** decision, not a **data modeling** decision:

- **Materialize** when the computed content is frequently queried by downstream analysis stages
- **Compute on demand** when the content is rarely needed or the source region is small
- **Store as CST attributes** when tightly coupled to the concrete syntax tree

The fact tables remain the ground truth. Computed tables are caches.
