# v0.1.6: unit test plan for modular processors

Each processor is a pure function: `DataFrame → (DataFrame, DataFrame)`. Tests verify: given a Fortran source pattern, the processor produces the correct fact rows and the correct residual for the next step.

Tests are organized by processor. Each section lists the **Fortran patterns** the processor must handle, what the **fact output** should contain, and what the **residual** should carry forward.

---

## 0. parse_source

Entry point. Input: file path. Output: (`source_line`, `file_residual`).

### Patterns

| Pattern | Source | Expected |
|---|---|---|
| Single program unit | `PROGRAM hello ... END PROGRAM` | source_line: one row per line; residual: one row, full text, ast_kind=`'Program'` |
| Multiple program units | module + external subroutine in one file | source_line: all lines; residual: one row per top-level unit |
| Empty file | blank or comment-only | source_line: rows for each line (including blanks/comments); residual: empty DataFrame |
| Fixed-form source | column-based layout with continuation in col 6 | source_line preserves original lines; fparser handles continuation |
| Free-form with continuations | `&` at end-of-line | source_line preserves raw lines; CST spans cover logical statements |

### Fact: source_line

- One row per physical line in the file
- Line numbers are 1-based, contiguous, complete

### Residual: file_residual

- `text`: full source text of each top-level program unit
- `ast_kind`: fparser class name of the root node (e.g., `'Program'`, `'Module'`, `'Subroutine_Subprogram'`)

---

## 1. parse_scopes

Input: file_residual. Output: (`scope`, `scope_residual`).

### Patterns

| Pattern | Fortran | scope rows expected |
|---|---|---|
| **Standalone program** | `PROGRAM main ... END PROGRAM` | 1 scope: kind=`program`, name=`main` |
| **Module** | `MODULE mymod ... END MODULE` | 1 scope: kind=`module` |
| **Module with internal procedures** | `MODULE m ... CONTAINS ... SUBROUTINE s ... FUNCTION f ...` | 3 scopes: module + subroutine + function; subroutine/function have parent_scope_id → module |
| **External subroutine** | `SUBROUTINE sub(x) ... END SUBROUTINE` (no enclosing program) | 1 scope: kind=`subroutine` |
| **External function** | `FUNCTION f(x) RESULT(r) ... END FUNCTION` | 1 scope: kind=`function` |
| **Block data** | `BLOCK DATA init ... END BLOCK DATA` | 1 scope: kind=`block_data` |
| **Submodule** | `SUBMODULE (parent) child ... END SUBMODULE` | 1 scope: kind=`submodule`, ancestor_scope_id referencing parent by name |
| **Nested: program + internal procedures** | `PROGRAM p ... CONTAINS ... SUBROUTINE s1 ... SUBROUTINE s2 ...` | 3 scopes: program + 2 subroutines; parent_scope_id links correct |
| **Deeply nested** | module → contains → subroutine → contains → function | parent_scope_id chain: function → subroutine → module |
| **Unnamed program** | statements without `PROGRAM` keyword | 1 scope: kind=`program`, name=NULL |

### Fact: scope

- `scope_id`: unique per scope, locally assigned (0, 1, 2, ...)
- `parent_scope_id`: NULL for top-level scopes, FK to containing scope otherwise
- `kind`: one of 8 values
- `name`: from program-unit header; NULL if unnamed
- `filename`, `start_line`, `end_line`: span of entire scope including END statement
- `implicit_typing`: default value `'default'` (updated later by parse_implicit)

### Residual: scope_residual

- One row per scope
- `scope_id`: FK to fact table
- `text`: source text of the scope body (between header and END, exclusive)
- `ast_kind`: fparser class name (e.g., `'Module'`, `'Subroutine_Subprogram'`)

---

## 2. segment_parts

Input: scope_residual. Output: (`scope_part`, `part_residual`).

### Patterns

| Pattern | Fortran | parts produced |
|---|---|---|
| **Spec + exec + subprogram** | `SUBROUTINE s ... INTEGER :: x ... x = 1 ... CONTAINS ... FUNCTION f ...` | 3 rows: specification, execution, subprogram |
| **Spec only** | `MODULE m ... INTEGER, PARAMETER :: n = 10 ... END MODULE` | 1 row: specification |
| **Spec + exec** | `PROGRAM p ... INTEGER :: x ... x = 1 ... END PROGRAM` | 2 rows: specification, execution |
| **Spec + subprogram** | `MODULE m ... INTEGER :: n ... CONTAINS ... SUBROUTINE s ...` | 2 rows: specification, subprogram |
| **Empty spec** | `SUBROUTINE s ... CALL foo() ... END SUBROUTINE` (no declarations) | execution only (or spec with zero-width range) |
| **Block data** | `BLOCK DATA bd ... COMMON /blk/ a, b ... DATA a, b / 1, 2 / ... END` | 1 row: specification (block_data has no execution part) |

