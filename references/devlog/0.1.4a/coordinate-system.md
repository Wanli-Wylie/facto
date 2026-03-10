# fact tables as coordinate system — conditions for completeness

## The claim

A system of fact tables is a **coordinate system** for a source region if and only if it assigns every piece of source text a unique, typed address — and that address carries enough structural information that the semantic content at that address is **deterministically recoverable** by a parser that knows nothing beyond the address and the raw source lines.

In other words: the fact tables tell you WHERE to look and WHAT grammar production to apply. The source tells you the rest.

## The three conditions

### Condition 1: Complete partition

Every source line within the target region must belong to exactly one fact table row. No line is unindexed; no line is multiply-indexed.

Formally: the fact table rows, projected onto `[start_line, end_line]`, form a **partition** of the line range — covering, non-overlapping.

**Weakened form**: the partition need not cover blank lines and comments. It must cover every statement that contributes to the name-binding environment.

### Condition 2: Kind-determined grammar

For each fact table row, its `construct` kind (or table identity itself) must uniquely determine the **grammar production** that governs the content within that row's line range.

This means: given only the row's kind and its source lines, a parser can unambiguously apply the correct production rule and extract all semantic content. No external context is needed.

The mapping from kind to production must be injective — no two kinds share a production, and the kind is sufficient for dispatch. No lookahead, no context, no trial-and-error.

**Acceptable refinement**: if a kind maps to a production with a small, deterministic sub-dispatch (e.g., reading the first keyword to disambiguate among sub-productions), this is permitted as long as the sub-dispatch is bounded and always succeeds.

### Condition 3: Layered dependency order

The fact tables must be organized so that the **name-binding environment** at any point in the target region can be reconstructed by processing layers in order.

Each layer's table rows must be interpretable given only the preceding layers' tables and the source. No circular dependencies.

This means a parser processing layers in order 1 → 2 → ... → N can incrementally build the environment, using each layer's output as context for the next.

## Sufficiency argument

If all three conditions hold, then for any point in the indexed region:

1. **Address**: the fact tables give a unique (scope_id, layer, construct_id) triple and a line range
2. **Grammar**: the construct kind determines the production rule to apply
3. **Context**: layers 1 through N-1 (processed in order) supply the name-binding environment needed to interpret layer N

Therefore: `semantic_content = parse(source_lines, grammar_production, environment)`, and all three inputs are determined by the fact tables + raw source. The coordinate system is complete.

## What breaks completeness

### Missing partition (Condition 1 failure)

If a semantically significant statement is not covered by any fact table row, it cannot be located or typed. The parser would need to scan the entire region to find it — the fact tables lose their indexing role.

### Ambiguous grammar (Condition 2 failure)

If a construct kind does not uniquely determine the grammar production, the parser cannot dispatch without trial-and-error or additional context.

**Classic example**: statement-function ambiguity — `f(x) = expr` could be a statement function or an array assignment. The structural parser must resolve this ambiguity when populating the fact table; once the kind is assigned, downstream parsing is deterministic.

### Broken dependency order (Condition 3 failure)

If the layers cannot be processed in a fixed order (e.g., a circular dependency between layers), the environment cannot be incrementally constructed.

**Intra-layer forward references** are not a violation — they are resolved within a single layer by multi-pass processing over the same line range. The fact tables are not affected because the layer boundary is still respected.
