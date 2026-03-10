# the system is an OS for source code

## The analogy

An operating system has three layers:

1. **File system** — persistent, hierarchical namespace. Stores WHERE data lives (paths, inodes, block pointers), not WHAT it means. Stable across reboots. Everything else reads from it.

2. **Kernel** — builds and maintains the file system. Provides system calls (`open`, `read`, `stat`) for structured access. Small, fixed, trusted.

3. **Processes** — transient computations that use kernel APIs to read from the file system, compute results, and optionally cache them. Spawned on demand. Many processes, each with its own concern.

Our system has the same three layers:

### File system = coordinate system (6 fact tables)

```
source_line         ← disk blocks (raw bytes)
scope               ← directory tree (containment hierarchy)
scope_part          ← file types (environment, declarations, execution, subprogram)
control_region      ← subdirectory nesting within execution
semantic_basic_block ← leaf files (smallest addressable unit)
sbb_edge            ← symbolic links (control flow between blocks)
```

The coordinate system is a **persistent hierarchical namespace for source code**. It tells you WHERE every structural unit lives — file, scope, part, region, block — without storing WHAT it contains semantically.

A coordinate tuple `(filename, scope_id, part, start_line, end_line)` is a **path**. It uniquely addresses a region of code. The raw content lives in `source_line` (disk blocks). The structural metadata lives in scope/scope_part/control_region/sbb (inodes).

### Kernel = pipeline + fcst

The kernel builds the file system (`mkfs`) and provides system calls for structured access:

| Kernel operation | OS equivalent |
|---|---|
| `parse_source` | `mkfs` — format raw bytes into addressable structure |
| `parse_scopes` | build directory tree |
| `segment_parts` | assign file types |
| `parse_regions` | build subdirectory nesting |
| `partition_blocks` | allocate leaf blocks |
| `trace_edges` | create symbolic links |
| `parse_as(text, kind)` | `read()` — the system call: given coordinates, return structured content |

The kernel is small (6 steps), fixed (the pipeline doesn't change), and trusted (pandera-validated at boundaries). It runs once per file to build the coordinate system.

### Processes = computed tables

Every analysis is a process — a transient computation that reads from the coordinate system via `parse_as`:

| Process | Reads from | Produces |
|---|---|---|
| USE resolution | environment part coordinates | use_stmt, use_entity |
| IMPORT resolution | environment part coordinates | import_stmt, import_entity |
| IMPLICIT typing | environment part coordinates | implicit_rule |
| Declaration parsing | declarations part coordinates | declaration_construct |
| Data flow analysis | SBB coordinates | data_access (read/write sets) |
| Call graph | SBB coordinates | call_edge |
| I/O analysis | SBB coordinates | io_operation |
| Type inference | declarations + environment | entity types |

Processes are:
- **Spawned on demand** — you don't parse all declarations upfront; you parse the ones you need when you need them
- **Independent** — each process reads from the same coordinate system but doesn't depend on other processes (unless explicitly composed)
- **Cacheable** — a process can materialize its results (write to a table), or run every time (pure computation)
- **Composable** — type inference reads from declaration parsing, which reads from the coordinate system. The dependency chain is explicit.

Like `/proc` in Linux, computed tables present a structured view generated on demand from the underlying data. They look like tables but are virtual — derived from coordinates + source text + grammar rules.

## Why this matters

### The file system is the stable layer

The coordinate system changes only when the source code changes. Analysis processes come and go — new analyses are added, old ones refined — but the coordinate system stays. This is exactly how a file system works: applications change; the file system persists.

### The kernel is minimal

6 pipeline steps. One system call (`parse_as`). No analysis logic in the kernel. The kernel's job is to build the structural namespace and provide read access. Everything semantic is a process.

### Processes don't need a framework

You don't use Dagster to manage Unix processes. Processes are just functions that call `read()`. Similarly, computed tables are just functions that call `parse_as()`. The coordination (if any) is process-level composition, not infrastructure.

### Mount points = USE associations

`USE module_name` makes another module's public namespace visible in the current scope. This is exactly a mount point — it grafts one subtree of the coordinate system onto another. Cross-file resolution is the mount table.

### The analogy explains the spec/exec asymmetry

The spec part is like a flat directory (environment + declarations — two file types, no nesting). Listing its contents is trivial — just read the files.

The exec part is like a deeply nested directory tree (control regions, basic blocks, CFG edges). Navigating it requires structural indexing — you need the subdirectory tree and the symlinks.

That's why the kernel has 3 steps for exec (parse_regions, partition_blocks, trace_edges) and 0 steps for spec (just segmentation). The structural complexity is different.
