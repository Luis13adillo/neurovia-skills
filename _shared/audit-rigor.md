# Audit Rigor Standard — MT Barbershop Bulletproof Skills

**This standard is mandatory for every `bulletproof-*` skill in `~/.claude/skills/`.**

It exists because audits kept being "half-assed": the model would run 4 of 12 queries, skip the RLS check entirely, hit one passing grep and call it done. A report with no coverage footer looks confident but hides skipped work.

**An audit that does not run every required check is a FAILED audit, not a partial one.** Silence on a surface is NOT a pass — it is a gap.

---

## The Five Pillars of a Complete Audit

Every audit MUST cover all five. Skipping any pillar = failed audit.

### Pillar 1 — Codebase
Every file in the domain's Surface Inventory is either: (a) opened and the relevant invariant checked, or (b) explicitly skipped with a reason. The coverage report lists each file as PASS / FAIL / NOT-RUN / SKIPPED-(reason).

### Pillar 2 — Database state
Every table listed in the Surface Inventory is queried for: row count, status distribution, NULL counts on required columns, orphan rows, and domain-specific invariants. Queries run via `mcp__supabase-mt__execute_sql` ONLY — never the other supabase MCP.

### Pillar 3 — Queries
Every numbered query in `references/audit-queries.sql` MUST be run. Each one gets a PASS (0 rows or expected count) / FAIL (violations found, list them) / NOT-RUN (explain why) verdict. No query may be silently skipped.

### Pillar 4 — RLS policies
Every table in the domain has its RLS policies listed, checked against the expected role pattern (public / client / barber / owner), and tested for one bypass attempt where relevant (e.g., "can a barber read another barber's payouts?"). Use the RLS query in the Universal Audit Preamble below.

### Pillar 5 — Integrations / downstream
Every external service (Stripe, Twilio, Resend, Google Calendar, Antigravity), cron route, webhook, trigger, and RPC function touched by the domain is verified. Missing/stale records in idempotency tables, webhook logs, and cron audit trails all count.

---

## Universal Audit Preamble (MUST run at the top of EVERY audit mode)

Before running any domain-specific query, the model MUST run these 5 discovery queries and attach the results to the report. These are the proof that the Surface Inventory is still accurate.

### 1. Enumerate tables in domain
```sql
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN (<every table from SURFACE_INVENTORY.md>)
ORDER BY table_name;
```
Verdict: all tables from the inventory must exist. Missing table = the inventory drifted; stop and ask the user before continuing.

### 2. List RLS policies for every domain table
```sql
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN (<every table from SURFACE_INVENTORY.md>)
ORDER BY tablename, policyname;
```
Verdict: every table has at least one policy per expected role. Missing policy = RLS gap; flag in the report.

### 3. List triggers on domain tables
```sql
SELECT event_object_table AS table_name, trigger_name, action_timing, event_manipulation
FROM information_schema.triggers
WHERE event_object_schema = 'public'
  AND event_object_table IN (<every table from SURFACE_INVENTORY.md>)
ORDER BY event_object_table, trigger_name;
```
Verdict: expected triggers (from the Surface Inventory) exist; extra triggers get flagged.

### 4. List RPC functions in domain
```sql
SELECT routine_name, data_type, routine_definition IS NOT NULL AS has_body
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name IN (<every RPC from SURFACE_INVENTORY.md>)
ORDER BY routine_name;
```
Verdict: every RPC exists. Missing RPC = broken feature.

### 5. Verify domain migration history
```sql
SELECT name, executed_at
FROM supabase_migrations.schema_migrations
WHERE name ILIKE ANY (ARRAY[<every migration keyword from SURFACE_INVENTORY.md>])
ORDER BY executed_at;
```
Verdict: every expected migration ran. Missing migration = schema drift.

---

## Proof-of-Read Rule (MANDATORY)

**A file listed as PASS in the Coverage Report MUST cite a specific line number from that file as evidence.** The format is `file.ts:LINE — <what was checked>`. No line number cited = NOT-RUN, not PASS. This blocks the "I looked at it" self-report that has no backing.

Acceptable PASS: `stripe/route.ts:232 — checkout.session.completed handler syncs payment_status`.
Rejected PASS: `stripe/route.ts — looks fine`.
NOT-RUN: `stripe/route.ts — file not opened this session`.

If the audit opened the file but found no issue, cite the line of the invariant you verified. If the audit didn't open the file, mark NOT-RUN and add the filename to the Gap Self-Report below.

---

## Cross-Surface Coupling Rules (per-skill)

Each skill defines a table of "when you audit X, you MUST also audit Y" couplings. A coupling violation = audit reported PASS on X but didn't open Y. These catch systemic gaps where one surface's behavior depends on another.

