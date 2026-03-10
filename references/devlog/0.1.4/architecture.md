# coordinate system architecture (v0.1.4)

A system of fact tables that assigns every piece of Fortran source code a unique, typed address — so that any semantic question reduces to: look up the address, extract the source text, parse it.

This document is the unified reference for v0.1.4. It consolidates the specification-part coordinate system (v0.1.4a) and the execution-part coordinate system (v0.1.4b) into a single architecture.

## 1. The three conditions

A system of fact tables is a **complete coordinate system** for a source region if and only if:

**Condition 1 — Complete partition.** Every semantically significant source line belongs to exactly one leaf-level fact table row. No gaps, no overlaps. (Blank lines and comments are exempt.)

**Condition 2 — Kind-determined grammar.** Each fact table row's kind uniquely determines the grammar production that governs its content. Given only the kind and the source lines, a parser can unambiguously dispatch — no external context, no trial-and-error. Bounded sub-dispatch (one-keyword lookahead) is permitted.

**Condition 3 — Layered dependency order.** The name-binding environment at any point is recoverable by processing layers in order. No circular dependencies. Each layer is interpretable given only the preceding layers and the source.

When all three hold: `semantic_content = parse(source_lines, grammar_production, environment)`, and all three inputs are determined by the fact tables + raw source.

## 2. The table hierarchy

```
source_code (view)                     (filename, lineno) → line
  │
  └─ scope                             8 structural kinds, containment tree
       │
       └─ scope_part                   spec / exec / subprogram line ranges
            │
            ├─ SPECIFICATION PART (4 layers, linear dependency)
            │    │
            │    ├─ use_stmt → use_entity           Layer 1: module association
            │    ├─ import_stmt → import_entity      Layer 2: host association
            │    ├─ implicit_rule                    Layer 3: typing rules
            │    └─ declaration_construct             Layer 4: 18 construct kinds
            │
            └─ EXECUTION PART (tree-compositional dependency)
                 │
                 ├─ control_region                   CCT: 13 construct kinds
                 │                                    self-referential nesting
                 │
                 └─ semantic_basic_block              leaf partition of exec lines
                      └─ sbb_edge                     CFG: 8 edge kinds
```

**12 tables + 1 view.** Every table carries line ranges back to `source_code`.

## 3. Condition verification

### Specification part

| Condition | How satisfied |
|---|---|
| Partition | Every line in the spec part belongs to exactly one of: scope opening statement, `use_stmt` row, `import_stmt` row, implicit statement (via `scope.implicit_typing`), or `declaration_construct` row |
| Grammar | Each `declaration_construct` kind maps to exactly one grammar production (18 kinds → 18 productions, injective). `use_stmt` → R1409, `import_stmt` → R1514, `implicit_rule` → R863 |
| Dependency | 4 linear layers: USE (depends on nothing) → IMPORT (depends on Layer 1) → IMPLICIT (depends on 1–2) → declarations (depends on 1–3). Matches grammar ordering R504 |

### Execution part

| Condition | How satisfied |
|---|---|
| Partition | SBBs tile each execution part completely. Convention B (every construct boundary starts a new SBB) ensures no gaps |
| Grammar | `control_region` kind maps to one grammar production (13 kinds → 13 productions). SBBs parse as sequences of `action-stmt` (R214) with per-statement keyword dispatch — bounded, deterministic |
| Dependency | Tree-compositional: `env(SBB) = spec_env(scope) ∘ Δ(ancestor₁) ∘ ... ∘ Δ(ancestorₖ)` along the CCT ancestor chain. Acyclic (tree-shaped) |

**Structural asymmetry (by design):**
- Spec part: one row per construct, linear layer dependency
- Exec part: one row per basic block (coarser — a group of statements), tree-compositional dependency
- The SBB is the natural leaf because it is the unit where control flow context and name-binding environment are both uniform

## 4. Table reference

### source_code (view)

The public interface to raw source text. Maps `(filename, lineno)` → `line`. All other tables join here via their `(filename, start_line, end_line)` coordinates.

### scope

One row per program unit or subprogram. 8 structural kinds: `global`, `program`, `module`, `submodule`, `block_data`, `function`, `subroutine`, `separate_mp`. Nesting depth bounded (~3 levels). `parent_scope_id` for containment, `ancestor_scope_id` for submodule lineage.

Key columns: `implicit_typing` (`default`/`none`/`inherit`/`custom`), `default_accessibility` (`public`/`private`/NULL).

