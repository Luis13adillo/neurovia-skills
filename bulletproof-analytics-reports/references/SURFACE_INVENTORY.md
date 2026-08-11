# Analytics & Reports Domain — Surface Inventory

**Last verified:** 2026-04-24 against MT Barbershop production.
**Purpose:** Exhaustive list of every surface the analytics/reports display layer touches. The audit MUST tick through every item here — none skipped.

When an audit finds a surface that isn't listed here, add it to the report's "Surface Drift" section and wait for approval before updating this file.

---

## 1. API Routes — owner analytics (13 routes)

| # | Route | Methods | Purpose |
|---|---|---|---|
| 1 | `src/app/api/analytics/route.ts` | GET | Top-level analytics (period 7d/30d/90d/1y) — summary + daily buckets + barber performance + fairness |
| 2 | `src/app/api/analytics/advanced/route.ts` | GET | Workload, capacity breakdown |
| 3 | `src/app/api/analytics/barber-comparison/route.ts` | GET | Multi-barber side-by-side |
| 4 | `src/app/api/analytics/campaigns/route.ts` | GET | Campaign performance |
| 5 | `src/app/api/analytics/customer-retention/route.ts` | GET | Retention cohorts |
| 6 | `src/app/api/analytics/locations/route.ts` | GET | Per-location breakdown |
| 7 | `src/app/api/analytics/queue/route.ts` | GET | Wait times, peak hours, abandonment |
| 8 | `src/app/api/analytics/referrals/route.ts` | GET | Referral source tracking |
| 9 | `src/app/api/analytics/retention/route.ts` | GET | Loyalty tier analytics |
| 10 | `src/app/api/analytics/rotation-fairness/route.ts` | GET | Rotation equity |
| 11 | `src/app/api/analytics/workload/route.ts` | GET | Workload distribution |

## 2. API Routes — owner reports + dashboard (4 routes)

| # | Route | Methods | Purpose |
|---|---|---|---|
| 12 | `src/app/api/reports/route.ts` | GET | Daily/weekly/monthly totals + barber/location breakdown + payment split |
| 13 | `src/app/api/dashboard/summary/route.ts` | GET | Owner home hero: revenue, queue depth, active barbers, bookings count, 7-day history, per-location |
| 14 | `src/app/api/activity-feed/route.ts` | GET | Unified feed — queue + bookings + payments (default limit 15, max 50) |
| 15 | `src/app/api/barber/reconcile/route.ts` | GET | Dashboard-home side-fetch for reconcile tile |

## 3. API Routes — commission summaries (2 routes)

| # | Route | Methods | Purpose |
|---|---|---|---|
| 16 | `src/app/api/commission/summary/route.ts` | GET | Owner: aggregated totals, per-barber, recent transactions (also read by dashboard home) |
| 17 | `src/app/api/commission/barber-summary/route.ts` | GET | Barber-scoped earnings / fees owed / payouts |

## 4. API Routes — barber-scoped analytics (1 route)

| # | Route | Methods | Purpose |
|---|---|---|---|
| 18 | `src/app/api/barber/analytics/route.ts` | GET | Personal cuts, earnings, service breakdown — scoped to caller's barber_id (resolved from `auth.uid()`) |

## 5. UI pages — Owner analytics (8 pages)

| # | Page | Hydration |
|---|---|---|
| 19 | `src/app/(dashboard)/dashboard/analytics/page.tsx` | `/api/analytics?period=...` |
| 20 | `src/app/(dashboard)/dashboard/analytics/advanced/page.tsx` | `/api/analytics/advanced` |
| 21 | `src/app/(dashboard)/dashboard/analytics/campaigns/page.tsx` | `/api/analytics/campaigns` |
| 22 | `src/app/(dashboard)/dashboard/analytics/commissions/page.tsx` | `/api/commission/summary` |
| 23 | `src/app/(dashboard)/dashboard/analytics/feedback/page.tsx` | Feedback aggregation |
| 24 | `src/app/(dashboard)/dashboard/analytics/locations/page.tsx` | `/api/analytics/locations` |
| 25 | `src/app/(dashboard)/dashboard/analytics/queue/page.tsx` | `useQueueAnalytics()` + inline CSV string-builder (NOT using canonical `csvExport.ts`) |
| 26 | `src/app/(dashboard)/dashboard/analytics/retention/page.tsx` | `/api/analytics/retention` |

## 6. UI pages — Owner home + reports (2 pages)

| # | Page | Hydration |
|---|---|---|
| 27 | `src/app/(dashboard)/dashboard/page.tsx` | Home: `useActivityFeed()` + `useHomeSummary()` + parallel `/api/commission/summary` + `/api/barber/reconcile` |
| 28 | `src/app/(dashboard)/dashboard/reports/page.tsx` | `/api/reports?period=...` + `exportToCSV()` |