Example from commission:
- Refund handler audited → MUST also audit daily_summaries reversal + barber_payouts reversal + cash_fee_ledger reversal
- Waive endpoint audited → MUST also audit parent row update + service_transactions update + cash_fee_ledger update (3-table atomicity)
- Reassign-completed audited → MUST also audit cash_fee_ledger delta + service_transactions recompute

Each skill's SKILL.md contains its own coupling table. Obey it.

---

## Gap Self-Report (MANDATORY)

Every audit report MUST include a "Gap Self-Report" section listing what was NOT investigated deeply. Silence on a surface becomes visible as a gap, not a false pass. Format:

```markdown
## Gap Self-Report

| # | Gap | Why it matters | Severity |
|---|---|---|---|
| G1 | Did not open src/app/api/X/route.ts | Touches table Y — could duplicate rows | Unknown |
| G2 | Did not verify daily_summaries reversal on refund | Summary keeps stale totals after refund | HIGH |

Surfaces in inventory not audited this run: <comma-separated list of item numbers from SURFACE_INVENTORY.md>.
Questions requiring external verification (Stripe Dashboard, Twilio console, etc.): <list>.
```

If there are zero gaps, the section still appears with "No gaps identified. All surfaces audited with proof-of-read." — so the reader knows the model actually considered it.

---

## Mandatory Output Template

Every audit report MUST end with this exact block. An audit without this block is INCOMPLETE.

```markdown
---

## Coverage Report (MANDATORY — audit is incomplete without this)

### Pillar 1 — Codebase (Proof-of-Read REQUIRED)
| File | Verdict | Evidence (file:line — what was checked) |
|---|---|---|
| src/app/api/.../route.ts | PASS | route.ts:142 — Zod schema rejects tip < 0 |
| src/lib/.../helper.ts | FAIL | helper.ts:47 — calcFee() bypasses owner exemption |
| src/components/.../Modal.tsx | NOT-RUN | file not opened this session |

Files audited: N / N_total. Every PASS MUST have a file:line citation. Any PASS without evidence is treated as NOT-RUN.

### Pillar 2 — Database
| Table | Row count | Status dist | NULL violations |
|---|---|---|---|
| table_a | 523 | — | 0 |
| table_b | 134 | owed:130, settled:4 | 1 (flagged) |

Tables audited: N / N_total

### Pillar 3 — Queries
| # | Name | Verdict | Rows |
|---|---|---|---|
| 1 | missing_ledger | PASS | 0 |
| 2 | orphan_txns | FAIL | 6 |
| 3 | ... | ... | ... |

Queries run: N / N_total. Queries skipped: <list> (must be empty OR explained).

### Pillar 4 — RLS
| Table | Policies found | Expected | Verdict |
|---|---|---|---|
| table_a | 4 | 4 | PASS |
| table_b | 1 | 3 | FAIL — missing client read, owner write |

RLS tables audited: N / N_total

### Pillar 5 — Integrations
| Integration | Verdict | Note |
|---|---|---|
| stripe webhook idempotency | PASS | dedup working |
| twilio send path | FAIL | no retry on 5xx |
| cron /api/cron/X | NOT-RUN | did not inspect |

Integrations audited: N / N_total

---

## Totals

- Surfaces audited with proof-of-read: X / Y total (XX%)
- FAILs: N
- NOT-RUNs: N  (if > 0, the audit is PARTIAL, not COMPLETE — state this in the header)
- Coupling violations (PASS on X without auditing coupled Y): N  (must be 0)

**An audit with NOT-RUNs is PARTIAL. The header of the audit report MUST say "PARTIAL AUDIT — N surfaces unaudited" instead of "Commission Audit Report" if NOT-RUN > 0.**
```

---

## Forcing Language (copy into every skill's `audit` mode header)

> **Do NOT stop on first pass.** You MUST work through every file in SURFACE_INVENTORY.md, every query in audit-queries.sql, every RLS policy, every trigger, and every integration. Stopping after one finding is a half-audit and is explicitly forbidden.
>
> **Silence ≠ Pass. Self-declaration ≠ Proof.** If you did not open a file with Read, it is NOT-RUN — even if the file sounds minor. Every PASS requires a file:line citation.
>
> **Obey the Cross-Surface Coupling Rules.** When you audit X that has a coupling to Y, you MUST also audit Y in the same session. Skipping Y while passing X = coupling violation.
>
> **The Coverage Report + Gap Self-Report are mandatory.** A report missing either is rejected. If NOT-RUN > 0, the report header MUST say "PARTIAL AUDIT".

---

## When the Surface Inventory is wrong

If you discover a file, table, trigger, or RPC that belongs to the domain but isn't in SURFACE_INVENTORY.md: (a) finish the audit using the current inventory, (b) flag the missing surface in the Coverage Report under a new "Surface Drift" section, (c) propose adding it to SURFACE_INVENTORY.md and wait for approval.

Do NOT silently expand the inventory mid-audit. That's how skills drift.
