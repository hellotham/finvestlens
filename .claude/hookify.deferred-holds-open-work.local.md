---
name: deferred-holds-open-work
enabled: true
event: file
action: warn
conditions:
  - field: file_path
    operator: regex_match
    pattern: docs/deferred\.md$
  - field: new_text
    operator: regex_match
    pattern: (?m)^\|[^|\n]*\|[^|\n]*\|[^|\n]*(?:✅|\*\*Done \(|\*\*Closed |\*\*Shipped |\*\*Resolved )
---

**A finished row does not belong in `docs/deferred.md`.**

That file holds **open work only** — its own heading says so, and CLAUDE.md
describes it as "what was consciously *not* built, with reasons". Completed work
goes to [implemented.md](../docs/implemented.md).

You are adding (or leaving) a table row marked done — ✅, **Done (**, **Closed**,
**Shipped** or **Resolved**.

**Move it, don't tick it:**

1. Write the substance into `docs/implemented.md` — the finding, the fix, and
   how it was verified. Check first whether an entry already covers it; three of
   the five rows found on 11 Aug 2026 were already recorded there and only
   needed deleting here.
2. Delete the row from `docs/deferred.md`.
3. If only *part* of the item shipped, the row stays — but its note must say
   what remains open, not lead with what was finished.

Why this matters: a reader scanning `deferred.md` for what is left cannot tell a
✅ row from an open one without reading every cell, so the file stops answering
the single question it exists to answer. This drifted once already — five
completed rows had accumulated, two of whose detail existed nowhere else.
