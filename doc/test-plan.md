# v0.1.8: test plan

Tests for 5 processors. Each processor is a pure function: `DataFrame → (DataFrame, DataFrame)`. Tests verify: given a Fortran source pattern, the processor produces the correct fact rows and the correct residual for the next step.

---

## 0. parse_source

Input: `(text, filename)`. Output: `(source_line, file_residual)`.

### Patterns

| Pattern | Source | Expected |
|---|---|---|
| Single program unit | `PROGRAM hello ... END PROGRAM` | source_line: one row per line; residual: one row, full text, ast_kind=`'Program'` |
| Multiple program units | module + external subroutine in one file | source_line: all lines; residual: one row per top-level unit |
| Empty file | blank or comment-only | source_line: rows for each line; residual: empty DataFrame |
| Fixed-form source | column-based layout with continuation in col 6 | source_line preserves original lines |
| Free-form with continuations | `&` at end-of-line | source_line preserves raw lines |

### Fact: source_line

- One row per physical line in the file
- Line numbers are 1-based, contiguous, complete

### Residual: file_residual

- `text`: full source text
- `ast_kind`: fparser root class name (e.g. `'Program'`, `'Module'`)

---

## 1. parse_scopes

Input: `file_residual`. Output: `(scope, scope_residual)`.

### Patterns

| Pattern | Fortran | scope rows |
|---|---|---|
| Standalone program | `PROGRAM main ... END PROGRAM` | 1: kind=`program`, name=`main` |
| Module | `MODULE mymod ... END MODULE` | 1: kind=`module` |
| Module with internal procedures | `MODULE m ... CONTAINS ... SUBROUTINE s ... FUNCTION f` | 3: module + subroutine + function; children have parent_scope_id → module |
| External subroutine | `SUBROUTINE sub(x) ... END SUBROUTINE` | 1: kind=`subroutine` |
| External function | `FUNCTION f(x) RESULT(r) ... END FUNCTION` | 1: kind=`function` |
| Block data | `BLOCK DATA init ... END BLOCK DATA` | 1: kind=`block_data` |
| Submodule | `SUBMODULE (parent) child ... END SUBMODULE` | 1: kind=`submodule` |
| Nested: program + internals | `PROGRAM p ... CONTAINS ... SUBROUTINE s1 ... SUBROUTINE s2` | 3: program + 2 subroutines; parent_scope_id links correct |
| Deeply nested | module → contains → subroutine → contains → function | parent_scope_id chain: function → subroutine → module |
| Unnamed program | statements without PROGRAM keyword | 1: kind=`program`, name=NULL |

### Fact: scope

- `scope_id`: unique, locally assigned (0, 1, 2, ...)
- `parent_scope_id`: NULL for top-level, FK to containing scope
- `kind`: one of 8 values
- `name`: from program-unit header; NULL if unnamed
- `filename`, `start_line`, `end_line`: span of entire scope including END statement

### Residual: scope_residual

- One row per scope
- `text`: scope body (between header and END, exclusive)
- `ast_kind`: fparser class name

---

## 2. segment_parts

Input: `scope_residual`. Output: `(scope_part, part_residual)`.

### Patterns

| Pattern | Fortran | parts produced |
|---|---|---|
| Env + decl + exec | `USE m ... INTEGER :: x ... x = 1` | 3 rows: environment, declarations, execution |
| Env + decl only | `MODULE m ... USE iso ... INTEGER :: n ... END MODULE` | 2 rows: environment, declarations |
| Decl + exec | `SUBROUTINE s ... INTEGER :: x ... x = 1` (no USE/IMPORT/IMPLICIT) | 2 rows: declarations, execution |
| Exec only | `SUBROUTINE s ... CALL foo() ... END SUBROUTINE` (no spec) | 1 row: execution |
| Decl only | `MODULE m ... INTEGER :: n ... END MODULE` (no env) | 1 row: declarations |
| Env only | `SUBROUTINE s ... USE m ... IMPLICIT NONE ... END SUBROUTINE` (env is entire spec, no exec) | 1 row: environment |
| Block data | `BLOCK DATA ... COMMON /blk/ a ... DATA a/1/ ... END` | 1–2 rows: environment and/or declarations (no execution) |
| CONTAINS handling | `SUBROUTINE s ... INTEGER :: x ... x = 1 ... CONTAINS ... FUNCTION f` | environment/declarations/execution only — CONTAINS region excluded |

