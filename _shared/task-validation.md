# Task Validation Standard — before implementing anything sourced from a document

**Applies to:** any implementation task whose origin is *historical documentation* rather
than a live, reproduced symptom — TODO lists, known-bug docs, planning docs, incident
write-ups, memory files, backlog/Sprint tickets seeded from any of those, or a handoff note.

**Rule:** documentation describes the code as it was on the day someone wrote it. It is a
*lead*, never a finding. Validate the claim against current code before writing a line.

**Why this exists:** on 2026-08-11 two MT Barbershop Sprint tasks (B-0001 waitlist
prioritize, B-0002 calendar cancel confirm) were seeded from `docs/KNOWN_BUGS.md`. Both
had already been fixed on `main` — B-0002 ten days *before* the doc that reported it was
written. A third task from the same doc was still genuinely open. The docs were not
worthless; they were unvalidated.

---

## The gate

Run this before implementation. It is not optional, and it is not a code review.

### 1. Read the cited code at current HEAD

Open the file the task names and read the actual behaviour. This is the primary evidence
and it is always required. Nothing below substitutes for it.

If the task cites a line number that no longer matches, treat that as a **staleness
signal**, not as a location. Find the real code; do not assume the task is therefore wrong.

### 2. Establish when and whether the behaviour changed

Use whatever gives the strongest evidence for this particular claim. Reach for the
cheapest sufficient method, and say which one you used:

- searching history for the claim's distinctive string or symbol, then confirming the
  commit is an ancestor of the mainline branch
- reading the file's change history for the relevant region
- comparing the working tree against the mainline branch
- checking the live/production surface, a database row, a log line, or an API response
  when the claim is about runtime behaviour rather than source
- running an existing test that covers the path

One well-chosen check beats three ritual ones. Weak evidence is worse than none because it
reads as certainty.

### 3. Classify with exactly one verdict

| Verdict | Meaning | What happens next |
|---|---|---|
| **CONFIRMED OPEN** | The described defect exists in current code | Implementation may proceed |
| **ALREADY FIXED** | Current code resolves it | Close/update the task **with the evidence**. Do **not** touch application code |
| **CANNOT REPRODUCE** | The described behaviour cannot be observed and no fix is identifiable | Record exactly what was checked, then stop |
| **NEEDS MORE EVIDENCE** | The claim is neither confirmed nor refuted with what is available | Stop. Request or collect the specific missing evidence, and name what it is |

Only **CONFIRMED OPEN** unlocks implementation. The other three end the run.

### 4. Write the verdict where the work lives

Record the verdict, the evidence, and the source you validated against on the task itself —
the Sprint note, ticket, or equivalent — not only in conversation. A verdict that exists
only in a chat log has to be re-derived by the next person.

State the source's staleness plainly when you find it, so the next task drawn from the same
document is treated with the right suspicion.

---

## Hard limits

- **ALREADY FIXED means no application-code change.** Not a "small cleanup while I'm here,"
  not a refactor, not a comment tidy. Close it and stop.
- **Do not edit the stale source document as a side effect.** Report it. Correcting project
  docs is its own scoped task with its own approval.
- **Do not widen scope on a CONFIRMED OPEN.** The validated claim is the work; anything else
  you noticed gets mentioned, not fixed.

## Relationship to other standards

This gate runs *before* implementation. It is upstream of debugging a live symptom
(`.claude/rules/evidence-first-debugging.md`), upstream of domain audits
(`_shared/audit-rigor.md`), and well upstream of shipping. Passing this gate says only that
the work is real — every later gate still applies.