### Fact: scope_part

- `scope_id`: FK to scope
- `part`: `'specification'` | `'execution'` | `'subprogram'`
- `start_line`, `end_line`: line range of this section (non-overlapping, ordered)

### Residual: part_residual

- One row per scope part
- `scope_id`, `part`: FK to fact table
- `text`: source text of that part
- `ast_kind`: `'Specification_Part'` | `'Execution_Part'` | `'Internal_Subprogram_Part'`

### Key invariant

Parts are strictly ordered and non-overlapping within each scope. Their line ranges cover the scope body completely (no gaps).

---

## 3. parse_use

Input: part_residual (filtered to `part == 'specification'`). Output: (`use_stmt`, `post_use_residual`).

### Patterns

| Pattern | Fortran | use_stmt rows | Notes |
|---|---|---|---|
| **Simple USE** | `USE mymod` | 1 row: module_name=`mymod`, nature=`unspecified`, only_clause=False | |
| **USE with ONLY** | `USE mymod, ONLY : foo, bar` | 1 row: only_clause=True | Entity extraction deferred to parse_use_entities |
| **USE with renames** | `USE mymod, local => remote` | 1 row: only_clause=False | |
| **USE INTRINSIC** | `USE, INTRINSIC :: iso_fortran_env` | 1 row: nature=`intrinsic` | |
| **USE NON_INTRINSIC** | `USE, NON_INTRINSIC :: mymod` | 1 row: nature=`non_intrinsic` | |
| **Multiple USE statements** | 3 USE statements in one spec part | 3 rows, each with distinct use_id | |
| **No USE statements** | spec part with only declarations | 0 rows; residual = input unchanged | |
| **USE + ONLY + renames** | `USE mymod, ONLY : x, y => local_y` | 1 row: only_clause=True | |

### Fact: use_stmt

- `use_id`: locally unique
- `scope_id`: from the residual's scope_id
- `module_name`: string (case-insensitive in Fortran, stored lowercase or as-is)
- `nature`: `'unspecified'` | `'intrinsic'` | `'non_intrinsic'`
- `only_clause`: boolean
- `start_line`: line number of the USE statement

### Residual: post_use_residual

- Same rows as input, but `text` narrowed: USE lines consumed
- `start_line` advanced past last USE statement (or text content updated)
- Remaining text contains IMPORT, IMPLICIT, and declaration lines only

---

## 4. parse_import

Input: post_use_residual. Output: (`import_stmt`, `post_import_residual`).

### Patterns

| Pattern | Fortran | import_stmt rows |
|---|---|---|
| **Explicit import** | `IMPORT :: a, b, c` | 1 row: mode=`explicit` |
| **IMPORT ALL** | `IMPORT, ALL` | 1 row: mode=`all` |
| **IMPORT NONE** | `IMPORT, NONE` | 1 row: mode=`none` |
| **IMPORT ONLY** | `IMPORT, ONLY : x, y` | 1 row: mode=`only` |
| **No IMPORT** | (most scopes) | 0 rows; residual = input unchanged |
| **Multiple IMPORT** | not legal per Fortran standard (only one per scope), but test graceful handling | |

### Fact: import_stmt

- `import_id`: locally unique
- `scope_id`: FK
- `mode`: one of 4 values
- `start_line`: line number

### Residual: post_import_residual

- Input text minus IMPORT lines

### Note

IMPORT statements are rare — they appear mainly in BLOCK constructs and interface bodies. Most scopes produce 0 rows here.

---

## 5. parse_implicit

Input: post_import_residual. Output: (`implicit_rule`, `post_implicit_residual`).

### Patterns

| Pattern | Fortran | implicit_rule rows | scope update |
|---|---|---|---|
| **IMPLICIT NONE** | `IMPLICIT NONE` | 0 rows | implicit_typing → `'none'` |
| **Default (no statement)** | (no IMPLICIT statement) | 0 rows | implicit_typing stays `'default'` |
| **Custom single range** | `IMPLICIT REAL (A-H)` | 1 row: letter_start=`a`, letter_end=`h`, type_spec=`REAL` | implicit_typing → `'custom'` |
| **Custom multiple ranges** | `IMPLICIT INTEGER (I-N), REAL (A-H, O-Z)` | 3 rows: I-N/INTEGER, A-H/REAL, O-Z/REAL | implicit_typing → `'custom'` |
| **Custom single letter** | `IMPLICIT DOUBLE PRECISION (D)` | 1 row: letter_start=`d`, letter_end=`d` | implicit_typing → `'custom'` |