### scope_part

Segments each scope into up to 3 sequential parts: `specification`, `execution`, `subprogram`. Grammar-ordered, non-overlapping. Primary key: `(scope_id, part)`.

### use_stmt + use_entity (Spec Layer 1)

One `use_stmt` per USE statement. `module_name`, `nature` (`unspecified`/`intrinsic`/`non_intrinsic`), `only_clause`. Child table `use_entity` lists individual names with optional `local_name` rename.

### import_stmt + import_entity (Spec Layer 2)

One `import_stmt` per IMPORT statement. `mode` (`explicit`/`all`/`none`/`only`). Child table `import_entity` lists names for `explicit` and `only` modes.

### implicit_rule (Spec Layer 3)

Letter-range → type mappings for scopes with `implicit_typing = 'custom'`. Primary key: `(scope_id, letter_start)`. No rows needed for `default`, `none`, or `inherit`.

### declaration_construct (Spec Layer 4)

One row per declaration construct. 18 kinds covering all R507/R508 productions:

| Category | Kinds |
|---|---|
| Block constructs | `derived_type_def` (R726), `interface_block` (R1501), `enum_def` (R759) |
| Statement constructs | `type_declaration` (R801), `generic_stmt` (R1510), `procedure_decl` (R1512), `parameter_stmt` (R855), `access_stmt` (R827), `attribute_stmt` (R813), `common_stmt` (R873), `equivalence_stmt` (R870), `namelist_stmt` (R868), `external_stmt` (R1519), `intrinsic_stmt` (R1519), `data_stmt` (R837) |
| Cross-boundary | `format_stmt` (R1001), `entry_stmt` (R1541), `stmt_function` (R1544) |

`ordinal` preserves source order. `name` captures the construct's primary identifier when applicable.

### control_region (Exec: CCT)

One row per control construct. 13 kinds: `if`, `select_case`, `select_type`, `select_rank`, `do`, `do_while`, `do_concurrent`, `forall`, `where`, `block`, `associate`, `critical`, `change_team`.

`binding_kind` classifies the name-binding change: `none` (most constructs), `full_scope` (BLOCK), `construct_index` (DO CONCURRENT, FORALL), `construct_entity` (ASSOCIATE, SELECT TYPE/RANK).

Self-referential `parent_region_id` for nesting. `construct_name` for named CYCLE/EXIT targeting.

### semantic_basic_block (Exec: leaf partition)

Maximal contiguous statement sequence with uniform control flow context and name-binding environment. `region_id` FK to innermost enclosing `control_region` (NULL for top-level code). Synthetic ENTRY/EXIT SBBs per executable scope.

### sbb_edge (Exec: CFG)

Intraprocedural control flow edges. 8 kinds: `fallthrough`, `branch_true`, `branch_false`, `case_select`, `loop_back`, `loop_exit`, `jump`, `return`. Primary key: `(from_sbb_id, to_sbb_id, edge_kind)`.

## 5. Population order

Processing a Fortran source file populates the tables in this order:

```
 1. Load source text        → file_version, source_line (source_code view)
 2. Identify scopes         → scope (program units, subprograms, containment)
 3. Segment scope parts     → scope_part (spec / exec / subprogram line ranges)
 4. Spec Layer 1            → use_stmt, use_entity
 5. Spec Layer 2            → import_stmt, import_entity
 6. Spec Layer 3            → implicit_rule (+ scope.implicit_typing)
 7. Spec Layer 4            → declaration_construct
 8. Exec: build CCT         → control_region (identify constructs, nesting)
 9. Exec: partition into SBBs → semantic_basic_block
10. Exec: compute CFG edges → sbb_edge
```

Steps 4–7 and 8–10 are independent (spec and exec parts can be processed in parallel). Within each group, steps are sequential — each depends on the previous.

## 6. Canonical queries

**Source text at any coordinate:**
```sql
SELECT sc.lineno, sc.line
FROM   source_code sc
WHERE  sc.filename = :filename
  AND  sc.lineno BETWEEN :start_line AND :end_line
ORDER  BY sc.lineno;
```

**All declarations in a scope:**
```sql
SELECT dc.ordinal, dc.construct, dc.name, dc.start_line, dc.end_line
FROM   declaration_construct dc
WHERE  dc.scope_id = :scope_id
ORDER  BY dc.ordinal;
```