### Fact: scope_part

- `scope_id`: FK to scope
- `part`: `'environment'` \| `'declarations'` \| `'execution'`
- `start_line`, `end_line`: non-overlapping, ordered

### Residual: part_residual

- One row per part
- `text`: source text of that part
- `ast_kind`: `'Specification_Part'` or `'Execution_Part'`

### Key invariants

- Parts are strictly ordered: environment < declarations < execution
- No overlap, no interleaving
- Line ranges cover the scope body completely (together with CONTAINS region, which is excluded from parts)

### Boundary rules

| Boundary | Identified by |
|---|---|
| Environment end | first line that is not USE / IMPORT / IMPLICIT |
| Declarations end | first executable statement or CONTAINS |
| Execution end | END statement or CONTAINS |

---

## 3. parse_regions

Input: `exec_residual` (part_residual filtered to `part == 'execution'`). Output: `(control_region, region_residual)`.

### Patterns

| Pattern | Fortran | region rows | Notes |
|---|---|---|---|
| IF-THEN-ENDIF | `IF (x > 0) THEN ... END IF` | 1: kind=`if` | |
| IF-THEN-ELSE-ENDIF | `IF (...) THEN ... ELSE ... END IF` | 1: kind=`if` | |
| IF-ELSEIF-ELSE-ENDIF | multi-branch IF | 1: kind=`if` | |
| DO loop | `DO i = 1, n ... END DO` | 1: kind=`do` | |
| DO WHILE | `DO WHILE (condition) ... END DO` | 1: kind=`do_while` | |
| DO CONCURRENT | `DO CONCURRENT (i = 1:n) ... END DO` | 1: kind=`do_concurrent` | |
| SELECT CASE | `SELECT CASE (expr) ... CASE (...) ... END SELECT` | 1: kind=`select_case` | |
| SELECT TYPE | `SELECT TYPE (a => expr) ... TYPE IS ... END SELECT` | 1: kind=`select_type` | |
| SELECT RANK | `SELECT RANK (a) ... RANK (1) ... END SELECT` | 1: kind=`select_rank` | |
| WHERE | `WHERE (mask) ... ELSEWHERE ... END WHERE` | 1: kind=`where` | |
| ASSOCIATE | `ASSOCIATE (x => expr) ... END ASSOCIATE` | 1: kind=`associate` | |
| FORALL | `FORALL (i=1:n) ... END FORALL` | 1: kind=`forall` | |
| CRITICAL | `CRITICAL ... END CRITICAL` | 1: kind=`critical` | |
| CHANGE TEAM | `CHANGE TEAM (team) ... END TEAM` | 1: kind=`change_team` | |
| **BLOCK** | `BLOCK ... END BLOCK` | **0 rows** | BLOCK → residual with ast_kind=`'Block_Construct'`, not a control_region |
| Named construct | `outer: DO i = 1, n ... END DO outer` | 1: kind=`do` | construct_name is a process output, not in fact table |
| Nested constructs | `DO ... IF ... END IF ... END DO` | 2: IF has parent_region_id → DO | |
| Deeply nested | 3+ nesting levels | parent_region_id chain | |
| No constructs | straight-line exec part | 0 rows | |
| Multiple siblings | `IF ... END IF ... DO ... END DO` | 2: both parent_region_id=NULL | |
| BLOCK inside DO | `DO ... BLOCK ... END BLOCK ... END DO` | 1: kind=`do` only; BLOCK → residual | |

### Fact: control_region

- `region_id`: locally unique
- `parent_region_id`: NULL for top-level, FK for nested
- `scope_id`: FK to scope
- `kind`: one of 12 values (BLOCK excluded)
- `start_line`, `end_line`: construct header to END statement

### Residual: region_residual

- Rows for: each control region body + top-level statement segments + BLOCK constructs as opaque units
- `region_id`: FK (NULL for top-level segments)
- `text`: source text
- `ast_kind`: `'Execution_Part'` for statement segments; `'Block_Construct'` for BLOCK scopes

### Critical test: BLOCK passthrough

BLOCK constructs must NOT produce control_region rows. They appear in the residual as opaque text blocks with `ast_kind = 'Block_Construct'`. This is the key v0.1.8 design decision.