## 7. UI pages — Owner personal (My Chair) + Barber mirror (4 pages — mirror pairs)

| # | Owner personal | Barber mirror |
|---|---|---|
| 29 | `src/app/(dashboard)/dashboard/my-chair/reports/page.tsx` — direct Supabase reads from `daily_summaries`, `queue_entries` tips; inline CSV | `src/app/(dashboard)/barber/reports/page.tsx` — same pattern |
| 30 | `src/app/(dashboard)/dashboard/my-chair/analytics/page.tsx` — `useBarberDailySummary()` + `useBarberDailyGoal()` | `src/app/(dashboard)/barber/analytics/page.tsx` — same |

Mirror drift on these two pairs = Cross-Dashboard Code Mirroring HARD RULE violation.

## 8. Hooks (5 files)

| # | File | Role |
|---|---|---|
| 31 | `src/lib/hooks/useActivityFeed.ts` | Polls `/api/activity-feed` — NO realtime subscription |
| 32 | `src/lib/hooks/useHomeSummary.ts` | Hydrates `/api/dashboard/summary` |
| 33 | `src/lib/hooks/useBarberDailySummary.ts` | Calls RPC `rpc('get_barber_daily_summary', ...)` |
| 34 | `src/lib/hooks/useBarberDailyGoal.ts` | Reads `barbers.daily_goal_cuts` |
| 35 | `src/lib/hooks/useQueueAnalytics.ts` | Analytics queue page hydration |

## 9. Contexts (2 files)

| # | File | Role |
|---|---|---|
| 36 | `src/lib/contexts/DashboardDataContext.tsx` | Shared queue data (via `useQueue`) for dashboard tree |
| 37 | `src/lib/contexts/BarberClockContext.tsx` | Shared clock status for dashboard tree |

## 10. Components (1 file)

| # | File | Role |
|---|---|---|
| 38 | `src/components/dashboard/owner/LiveActivityFeed.tsx` | Renders unified activity feed items |

Analytics-heavy components (not exhaustive; all under `src/components/dashboard/owner/` + `analytics/` subfolder):

| # | File | Role |
|---|---|---|
| 39 | `src/components/dashboard/owner/HomeSummaryCards.tsx` | Hero-tile rendering |
| 40 | `src/components/dashboard/owner/MiniRevenueTrend.tsx` | 7-day spark |
| 41 | `src/components/dashboard/owner/BarberLeaderboard.tsx` | Home + analytics leaderboard |
| 42 | `src/components/dashboard/owner/LocationComparisonChart.tsx` | Location breakdown |
| 43 | `src/components/dashboard/owner/BusiestTimesHeatmap.tsx` + `QueuePeakHoursHeatmap.tsx` + `QueueWaitTimeTrend.tsx` | Queue analytics |
| 44 | `src/components/dashboard/owner/analytics/MetricsGrid.tsx` + `AnalyticsCharts.tsx` + `BarberPerformanceTable.tsx` + `BottomInsightsGrid.tsx` + `AnalyticsHeader.tsx` | Core analytics page shell |

## 11. Utilities (1 file)

| # | File | Role |
|---|---|---|
| 45 | `src/lib/utils/csvExport.ts` | `exportToCSV(data, columns, filename)`, `downloadCSV()`, `arrayToCSV()`, `CSVFormatters` (currency, percentage, date, datetime). Canonical path for any CSV export |

## 12. Database tables (read-only consumers) (7)

The display layer READS these — it does NOT own them. Writes are owned by commission/queue/bookings skills.

| # | Table | Role |
|---|---|---|
| 46 | `daily_summaries` | Per-(date, barber_id, location_id): `total_cuts`, `total_revenue`, `total_tips`, `cash_amount`, `card_amount`, `link_amount`, `total_owner_fees`, `total_barber_net` — derived data; optimization cache |
| 47 | `service_transactions` | Immutable INSERT-only audit log — SOURCE OF TRUTH for revenue/cuts/tips |
| 48 | `queue_entries` | Activity feed + queue analytics + tip detail reads |
| 49 | `bookings` | Activity feed + reports source (must filter `deleted_at IS NULL`) |
| 50 | `staff_status` | Dashboard summary: active-barber count |
| 51 | `feedback` | Feedback analytics page |
| 52 | `barbers` + `locations` | JOIN context on every aggregation |

## 13. RPC functions (4)