**Environment at a scope (Layers 1–3):**
```sql
-- USE associations
SELECT u.module_name, u.only_clause, e.module_entity_name, e.local_name
FROM   use_stmt u
LEFT JOIN use_entity e ON e.use_id = u.use_id
WHERE  u.scope_id = :scope_id;

-- IMPORT controls
SELECT i.mode, ie.name
FROM   import_stmt i
LEFT JOIN import_entity ie ON ie.import_id = i.import_id
WHERE  i.scope_id = :scope_id;

-- Implicit typing
SELECT s.implicit_typing, ir.letter_start, ir.letter_end, ir.type_spec
FROM   scope s
LEFT JOIN implicit_rule ir ON ir.scope_id = s.scope_id
WHERE  s.scope_id = :scope_id;
```

**All SBBs in a control region:**
```sql
SELECT sbb.*
FROM   semantic_basic_block sbb
JOIN   control_region cr ON cr.scope_id = sbb.scope_id
WHERE  cr.region_id = :region_id
  AND  sbb.start_line >= cr.start_line
  AND  sbb.end_line   <= cr.end_line;
```

**CFG successors of an SBB:**
```sql
SELECT e.edge_kind, succ.*
FROM   sbb_edge e
JOIN   semantic_basic_block succ ON succ.sbb_id = e.to_sbb_id
WHERE  e.from_sbb_id = :sbb_id;
```

**Binding-changing ancestors (environment recovery):**
```sql
WITH RECURSIVE ancestors AS (
    SELECT region_id, parent_region_id, kind, binding_kind
    FROM   control_region
    WHERE  region_id = (SELECT region_id
                        FROM semantic_basic_block WHERE sbb_id = :sbb_id)
  UNION ALL
    SELECT cr.region_id, cr.parent_region_id, cr.kind, cr.binding_kind
    FROM   control_region cr
    JOIN   ancestors a ON cr.region_id = a.parent_region_id
)
SELECT * FROM ancestors WHERE binding_kind != 'none';
```

**Containment test (universal — works for any two rows with line ranges):**
```sql
-- Does A contain B?
-- A.filename = B.filename AND A.start_line <= B.start_line AND B.end_line <= A.end_line
```

## 7. Computed tables

The fact tables establish WHERE and WHAT kind. Everything beyond is a **computed table** — derived from source text at fact table coordinates. Computed tables are caches; the fact tables are ground truth.

### Specification part (keyed to declaration_construct)

5 progressive layers of recovery from source text:

| Layer | Content | Per |
|---|---|---|
| C1 | Entity names and their origin construct | declaration_construct |
| C2 | Type specifications (intrinsic/derived, kind, len, polymorphic) | entity |
| C3 | Attributes (18 boolean/parametric: ALLOCATABLE, POINTER, INTENT, ...) + array spec | entity |
| C4 | Block construct internals (components, bindings, interface bodies, enumerators) | derived_type_def, interface_block, enum_def |
| C5 | Cross-entity relationships (COMMON/NAMELIST ordering, EQUIVALENCE sets, argument ordering, generic resolution) | scope |

### Execution part (keyed to semantic_basic_block or control_region)

| Table | Content | Keyed to |
|---|---|---|
| data_access | Read/write sets per SBB (name, direction, access pattern) | SBB |
| call_edge | Procedure calls per SBB (callee, call kind, argument association) | SBB |
| io_operation | I/O statements per SBB (kind, unit, format, data items) | SBB |
| allocation_event | ALLOCATE/DEALLOCATE per SBB (object, shape bounds) | SBB |
| construct_entity | Names introduced by binding-changing regions (BLOCK locals, DO CONCURRENT indices, ASSOCIATE aliases) | control_region |

Each computed table = `parse(source_lines, grammar_production, environment)`.

## 8. Testing against real codebases

### Completeness checks

After populating the tables for a codebase, verify the three conditions:

**Partition coverage** — every source line in a scope part is accounted for:

