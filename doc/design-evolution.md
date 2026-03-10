# Design evolution: v0.1.0 → v0.1.8

Rationale and lessons from each version. The coordinate system went from 13 scope kinds and 12 fact tables to 8 scope kinds and 5 fact tables. Each version removed concept noise — structures that could be derived rather than stored.

---

## v0.1.0: initial research

**What**: 4 SQL tables + 1 view. scope table with 13 kinds (8 structural + 5 internal: derived_type, interface_body, block, forall, do_concurrent). source_code view. CFG concepts documented. Semantic basic block concept introduced.

**Key idea**: the SBB is the meet of traditional basic blocks and scoping unit boundaries — the finest partition where both control flow and name binding are uniform.

**Problem found**: the 5 internal scope kinds exhibit unbounded left-recursive nesting. A DO loop inside a DO loop inside a DO loop creates arbitrary depth. Self-referential FK works for bounded nesting (program units nest ~3 levels), but not for unbounded nesting.

**Lesson**: structural scopes (program units) and internal constructs (control flow) have different nesting properties. They need separate tables.

---

## v0.1.1: narrow to 8 structural kinds

**Delta**: remove 5 internal kinds from scope. Scope has exactly 8 kinds: global, program, module, submodule, block_data, function, subroutine, separate_mp.

**Rationale**: structural scopes nest boundedly (global → module → function, ~3 levels). Internal constructs (IF, DO, BLOCK) nest unboundedly. Different tables for different recursion depths.

**Design methodology introduced**: relational-first (fact tables as coordinate axes), structural before internal, spec/exec separation.

**Lesson**: the right question is not "what are all the scopes" but "what scopes have bounded nesting." Bounded → self-referential FK. Unbounded → separate tree table.

---

## v0.1.2: specification/execution split

**Delta**: add scope_part table. Each scope body splits into specification, execution, subprogram parts.

**Rationale**: Fortran grammar enforces strict ordering (R504). Specification defines the name-binding environment; execution consumes it. This ordering is not a convention — it's syntax.

**Key insight**: the 3-part structure is universal across all Fortran scope kinds. Modules have spec only. Programs/subroutines have spec + exec. CONTAINS introduces the subprogram part.

**Lesson**: grammar-enforced ordering is a structural fact, not a semantic one. It belongs in the coordinate system.

---

## v0.1.3a: specification layers (parallel branch)

**Delta**: 4 sequential layers for the spec part. USE → IMPORT → IMPLICIT → declarations. 3 new tables (use_stmt, import_stmt, implicit_rule) + 2 child tables (use_entity, import_entity).

**Rationale**: spec part has strict semantic dependency order. USE imports names from modules. IMPORT controls host association (which parent names are visible). IMPLICIT defines default typing. Declarations use all of these. Each layer depends on the previous.

**Lesson**: the spec part is flat (ordered sequence of groups), not nested. Four layers of the same shape: keyword-group → parsed entities.

---

## v0.1.3b: execution internal structure (parallel branch)

**Delta**: control_region table (13 kinds, self-referential nesting) + semantic_basic_block + sbb_edge (CFG). binding_kind and construct_name columns on control_region.

**Rationale**: the exec part is a tree (nested control constructs), not a flat sequence. Control regions are internal nodes; SBBs are leaves. The CFG (sbb_edge) adds flow edges on top of the containment tree.

**Key insight**: BLOCK is the only control construct that changes the name-binding environment completely (full_scope). DO CONCURRENT introduces construct indices. ASSOCIATE introduces construct entities. All others have binding_kind = none.

**Lesson**: execution has two orthogonal structures — containment (tree) and flow (graph). Both built on the same SBB leaf units.

---

## v0.1.3: merge

Branches 0.1.3a (spec) and 0.1.3b (exec) merged. No conflicts by construction — they addressed disjoint concerns.

**State**: 12 fact tables + 1 view. Complete but sprawling.

---

## v0.1.4a: fact tables as coordinate system

**Delta**: add declaration_construct table (18 kinds). Formalize the three conditions for a complete coordinate system.

**Three conditions** (the central design principle from this point forward):
1. **Complete partition**: every source line belongs to exactly one leaf-level fact table row
2. **Kind-determined grammar**: the kind value uniquely determines which grammar production to parse
3. **Layered dependency**: layers can be processed sequentially with acyclic dependencies

