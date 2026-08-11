---
name: bulletproof-analytics-reports
description: Audit, diagnose, or scale-check the MT Barbershop analytics and reports surface (/dashboard home hero metrics + live activity feed, /api/dashboard/summary, /api/activity-feed, /api/analytics/**, /api/reports, /api/commission/summary, /api/commission/barber-summary, /api/barber/analytics, daily_summaries table + update_daily_summary + get_barber_daily_summary RPCs, DashboardDataContext, BarberClockContext, CSV export via src/lib/utils/csvExport.ts, and the owner↔barber mirror pair of /dashboard/my-chair/{reports,analytics} ↔ /barber/{reports,analytics}). Use when home-page revenue looks wrong, reports drift from the underlying transactions, analytics counts don't match queue or booking data, CSV export is malformed, activity feed misses events, daily_summaries is stale, or before adding a new location or barber that will show up in every aggregate. Read-only SQL via mcp__supabase-mt__execute_sql and codebase greps only. Never writes to the production DB. Never modifies application code without explicit user approval. Complement to bulletproof-commission (fee ledger), bulletproof-queue (queue state), and bulletproof-bookings (booking lifecycle) — this skill audits what the owner SEES on the dashboard, not the underlying business logic.
---

# Bulletproof Analytics & Reports

The dashboard home page, analytics pages, and reports pages are the surfaces the owner looks at every single day to decide whether the business is healthy. If these show wrong numbers — revenue off by $200, cuts off by 3, barber breakdown missing a row — the owner loses trust in the entire system even when the underlying data is correct. This skill audits the aggregation + display layer so the numbers the owner sees match the numbers in the database.

This skill does NOT replace `CLAUDE.md`, `MEMORY.md`, or the `.claude/rules/*.md` files. It READS them, then runs a structured protocol.

This skill does NOT re-audit domain logic already covered elsewhere:

| Concern | Owned By |
|---|---|
| Fee amounts, payout rows, commission routing | `bulletproof-commission` |
| Walk-in queue state machine, rotation fairness data | `bulletproof-queue` |
| Booking rows, availability, reminders, Booksy sync | `bulletproof-bookings` |
| Stripe payment capture, tips, refunds | `bulletproof-payments` |
| SMS log rows | `bulletproof-communications` |
| Cross-dashboard code drift | `mirror-check` |
| UI quality (accessibility, performance, theme) | `analyze-dashboard` / `audit` |
| Flow correctness (page→hook→API→DB) | `verify-flow` |
| Single-record debugging | `trace-transaction` |

This skill audits **the aggregation layer that consumes all of the above** and renders it on the dashboard.

---

## Mandatory Preflight — BEFORE any action

Read in order:
1. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/CLAUDE.md` — "Dashboard Architecture" section, "Database Schema → Payment Reporting (011)" section, "Key RPC Functions" table, "Existing Systems Are Sacred" rule.
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-MT-Barbershop-Systems/memory/MEMORY.md` — Next.js 14 Data Cache rule (CRITICAL), Booksy Timezone Rule, Zero Production Data Contamination rule, Cross-Dashboard Code Mirroring rule.
3. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.claude/rules/debugging-protocol.md` — Sections 4, 5, 7, 8, 9.
4. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.claude/rules/context-awareness.md` — Cross-Dashboard Code Mirroring Rule section, "User Reports Override Queries" HARD RULE.

After reading, confirm "Preflight complete. Running [mode]."

---

## Choose a Mode

- **audit** → read-only health check across every invariant
- **diagnose** → specific symptom to investigate ("revenue doesn't match", "CSV is broken", "activity feed missing an entry")
- **scale-check** → prep before adding a location or barber that will join every aggregate
- **reconcile** → single-day deep reconciliation: the owner says "today's revenue is wrong" — walk the owner through every source that feeds that number
- **fix** — apply canonical patterns from `references/fix-patterns.md`. EXPLICIT activation only; audit findings do NOT auto-trigger this mode.

---

## Surface Inventory (what this skill owns)

### Pages — Owner
| Path | Hydration |
|---|---|
| `/dashboard` (home) | `useActivityFeed()` + `useHomeSummary()` + parallel fetch `/api/commission/summary`, `/api/barber/reconcile` |
| `/dashboard/reports` | fetch `/api/reports?period=daily\|weekly\|monthly` + `exportToCSV()` |
| `/dashboard/analytics` | fetch `/api/analytics?period=7d\|30d\|90d\|1y` |
| `/dashboard/analytics/advanced` | fetch `/api/analytics/advanced` |
| `/dashboard/analytics/campaigns` | fetch `/api/analytics/campaigns` |
| `/dashboard/analytics/commissions` | fetch `/api/commission/summary` |
| `/dashboard/analytics/locations` | fetch `/api/analytics/locations` |
| `/dashboard/analytics/queue` | `useQueueAnalytics()` + inline CSV |
| `/dashboard/analytics/retention` | fetch `/api/analytics/retention` |
| `/dashboard/my-chair/reports` | direct Supabase: `daily_summaries`, `queue_entries` tips/services + CSV |
| `/dashboard/my-chair/analytics` | `useBarberDailySummary()` + `useBarberDailyGoal()` |

### Pages — Barber (mirror of owner's personal pages)
| Owner personal | Barber |
|---|---|
| `/dashboard/my-chair/` | `/barber/` |
| `/dashboard/my-chair/reports` | `/barber/reports` |
| `/dashboard/my-chair/analytics` | `/barber/analytics` |

### APIs
| Route | Role | Purpose |
|---|---|---|
| `/api/dashboard/summary` | owner | Home hero: revenue, queue depth, active barbers, bookings count, 7-day history, per-location |
| `/api/activity-feed` | owner | Unified feed — queue + bookings + payments, default limit 15, max 50 |
| `/api/reports` | owner | Financial: period (daily/weekly/monthly), totals, barber breakdown, location breakdown, payment split |
| `/api/analytics` | owner | Period (7d/30d/90d/1y), summary + daily buckets + barber performance + fairness metrics |
| `/api/analytics/advanced` | owner | Workload, capacity |
| `/api/analytics/campaigns` | owner | Campaign performance |
| `/api/analytics/customer-retention` | owner | Retention cohorts |
| `/api/analytics/locations` | owner | Per-location breakdown |
| `/api/analytics/queue` | owner | Wait times, peak hours, abandonment |
| `/api/analytics/retention` | owner | Loyalty tier analytics |
| `/api/analytics/referrals` | owner | Referral source tracking |
| `/api/analytics/workload` | owner | Workload distribution |
| `/api/analytics/barber-comparison` | owner | Multi-barber comparison |
| `/api/analytics/rotation-fairness` | owner | Rotation equity |
| `/api/commission/summary` | owner | Totals, per-barber, recent transactions (also read by `/dashboard` home) |
| `/api/commission/barber-summary` | barber (own scope) | Personal fees owed, earnings, payout history |
| `/api/barber/analytics` | barber (own scope) | Personal cuts, earnings, service breakdown |

### Shared Plumbing
- **Contexts:** `src/lib/contexts/DashboardDataContext.tsx` (~50 lines, hydrates queue via `useQueue`), `src/lib/contexts/BarberClockContext.tsx` (~68 lines, hydrates clock status via `useBarberClock`)
- **Hooks:** `useActivityFeed` (polled, NOT realtime), `useHomeSummary`, `useBarberDailySummary` (calls `rpc('get_barber_daily_summary')`), `useBarberDailyGoal`, `useQueueAnalytics`
- **CSV:** `src/lib/utils/csvExport.ts` — `exportToCSV(data, columns, filename)`, `downloadCSV()`, `arrayToCSV()`, `CSVFormatters` (currency, percentage, date, datetime)
- **Activity feed component:** `src/components/dashboard/owner/LiveActivityFeed.tsx`

### Database
- **`daily_summaries`** (migration 011) — per (date, barber_id, location_id): `total_cuts`, `total_revenue`, `total_tips`, `cash_amount`, `card_amount`, `link_amount`, `total_owner_fees`, `total_barber_net`
- **`service_transactions`** (migration 024) — immutable INSERT-only audit log; SOURCE OF TRUTH for every completed service
- **RPCs:** `get_barber_daily_summary(barber_id, date)`, `update_daily_summary(date, barber_id, location_id)`, `get_dashboard_home_summary(location_id?)`, `increment_barber_cuts(p_barber_id)`

### Known writer paths for `daily_summaries`
- `src/app/api/bookings/[id]/route.ts:558` — calls `rpc('update_daily_summary', ...)` when a booking status hits `completed`
- Walk-in queue completion path must also trigger this (verify — see invariant D2)

---

## AUDIT RIGOR — read before starting audit mode

This skill enforces the universal Audit Rigor Standard at `~/.claude/skills/_shared/audit-rigor.md` and the domain Surface Inventory at `references/SURFACE_INVENTORY.md`. Read both before you do anything.

**Five Pillars (all mandatory):** codebase, database, queries, RLS, integrations. Missing any pillar = failed audit.

**Proof-of-Read:** every file claimed PASS in the Coverage Report MUST cite a `file.ts:LINE` from that file. No line = NOT-RUN, not PASS. This is enforced by the universal standard.

**Forcing language — copy this into your mental model:**

> Do NOT stop on first pass. You MUST work through EVERY file in SURFACE_INVENTORY.md (70+ surfaces), EVERY query in audit-queries.sql, EVERY RLS policy, EVERY RPC, and every completion-path that writes `daily_summaries`. Stopping after one finding is a half-audit and is explicitly forbidden.
>
> Silence ≠ Pass. Self-declaration ≠ Proof. Every PASS needs a file:line citation.
>
> Obey the Cross-Surface Coupling Rules below. Skipping a coupled surface while passing its partner = coupling violation.
>
> The Coverage Report + Gap Self-Report are MANDATORY. A report missing either is rejected. If NOT-RUN > 0, the header must say "PARTIAL AUDIT".

---

## Cross-Surface Coupling Rules — MUST be followed

When you audit an aggregation surface on the left, you MUST also audit every source and every consumer on the right in the same session. Analytics is a derive-and-display layer — confirming one row of output matches one row of input is useless without confirming the full chain.

| If you audit... | You MUST also audit... | Why |
|---|---|---|
| `/dashboard` home page | `useHomeSummary` + `useActivityFeed` + parallel `/api/commission/summary` + `/api/barber/reconcile` + `get_dashboard_home_summary` RPC + 4-way snapshot consistency (KNOWN TIMING GAP) + `force-dynamic` on every hit route | Home is a 4-fetch mosaic. If any fetch caches yesterday's value, owner sees stale numbers. Missing `force-dynamic` = Vercel Data Cache wins. |
| `/api/dashboard/summary/route.ts` | `service_transactions` (primary read) + `queue_entries` count + `bookings` count (with `deleted_at IS NULL`) + `staff_status` active-barber read + per-location SQL aggregation (NOT JS fan-out) + owner-role check + `cache: 'no-store'` Supabase factory | The home hero pulls from 4 tables. Missing soft-delete filter inflates. JS fan-out over locations doesn't scale past 5 locations. |
| `/api/activity-feed/route.ts` | `queue_entries` + `bookings` + `service_transactions` 3-parallel read + default limit 15 / max 50 + polling cadence in `useActivityFeed` (NO realtime) + includes BOTH `called_time` and `service_completed_at` where applicable + owner-role check | Activity feed polls — not realtime. Missing completion counterpart for a "called" event = orphan tile. Unbounded limit could OOM the client on slow network. |
| `/api/analytics/**` route | `force-dynamic` export + `@/lib/supabase/server` client (no inline) + owner-role check + timezone-aware date bucketing (NO `toISOString().split('T')[0]`, no `getDay()`, no `getHours()` without `timeZone:'America/New_York'`) + `bookings.deleted_at IS NULL` filter where applicable + soft-deleted exclusion + no hardcoded barber/location IDs | Analytics aggregations live or die by: dynamic rendering, correct TZ, soft-delete awareness. One miss = wrong numbers every day. |
| `/api/reports/route.ts` | CSV source SQL matches on-screen SQL (both consume same query) + period arg validation + location/barber filter pass-through + payment_method split + owner-role check + `exportToCSV()` canonical formatter used + force-dynamic + timezone-aware day rollup | CSV divergence from screen = owner's accountant sees different numbers than owner's dashboard. |
| `/api/commission/summary/route.ts` + `/api/commission/barber-summary/route.ts` | Formula parity `(service_amount − owner_fee_amount + tip_amount)` + `payment_status='paid'` filter + exclude `auto_split` + owner force-zero exemption + `barber_payouts` subtraction + barber-scope enforced via `auth.uid()` → `barbers.profile_id` (NOT a spoofable query param) | Commission summaries are what dashboards display. Formula drift between the two endpoints = owner and barber see different "owed" numbers. |
| `/api/barber/analytics/route.ts` | Barber scope from `auth.uid()` (NOT a `?barber_id=` param) + `service_transactions` filter by own barber_id + `feedback` filter by own barber_id + tip totals include cash + card + link + force-dynamic | Any acceptance of `?barber_id=` in the query string = barber can read another barber's numbers. |
| `useBarberDailySummary` (hook) → `get_barber_daily_summary` RPC | RPC exists in production + RPC returns non-null rows for active dates + hook dedupes on `(barber_id, date)` + no admin client in hook | If RPC is missing, barber sees zeros. If hook uses admin client, session pollution. |
| `daily_summaries` row writes | `update_daily_summary(date, barber_id, location_id)` call at BOOKING completion (`bookings/[id]/route.ts:558`) AND queue completion path AND refund path AND tip-adjust path + UNIQUE key is `(date, barber_id, location_id)` (migration 042 fix) + `fee_settlement_status` filter inside RPC | Missing call from ANY completion path = `daily_summaries` drifts. Phase-4 of commission cleanup on 2026-04-24 proved this (22 RPC calls needed to re-sync). |
| `/dashboard/my-chair/reports` ↔ `/barber/reports` | Same Supabase reads + same columns + same CSV filename pattern + same error banner + mirror-check on every change | Cross-Dashboard Code Mirroring HARD RULE. Owner-as-barber reports must match barber reports byte-for-byte in structure. |
| `/dashboard/my-chair/analytics` ↔ `/barber/analytics` | Same `useBarberDailySummary` call + same `useBarberDailyGoal` call + same computed values + same UI feedback + mirror-check on every change | Same rule. Any state variable added to one must exist on the other. |
| CSV export via `csvExport.ts` | Canonical `exportToCSV` + `CSVFormatters` for currency/date + comma/quote/newline escape + download filename timezone-aware + column headers match source query aliases + Inline CSV string-builders flagged (seen in `/dashboard/analytics/queue/page.tsx`) | Inline CSV that concatenates user-supplied barber names without escape = broken CSV when a barber name contains a comma. |
| `useActivityFeed` (polled, NO realtime) | Polling interval doesn't overwhelm API + no-realtime documented as KNOWN GAP + `refetch()` exposed + 15-item default scales to 5 locations with pagination plan | Activity feed can never catch up to a busy Saturday across 4 locations with a 15-item cap. |
| `DashboardDataContext` + `BarberClockContext` | Hydration via `useQueue` / `useBarberClock` + context values never cached past component lifetime + no stale-closure state in consumers + cleanup on unmount | Stale context = every consumer shows stale data without knowing. |
| `daily_summaries` reads on `/dashboard/my-chair/reports` | `daily_summaries` is optimization, `service_transactions` is truth + reconcile query detects drift + repair via RPC re-run, NEVER via hand-edit of `daily_summaries` + RLS owner-all + barber-self read | A stale summary page that doesn't match the underlying transactions is always "fix the write path", never "fix the summary row". |
| Scale-check touches (`scale-check` mode) | Hardcoded barber/location IDs grep (zero hits) + `locations[0]` fallback grep + N+1 loops over barbers grep + per-location API fan-out check + index coverage on `(service_completed_at, barber_id)` + chart dataset size for `1y` period | Pre-cohort/pre-location prep. Silent drift here = every new location shows wrong numbers on day 1. |

**A PASS on the left side without evidence of auditing the right side = COUPLING VIOLATION.** Report it in the Gap Self-Report.

---

## Mode: audit

### Step 0 — Universal Audit Preamble (MANDATORY — run first, always)

Run the 5 discovery queries from `~/.claude/skills/_shared/audit-rigor.md` section "Universal Audit Preamble", filled in with the analytics domain values:

```sql
-- 1. Enumerate analytics-read tables
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN (
    'daily_summaries','service_transactions','queue_entries',
    'bookings','staff_status','feedback','barbers','locations'
  )
ORDER BY table_name;
-- Expected: 8 rows. Missing any = inventory drift; STOP and ask user.

-- 2. RLS policies on every analytics-read table
SELECT tablename, policyname, cmd, roles
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN (
    'daily_summaries','service_transactions','queue_entries',
    'bookings','feedback'
  )
ORDER BY tablename, policyname;
-- Expected: owner-all + barber-self on each (migration 015 enabled RLS on daily_summaries).
-- Missing policy = hidden row leak or hidden row loss; FLAG in coverage report.

-- 3. Triggers feeding analytics tables (NOT owned by this skill but must exist)
SELECT event_object_table, trigger_name, action_timing, event_manipulation
FROM information_schema.triggers
WHERE event_object_schema = 'public'
  AND event_object_table IN ('queue_entries','bookings','service_transactions')
ORDER BY event_object_table, trigger_name;
-- Expected: create_service_transaction_from_queue, create_service_transaction_from_booking,
-- tr_referral_conversion. Missing = analytics drift source; hand off to commission skill.

-- 4. RPC functions in domain
SELECT routine_name, data_type, routine_definition IS NOT NULL AS has_body
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name IN (
    'update_daily_summary','get_barber_daily_summary',
    'get_dashboard_home_summary','increment_barber_cuts'
  );
-- Expected: 4 rows, all has_body=true.

-- 5. Migration history
SELECT name, executed_at FROM supabase_migrations.schema_migrations
WHERE name ILIKE '%payment_reporting%' OR name ILIKE '%home_page_rpc%'
   OR name ILIKE '%daily_summary%' OR name ILIKE '%performance_indexes%'
   OR name ILIKE '%security_audit%' OR name ILIKE '%service_transactions_audit%'
ORDER BY executed_at;
-- Expected: at least 6 rows (011, 015, 024, 027, 028, 042_fix_daily_summary_conflict,
-- 20260421000000_fix_daily_summary_drift).
```

Attach all 5 result sets to the report under "Universal Preamble". Any drift = stop before domain checks.

### Code-level invariants (grep-based)

1. **Every analytics/reports API route has `export const dynamic = 'force-dynamic'`**
   - Files: every route under `src/app/api/analytics/**/route.ts`, plus `/api/reports/route.ts`, `/api/dashboard/summary/route.ts`, `/api/activity-feed/route.ts`, `/api/commission/summary/route.ts`, `/api/commission/barber-summary/route.ts`, `/api/barber/analytics/route.ts`
   - Without this, Vercel caches the first response and the owner sees yesterday's numbers.

2. **Every analytics/reports API route uses `createClient()` from `@/lib/supabase/server` — no inline clients**
   - Inline clients bypass the `cache: 'no-store'` fetch wrapper. MEMORY.md rule. If an inline client is unavoidable, it MUST wrap `global.fetch` with `cache: 'no-store'`.

3. **Owner role check on every `/api/analytics/**`, `/api/reports`, `/api/dashboard/summary`, `/api/activity-feed`, `/api/commission/summary`**
   - Pattern: `getUser()` → query `profiles.role` → 403 if not `owner`.

4. **Barber scope enforcement on `/api/commission/barber-summary` and `/api/barber/analytics`**
   - Route MUST resolve the caller's `barber_id` from `auth.uid()` via `profiles → barbers.profile_id`, NOT accept a `barber_id` query param that a barber could spoof to read another barber's data.

5. **Timezone-aware date aggregation**
   - ANY aggregation that buckets by date/day/week/month in an analytics or reports route MUST use Eastern TZ. Banned: `toISOString().split('T')[0]`, `getDay()`, `getHours()`, `toTimeString().slice()` without `timeZone: 'America/New_York'`.
   - Command: `grep -rEn "toISOString\(\)\.split|\.getDay\(\)|\.getHours\(\)" src/app/api/analytics src/app/api/reports src/app/api/dashboard src/app/api/activity-feed src/app/api/commission`

6. **Soft-deleted bookings excluded from reports/analytics**
   - Any query against `bookings` in an analytics or reports route MUST include `.is('deleted_at', null)` (or equivalent). Otherwise cancelled-and-soft-deleted bookings inflate the numbers.

7. **Mirror parity between owner-personal and barber pages**
   - Files: `/dashboard/my-chair/reports/page.tsx` ↔ `/barber/reports/page.tsx`
   - Files: `/dashboard/my-chair/analytics/page.tsx` ↔ `/barber/analytics/page.tsx`
   - Files: `/dashboard/my-chair/page.tsx` (home) ↔ `/barber/page.tsx` (home)
   - UI feedback, error banners, state variables, computed values, and CSV export columns must match. If one adds a feature the other lacks, the Cross-Dashboard Code Mirroring Rule is broken. Hand off to `mirror-check` for a structural diff.

8. **CSV export uses canonical formatters**
   - All `.csv` output should flow through `src/lib/utils/csvExport.ts`. Inline CSV string-building (seen in `/dashboard/analytics/queue/page.tsx`) is allowed but must escape commas, quotes, and newlines. Flag any inline CSV that concatenates user-supplied text without escaping.

9. **Activity feed staleness — polling vs realtime gap**
   - `useActivityFeed` polls once on mount and exposes `refetch()`. There is NO realtime subscription. If the user perception is "this should be live," flag as KNOWN GAP and refer to `bulletproof-queue` / `bulletproof-bookings` for realtime patterns already in use.

10. **Parallel fetch snapshot consistency on `/dashboard` home**
    - Home page fires 4+ parallel fetches (`useHomeSummary`, `useActivityFeed`, `/api/commission/summary`, `/api/barber/reconcile`). These resolve independently — a booking completed at T=0 can appear in the activity feed but not yet in the commission summary. This is a KNOWN TIMING GAP, not a bug, but document it.

### Data-level invariants

Run queries in `references/audit-queries.sql` via `mcp__supabase-mt__execute_sql`. All SELECT-only. Expected result is 0 rows unless noted.

### Audit output template — MANDATORY Coverage Report

Every analytics/reports audit MUST produce this full block. A report without the Coverage Report section is INCOMPLETE and will be rejected.

```markdown
## Analytics & Reports Audit Report — [YYYY-MM-DD]

### Universal Preamble
- Tables enumerated: X/8 (daily_summaries, service_transactions, queue_entries, bookings, staff_status, feedback, barbers, locations)
- RLS policies found: X (expected owner-all + barber-self on each of 5 display tables)
- Triggers found: X/3 (create_service_transaction_from_queue, create_service_transaction_from_booking, tr_referral_conversion)
- RPCs found: X/4 (update_daily_summary, get_barber_daily_summary, get_dashboard_home_summary, increment_barber_cuts)
- Migrations confirmed: X/6 (011, 015, 024, 027, 028, 042_fix_daily_summary_conflict, 20260421000000)

### Findings
[Ranked critical/high/medium/low with file:line anchors]

---

## Coverage Report (MANDATORY)

### Pillar 1 — Codebase (from SURFACE_INVENTORY.md sections 1-11) — PROOF-OF-READ REQUIRED
| # | File | Verdict | Evidence (file:line — what was checked) |
|---|---|---|---|
| 1 | src/app/api/analytics/route.ts | PASS/FAIL/NOT-RUN | e.g. "analytics/route.ts:12 — `export const dynamic = 'force-dynamic'`" |
| 2 | src/app/api/analytics/advanced/route.ts | | |
| ... | [all 20 API routes + 14 pages + 5 hooks + 2 contexts + 1+ components + 1 util] | | |

Files audited with proof-of-read: N / 45+ (target: 100%). Any PASS without evidence = treated as NOT-RUN.

### Pillar 2 — Database (8 tables from inventory section 12)
| Table | Row count | Invariant check | Verdict |
|---|---|---|---|
| daily_summaries | | rows match distinct (date, barber, location) of completed svc | |
| service_transactions | | sum matches daily_summaries per day | |
| queue_entries | | completed rows all have svc_txn | |
| bookings | | soft-deleted excluded from reports | |
| staff_status | | active-barber count matches home hero | |
| feedback | | scoped to barbers in feedback analytics | |
| barbers | | referenced rows not deleted | |
| locations | | referenced rows not deleted | |

Tables audited: N / 8

### Pillar 3 — Queries (from references/audit-queries.sql, including reconcile block)
| # | Query | Verdict | Rows |
|---|---|---|---|
| 1 | daily_summary_row_match | | |
| 2 | revenue_match | | |
| 3 | tips_match | | |
| 4 | cuts_match | | |
| 5 | no_orphan_barbers | | |
| 6 | no_orphan_locations | | |
| 7 | home_vs_reports_reconcile | | |
| 8 | commission_reconcile | | |
| 9 | completed_queue_has_txn | | |
| 10 | completed_booking_has_txn | | |
| 11 | soft_deleted_excluded | | |
| 12 | index_coverage | | |
| ... | [all queries from audit-queries.sql] | | |

Queries run: N / total. Skipped: [empty — or list with reason].

### Pillar 4 — RLS (5 display tables)
| Table | Policies found | Expected | Verdict |
|---|---|---|---|
| daily_summaries | | owner-all, barber-self | |
| service_transactions | | owner-all, barber-self | |
| queue_entries | | owner-all, barber-location, public-limited | |
| bookings | | owner-all, barber-own, client-own | |
| feedback | | owner-all, barber-self-read, public-insert | |

RLS tables audited: N / 5

### Pillar 5 — Integrations (inventory section 14, 17)
| Integration | Verdict | Note |
|---|---|---|
| Trigger: create_service_transaction_from_queue | | |
| Trigger: create_service_transaction_from_booking | | |
| RPC update_daily_summary called from bookings/[id] | | line 558 |
| RPC update_daily_summary called from queue completion path | | (verify) |
| RPC get_dashboard_home_summary | | |
| RPC get_barber_daily_summary | | |
| Activity feed polled (not realtime) | | KNOWN GAP |
| Dashboard home parallel-fetch timing | | KNOWN GAP |

Integrations audited: N / 8

### Coupling Checks (from Cross-Surface Coupling Rules table)
| Coupling | Both sides audited? | Note |
|---|---|---|
| /dashboard home → {useHomeSummary, useActivityFeed, /api/commission/summary, /api/barber/reconcile, get_dashboard_home_summary, force-dynamic} | YES/NO | |
| /api/dashboard/summary → {service_transactions, queue_entries, bookings soft-delete, staff_status, SQL location aggregation, owner role, cache:no-store} | YES/NO | |
| /api/activity-feed → {queue_entries + bookings + service_transactions 3-parallel, limit, no-realtime, called_time+completed_time, owner role} | YES/NO | |
| /api/analytics/** → {force-dynamic, @/lib/supabase/server, owner role, TZ-aware, deleted_at filter, no hardcoded IDs} | YES/NO | |
| /api/reports → {CSV SQL == screen SQL, period validation, filters, payment_method split, owner role, exportToCSV, force-dynamic, TZ} | YES/NO | |
| /api/commission/{summary,barber-summary} → {formula parity, payment_status='paid', !auto_split, owner exemption, payouts subtract, barber scope from auth.uid} | YES/NO | |
| /api/barber/analytics → {barber scope from auth.uid, own barber_id filter, feedback scope, tip triple-source, force-dynamic} | YES/NO | |
| useBarberDailySummary → {get_barber_daily_summary RPC exists, dedupe key, no admin client} | YES/NO | |
| daily_summaries writes → {update_daily_summary called from booking + queue + refund + tip-adjust, UNIQUE (date,barber,location), fee_settlement filter} | YES/NO | |
| my-chair/reports ↔ barber/reports mirror | YES/NO | |
| my-chair/analytics ↔ barber/analytics mirror | YES/NO | |
| CSV export → {csvExport canonical, CSVFormatters, CSV escape, filename TZ, column-alias parity, inline builders flagged} | YES/NO | |
| useActivityFeed → {polling interval, no-realtime documented gap, refetch exposed, 5-location pagination plan} | YES/NO | |
| DashboardDataContext + BarberClockContext → {hydration hooks, no-stale values, no cross-component leak, cleanup} | YES/NO | |
| daily_summaries reads on my-chair/reports → {service_transactions truth, reconcile query, RPC repair path, RLS} | YES/NO | |
| scale-check → {hardcoded ID greps, locations[0] fallback, N+1 loops, per-location fan-out, index coverage, 1y chart dataset} | YES/NO | |

Coupling violations: N  **(must be 0 — any NO row is a violation)**

---

## Gap Self-Report (MANDATORY)

| # | Gap | Why it matters | Severity |
|---|---|---|---|
| G1 | [e.g. Did not open src/app/api/analytics/rotation-fairness/route.ts] | Rotation fairness is displayed on /dashboard/analytics/advanced — stale numbers = owner loses trust | Unknown |

Surfaces in SURFACE_INVENTORY.md NOT audited this run: <comma-separated item numbers>.
Questions requiring external verification (Vercel cache behavior, Recharts 1y render cost, N-location SQL plan): <list>.

If zero gaps: write "No gaps identified. All 70+ surfaces audited with proof-of-read + all coupling checks passed."

---

## Totals

- Surfaces audited with proof-of-read: X / 70+ (XX%)
- FAILs: N
- NOT-RUNs: N
- Coupling violations: N (must be 0)

**If NOT-RUNs > 0 OR coupling violations > 0, the report header MUST say "PARTIAL ANALYTICS AUDIT — N surfaces unaudited, M coupling violations" instead of "Analytics & Reports Audit Report".**
```

Stop only after every row above is filled. "Stop on first fail" is NOT the protocol — complete the full coverage sweep, then report.

---

## Mode: diagnose

1. **Ask for symptom.** Examples:
   - "Home page shows $1,240 but reports page shows $1,410 for today — same date, different number"
   - "I completed 3 cuts today but my analytics says 2"
   - "CSV export has a barber's name split across two columns"
   - "Activity feed didn't show the booking I just made"
   - "Barber's personal analytics shows $0 but I can see their cuts in /dashboard/queue"
   - "Retention cohort percentage changed overnight — nothing was deployed"

2. **Match against `references/incidents.md`.**
   - Numbers disagreeing across pages → likely Next.js Data Cache OR `daily_summaries` drift from `service_transactions`
   - Personal barber analytics zero → likely `get_barber_daily_summary` RPC returning empty, or `barber_id` mismatch
   - Activity feed missing an event → polling + stale fetch, confirm with hard refresh
   - CSV malformed → unescaped comma/quote, check inline CSV builders
   - Overnight drift with no deploy → `update_daily_summary` never called on a completion path

3. **Three-file rule.** Read max 3 files. If no match after 3, STOP and ask for direction.

4. **Two-strike rule.** Second fix must differ in approach from the first.

5. **Stay in scope.** Do not wander into queue, commission, or booking business logic. Those belong to their own skills. This skill only audits the aggregation + display layer.

6. **User reports override queries.** If the owner says "my home page shows $X," that's fact. Query the code path that HOME PAGE uses (`/api/dashboard/summary`) — do NOT query `daily_summaries` directly and contradict them.

---

## Mode: reconcile

Single-day deep walk-through. Used when the owner points at a specific number and says "this is wrong."

1. **Pin the inputs.** Ask: which date, which barber (or ALL), which location (or ALL), which page (home / reports / analytics / commission). Convert relative dates to absolute (`today` → `2026-04-21`).

2. **Identify the source of truth.** For revenue, tips, cuts: `service_transactions`. For fees: `service_transactions.owner_fee_amount` + `cash_fee_ledger`. For bookings count: `bookings` filtered `status='completed'` AND `deleted_at IS NULL`. For queue count: `queue_entries` filtered `status='completed'`.

3. **Run the reconcile query block** from `references/audit-queries.sql` section "RECONCILE — single day". It produces side-by-side: (a) what `service_transactions` says, (b) what `daily_summaries` says, (c) what the owner saw on the page.

4. **Explain the delta.** Do not guess. If `daily_summaries.total_revenue = $1,410` but `service_transactions` sum = $1,240, the summary is stale — trace which write path was missed.

5. **Do NOT fix the data.** Writes to production DB are banned. Propose a code fix to the broken write path and hand off.

---

## Mode: scale-check

Produce a "must-fix-before-location-#5 / barber-#N+1" checklist.

1. **Hardcoded location or barber IDs in analytics/reports SQL**
   - `grep -rEn "b0010000|b0020000|b0030000|b0040000|a274e1cf-955a-46f1-bc4c-dcd06a0510af" src/app/api/analytics src/app/api/reports src/app/api/dashboard src/app/api/commission`
   - Expected: zero hits. Any hit is a scale blocker.

2. **`locations[0]` fallback in analytics/reports pages**
   - `grep -rEn "locations\[0\]" src/app/\(dashboard\)/dashboard/analytics src/app/\(dashboard\)/dashboard/reports src/app/\(dashboard\)/dashboard/my-chair`
   - Flag each occurrence — with 5 locations, defaulting to the first is wrong for 4 of them.

3. **N+1 queries over barbers**
   - `grep -rEn "for.*barbers.*supabase" src/app/api/analytics src/app/api/reports` and equivalents.
   - Any per-barber SQL call inside a loop is O(N) at request time. Should be one aggregation query.

4. **`daily_summaries` upsert bottleneck**
   - Currently called from `src/app/api/bookings/[id]/route.ts:558`. At scale (200+ completions/day), confirm `update_daily_summary` is idempotent and cheap (should be an UPSERT, not a read-aggregate-write transaction).

5. **Activity feed `limit` vs volume**
   - Default 15, max 50. With 4+ locations, an owner catching up from the morning may need more. Flag as UX concern — the feed may need pagination or date scoping before growing to 4 locations.

6. **Service transactions index coverage**
   - Queries will scale only if indexed on `(service_completed_at, barber_id)` and `(service_completed_at, location_id)`. Verify via `pg_indexes`.

7. **Recharts dataset size**
   - `/dashboard/analytics` period `1y` will pull 365 daily buckets. Confirm the chart handles that without client-side stutter. Not a data bug — a rendering cost. Flag if the 1y option is used often.

8. **Per-location API fan-out**
   - `/api/dashboard/summary` computes per-location summaries in parallel. With 5+ locations, confirm the aggregation is SQL-side (one query grouped by location) — NOT a JS `Promise.all` over location count.

---

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
7. **Mirror check.** If the fix touches any page in the Cross-Dashboard Code Mirroring map, invoke the `mirror-check` skill before handoff.
8. **Handoff to `bulletproof-ship`.** Fix mode DOES NOT commit, stage, or push. Propose a branch name (`fix/analytics-<pattern-slug>` or `fix/reports-<pattern-slug>`) and a commit message in MT's conventional format, then tell the user to invoke `bulletproof-ship`.

### Integration with other skills

| Skill | Role |
|---|---|
| `bulletproof-ship` | Final step. Commit + push + deploy safety. Mandatory. |
| `mirror-check` | Cross-dashboard enforcement for any reports/analytics/home page fix. |
| `safe-query` | If a pattern requires DB writes (rare — e.g., backfilling `daily_summaries`), route through safe-query. |
| `verify-flow` | After a fix, trace the page→hook→API→DB path to confirm the fix holds end-to-end. |
| `trace-transaction` | If a specific day's numbers are wrong, trace one transaction to find the broken write path. |

---

## Downstream Consumers & Propagation

When a service completes — queue or booking — every aggregate downstream must update. The skill traces every link.

### Sources (who WRITES the data this skill displays)
| Source | File | Produces |
|---|---|---|
| Queue completion RPC | `complete_queue_service` (migration 035) | `queue_entries.status='completed'`, `service_transactions` row via trigger |
| Booking completion | `src/app/api/bookings/[id]/route.ts` PATCH to `status='completed'` | `bookings` row update, `service_transactions` row via trigger, `update_daily_summary` RPC call |
| Commission waiver | `src/app/api/commission/waive` | `service_transactions.fee_settlement_status='waived'` |
| Barber payout | `src/app/api/commission/payout` | `barber_payouts` row |

### Consumers (who READS and DISPLAYS)
| Consumer | Reads |
|---|---|
| `/api/dashboard/summary` | `service_transactions`, `queue_entries`, `bookings`, `staff_status`, `barbers`, `locations` |
| `/api/activity-feed` | `queue_entries`, `bookings`, `service_transactions` (3 parallel queries, merged, limit 15) |
| `/api/reports` | `service_transactions` (primary) + optional `daily_summaries` aggregate |
| `/api/analytics/**` | `service_transactions`, `bookings`, `queue_entries`, `feedback` depending on page |
| `/api/commission/summary` | `service_transactions.owner_fee_amount`, `cash_fee_ledger`, `barber_payouts` |
| `/api/commission/barber-summary` | Same tables, scoped to `barber_id` from auth |
| `/api/barber/analytics` | `service_transactions`, `feedback`, scoped to barber |
| Owner personal reports (direct Supabase) | `daily_summaries`, `queue_entries` (for tips detail) |

### Propagation invariants

1. **Every completed queue_entry has a matching service_transactions row** — trigger or handler responsibility. If missing, the entry shows in queue history but not in reports.
2. **Every completed booking has a matching service_transactions row** — same rule.
3. **`update_daily_summary` is called on EVERY completion path** — booking completion, queue completion, refund, tip adjustment. Missing any of these leaves `daily_summaries` stale.
4. **`daily_summaries` is an OPTIMIZATION, `service_transactions` is TRUTH.** If a report page shows `daily_summaries` numbers that disagree with `service_transactions`, the summary is stale — the fix is re-running `update_daily_summary`, NOT editing `daily_summaries` directly.
5. **Activity feed queries must include BOTH `called_time` and `service_completed_at` where applicable** — otherwise "called" events leak into the feed without their "completed" counterpart.
6. **CSV export MUST use the same SQL as the on-screen numbers.** If CSV is built from a different query than the page's charts, they can disagree silently.

### Diagnose: "Dashboard home shows $1,240, reports page shows $1,410 for today"

1. Same date? Same location filter? Same barber filter? Confirm — pages default differently.
2. Both reading `service_transactions` or is home reading `daily_summaries`? Read `/api/dashboard/summary` to check.
3. If home uses `daily_summaries`: run reconcile query. Likely `update_daily_summary` missed a write — one completion path didn't call it.
4. If both read `service_transactions` but disagree: timezone filter. One uses Eastern (correct), one uses UTC (wrong).
5. If cache stale: verify `export const dynamic = 'force-dynamic'` on `/api/dashboard/summary/route.ts` and `/api/reports/route.ts`. Verify Supabase factories wrap fetch with `cache: 'no-store'` (MEMORY.md CRITICAL rule).
6. Second-last resort: Next.js Full Route Cache — verify the page files don't have `export const revalidate = N` with a stale N.

---

## HARD RULES

- NEVER write to production DB. READ-ONLY via `mcp__supabase-mt__execute_sql`.
- NEVER modify a working system without explicit user approval.
- NEVER expand scope. Analytics/reports bug = aggregation-layer fix. If the root cause is in a queue RPC, a booking handler, or a commission calculation, hand off to the owning skill — do NOT fix it here.
- ALWAYS use `mcp__supabase-mt__`, never `mcp__supabase__`.
- NEVER test on real barbers (use test accounts only — see CLAUDE.md "Test Accounts").
- If a fix breaks any existing behavior, FULL REVERT.
- Branch workflow: any code change on a `fix/…` branch, not `main`.
- User reports override queries. If the owner says "this page shows X," query the CODE PATH that page uses — do not contradict the user with a query against a different table.
- `daily_summaries` is derived data. It can be repaired by re-running `update_daily_summary`. It should NEVER be hand-edited. `service_transactions` is truth — never patch it to make a dashboard look right.
