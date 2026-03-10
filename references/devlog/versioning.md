# devlog versioning protocol

## Directory layout

```
devlog/
  0.1.0/          ← base version (all files)
  0.1.1/          ← only files changed or added in this version
  0.1.2/          ← only files changed or added in this version
  0.1.3a/         ← parallel branch "a" from 0.1.2
  0.1.3b/         ← parallel branch "b" from 0.1.2
  0.1.3/          ← merge of 0.1.3a + 0.1.3b (contains MERGE file)
  ...
```

## Rules

1. **Base version** contains all initial files.

2. **Subsequent versions** contain only files that are **new or modified** relative to the previous version. Unchanged files are not copied forward.

3. **Deletion** is signaled by an **empty file**. If version N+1 needs to remove a file that existed in version N, it includes that filename with zero bytes of content.

4. **To resolve a file at version V**, walk backwards from V along its ancestry to the base version. The first version that contains the file wins. If that file is empty, the file is considered deleted at that version.

## Parallel versions (branches)

Versions may branch to evolve **independent concerns** in parallel. Branches use a **letter suffix** on the PATCH segment: `0.1.3a`, `0.1.3b`, etc.

### Branch rules

1. **Same parent.** All branches at a given level share the same parent version. `0.1.3a` and `0.1.3b` both descend from `0.1.2`.

2. **No file conflicts.** Parallel branches must not contain files with the same name. Each branch owns a disjoint set of files. This is enforced by convention — branches address separate concerns and produce separate artifacts.

3. **Ancestry for resolution.** A branch version's ancestry is: itself → parent → grandparent → ... → base. Branch `0.1.3a` resolves files through `[0.1.3a, 0.1.2, 0.1.1, 0.1.0]`. It does **not** see files from sibling branch `0.1.3b`.

4. **Merging.** A merge version (e.g., `0.1.3`) combines parallel branches. Its directory contains a `MERGE` file listing the parent branches. The merged state is the union of all branch states. The no-conflict rule guarantees this union is well-defined. The merge version may also contain new or modified files of its own.

### Branch ancestry graph

```
0.1.0 → 0.1.1 → 0.1.2 ─┬─ 0.1.3a ─┐
                         └─ 0.1.3b ─┤
                                     └─ 0.1.3 (merge) ─┬─ 0.1.4a ─┐
                                                        └─ 0.1.4b ─┤
                                                                    └─ 0.1.4 (merge)
```

## Resolution algorithm

```
resolve(filename, version):
    for v in ancestry(version):
        if filename exists in devlog/v/:
            if file is empty:
                return DELETED
            else:
                return contents of devlog/v/filename
    return NOT_FOUND

ancestry(version):
    if version has a MERGE file:
        parents = parse MERGE file for parent list
        return [version] + interleave(ancestry(p) for p in parents)
    elif version has a letter suffix (branch):
        return [version, strip_suffix(version) - 1, ...]
        # e.g., 0.1.3a → [0.1.3a, 0.1.2, 0.1.1, 0.1.0]
    else:
        return [version, version-1, ..., base]
```

## To reconstruct the full state at any version

```
materialize(version):
    state = {}
    for v in reverse(ancestry(version)):   # base first
        for each file in devlog/v/:
            if file is empty:
                delete state[filename]
            else:
                state[filename] = contents
    return state
```

## Example

```
devlog/
  0.1.0/                               ← base: initial scope & CFG design
    sourcecode.sql
    scope.sql
    scope.md
    cfg.md
    semantic-basic-block.md
  0.1.1/                               ← refine scope to 8 structural kinds
    scope.sql
    scope.md
    schema-design.md
  0.1.2/                               ← add scope_part table
    spec-exec-parts.md
    spec-exec.sql
  0.1.3a/                              ← branch: specification part
    specification-semantics.md
    use_association.sql
    import_control.sql
    implicit_rule.sql
    declaration-structures.md
  0.1.3b/                              ← branch: execution part
    execution-semantics.md
    control-flow-and-name-binding.md
    exec-internal-design.md
    control-region.sql
    semantic-basic-block.sql
  0.1.3/                               ← merge
    MERGE
  0.1.4a/                              ← branch: spec coordinate system
    coordinate-system.md
    evolution.md
    semantic-recovery.md
    declaration.sql
  0.1.4b/                              ← branch: exec coordinate system
    exec-coordinate-system.md
    exec-evolution.md
    semantic-dimensions.md
    exec-fact.sql
  0.1.4/                               ← merge (final coordinate system)
    MERGE
    schema.sql
    architecture.md
  0.1.5/                               ← extraction pipeline: parser combinator design
    pipeline-design.md
  0.1.6/                               ← two-table contract + explicit composition
    pipeline-orchestration.md
    test-plan.md
  0.1.7/                               ← structural segmentation only + OS analogy
    spec-branch-redesign.md
    os-analogy.md
  0.1.8/                               ← BLOCK as opaque leaf; final archive
    design-evolution.md
    schema.sql
    processors.md
    test-plan.md
    block-as-leaf.md
```

At any version, the full state is the union of all files from its
ancestry chain. No file conflicts between branches.

## Version numbering

`MAJOR.MINOR.PATCH[BRANCH]` where:
- `MAJOR.MINOR.PATCH` — integers, compared left to right
- `BRANCH` — optional lowercase letter suffix for parallel versions
- Directory name is the full version string (e.g., `0.1.3a`)