**Key insight**: fact tables are structural coordinates (WHERE + WHAT KIND). Anything recoverable from coordinates + source text is a computed table, not a fact table. `semantic_content = parse(source_text, grammar_production, environment)` is deterministic given coordinates.

**Lesson**: the three conditions are the test for whether something belongs in the coordinate system. If it fails any condition, it's either a process output or the partitioning is wrong.

---

## v0.1.4b: execution completeness verification

**Delta**: verified exec part satisfies all three conditions. Documented 5 computed tables for exec content (data_access, call_edge, io_operation, allocation_event, construct_entity).

**Key insight**: the environment for each SBB is tree-compositional: `env(SBB) = spec_env(scope) ∘ Δ(region₁) ∘ ... ∘ Δ(regionₖ)`. Each control region's binding change (Δ) is a pure function of its kind.

**Lesson**: the containment hierarchy IS the coordinate system. Every semantic property is recoverable by walking the tree upward and applying binding deltas.

---

## v0.1.4: merge — the 12-table system

Merged architecture. 12 fact tables + 1 view. Both spec and exec satisfy the three conditions. Canonical reference schema published.

**Peak complexity**. Everything downstream simplifies.

---

## v0.1.5: extraction pipeline design

**Delta**: designed parser combinator pipeline. 10 sequential steps + 2 leaf steps. Each step: `Residual → (dict[str, DataFrame], Residual)`.

**Key insight**: file locality — every fact table depends only on single-file information. This enables embarrassingly parallel processing with `Pool.map(process_file, files)`.

**Problem found**: the `dict[str, DataFrame]` return type adds unnecessary complexity. Each step produces exactly one fact table — why wrap it in a dict?

**Lesson**: the pipeline topology is a fixed DAG, not a dynamic graph. It's a compiler pass chain, not a data pipeline.

---

## v0.1.6: two-table contract + plain composition

**Delta**: simplify to `(DataFrame, DataFrame)` two-table contract. Drop Dagster/framework overhead. Pipeline is a ~25-line Python function.

**Key decisions**:
- Two-table contract: each processor returns `(fact_df, residual_df)`. No dicts, no string keys.
- Domain verbs: parse, segment, partition, trace (not extract, transform, load).
- The pipeline function IS the DAG. Reading the code is reading the topology.

**Lessons**:
- Frameworks solve coordination problems. This pipeline has no coordination problem — it's a fixed linear chain with one branch point (spec/exec filter).
- ETL naming implies batch processing at scale. This is a compiler: one file in, structured facts out.
- The simplest orchestration is function calls.

---

## v0.1.7: structural indexing only — the OS analogy

**Delta**: drop 7 fact tables. Keep only 5 structural coordinate tables. All spec content (USE, IMPORT, IMPLICIT, declarations) becomes computed-on-demand. Drop binding_kind, construct_name, implicit_typing, ancestor_scope_id, default_accessibility from fact tables.

**The OS analogy** (central metaphor):
- **File system** = fact tables (containment hierarchy). Built once by `mkfs`.
- **Kernel** = pipeline + fcst. The `parse_source → partition_blocks` chain IS mkfs.
- **Processes** = computed tables. Read from fact tables + source_line on demand via `parse_as(text, kind)`.

**Key decisions**:
- scope_part splits `'specification'` into `'environment'` + `'declarations'`. Finer structural index, but still just line ranges.
- `'subprogram'` part absorbed into scope.parent_scope_id — CONTAINS creates child scopes, not a part.
- All spec content tables (use_stmt, import_stmt, implicit_rule, declaration_construct, use_entity, import_entity) become processes.
- sbb_edge becomes a process (flow ≠ containment).

**BLOCK construct problem discovered**: BLOCK is both a control construct (syntactically) and a scoping unit (semantically). It has USE/IMPORT/IMPLICIT/declarations — a full specification part. Where does it go?

**v0.1.7 solution**: separate `block_scope` physical table + `scoping_unit` view + `unit_source`/`unit_id` pattern + recursive pipeline. This worked but added substantial complexity: 6 fact tables, 2 views, recursive orchestrator, three-table parse_execution output, unit_source/unit_id threading through 3 tables.

**Lesson**: the OS analogy is the right frame. It clarifies the fact/process boundary immediately. But the BLOCK treatment was over-engineered.

---

## v0.1.8: BLOCK as opaque leaf — final design