### Fact: implicit_rule

- `scope_id`: FK
- `letter_start`, `letter_end`: single lowercase characters, start ≤ end
- `type_spec`: type specification string

### Side effect

This step also signals an update to `scope.implicit_typing` for the parent scope. The mechanism (return alongside fact, or update in place) is an implementation detail — the test verifies both the implicit_rule rows and the intended typing mode.

### Residual: post_implicit_residual

- Input text minus IMPLICIT lines
- Only declaration constructs remain

---

## 6. parse_declarations

Input: post_implicit_residual. Output: (`declaration_construct`, `spec_terminal`).

### Patterns

| Pattern | Fortran | construct kind | Multi-line? |
|---|---|---|---|
| **Type declaration** | `INTEGER, INTENT(IN) :: a, b` | `type_declaration` | No |
| **Derived type definition** | `TYPE :: point ... REAL :: x, y ... END TYPE` | `derived_type_def` | Yes |
| **Interface block** | `INTERFACE operator(+) ... MODULE PROCEDURE add ... END INTERFACE` | `interface_block` | Yes |
| **Enum definition** | `ENUM, BIND(C) ... ENUMERATOR :: red=1, green=2 ... END ENUM` | `enum_def` | Yes |
| **Generic statement** | `GENERIC :: assignment(=) => assign_int, assign_real` | `generic_stmt` | No |
| **Procedure declaration** | `PROCEDURE(real_func), POINTER :: fptr` | `procedure_decl` | No |
| **Parameter statement** | `PARAMETER (pi = 3.14159)` | `parameter_stmt` | No |
| **Access statement** | `PRIVATE` or `PUBLIC :: typename` | `access_stmt` | No |
| **Common block** | `COMMON /blk/ a, b, c` | `common_stmt` | No |
| **Equivalence** | `EQUIVALENCE (a, b)` | `equivalence_stmt` | No |
| **Namelist** | `NAMELIST /grp/ x, y, z` | `namelist_stmt` | No |
| **External** | `EXTERNAL :: func1` | `external_stmt` | No |
| **Intrinsic** | `INTRINSIC :: sin, cos` | `intrinsic_stmt` | No |
| **Data statement** | `DATA x, y / 1, 2 /` | `data_stmt` | No |
| **Format statement** | `100 FORMAT(A10, I5)` | `format_stmt` | No |
| **Entry statement** | `ENTRY alt_entry(x)` | `entry_stmt` | No |
| **Statement function** | `f(x) = 2*x + 1` | `stmt_function` | No |
| **Mixed** | multiple declarations interleaved | multiple rows; ordinal preserves source order | |
| **Empty spec** | (all consumed by prior layers) | 0 rows | |

### Fact: declaration_construct

- `construct_id`: locally unique
- `scope_id`: FK
- `construct`: one of 18 kind strings
- `name`: from the construct header where applicable (type name, interface name, etc.); NULL otherwise
- `ordinal`: 1-based position in source order within this scope
- `start_line`, `end_line`: line range (single line for statements, multi-line for blocks)

### Residual: spec_terminal (terminal)

- One row per declaration construct
- `construct_id`, `scope_id`: FKs
- `text`: source text of the individual construct
- `ast_kind`: fparser class name (e.g., `'Type_Declaration_Stmt'`, `'Derived_Type_Def'`)
- This is the **terminal residual** — input for future computed table analysis

---

## 7. parse_regions

Input: part_residual (filtered to `part == 'execution'`). Output: (`control_region`, `region_residual`).

### Patterns