| # | RPC | Purpose |
|---|---|---|
| 53 | `get_barber_daily_summary(barber_id, date)` | Aggregate daily stats from `queue_entries` + tips for a barber — called from `useBarberDailySummary` |
| 54 | `update_daily_summary(date, barber_id, location_id)` | Upsert `daily_summaries` row — called from booking completion (`src/app/api/bookings/[id]/route.ts:558`) and must fire on queue completion + refund + tip adjust |
| 55 | `get_dashboard_home_summary(location_id?)` | Owner home aggregated payload (migration 028) |
| 56 | `increment_barber_cuts(p_barber_id)` | Bumps `staff_status.cuts_today` — side-effect on analytics |

## 14. DB triggers (0 owned)

The display layer does not own triggers. The commission skill owns `create_service_transaction_from_queue` + `create_service_transaction_from_booking`. Analytics DRIFT when those triggers fail — flag but hand off.

## 15. RLS policies (expected)

Display-layer RLS governs what the owner vs barber can SELECT.

| # | Table | Expected policies |
|---|---|---|
| 57 | `daily_summaries` | Owner-all (select), barber-self (select via barber_id = own) — confirm migration 015 enabled RLS |
| 58 | `service_transactions` | Owner-all, barber-self-select |
| 59 | `queue_entries` | Owner-all, barber-own-location reads, public read limited (tracking token) |
| 60 | `bookings` | Owner-all, barber-own, client-own |
| 61 | `feedback` | Owner-all, barber-self-read, public insert |
| 62 | `barbers` + `locations` | Public select of limited cols |

## 16. Migrations (6)

| # | Migration | What it did |
|---|---|---|
| 63 | `011_payment_reporting.sql` | Created `daily_summaries`, `cash_reconciliations`, `update_daily_summary`, `get_barber_daily_summary` RPCs |
| 64 | `015_security_audit.sql` | Enabled RLS on `daily_summaries` + `cash_reconciliations` (display-layer tables lacked RLS) |
| 65 | `028_home_page_rpc.sql` | Created `get_dashboard_home_summary` |
| 66 | `027_add_performance_indexes.sql` | Performance indexes on `service_transactions`, `queue_entries`, `bookings` for analytics |
| 67 | `042_fix_daily_summary_conflict.sql` | Fix upsert conflict on `daily_summaries` |
| 68 | `20260421000000_fix_daily_summary_drift.sql` | Repaired silent drift between `daily_summaries` and `service_transactions` |

## 17. External integrations / background jobs (0 direct, 1 adjacent)

No cron routes feed analytics directly. Analytics rely on completion-path writes firing `update_daily_summary`. If they don't, `daily_summaries` drifts — the 2026-04-24 commission Phase 4 backfill is an example (22 RPC calls to re-sync).

The display layer is fed by integrations owned elsewhere:
- Stripe webhook → `service_transactions.payment_status='paid'` → analytics rollup
- Google Calendar sync → `bookings` rows → reports revenue
- Booksy parser → `external_calendar_events` (not in analytics aggregates)

## 18. Environment variables (3)

| # | Var | Purpose |
|---|---|---|
| 69 | `NEXT_PUBLIC_SUPABASE_URL` + `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Client reads (hooks hitting Supabase directly — e.g., my-chair/reports) |
| 70 | `SUPABASE_SERVICE_ROLE_KEY` | Not used by analytics routes — they use anon + RLS. Flag if an analytics route imports `admin.ts` (likely a scope bleed) |
| 71 | `NEXT_PUBLIC_APP_URL` | CSV filename prefix + share links |

---

## Surface Totals

- **API routes:** 20 (owner analytics: 11 + owner reports/dashboard: 4 + commission: 2 + barber-scoped: 1 + other: 2)
- **UI pages (owner):** 10 (8 analytics + home + reports)
- **UI pages (mirror pairs):** 4 (my-chair reports/analytics ↔ barber reports/analytics)
- **Hooks:** 5
- **Contexts:** 2
- **Components:** 7+ (1 feed + 6 analytics-heavy)
- **Utilities:** 1 (CSV)
- **Database tables (read):** 7
- **RPC functions:** 4
- **DB triggers (watched, not owned):** 2 (from commission skill)
- **RLS policies:** 6+ tables
- **Migrations:** 6
- **Integrations (adjacent):** 3
- **Env vars:** 3

**Grand total surfaces to audit:** 70+ discrete items.

**Any audit that touches fewer than ~90% of these surfaces is INCOMPLETE.**

---

## How to Use This Inventory

1. At the start of audit mode, copy the Surface Totals into the scratchpad.
2. As each surface is checked, mark PASS / FAIL / NOT-RUN against it.
3. At the end, the Coverage Report MUST account for every single numbered item above.
4. A NOT-RUN row must include a reason (e.g., "could not open — file not found" — which is itself a FAIL for that surface).