```fortran
subroutine foo()
    integer :: a
    a = 1
    BLOCK
        integer :: b
        b = 2
    END BLOCK
    a = a + 1
end subroutine
```

Expected:
- control_region: 0 rows
- region_residual: 3 rows
  - `a = 1` (ast_kind=`'Execution_Part'`)
  - `BLOCK ... END BLOCK` (ast_kind=`'Block_Construct'`)
  - `a = a + 1` (ast_kind=`'Execution_Part'`)

---

## 4. partition_blocks

Input: `region_residual`. Output: `(sbb, None)`.

### Patterns

| Pattern | Input | SBB rows |
|---|---|---|
| Straight-line | 3 assignments, ast_kind=`'Execution_Part'` | 1: kind=`statements` |
| Single statement | `CALL subroutine(x)` | 1: kind=`statements` |
| BLOCK scope | ast_kind=`'Block_Construct'` | 1: kind=`block_scope` |
| Mixed: stmts + BLOCK + stmts | 3 residual segments | 3: statements, block_scope, statements |
| DO body | loop body statements | 1: kind=`statements` |
| IF branches | then-body, else-body | 2+: kind=`statements` per branch |
| Empty segment | no executable statements | 0 rows |
| Multiple siblings | gaps between nested constructs | 1 SBB per gap, kind=`statements` |
| SELECT CASE branches | one segment per CASE body | 1 SBB per case, kind=`statements` |

### Fact: semantic_basic_block

- `sbb_id`: locally unique
- `scope_id`: FK to scope
- `region_id`: FK to innermost enclosing region; NULL for top-level
- `kind`: `'statements'` or `'block_scope'`
- `start_line`, `end_line`: line range

### Residual: None (terminal)

partition_blocks is terminal. SBB content recovered on demand from source_line at coordinates.

### Convention B

Every construct boundary (control region or BLOCK scope) starts a new SBB. Within a region body, the text between nested constructs is a straight-line sequence → one SBB.

### Key test: kind assignment

The `ast_kind` value from region_residual determines the SBB kind:

| residual ast_kind | SBB kind |
|---|---|
| `'Execution_Part'` | `'statements'` |
| `'Block_Construct'` | `'block_scope'` |

---

## Cross-cutting test concerns

### Residual threading

End-to-end test: verify that source lines are neither lost nor double-counted through the full pipeline.

```
parse_source     → all lines in source_line
parse_scopes     → body text (minus header/END)
segment_parts    → partitioned into env/decl/exec
parse_regions    → exec text decomposed into region bodies + gaps + BLOCKs
partition_blocks → leaf SBBs tile the exec part
```

The union of all SBB line ranges plus all control_region header/END lines plus all BLOCK scope ranges must equal the execution part line range.

### Empty inputs

Every processor must handle an empty input DataFrame: return empty fact and empty/pass-through residual. Common cases:
- Module with no execution part → parse_regions receives empty input
- Subroutine with no control constructs → 0 control_region rows
- No BLOCK constructs → 0 block_scope SBBs

### Pandera validation

Each test should verify that fact output passes its schema validation (schemas.py). Tests should also verify that known-bad data (wrong types, invalid kind values, start_line > end_line) is rejected.

### ID locality

All IDs (scope_id, region_id, sbb_id) are file-local, starting from 0. Tests verify sequential, consistent assignment within one `process_file` call. Global IDs assigned in a post-processing step after concatenating per-file results.

### BLOCK scope opacity

BLOCK scopes are opaque at the pipeline level. Tests verify:
- BLOCK produces no control_region row
- BLOCK produces exactly one SBB with kind=`'block_scope'`
- BLOCK's internal structure (USE, declarations, nested control constructs) is NOT decomposed
- The SBB's line range covers the full BLOCK...END BLOCK span

### Process smoke tests (not pipeline tests)

Verify that processes can recover content from fact tables + source_line:
- `parse_environment`: given scope_part (environment) coordinates, extract USE/IMPORT/IMPLICIT
- `parse_declarations`: given scope_part (declarations) coordinates, extract declaration constructs
- `parse_block_scope`: given SBB (kind=block_scope) coordinates, extract environment + declarations + nested execution
- `trace_edges`: given SBBs + control_regions, compute CFG edges