**Delta**: treat BLOCK as a leaf SBB with `kind = 'block_scope'`. Drop block_scope table, scoping_unit view, unit_source/unit_id, recursive orchestrator.

**The argument**: BLOCK is a let-binding region — like C's `{ }` but with USE/IMPORT/IMPLICIT. It's anonymous, unreferenceable, no-escape, purely lexical. Its internal structure is local by definition. Nobody outside the BLOCK can name anything inside it.

**Therefore**: the pipeline doesn't need to decompose BLOCK internals. It records WHERE the BLOCK is and WHAT KIND it is (`block_scope`). Processes that need BLOCK internals (name resolution, environment analysis) parse the BLOCK's text on demand — same as environment content, declaration content, or SBB statement content.

**What this eliminated**:
- `block_scope` table → BLOCK is an SBB leaf
- `scoping_unit` view → one scope table
- `unit_source`/`unit_id` → plain `scope_id`
- Recursive orchestrator → linear pipeline
- Three-table parse_execution → all processors follow two-table contract

**Final architecture**: 5 fact tables, 5 processors, ~25 lines of composition, no recursion, no framework.

---

## Summary of lessons

### 1. Bounded vs. unbounded nesting determines table structure
Structural scopes (≤3 levels) → self-referential FK in one table. Control constructs (unbounded) → separate tree table. This distinction drove v0.1.1 and remained stable.

### 2. The three conditions test what belongs in the coordinate system
Complete partition, kind-determined grammar, layered dependency. If a column or table fails any condition, it's either a process output or the partitioning needs adjustment. Introduced at v0.1.4, applied ruthlessly at v0.1.7–v0.1.8.

### 3. Fact vs. process is the hardest boundary to draw
v0.1.0–v0.1.4 stored too much (12 tables). v0.1.7 applied the OS analogy and realized: anything recoverable from `(coordinates, source_text, grammar_production)` is a process, not a fact. The coordinate system is a file system, not a database of parsed content.

### 4. Frameworks solve coordination problems you don't have
The pipeline is a fixed linear chain. Dagster/Airflow/Prefect solve dynamic DAG scheduling, retry logic, asset materialization. None of these apply. Function calls are the right orchestration.

### 5. Recursion signals a missing abstraction
v0.1.7's recursive orchestrator existed because BLOCK was treated as a full scoping unit requiring the same pipeline. v0.1.8 realized BLOCK is opaque at the structural level — its internals are a process concern. The recursion disappeared.

### 6. Naming reveals category errors
ETL names (extract, transform, load) implied batch data processing. Domain verbs (parse, segment, partition) revealed the true operation: compiler-style structural decomposition. BLOCK in the control_region table was a name/category error too — it's a scoping device, not a control flow mechanism.

### 7. Simplification is non-monotonic
The table count went: 4 → 5 → 10 → 12 → 12 → 6 → 5. Complexity grew as the problem was explored, then shrank as the structural/semantic boundary was understood. The final system is simpler than the initial one, but it required traversing the complexity to find the simplicity.

---

## Version lineage

```
0.1.0 → 0.1.1 → 0.1.2 ─┬─ 0.1.3a ─┐
                         └─ 0.1.3b ─┤
                                     └─ 0.1.3 ─┬─ 0.1.4a ─┐
                                                └─ 0.1.4b ─┤
                                                            └─ 0.1.4 → 0.1.5 → 0.1.6 → 0.1.7 → 0.1.8
```

| Version | Fact tables | Key change |
|---------|:-----------:|------------|
| 0.1.0 | 4 | initial: 13 scope kinds, CFG concepts |
| 0.1.1 | 1 | narrow to 8 structural scope kinds |
| 0.1.2 | 2 | add scope_part (spec/exec/subprogram) |
| 0.1.3a | 7 | spec layers: USE, IMPORT, IMPLICIT + entities |
| 0.1.3b | 5 | exec tree: control_region, SBB, sbb_edge |
| 0.1.4a | 8 | declaration_construct; three conditions formalized |
| 0.1.4 | 12 | merge: complete coordinate system |
| 0.1.5 | 12 | pipeline design (parser combinator pattern) |
| 0.1.6 | 12 | two-table contract, drop framework |
| 0.1.7 | 6 | OS analogy; drop spec content tables; BLOCK as recursive scoping unit |
| 0.1.8 | 5 | BLOCK as opaque leaf; final minimal design |