| Pattern | Fortran | region rows |
|---|---|---|
| **IF-THEN-ENDIF** | `IF (x > 0) THEN ... END IF` | 1 row: kind=`if` |
| **IF-THEN-ELSE-ENDIF** | `IF (...) THEN ... ELSE ... END IF` | 1 row: kind=`if` |
| **IF-ELSEIF-ELSE-ENDIF** | multi-branch IF | 1 row: kind=`if` |
| **DO loop** | `DO i = 1, n ... END DO` | 1 row: kind=`do` |
| **DO WHILE** | `DO WHILE (condition) ... END DO` | 1 row: kind=`do_while` |
| **DO CONCURRENT** | `DO CONCURRENT (i = 1:n) ... END DO` | 1 row: kind=`do_concurrent`, binding_kind=`construct_index` |
| **SELECT CASE** | `SELECT CASE (expr) ... CASE (...) ... END SELECT` | 1 row: kind=`select_case` |
| **SELECT TYPE** | `SELECT TYPE (a => expr) ... TYPE IS (...) ... END SELECT` | 1 row: kind=`select_type`, binding_kind=`construct_entity` |
| **WHERE** | `WHERE (mask) ... ELSEWHERE ... END WHERE` | 1 row: kind=`where` |
| **BLOCK** | `BLOCK ... END BLOCK` | 1 row: kind=`block`, binding_kind=`full_scope` |
| **ASSOCIATE** | `ASSOCIATE (x => expr) ... END ASSOCIATE` | 1 row: kind=`associate`, binding_kind=`construct_entity` |
| **FORALL** | `FORALL (i=1:n) ... END FORALL` | 1 row: kind=`forall`, binding_kind=`construct_index` |
| **Named construct** | `outer: DO i = 1, n ... END DO outer` | 1 row: construct_name=`outer` |
| **Nested constructs** | `DO ... IF ... END IF ... END DO` | 2 rows; IF has parent_region_id → DO |
| **Deeply nested** | 3+ levels of nesting | parent_region_id chain tracks depth |
| **No control constructs** | straight-line execution part | 0 rows; residual carries all statements as top-level |
| **Multiple siblings** | `IF ... END IF ... DO ... END DO` at same level | 2 rows, both with parent_region_id=NULL |

### Fact: control_region

- `region_id`: locally unique
- `parent_region_id`: NULL for top-level constructs, FK for nested
- `scope_id`: FK
- `kind`: one of 13 values
- `binding_kind`: functionally determined from kind
- `construct_name`: Fortran construct name label, or NULL
- `start_line`, `end_line`: from construct header to END statement

### Residual: region_residual

- Rows for: each control region interior + top-level statement segments not inside any construct
- `region_id`: FK (NULL for top-level segments)
- `text`: source text of the region body or statement sequence
- `ast_kind`: construct class name or `'Execution_Part'` for top-level segments

---

## 8. partition_blocks

Input: region_residual. Output: (`sbb`, `sbb_residual`).

### Patterns

| Pattern | Fortran | SBB rows |
|---|---|---|
| **Straight-line** | `a = 1; b = 2; c = a + b` (3 assignments) | 1 SBB covering all 3 statements |
| **Single statement** | `CALL subroutine(x)` | 1 SBB |
| **Construct boundary** | `a = 1 ... IF (...) THEN ... END IF ... b = 2` | 3 SBBs: pre-IF, IF-body, post-IF |
| **IF with ELSE** | `IF ... THEN ... stmts ... ELSE ... stmts ... END IF` | 2+ SBBs: then-branch body, else-branch body |
| **DO loop body** | `DO i=1,n ... s=s+i ... END DO` | 1 SBB for loop body |
| **Nested constructs** | `DO ... IF ... END IF ... END DO` | SBBs partition both DO body and IF branches |
| **Empty execution part** | (no executable statements) | 0 SBBs |
| **Multiple branches** | `SELECT CASE ... CASE(1) ... CASE(2) ... END SELECT` | 1 SBB per case branch body |

### Convention B

Every control construct boundary (header, ELSE, CASE, END) starts a new SBB. This ensures each SBB has uniform control flow context.

### Fact: sbb

- `sbb_id`: locally unique
- `scope_id`: FK
- `region_id`: FK to innermost enclosing control region; NULL for top-level
- `start_line`, `end_line`: line range

### Residual: sbb_residual (terminal)

- One row per SBB
- `sbb_id`, `scope_id`, `region_id`: FKs
- `text`: source text of the action statements in this block
- `ast_kind`: tag for the statement sequence
- This is the **terminal residual** — input for `trace_edges` and future computed table analysis

---

## 9. trace_edges

Input: sbb_residual + control_region. Output: `sbb_edge` (leaf step, no residual).

### Patterns