```sql
-- Lines in the specification part not covered by any fact table
SELECT sc.filename, sc.lineno, sc.line
FROM   source_code sc
JOIN   scope_part sp ON sc.filename = (SELECT filename FROM scope WHERE scope_id = sp.scope_id)
WHERE  sp.part = 'specification'
  AND  sc.lineno BETWEEN sp.start_line AND sp.end_line
  AND  sc.line NOT LIKE '---%'     -- skip comments
  AND  TRIM(sc.line) != ''         -- skip blank lines
  AND  NOT EXISTS (
      SELECT 1 FROM use_stmt u
      WHERE u.scope_id = sp.scope_id AND u.start_line = sc.lineno
  )
  AND  NOT EXISTS (
      SELECT 1 FROM import_stmt i
      WHERE i.scope_id = sp.scope_id AND i.start_line = sc.lineno
  )
  AND  NOT EXISTS (
      SELECT 1 FROM declaration_construct dc
      WHERE dc.scope_id = sp.scope_id
        AND sc.lineno BETWEEN dc.start_line AND dc.end_line
  );
-- Result should be empty (or contain only scope open/close and IMPLICIT statements)
```

```sql
-- Lines in the execution part not covered by any SBB
SELECT sc.filename, sc.lineno, sc.line
FROM   source_code sc
JOIN   scope_part sp ON sc.filename = (SELECT filename FROM scope WHERE scope_id = sp.scope_id)
WHERE  sp.part = 'execution'
  AND  sc.lineno BETWEEN sp.start_line AND sp.end_line
  AND  sc.line NOT LIKE '---%'
  AND  TRIM(sc.line) != ''
  AND  NOT EXISTS (
      SELECT 1 FROM semantic_basic_block sbb
      WHERE sbb.scope_id = sp.scope_id
        AND sc.lineno BETWEEN sbb.start_line AND sbb.end_line
  );
-- Result should be empty
```

**Hierarchy consistency** — every child row's line range is within its parent's:

```sql
-- SBBs outside their scope's execution part
SELECT sbb.sbb_id, sbb.filename, sbb.start_line, sbb.end_line
FROM   semantic_basic_block sbb
JOIN   scope_part sp ON sp.scope_id = sbb.scope_id AND sp.part = 'execution'
WHERE  sbb.start_line < sp.start_line OR sbb.end_line > sp.end_line;
-- Result should be empty

-- control_regions outside their scope's execution part
SELECT cr.region_id, cr.filename, cr.start_line, cr.end_line
FROM   control_region cr
JOIN   scope_part sp ON sp.scope_id = cr.scope_id AND sp.part = 'execution'
WHERE  cr.start_line < sp.start_line OR cr.end_line > sp.end_line;
-- Result should be empty

-- declaration_constructs outside their scope's specification part
SELECT dc.construct_id, dc.start_line, dc.end_line
FROM   declaration_construct dc
JOIN   scope_part sp ON sp.scope_id = dc.scope_id AND sp.part = 'specification'
WHERE  dc.start_line < sp.start_line OR dc.end_line > sp.end_line;
-- Result should be empty
```

**CFG consistency** — every SBB has at least one edge (except EXIT SBB) and edges connect SBBs in the same scope:

```sql
-- SBBs with no outgoing edges (should only be EXIT SBBs)
SELECT sbb.sbb_id, sbb.scope_id, sbb.start_line
FROM   semantic_basic_block sbb
WHERE  NOT EXISTS (
    SELECT 1 FROM sbb_edge e WHERE e.from_sbb_id = sbb.sbb_id
);

-- Edges between SBBs in different scopes (should be empty)
SELECT e.from_sbb_id, e.to_sbb_id
FROM   sbb_edge e
JOIN   semantic_basic_block s1 ON s1.sbb_id = e.from_sbb_id
JOIN   semantic_basic_block s2 ON s2.sbb_id = e.to_sbb_id
WHERE  s1.scope_id != s2.scope_id;
-- Result should be empty
```

### Coverage statistics

```sql
-- Per-file summary
SELECT s.filename,
       COUNT(DISTINCT s.scope_id) AS scopes,
       COUNT(DISTINCT dc.construct_id) AS declarations,
       COUNT(DISTINCT cr.region_id) AS control_regions,
       COUNT(DISTINCT sbb.sbb_id) AS sbbs,
       COUNT(DISTINCT e.from_sbb_id || '-' || e.to_sbb_id) AS cfg_edges
FROM   scope s
LEFT JOIN declaration_construct dc ON dc.scope_id = s.scope_id
LEFT JOIN control_region cr ON cr.scope_id = s.scope_id
LEFT JOIN semantic_basic_block sbb ON sbb.scope_id = s.scope_id
LEFT JOIN sbb_edge e ON e.from_sbb_id = sbb.sbb_id
WHERE  s.kind != 'global'
GROUP  BY s.filename
ORDER  BY s.filename;
```
