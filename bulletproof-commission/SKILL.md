---
name: bulletproof-commission
description: Audit, diagnose, or scale-check the MT Barbershop commission / fee system (walkin_fee_config, cash_fee_ledger, barber_payouts, service_transactions fee columns, Stripe Connect routing, grace periods). Use when commission amounts look wrong, payouts fail, ledger drift appears, or before adding a new location or barber. Read-only SQL via mcp__supabase-mt__execute_sql only. NEVER writes to production DB — commission data is revenue-critical.
---

# Bulletproof Commission

Commission data flows directly into revenue reporting and into what barbers expect to be paid. A wrong fee calculation or a missing ledger entry erodes trust with both the owner and the barbers. This domain is under a special rule: zero tolerance for production data writes — not even test data.

This skill does NOT replace `CLAUDE.md`, `MEMORY.md`, or the `.claude/rules/*.md` files. It READS them, then runs a structured protocol.

---

## Two-direction ledger (read this first)

MT Barbershop runs **two separate balances** that move in opposite directions. Confusing them is the #1 source of commission bugs.

### Ledger A — Cash services: barber owes shop
When a client pays cash, the **barber** takes the full amount at the chair. The shop is owed the owner's fee (30% of service for walk-ins, 30% of first-time booking clients).
- Source of truth: `cash_fee_ledger` (status `owed` → `settled` or `waived`)
- **Populated by explicit app-code INSERT in 4 route handlers** (NOT a DB trigger — this was the original plan per migration 041's comments but the trigger was never created; only `tr_referral_conversion` exists on `service_transactions`):
  1. `src/app/api/queue/entry/[id]/route.ts` (~line 407) — walk-in PATCH completion
  2. `src/app/api/queue/complete/route.ts` (~line 180) — alternate completion path
  3. `src/app/api/bookings/[id]/route.ts` (~line 375) — booking PATCH completion
  4. `src/app/api/bookings/quick-complete/route.ts` (~line 159) — quick-complete booking
- **A single `catch` block on any of these = a silent missing ledger row.** The handler logs to `owner_alerts` but does NOT block the completion. Query #1 in audit-queries.sql surfaces these.
- Barber sees: "You owe: $X" on barber dashboard
- Owner collects via cash/Venmo/etc., then marks settled via `/api/barber/cash-fees`

### Ledger B — Card/link services (non-Connect barbers): shop owes barber
When a client pays by card or payment link and the barber does NOT have Stripe Connect, the money flows to the **shop's** Stripe account. The shop now owes the barber their net earnings (service minus owner fee) PLUS 100% of the tip.
- Source of truth: `service_transactions` rows where `payment_method IN ('card','link')` AND `fee_settlement_status != 'auto_split'` AND `payment_status = 'paid'`, offset by `barber_payouts` rows.
- Formula (identical in `/api/commission/summary` and `/api/commission/barber-summary`):
  ```
  gross_earnings = Σ (service_amount − owner_fee_amount + tip_amount)
  owed_to_barber = max(0, gross_earnings − Σ barber_payouts.amount)
  ```
- Barber sees: "Shop owes you: $X" on barber dashboard (only when `has_stripe_connect = false`)
- Owner settles via `/api/commission/payout` — this records the payout; the actual Venmo/Zelle/etc. transfer is manual.

### Ledger B' — Card/link services (Connect barbers): should auto-route via Stripe
- Transaction should land with `fee_settlement_status = 'auto_split'`. Barber receives funds directly; shop gets the `application_fee` cut automatically.
- `determinePaymentRouting()` in `src/lib/stripe/connect-helpers.ts` is the logic. **But only `/api/payments/checkout` and `/api/payments/send-link` call it.** The 4 completion handlers listed under Ledger A hardcode `cash_owed | pending` regardless of Connect status — meaning a Connect barber's completion through those paths silently becomes Ledger B instead of B'.
- **Audit signal:** if a barber has `stripe_charges_enabled = true` but ALL their recent card/link transactions are `pending` (not `auto_split`), the Connect flow is bypassed. See query #12 and #17 in `audit-queries.sql`.

### Critical distinctions

| Detail | Ledger A (cash) | Ledger B (card, no Connect) |
|---|---|---|
| Who holds the money after service | Barber | Shop |
| Who owes whom | Barber → Shop | Shop → Barber |
| Table | `cash_fee_ledger` | `service_transactions` − `barber_payouts` |
| Includes tips? | No (fee is on service only) | **Yes — 100% of tip added to owed** |
| Payment status filter | N/A (cash always paid) | **Must filter `payment_status = 'paid'`** |
| Excluded group | — | Stripe Connect barbers (`fee_settlement_status = 'auto_split'`) — they're already paid by Connect |
| Owner-barber exemption | `apply_to_owner_cuts = false` skips fee | `OWNER_BARBER_ID` force-zeroed in summary endpoint |

**If an audit query omits `payment_status = 'paid'`, it will count unpaid payment links as money already collected — false overpayment flags. If an audit query uses `barber_net_amount` alone instead of `(service_amount − owner_fee_amount + tip_amount)`, it under-counts by the full tip amount — false under-threshold readings.**

---

## Mandatory Preflight — BEFORE any action

1. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/CLAUDE.md` — "Commission / Fee System (041)" section and all table schemas.
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-MT-Barbershop-Systems/memory/MEMORY.md` — the "ABSOLUTE RULE — Zero Production Data Contamination" entry (2026-03-23 incident, 190+ rows cleaned across 14 tables).
3. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.claude/rules/debugging-protocol.md` — Sections 7 (Zero Tolerance), 8 (Existing Systems Untouchable), **9 (ZERO Production Data Contamination)**.
4. Planning docs if they exist: `.planning/commission-system-spec.md`, `.planning/commission-two-way-tracking.md`, `.planning/commission-barber-earnings-visibility.md`.

Confirm "Preflight complete. Running [mode]."

---

## Choose a Mode

- **audit**, **diagnose**, **scale-check**, or **fix**. `audit`, `diagnose`, and `scale-check` are READ-ONLY. `fix` is the only mode that edits code, and only under the explicit gate described in its section.

---

## AUDIT RIGOR — read before starting audit mode

This skill enforces the universal Audit Rigor Standard at `~/.claude/skills/_shared/audit-rigor.md` and the domain Surface Inventory at `references/SURFACE_INVENTORY.md`. Read both before you do anything.

**Five Pillars (all mandatory):** codebase, database, queries, RLS, integrations. Missing any pillar = failed audit.

**Proof-of-Read:** every file claimed PASS in the Coverage Report MUST cite a `file.ts:LINE` from that file. No line = NOT-RUN, not PASS. This is enforced by the universal standard.

**Forcing language — copy this into your mental model:**

> Do NOT stop on first pass. You MUST work through EVERY file in SURFACE_INVENTORY.md (63+ surfaces), EVERY query in audit-queries.sql (24 queries), EVERY RLS policy, EVERY trigger, and EVERY integration. Stopping after one finding is a half-audit and is explicitly forbidden.
>
> Silence ≠ Pass. Self-declaration ≠ Proof. Every PASS needs a file:line citation.
>
> Obey the Cross-Surface Coupling Rules below. Skipping a coupled surface while passing its partner = coupling violation.
>
> The Coverage Report + Gap Self-Report are MANDATORY. A report missing either is rejected. If NOT-RUN > 0, the header must say "PARTIAL AUDIT".

---

## Cross-Surface Coupling Rules — MUST be followed

When you audit a surface on the left, you MUST also audit all surfaces on the right in the same session. These rules catch the systemic gaps where one file's behavior depends on another that looks unrelated.

| If you audit... | You MUST also audit... | Why |
|---|---|---|
| Refund branch of `webhooks/stripe/route.ts` | `daily_summaries` reversal behavior + `barber_payouts` reversal + `cash_fee_ledger` reversal + `commission_waiver_audit` write | Refund must reverse EVERY downstream surface. A refund that updates payment_status but not daily_summaries silently over-reports revenue forever (Gap G1). A refund with no compensating payout reversal double-pays the barber (Gap G2). |
| `commission/waive/route.ts` | Parent row (queue_entries OR bookings) update + `service_transactions` update + `cash_fee_ledger` update + `commission_waiver_audit` write | Waive must be atomic across 4 tables. Partial failure = drift. Missing audit-log row = forensic gap. |
| `queue/entry/[id]/void/route.ts` | `cash_fee_ledger` row deletion/waive + `service_transactions` update (filter MUST include both `pending` AND `cash_owed` — R2 #7) + parent row update + `daily_summaries` recompute via `update_daily_summary` call (R2 #8 — voided entries keep counting otherwise) | Void touches 4 tables, not 3. Filtering on only `pending` leaves `cash_owed` txns showing the fee owed. Skipping `daily_summaries` recompute means owner reports over-state revenue after every void. |
| `queue/entry/[id]/reassign-completed/route.ts` | `cash_fee_ledger` recompute for OLD barber + INSERT for NEW barber + `service_transactions` recompute + Connect routing for NEW barber (R2 #9 — no hardcoded `cash_owed`/`pending`) + `barber_payouts` reversal if OLD barber was already paid (R2 #10 — double-pay risk) + `daily_summaries` refresh for BOTH OLD and NEW barber (R2 #11 — cut + revenue stays with wrong barber otherwise) | Reassign-completed touches 6 surfaces: ledger (×2 barbers), service_transactions, Connect routing, payouts reversal, daily_summaries (×2 barbers). Any miss = silent drift. |
| `queue/entry/[id]/route.ts` (completion) | `cash_fee_ledger` INSERT + `service_transactions` creation trigger + `staff_status` transition + `daily_summaries` upsert | Completion path has 4 downstream writes. Any silent catch block = missing ledger row. |
| `bookings/[id]/route.ts` (completion) | Same as queue completion PLUS first-booking exemption logic + grace-period logic + `fee_settlement_status` NULL path | Booking completion has additional NULL fee path that quick-complete doesn't replicate. |
| `bookings/quick-complete/route.ts` | Compare to `bookings/[id]/route.ts` completion — first-booking check parity | Quick-complete historically skipped the first-booking exemption (Defect H7). |
| `payments/checkout/route.ts` | `determinePaymentRouting()` call site + `service_transactions.fee_settlement_status` set at INSERT time + tip_amount metadata propagation | If `determinePaymentRouting()` isn't called, Connect barbers accrue as Ledger B instead of B'. |
| `payments/send-link/route.ts` | Same as checkout | Payment-link path is separate from checkout and breaks independently. |
| `determinePaymentRouting()` in `connect-helpers.ts` | `OWNER_BARBER_ID` constant + `barbers.stripe_charges_enabled` read + `walkin_fee_config.apply_to_owner_cuts` read + `grace_period_ends_at` read | Fee routing decision depends on 4 inputs. Any stale read = wrong fee. |
| `settings/walkin-fee/route.ts` | (a) Zod schema MUST reject business-nonsense values (R2 #13 — owner_percentage in [0,100] is type-valid but business-invalid; require e.g. 10 ≤ p ≤ 50 OR explicit confirmation flag) + (b) every UPDATE to `walkin_fee_config` MUST append a row to `commission_waiver_audit` or a dedicated config-change log (R2 #14 — current code overwrites `updated_by`/`updated_at` with no history) + (c) all 4 completion handlers read fresh (no cache) | Config change must propagate immediately. Unbounded Zod = accidental nuke. Overwriting columns = no forensic history of who set the rate to what, when. |
| `cron/grace-period-notifications/route.ts` | `barbers.grace_period_ends_at` + `owner_alerts` writes + `commission_acknowledged_at` check | Cron failures are silent. |
| Any write to `cash_fee_ledger` | Unique partial indexes (`uniq_cash_fee_ledger_owed_booking` + `uniq_cash_fee_ledger_owed_entry`) still present + CHECK constraint `waived_requires_waiver` on parent tables | The indexes prevent the Juju Jackson duplicate bug (2026-04-24 Phase 3). Check they still exist. |
| `update_daily_summary()` RPC | UNIQUE key on `daily_summaries` (MUST be `(date, barber_id, location_id)` — NOT `(date, barber_id)`) + `fee_settlement_status` filter in WHERE | Gap G (multi-location drift): without location_id in the key, Gustavo's Wilmington day shows Newark totals. |
| `queue/entry/[id]/route.ts` PATCH path | (a) `validations/schemas.ts` MUST accept `loyalty_reward_applied` in the PATCH Zod schema + (b) fee calculation MUST reference `loyalty_reward_applied` and discount the fee base accordingly + (c) parity with `/api/queue/complete` RPC path which DOES handle loyalty correctly (R3 #16) | PATCH silently drops `loyalty_reward_applied`. Customer pays discounted price, barber still billed 30% on full. Only RPC path is correct — PATCH path is broken. |
| `barbers` row with active txns | MUST check `commission_acknowledged_at IS NOT NULL` before accruing any fee. `determinePaymentRouting()` + all 4 completion handlers MUST gate fee accrual on acknowledgement. If not acknowledged → `fee_settlement_status='exempt_pending_ack'` or block completion (R3 #17) | 5 barbers have txns but never acknowledged. Stanley's grace expired 14 days ago, $351 accrued on an un-signed commission agreement. Legal/collection risk. |
| `commission/summary/route.ts` display of Connect status | MUST validate `barbers.stripe_account_id` matches `/^acct_[A-Za-z0-9_]{16,}$/` before reporting "Connect enabled" to owner (R3 #18) | 3 barbers show as Connect on dashboard but `determinePaymentRouting()` rejects their malformed IDs. Owner sees a lie. |
| Any coupling rule in this table | MUST have ≥1 matching test spec under `tests/qa/commission-*.spec.ts` OR `tests/contract*/*.spec.ts`. If no test exists, flag as HIGH in Gap Self-Report (R3 #19) | Current test suite covers none of the 27 bugs found across 3 audit rounds. No regression net = every fix can be silently reverted by a future PR. |
| `queue/complete/route.ts` RPC path | **The order of operations is broken by design (R4 #20 — CRITICAL LIVE).** RPC sets `status='completed'` on queue_entries → `create_service_transaction_from_queue` trigger fires → inserts `service_transactions` with $0 fees → `tr_update_daily_summary_from_txn` watches `payment_status` only and aggregates the $0 immediately → route THEN updates `owner_fee_amount`/`barber_net_amount` on service_transactions → trigger does NOT re-fire on fee-column change → `daily_summaries` permanently locked to pre-fee snapshot. **Audit MUST verify:** (a) `tr_update_daily_summary_from_txn` WHEN clause includes `OLD.owner_fee_amount IS DISTINCT FROM NEW.owner_fee_amount`, OR (b) route explicitly calls `update_daily_summary()` AFTER the fee UPDATE. Current prod: neither happens. 4 live drift rows this week. | daily_summaries on the owner home dashboard systematically UNDER-counts commission by ~30% on every queue/complete completion. Different bug from multi-location drift (H2) — same location, same barber. |
| `barber/acknowledge-commission/route.ts` | (a) SELECT `commission_acknowledged_at` → if NOT NULL, reject with 409 Conflict or no-op (idempotency gate) + (b) `grace_period_ends_at` MUST be computed from `FIRST` acknowledgement timestamp, not every call + (c) owner_alert on repeat-acknowledge (potential grace-period-extension abuse) + (d) append to `commission_waiver_audit` or dedicated log on every call, success or reject (R4 #21) | Barber re-clicks "I acknowledge" at day 60 → grace resets to day 90 → owner loses 30 days of commission revenue. No alert, no log, no forensic trail. |
| Earnings threshold alert formula in `queue/complete/route.ts:367-377` and `bookings/[id]/route.ts:540-550` | The threshold-trigger SUM **MUST match** the payout formula in `/api/commission/payout` and `/api/commission/summary` exactly: `SUM(service_amount - owner_fee_amount + COALESCE(tip_amount, 0))`. Current code uses `SUM(barber_net_amount)` which equals `(svc - fee)` and **excludes tips**. (R5 #24) | Latent today because tips=0% in prod. Live the moment any barber starts collecting tips on card/link → threshold alert fires at the wrong owed amount → owner over/under-pays. Audit MUST grep both files and confirm tip is included in the SUM. |
| Supabase Realtime publication membership for commission tables | Run `SELECT tablename FROM pg_publication_tables WHERE pubname='supabase_realtime'`. **Required state:** `daily_summaries` either OUT (so dashboard doesn't auto-render buggy pre-fee totals — see R4 #20) OR all 4 commission tables IN together (`daily_summaries`, `service_transactions`, `cash_fee_ledger`, `barber_payouts`) with the dashboard subscribing to all 4. **Current prod state (R5 #25):** only `daily_summaries` is in the publication → owner sees stale Settle Cash / Record Payout writes (must F5) AND buggy daily_summary totals propagate instantly with no drift-catch window. Audit MUST report which of the 4 are in/out and flag the asymmetry. | Asymmetric realtime = owner sees the wrong numbers faster than they see the right ones. Either ship all 4 in publication + subscribe to all 4 in `useDashboardData`/`useBarberClock` hooks, OR pull `daily_summaries` out until R4 #20 is fixed. |

**A PASS on the left side without evidence of auditing the right side = COUPLING VIOLATION.** Report it in the Gap Self-Report.

---

## Cron Surface Must Be Enumerated — WITH EXPECTED LIST

Any commission audit MUST run `ls src/app/api/cron/` and `cat vercel.json` and report:
- Every cron route that touches any commission table
- Every cron's schedule and last-run log (check `owner_alerts` for failures)
- **The EXPECTED commission crons (from R2 #12) — if any of these are MISSING from `vercel.json`, flag as HIGH:**
  - **Nightly daily_summaries drift detector** — compares `SUM(service_transactions)` grouped by (date, barber, location) vs `daily_summaries` row; alerts on non-zero delta
  - **Stale payment-link cleanup** — marks `service_transactions` rows with `payment_method='link'` and `payment_status='pending'` older than N hours as expired
  - **Cash backlog escalation** — alerts owner when a barber's `cash_fee_ledger.status='owed'` sum exceeds `earnings_alert_threshold`
  - **Nightly reconciliation** — `SUM(service_transactions gross)` == `SUM(daily_summaries totals)` == `SUM(barber_payouts) + SUM(still-owed)` — any mismatch = alert
  - **Grace-period notifications** (already exists — `/api/cron/grace-period-notifications`)

Absent crons get flagged as gaps in the report, not silently passed.

## Write-Path Derivation Rule — DO THIS BEFORE PASSING ANY ROUTE

Before marking ANY route PASS, the audit MUST:

1. **List every table the route writes to** — grep `\.from\('<table>'\)\s*\.(update|insert|delete|upsert)` inside the route file.
2. **For each destination table, grep ALL OTHER writers across `src/`** — `grep -rn "from('<table>')" src/app/api/ src/lib/`.
3. **Compare the write-column sets.** If this route writes columns `{A, B, C}` but another writer to the same table writes `{A, B, C, D, E}`, the audit MUST either confirm the other columns are intentional-to-skip OR flag the route as UNDER-WRITING.
4. **Cross-reference with Cross-Surface Coupling Rules table above.** If the derived write-set reveals a downstream surface NOT in the coupling table, the skill has a gap — report it in the Gap Self-Report so we can add the coupling next round.

Example from R2 #8: `void/route.ts` writes to `cash_fee_ledger` and `service_transactions` only. Other void-adjacent writers (queue/complete, bookings/[id]) also write `daily_summaries`. The derivation rule would catch `void`'s missing `update_daily_summary` call even if the coupling table omits it.

This is the defense against Round N+1 finding Round N's blind spots.

---

## Trigger Correctness Audit — MANDATORY per round

A common blind spot: a trigger exists, fires, and appears correct — but its WHEN clause / UPDATE OF list misses a column the route updates LATER. This is the class of bug behind R4 #20. Every audit MUST:

1. List every trigger on `queue_entries`, `bookings`, `service_transactions` with its full definition (pg_get_triggerdef).
2. For each trigger, list the columns it WATCHES (UPDATE OF list or WHEN clause).
3. For each route that writes to the same table, list the columns it WRITES.
4. Compare: if a route updates a column the trigger does NOT watch, AND that column should affect downstream state → FLAG as HIGH.

Specific SQL to run every audit:
```sql
SELECT event_object_table, trigger_name, action_timing,
       event_manipulation, action_condition, action_statement
FROM information_schema.triggers
WHERE event_object_schema = 'public'
  AND event_object_table IN ('queue_entries','bookings','service_transactions')
ORDER BY event_object_table, trigger_name;
```

Cross-reference against every route that PATCH/UPDATE-writes fee columns. If route updates `owner_fee_amount` but no trigger re-fires on that column, **daily_summaries is silently stale**.

---

## R4 Forced Surfaces — MUST sweep these EVERY round

These surfaces have not been deeply audited in rounds 1-4. Skipping them is explicitly forbidden now:

1. **All 7 commission test specs** — `tests/qa/commission-*.spec.ts` + `tests/contract*/*.spec.ts`. Open each, list what it covers, cross-reference against the 31-bug tally. Every spec that doesn't cover a known bug = a spec that won't catch that bug's regression.
2. **Analytics readers of commission data** — `src/app/(dashboard)/dashboard/analytics/locations/page.tsx`, `dashboard/reports/page.tsx`, `src/app/api/reports/route.ts`, `src/app/api/analytics/**`. These consume `daily_summaries`. If `daily_summaries` drifts (R4 #20), these amplify the lie. Must be audited for: source-of-truth (raw txns vs daily_summaries), drift detection, cache invalidation.
3. **Barber-facing commission UI** — `src/app/(dashboard)/barber/page.tsx`, `barber/reports/page.tsx`, `dashboard/my-chair/reports/page.tsx`, any `MobileBarberHomeView` component. Barbers see balance numbers here. If the read path uses `daily_summaries` and it's stale, barbers see the wrong "you owe" or "shop owes you" amount. MUST verify balance calculation matches server endpoint formula exactly.
4. **Barber analytics endpoints** — `/api/barber/analytics/**`, `/api/barber/cash-fees`, `/api/barber/payouts/**`. Same source-of-truth check.
5. **Reschedule-with-completion edge case** — `bookings/[id]/reschedule/route.ts` interaction with completion. If a booking is rescheduled after completion, does fee recompute? Does cash_fee_ledger update? Audit the code path explicitly.
6. **Realtime publication of commission tables** — `SELECT schemaname, tablename FROM pg_publication_tables WHERE pubname='supabase_realtime'`. If `cash_fee_ledger`, `service_transactions`, `daily_summaries`, or `barber_payouts` are in the publication, browser clients may cache stale rows. Audit subscribing hooks for stale-read handling.
7. **Handoff to bulletproof-payments skill** — webhook idempotency, tip metadata, refund handler edge cases — properly belong to `bulletproof-payments`. Commission audit MUST call out which findings require that skill's deeper look.

If any of these 7 is NOT-RUN in the current audit, the report header MUST say "PARTIAL COMMISSION AUDIT — R4 Forced Surfaces incomplete."

---

## Multi-Pass Audit Protocol — DO NOT STOP AFTER ONE PASS

One-pass audits have consistently missed bugs that a second pass catches. Rounds 1→2→3 of the 2026-04-24 commission audit found 15, +8, +4 bugs respectively. The user shouldn't have to keep asking "did you miss X?" — the skill must do that to itself.

**At the end of what would normally be the audit output, BEFORE handing back to the user, do this:**

### Pass 1 — the normal audit
Produce the full Coverage Report + Gap Self-Report.

### Pass 2 — self-critique
Read your own Gap Self-Report. For every row marked "Unknown severity" or "surface not audited," pick the top 3 highest-impact ones and run a focused audit on each. Specifically:
1. **Every route listed as NOT-RUN** → open it with Read, run the Write-Path Derivation Rule on it, add findings to the report.
2. **Every "external verification needed" item** → if it's something the skill CAN verify (DB state, code grep), do it now.
3. **Every coupling row marked NO** → actually audit the coupled surface now.

### Pass 3 — adversarial question
Ask yourself: "If a malicious or careless developer wanted to break commission silently, which surface I already passed would they target?" Go back and audit THAT surface with extra scrutiny. Common answers:
- Zod schemas (type-valid but business-invalid values)
- RPC bodies (trigger firing on the wrong column change)
- Migration ordering (rollback mid-apply)
- Middleware bypasses (routes that skip `getUser()`)
- Cron routes with no idempotency

### Pass 4 — stop condition
Only stop when the Gap Self-Report has zero "Unknown severity" rows AND zero NOT-RUN rows AND zero NO in the Coupling Checks table. If you can't get to zero in one session, report what remains and explicitly tell the user "Round N+1 is recommended on these N items."

**This is slower than a one-pass audit. That's the point.** One-pass is what the user has been getting. Multi-pass is what exhaustive actually means.

---

## Honest Limit Acknowledgement

Even with Multi-Pass + Coupling Rules + Derivation Rule + Surface Inventory, this skill is a documentation-based audit tool. Its ceiling is "what the model can notice by reading code and running SQL." It cannot catch:
- Bugs that exist only in live execution (race conditions, webhook retry edge cases, timezone drift at 11:59 PM)
- Bugs introduced by PRs merged AFTER the audit runs
- Bugs in logic the model has never seen a similar pattern of

The only thing that catches those is **executable regression tests** — Playwright specs that run the actual flow and SQL property tests that assert invariants after each test run. Every coupling rule in this table should have a matching test spec. If `tests/qa/commission-*.spec.ts` doesn't cover a rule, R3 #19 fires.

---

## Mode: audit

### Step 0 — Universal Audit Preamble (MANDATORY — run first, always)

Run the 5 discovery queries from `~/.claude/skills/_shared/audit-rigor.md` section "Universal Audit Preamble", filled in with the commission domain values:

```sql
-- 1. Enumerate commission domain tables
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN (
    'walkin_fee_config','cash_fee_ledger','service_transactions',
    'barber_payouts','commission_waiver_audit','daily_summaries',
    'queue_entries','bookings','barbers'
  )
ORDER BY table_name;
-- Expected: 9 rows. Missing = inventory drift; STOP and ask user.

-- 2. RLS policies on every commission table
SELECT tablename, policyname, cmd, roles
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN (
    'walkin_fee_config','cash_fee_ledger','service_transactions',
    'barber_payouts','commission_waiver_audit','daily_summaries'
  )
ORDER BY tablename, policyname;
-- Expected: at least 8 rows (see SURFACE_INVENTORY.md section 9).
-- Any missing policy or extra-permissive policy = RLS gap; FLAG in coverage report.

-- 3. Triggers on commission-touched tables
SELECT event_object_table, trigger_name, action_timing, event_manipulation
FROM information_schema.triggers
WHERE event_object_schema = 'public'
  AND event_object_table IN ('queue_entries','bookings','service_transactions')
ORDER BY event_object_table, trigger_name;
-- Expected: create_service_transaction_from_queue, create_service_transaction_from_booking, tr_referral_conversion.

-- 4. RPC functions
SELECT routine_name, routine_definition IS NOT NULL AS has_body
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name IN (
    'update_daily_summary',
    'create_service_transaction_from_queue',
    'create_service_transaction_from_booking'
  );
-- Expected: 3 rows, all has_body=true.

-- 5. Migration history
SELECT name, executed_at FROM supabase_migrations.schema_migrations
WHERE name ILIKE '%041%' OR name ILIKE '%commission%' OR name ILIKE '%waiver%'
   OR name ILIKE '%payout%' OR name ILIKE '%walkin_fee%'
ORDER BY executed_at;
-- Expected: at least 8 rows (see SURFACE_INVENTORY.md section 10).
```

Attach all 5 result sets to the report under "Universal Preamble". Any drift = stop before domain checks.

### Step 1 — Production config snapshot (always run second)

```sql
SELECT id, flat_rate, owner_percentage, is_active, apply_to_owner_cuts,
       earnings_alert_threshold, updated_at
FROM walkin_fee_config LIMIT 1;
```

Expected (per MEMORY.md, 2026-03-23):
- `owner_percentage`: 30
- `flat_rate`: 40 (unused in current fee calc; flag if formula changed to use it)
- `earnings_alert_threshold`: 200.00
- `apply_to_owner_cuts`: false
- `is_active`: true

If any value differs, report to user and ASK before proceeding — someone may have changed config, or this is a drift signal.

### Code-level invariants

1. **Fee calculation centralized**
   - File: `src/lib/stripe/connect-helpers.ts` — `determinePaymentRouting()` is the SINGLE source of truth.
   - Grep: `grep -rn "owner_percentage\|owner_fee_amount[[:space:]]*=\|barber_net_amount[[:space:]]*=" src/app/ src/lib/`
   - Every write to fee columns should go through `determinePaymentRouting()` or the DB trigger. Flag any inline calculation.

2. **Owner barber exemption hardcoded**
   - Grep: `grep -rn "OWNER_BARBER_ID\|b0010000-0000-0000-0000-000000000001" src/lib/stripe/`
   - The owner barber (`b0010000…`) should be exempt from walk-in fees when `apply_to_owner_cuts = false`.

3. **Cash ledger populated by app-code INSERT (NOT a trigger)**
   - The planning doc / migration 041 comments imply a trigger, but the production DB has only `tr_referral_conversion` on `service_transactions`. Cash ledger rows are inserted explicitly from app code in 4 routes (see Ledger A list above).
   - Grep to verify all four insert paths exist: `grep -rn "cash_fee_ledger.*insert\|from('cash_fee_ledger').insert" src/app/api/`
   - Each insert is wrapped in try/catch that writes `owner_alerts` on failure. A single silent failure = a missing ledger row. Query #1 in audit-queries.sql finds these.

3b. **Connect routing actually fires** [CRITICAL — commonly broken]
   - `determinePaymentRouting()` is called ONLY by `src/app/api/payments/checkout/route.ts` and `src/app/api/payments/send-link/route.ts`. The 4 completion handlers (queue/entry/[id], queue/complete, bookings/[id], bookings/quick-complete) do NOT call it — they hardcode `fee_settlement_status = payment_method === 'cash' ? 'cash_owed' : 'pending'`.
   - **Expected outcome:** a Connect-enabled barber's card/link txn should end with `fee_settlement_status = 'auto_split'`.
   - **Actual outcome (current prod as of 2026-04-20):** ZERO `auto_split` rows have ever existed. Every Connect barber's earnings accrue as Ledger B instead of Ledger B'.
   - Grep: `grep -rn "determinePaymentRouting\|auto_split" src/app/api/` — should appear in at least the 4 completion handlers. If it doesn't, the Connect flow is bypassed.

4. **Stripe webhook idempotency**
   - File: `src/app/api/webhooks/stripe/route.ts`
   - Must check `stripe_webhook_events` table before processing (dedup by `stripe_event_id`).

5. **Waive endpoint atomicity**
   - File: `src/app/api/commission/waive/route.ts`
   - When waiving, must update all three: the source row (queue_entries or bookings), `service_transactions`, AND `cash_fee_ledger`.

6. **Payout validation**
   - File: `src/app/api/commission/payout/route.ts`
   - Must reject `amount <= 0` and reject amounts exceeding current owed balance (with small floating-point tolerance).

7. **Tips reach `service_transactions.tip_amount`** [HIGH]
   - UI: `PaymentCollectionModal` captures tip via quick buttons + custom. The value must survive:
     - PATCH body to `/api/queue/entry/[id]` and `/api/bookings/[id]` (both accept `tip_amount` in Zod schema)
     - Stripe checkout `session.metadata.tip_amount` (set in `/api/payments/checkout` + `/api/payments/send-link`)
     - Webhook persistence in `/api/webhooks/stripe/route.ts` (reads metadata → writes `tip_amount`)
   - **Audit signal:** query 17 in `audit-queries.sql` flags if tip_amount=0 across all completed txns in last 30d. If so, one of the links above is broken. As of 2026-04-20 production: 0/249 service_transactions have tip_amount>0 — broken.

8. **Valid fee_settlement_status enum**
   - Permitted values: `'pending' | 'cash_owed' | 'auto_split' | 'settled' | 'waived'`. The `cash_owed` value is explicitly set by all 4 completion handlers for cash payments (distinct from `pending` which is for card/link awaiting settlement).

### Data-level invariants

Run queries in `references/audit-queries.sql`. SELECT-only. Expected 0 rows for violations.

### Output template — MANDATORY Coverage Report

Every commission audit MUST produce this full block. A report without the Coverage Report section is INCOMPLETE and will be rejected.

```markdown
## Commission Audit Report — [YYYY-MM-DD]

### Universal Preamble
- Tables enumerated: 9/9 PASS | X/9 FAIL (list missing)
- RLS policies found: X (expected ≥8) — list any gaps
- Triggers found: X/3
- RPCs found: X/3
- Migrations confirmed: X/8

### Production config
- owner_percentage: [X]% (expected: 30%)
- flat_rate: [X] (expected: 40)
- earnings_alert_threshold: [X] (expected: 200)
- apply_to_owner_cuts: [X] (expected: false)
- is_active: [X] (expected: true)

### Findings
[Ranked critical/high/medium/low with file:line anchors and $ at risk]

---

## Coverage Report (MANDATORY)

### Pillar 1 — Codebase (28 files from SURFACE_INVENTORY.md sections 1-5) — PROOF-OF-READ REQUIRED
| # | File | Verdict | Evidence (file:line — what was checked) |
|---|---|---|---|
| 1 | src/app/api/commission/summary/route.ts | PASS/FAIL/NOT-RUN | e.g. "summary/route.ts:131 — neq('auto_split') filter active" |
| 2 | src/app/api/commission/barber-summary/route.ts | | |
| ... | [all 28] | | |

Files audited with proof-of-read: N / 28 (target: 28/28). Any PASS without evidence = treated as NOT-RUN.

### Pillar 2 — Database (9 tables from SURFACE_INVENTORY.md section 6)
| Table | Row count | Status dist | NULL violations | Verdict |
|---|---|---|---|---|
| walkin_fee_config | | | | |
| cash_fee_ledger | | owed:X, settled:X, waived:X | | |
| service_transactions | | | | |
| barber_payouts | | | | |
| commission_waiver_audit | | | | |
| daily_summaries | | | | |
| queue_entries (fee cols) | | | | |
| bookings (fee cols) | | | | |
| barbers (commission cols) | | | | |

Tables audited: N / 9

### Pillar 3 — Queries (24 queries from references/audit-queries.sql)
| # | Query | Verdict | Rows |
|---|---|---|---|
| 1 | missing_ledger | | |
| ... | [all 24] | | |

Queries run: N / 24. Skipped: [empty — or list with reason].

### Pillar 4 — RLS (6 commission tables)
| Table | Policies found | Expected | Verdict |
|---|---|---|---|
| walkin_fee_config | | 2 | |
| cash_fee_ledger | | 2 | |
| service_transactions | | ≥2 | |
| barber_payouts | | ≥2 | |
| commission_waiver_audit | | 1 | |
| daily_summaries | | ≥2 | |

RLS tables audited: N / 6

### Pillar 5 — Integrations (SURFACE_INVENTORY.md sections 8, 11, 12)
| Integration | Verdict | Note |
|---|---|---|
| Trigger: create_service_transaction_from_queue | | |
| Trigger: create_service_transaction_from_booking | | |
| Trigger: tr_referral_conversion | | |
| Stripe webhook idempotency | | |
| Stripe Connect routing | | |
| Cron: grace-period-notifications | | |
| owner_alerts writes | | |

Integrations audited: N / 7

### Coupling Checks (from Cross-Surface Coupling Rules table)
| Coupling | Both sides audited? | Note |
|---|---|---|
| Refund → {daily_summaries reversal, barber_payouts reversal, cash_fee_ledger reversal} | YES/NO | |
| Waive → {parent update, service_transactions update, cash_fee_ledger update, waiver_audit} | YES/NO | |
| Void → {cash_fee_ledger, service_transactions, parent row} | YES/NO | |
| Reassign-completed → {old ledger, new ledger, Connect routing} | YES/NO | |
| Queue completion → {ledger INSERT, ST creation, staff_status, daily_summaries} | YES/NO | |
| Booking completion → {same as queue + first-booking + grace-period} | YES/NO | |
| quick-complete → {first-booking parity with bookings/[id]} | YES/NO | |
| checkout + send-link → {determinePaymentRouting + ST insert + tip metadata} | YES/NO | |
| determinePaymentRouting → {OWNER_BARBER_ID, stripe_charges_enabled, apply_to_owner_cuts, grace_period} | YES/NO | |
| walkin-fee settings → {cache vs live on 4 completion handlers} | YES/NO | |
| grace-period cron → {barbers.grace_period_ends_at, owner_alerts, ack check} | YES/NO | |
| cash_fee_ledger writes → {unique partial indexes, waiver CHECK} | YES/NO | |
| update_daily_summary → {UNIQUE key is (date, barber_id, location_id)} | YES/NO | |

Coupling violations: N  **(must be 0 — any NO row is a violation)**

---

## Gap Self-Report (MANDATORY)

| # | Gap | Why it matters | Severity |
|---|---|---|---|
| G1 | [e.g. Did not open src/app/api/queue/entry/[id]/void/route.ts] | Touches cash_fee_ledger — could orphan rows | Unknown |

Surfaces in SURFACE_INVENTORY.md NOT audited this run: <comma-separated item numbers>.
Questions requiring external verification: <Stripe Dashboard checks, etc.>

If zero gaps: write "No gaps identified. All 63 surfaces audited with proof-of-read + all coupling checks passed."

---

## Totals

- Surfaces audited with proof-of-read: X / 63 (XX%)
- FAILs: N
- NOT-RUNs: N
- Coupling violations: N (must be 0)

**If NOT-RUNs > 0 OR coupling violations > 0, the report header MUST say "PARTIAL COMMISSION AUDIT — N surfaces unaudited, M coupling violations" instead of "Commission Audit Report".**
```

Stop only after every row above is filled. "Stop on first fail" is NOT the protocol — complete the full coverage sweep, then report.

---

## Mode: diagnose

1. Ask for symptom. Examples:
   - "Commission dashboard shows $X but sum of cash_fee_ledger is $Y"
   - "Payout was recorded but barber says they didn't get it"
   - "New barber's grace period shows expired when it shouldn't be"
   - "Stripe Connect barber still shows 'Card Earnings Owed'"
   - "A transaction was waived but still appears as owed"

2. Match against `references/incidents.md`.

3. Three-file rule. Two-strike rule. **Under NO circumstances** write to production DB to "test" a fix. Verify by reading code and running SELECTs only.

---

## Mode: scale-check

Add a barber or location — what needs to hold?

1. **Fee config applies to all locations uniformly**
   - `walkin_fee_config` is a single-row table. One owner_percentage across all locations. Verify no location-specific overrides exist.
   - If adding a multi-owner or franchise model is ever considered, this table needs a `location_id` column — flag as future schema change, do not implement.

2. **Owner barber exemption scoped correctly**
   - `OWNER_BARBER_ID` is hardcoded to `b0010000-0000-0000-0000-000000000001`. The dev owner `a274e1cf…` is a separate entity and WILL have fees applied unless explicitly exempted.
   - Verify: is the dev-owner expected to be exempt? If yes, the hardcode needs to be a list or a DB column.

3. **Grace period policy**
   - Column: `barbers.grace_period_ends_at`.
   - New barbers typically get 30 days to import clients before fees apply to booking clients.
   - Verify `determinePaymentRouting()` reads this column and applies the logic.

4. **Stripe Connect readiness per barber**
   - Adding a new barber without Connect = card earnings owed accrue to barber_payouts.
   - Flag if alert threshold ($200) would be hit quickly.

5. **Earnings alert firing** (non-Connect barbers — shop owes them)

   Must mirror the exact formula used in `/api/commission/summary` and `/api/commission/barber-summary`: include tips, require `payment_status='paid'`, net out payouts.
```sql
WITH earned AS (
  SELECT st.barber_id,
         SUM(st.service_amount - st.owner_fee_amount + COALESCE(st.tip_amount, 0)) AS gross
  FROM service_transactions st
  WHERE st.payment_method IN ('card', 'link')
    AND st.fee_settlement_status IS DISTINCT FROM 'auto_split'
    AND st.payment_status = 'paid'
  GROUP BY st.barber_id
),
paid AS (
  SELECT barber_id, SUM(amount) AS total_paid
  FROM barber_payouts GROUP BY barber_id
)
SELECT b.id, b.slug,
       COALESCE(e.gross, 0) - COALESCE(p.total_paid, 0) AS owed_to_barber
FROM barbers b
LEFT JOIN earned e ON e.barber_id = b.id
LEFT JOIN paid p   ON p.barber_id = b.id
WHERE b.is_active = true
  AND COALESCE(b.stripe_charges_enabled, false) = false
  AND b.id <> 'b0010000-0000-0000-0000-000000000001'  -- owner force-zeroed in endpoint
  AND COALESCE(e.gross, 0) - COALESCE(p.total_paid, 0) >= 200;
```
   If any barber exceeds threshold, owner should have a pending alert.

6. **Daily summary consistency at scale**
   - More barbers × more locations × more services = more daily_summaries rows. Verify upsert logic doesn't have race conditions (check migration 011 + any later hardening).

## Mode: fix

The only mode that writes code. Closes the loop between "audit/diagnose found X" and "X is fixed + verified." Does NOT commit, does NOT push, does NOT touch the production DB. See `references/fix-patterns.md` for the canonical patterns.

### Activation is EXPLICIT

Fix mode fires ONLY when the user types one of:
- `apply pattern N` — N is a pattern number from `references/fix-patterns.md`
- `fix <symptom-phrase>` — natural-language form; the skill maps to a pattern and CONFIRMS before doing anything
- `enter fix mode` followed by a scope

Any other phrasing → audit/diagnose instead. An audit finding NEVER auto-triggers a fix.

### Workflow (strict — every step, no shortcuts)

1. **Scope declaration.** Restate in 1–2 sentences which pattern (number + name), which file(s) will change, any mirror-page impact.
2. **Preflight.** Read the target file. Confirm the "before" block from `fix-patterns.md → Pattern N` still matches current code — imports, function signatures, surrounding context, NOT line numbers (which drift). If drift → STOP and report what differs. Do NOT apply a stale pattern.
3. **Scope audit.** Confirm the fix touches ONLY files named in the pattern's Before/After blocks. If a fix would require touching an unrelated system → STOP and ask for approval before expanding.
4. **Diff proposal.** Show the exact `old_string` / `new_string` the skill will pass to `Edit`. Wait for the user to type `yes` / `apply` / `proceed`. No implicit approval.
5. **Apply.** Single `Edit` call. ONE pattern per fix-mode invocation. Never bundled.
6. **Post-fix verification.** `npx tsc --noEmit` passes. Re-run the pattern's post-fix grep and/or SQL check — must pass. For UI patterns, explicitly tell the user "you must test this in the browser before shipping — I can't verify UI."
7. **Mirror check.** If the fix touches any page in the Cross-Dashboard Code Mirroring map (`.claude/rules/context-awareness.md`), invoke the `mirror-check` skill before handoff.
8. **Handoff to `bulletproof-ship`.** Fix mode DOES NOT commit, stage, or push. Propose a branch name (`fix/<domain>-<pattern-slug>`) and a commit message in MT's conventional format, then tell the user to invoke `bulletproof-ship`.

### Integration with other skills

| Skill | Role |
|---|---|
| `bulletproof-ship` | Final step. Commit + push + deploy safety. Mandatory. |
| `mirror-check` | Cross-dashboard enforcement for any dashboard-touching fix. |
| `safe-query` | If a pattern requires DB writes (rare), route through safe-query. |

---

## Downstream Consumers & Propagation

When a service completes or a fee is waived / settled / paid out, every commission surface must reflect it immediately — owner dashboard, barber balance card, reports.

### Consumers (every surface that reads commission data)

| Consumer | File / URL | What it reads |
|---|---|---|
| Owner commission dashboard | `src/app/(dashboard)/dashboard/analytics/commissions/page.tsx` | all barbers' owed / paid / waived totals |
| Barber home balance card | `src/app/(dashboard)/barber/page.tsx` | this barber's outstanding fees, card earnings owed, grace status |
| Barber reports | `src/app/(dashboard)/barber/reports/page.tsx` | payout history, today's card earnings |
| Daily close section | commission dashboard | same-day cash settlement UI |
| Owner alerts | `owner_alerts` table (`type='payout_due'`) when earnings threshold crossed |
| Stripe Connect router | `src/lib/stripe/connect-helpers.ts` — `determinePaymentRouting()` reads live config per transaction |

### Propagation invariants

1. **Trigger fires on every `service_transactions` insert** (auto-populates `cash_fee_ledger` for cash payments).
   ```sql
   SELECT tgname FROM pg_trigger
   WHERE tgrelid = 'service_transactions'::regclass AND NOT tgisinternal;
   ```
2. **`daily_summaries` upsert stays in sync** — the sum of `service_transactions.owner_fee_amount` per (day, barber, location) matches `daily_summaries.total_owner_fees`. Drift = missing RPC call somewhere.
3. **Realtime publication includes `daily_summaries`** (owner dashboard subscribes for live earnings updates).
4. **Waive is atomic across THREE tables** — source row (queue_entries/bookings) + service_transactions + cash_fee_ledger update together.
5. **Payout records are write-once** — `barber_payouts` rows don't get updated. To reverse, create a negative-amount row.
6. **Stripe webhook idempotency** — `stripe_webhook_events.stripe_event_id` checked before processing (migration 036).

### Diagnose: "Barber dashboard shows commission owed, but owner dashboard doesn't see it"

1. DB: does `cash_fee_ledger` have rows for this barber with `status='owed'`?
2. Trigger fired? Count `service_transactions` cash txns vs `cash_fee_ledger` rows (see audit query #1).
3. Owner endpoint filter: `src/app/api/commission/summary/route.ts` — what's the aggregation? Is there a location filter accidentally excluding rows?
4. Realtime: does the owner page subscribe to `daily_summaries` OR re-fetch on focus?
5. If the barber-side and owner-side numbers truly differ: one of the three waive-tables didn't update. Query all three for the suspect IDs.

**REMINDER:** Commission diagnoses NEVER involve production writes. Even to "test a waive." See hard rules below.

---

## HARD RULES — stronger than usual because revenue

- **NEVER write to production DB.** Not for a "test payout," not for a "one-row insert." Zero writes. Ever. Without explicit, scope-bounded, written approval from the user.
- **If a fix requires writes, STATE THE EXACT ROWS** and the exact tables, then wait for approval. See debugging-protocol.md Section 9.
- **NEVER bypass the fee trigger** by inserting directly into `cash_fee_ledger` from app code. The trigger is the source of truth for cash ledger creation.
- **NEVER alter `walkin_fee_config` without approval.** This table's row count is 1 — any change affects every barber immediately.
- **NEVER test a commission fix on the owner's real account.** Use test accounts if writes ever happen, and ONLY with approval.
- **Payout waive is irreversible** in barber perception. Don't run /api/commission/waive in diagnose mode without explicit approval.
- ALWAYS use `mcp__supabase-mt__`.
- Branch workflow. Stay in scope.