| Pattern | Fortran | Edges expected |
|---|---|---|
| **Sequential** | `a = 1 ... b = 2` (two SBBs from construct boundaries) | 1 edge: fallthrough |
| **IF-THEN-ENDIF** | `IF (c) THEN ... END IF` | branch_true → then-body, branch_false → after-IF; then-body → fallthrough to after-IF |
| **IF-THEN-ELSE-ENDIF** | `IF (c) THEN ... ELSE ... END IF` | branch_true → then-body, branch_false → else-body; both → fallthrough to after-IF |
| **IF-ELSEIF-ELSE** | multi-branch IF | chain of branch_true/branch_false through ELSEIF conditions |
| **DO loop** | `DO i=1,n ... END DO` | loop_back from body-end to header; loop_exit from header to after-DO; fallthrough into body |
| **DO WHILE** | `DO WHILE (c) ... END DO` | branch_true → body, branch_false (= loop_exit) → after-DO, loop_back from body-end |
| **SELECT CASE** | `SELECT CASE ... CASE(1) ... CASE(2) ...` | case_select from header to each CASE body; fallthrough from each body to after-SELECT |
| **GOTO** | `GOTO 100 ... 100 CONTINUE` | jump from GOTO's SBB to target SBB |
| **CYCLE** | `DO ... IF (c) CYCLE ... END DO` | jump from CYCLE's SBB to loop header (acts like loop_back) |
| **EXIT** | `DO ... IF (c) EXIT ... END DO` | jump from EXIT's SBB to after-DO |
| **RETURN** | `IF (err) RETURN` | return edge from RETURN's SBB (no successor in this scope) |
| **STOP** | `STOP 'error'` | return edge (program termination) |
| **Nested loops** | `DO ... DO ... END DO ... END DO` | inner loop edges + outer loop edges; EXIT targets correct loop |
| **Named EXIT** | `outer: DO ... EXIT outer ... END DO outer` | jump targets the named construct's exit point |
| **Straight-line only** | no branches or loops | only fallthrough edges |

### Fact: sbb_edge

- `from_sbb_id`, `to_sbb_id`: FKs to SBB
- `edge_kind`: one of 8 values

### Key invariant

Every SBB except STOP/RETURN terminals has at least one outgoing edge. Every SBB except the entry block has at least one incoming edge.

---

## 10. parse_use_entities

Input: use_stmt + source_line. Output: `use_entity` (leaf step).

### Patterns

| Pattern | Fortran | use_entity rows |
|---|---|---|
| **ONLY with names** | `USE m, ONLY : a, b, c` | 3 rows: module_entity_name = a, b, c; local_name = NULL |
| **ONLY with renames** | `USE m, ONLY : x, local => remote` | 2 rows: x (no rename), remote (local_name=`local`) |
| **Renames without ONLY** | `USE m, new => old` | 1 row: module_entity_name=`old`, local_name=`new` |
| **No entities** | `USE m` (import all, no ONLY, no renames) | 0 rows |
| **Operator rename** | `USE m, OPERATOR(.myop.) => OPERATOR(.add.)` | 1 row with operator syntax in names |

### Fact: use_entity

- `use_id`: FK to use_stmt
- `module_entity_name`: name as it exists in the module
- `local_name`: local alias; NULL if no rename

---

## 11. parse_import_entities

Input: import_stmt + source_line. Output: `import_entity` (leaf step).

### Patterns

| Pattern | Fortran | import_entity rows |
|---|---|---|
| **Explicit list** | `IMPORT :: a, b, c` | 3 rows |
| **ONLY list** | `IMPORT, ONLY : x, y` | 2 rows |
| **ALL** | `IMPORT, ALL` | 0 rows (mode is ALL, no specific entities) |
| **NONE** | `IMPORT, NONE` | 0 rows (mode is NONE, no specific entities) |

### Fact: import_entity

- `import_id`: FK to import_stmt
- `name`: imported identifier

---

## Cross-cutting test concerns

### Residual threading

For the spec branch, a single end-to-end test should verify that the residual narrows correctly through the full chain:

```
part_residual (spec)
  → parse_use → text minus USE lines
  → parse_import → text minus IMPORT lines
  → parse_implicit → text minus IMPLICIT lines
  → parse_declarations → one row per declaration construct (terminal)
```

The key property: no source line is lost or double-counted. The union of consumed lines (USE + IMPORT + IMPLICIT) plus the terminal residual lines equals the original spec-part lines.

### Empty inputs

Every processor must handle an empty input DataFrame gracefully — return empty fact and pass-through residual. This is the common case for many spec layers (most scopes have no IMPORT statements, many have no custom IMPLICIT rules).

### Pandera validation

Each test should verify that the fact output passes its schema validation. This is the contract: if the schema passes, the data is ready for the database. Tests should also verify that known-bad data (wrong types, constraint violations) is rejected.

### ID locality

All IDs (scope_id, use_id, sbb_id, etc.) are file-local, starting from 0. Tests should verify IDs are assigned sequentially and consistently within one `process_file` call.
