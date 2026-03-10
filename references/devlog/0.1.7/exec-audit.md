# exec part audit: file system vs. process

Applying the OS principle: the file system stores **structural containment** (where things are, what type they are). Everything else is a process.

## The test

For each column: is it a **coordinate** (needed to locate and identify the grammar production), or a **property** (derivable from coordinates + source text)?

For each table: is it **containment** (hierarchical partitioning of source text), or **flow** (derived from statement-level semantics)?

## 1. control_region

| Column | Verdict | Rationale |
|---|---|---|
| `region_id` | coordinate | Identity — primary key |
| `parent_region_id` | coordinate | Containment — nesting hierarchy |
| `scope_id` | coordinate | Containment — which scope |
| `kind` | coordinate | **File type** — determines grammar production (Condition 2). `if` → `If_Construct`, `do` → `Do_Construct`, etc. Without this, you can't parse the region. |
| `binding_kind` | **property** | Pure function of `kind`: block→full_scope, do_concurrent→construct_index, associate→construct_entity, else→none. Zero information beyond what `kind` already carries. |
| `construct_name` | **property** | Parsed from the header line text (`outer: DO ...`). Content, not structure. Any process needing it re-parses the first line. |
| `filename` | coordinate | Location |
| `start_line` | coordinate | Location |
| `end_line` | coordinate | Location |

**Verdict**: `binding_kind` and `construct_name` are process outputs, not file system entries. Drop both.

Minimal control_region:
```
control_region(region_id, parent_region_id, scope_id, kind, filename, start_line, end_line)
```

## 2. semantic_basic_block

| Column | Verdict | Rationale |
|---|---|---|
| `sbb_id` | coordinate | Identity |
| `scope_id` | coordinate | Containment |
| `region_id` | coordinate | Containment — innermost enclosing region |
| `filename` | coordinate | Location |
| `start_line` | coordinate | Location |
| `end_line` | coordinate | Location |

**Verdict**: already minimal. Every column is a structural coordinate. Nothing to drop.

SBB identification is purely structural: Convention B says every control construct boundary starts a new SBB. The construct boundaries come from control_region's line ranges — no statement-level parsing needed.

## 3. sbb_edge

| Column | Verdict | Rationale |
|---|---|---|
| `from_sbb_id` | — | flow |
| `to_sbb_id` | — | flow |
| `edge_kind` | — | flow semantics |

**Verdict**: the entire table is a **process output**, not file system.

The CFG requires understanding what each SBB's statements DO:
- Is there an IF condition? → branch_true / branch_false
- Is this a DO loop header? → loop_back / loop_exit
- Is there a GOTO? → jump target resolution
- Is there a RETURN/STOP? → return edge

These are all **statement-level semantic properties**, not structural containment. The containment tree (scope → region → sbb) tells you WHERE code lives. The flow graph tells you HOW it executes. That's a process.

### Analogy check

| OS | Our system |
|---|---|
| Directory tree | scope → scope_part → control_region → sbb |
| File type (in inode) | `kind` on scope_part and control_region |
| File content | source_line text at the coordinates |
| Symbolic links | sbb_edge — **but symlinks are created by users/processes, not by mkfs** |

In Unix, `mkfs` creates the empty file system. `ln -s` (a process) creates symbolic links later. Similarly, the pipeline (mkfs) should build the containment tree, and a process (trace_edges) should compute the flow graph.

## 4. Conclusion

### What stays in the file system (fact tables)

| Table | Columns | Role |
|---|---|---|
| `source_line` | line_no, text | Disk blocks |
| `scope` | scope_id, parent_scope_id, kind, name, filename, start_line, end_line, implicit_typing, ancestor_scope_id, default_accessibility | Directory tree |
| `scope_part` | scope_id, part, start_line, end_line | File types within directories |
| `control_region` | region_id, parent_region_id, scope_id, kind, filename, start_line, end_line | Subdirectory tree within execution |
| `semantic_basic_block` | sbb_id, scope_id, region_id, filename, start_line, end_line | Leaf files |

**5 fact tables. 5 pipeline steps.**

### What moves to processes (computed tables)

| Table | Computed from | Process |
|---|---|---|
| `binding_kind` | control_region.kind | `f(kind)` — trivial lookup |
| `construct_name` | source_line at control_region.start_line | parse header line |
| `sbb_edge` | sbb coordinates + region structure + source text | `trace_edges` |
| `use_stmt` | source_line at environment part | `parse_environment` |
| `import_stmt` | source_line at environment part | `parse_environment` |
| `implicit_rule` | source_line at environment part | `parse_environment` |
| `declaration_construct` | source_line at declarations part | `parse_declarations` |
| `use_entity` | computed use_stmt | `parse_use_entities` |
| `import_entity` | computed import_stmt | `parse_import_entities` |
| `data_access` | source_line at sbb coordinates | future |
| `call_edge` | source_line at sbb coordinates | future |

### What about scope columns?

Applying the same test to scope:

| Column | Verdict | Rationale |
|---|---|---|
| `scope_id` | coordinate | Identity |
| `parent_scope_id` | coordinate | Containment |
| `kind` | coordinate | File type — determines grammar production |
| `name` | **property** | Parsed from header line. Content, not structure. |
| `filename` | coordinate | Location |
| `start_line`, `end_line` | coordinate | Location |
| `implicit_typing` | **property** | Determined by IMPLICIT statements in the environment region. Process output. |
| `ancestor_scope_id` | **property** | Submodule ancestry — cross-file resolution. Process output. |
| `default_accessibility` | **property** | Determined by ACCESS statement. Process output. |

Strict application of the principle would drop `name`, `implicit_typing`, `ancestor_scope_id`, and `default_accessibility` from the scope fact table. But `name` is borderline — it's used as an identifier for cross-file resolution (USE module_name → scope lookup). Without it, every cross-file operation would need to re-parse scope headers.

**Pragmatic boundary**: keep `name` as a structural coordinate (it's the "directory name" in the OS analogy — directories have names). Drop `implicit_typing`, `ancestor_scope_id`, and `default_accessibility` as process outputs.

Minimal scope:
```
scope(scope_id, parent_scope_id, kind, name, filename, start_line, end_line)
```

## 5. Revised pipeline

```python
def process_file(filepath: str) -> dict[str, pd.DataFrame]:
    source_line, file_res      = parse_source(filepath)
    scope, scope_res           = parse_scopes(file_res)
    scope_part, part_res       = segment_parts(scope_res)

    # exec branch only — spec is fully handled by segment_parts
    exec_res = part_res[part_res["part"] == "execution"]
    control_region, region_res = parse_regions(exec_res)
    sbb, _                     = partition_blocks(region_res)

    return {
        "source_line": source_line,
        "scope": scope,
        "scope_part": scope_part,
        "control_region": control_region,
        "semantic_basic_block": sbb,
    }
```

**5 steps. 5 fact tables. No trace_edges in the pipeline — it's a process.**

## 6. The revised pipeline graph

```
parse_source
  ├── source_line  (fact)
  └── file_residual
        │
        ▼
      parse_scopes
        ├── scope  (fact: id, parent, kind, name, file, lines)
        └── scope_residual
              │
              ▼
            segment_parts
              ├── scope_part  (fact: environment, declarations, execution, subprogram)
              └── part_residual
                    │
                    │ filter: execution
                    ▼
                  parse_regions
                    ├── control_region  (fact: id, parent, scope, kind, file, lines)
                    └── region_residual
                          │
                          ▼
                        partition_blocks
                          └── sbb  (fact: id, scope, region, file, lines)
```

Five steps build the file system. Everything else is a process reading from it.
