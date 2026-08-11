---
name: elis-bulletproof-dashboard
description: Audit, diagnose, or scale-check the Eli's Dulce Tradicion Owner Dashboard (src/pages/OwnerDashboard.tsx, src/components/dashboard/ + src/components/admin/ — OwnerSidebar, DashboardHeader, QuickStatsWidget, TodayScheduleSummary, OwnerCalendar, MenuManager, InventoryManager, ReportsManager, BusinessSettingsManager, BusinessHoursManager, DeliveryZoneManager, FAQManager, GalleryManager, AnnouncementManager, ContactSubmissionsManager, OrderIssuesManager, get_dashboard_summary RPC, track_analytics_event RPC, /api/analytics/dashboard backend fallback, hero revenue tiles, trend arrows, Recharts revenue + status-breakdown charts, lazy-loaded managers, MFA requirement). Complement to elis-bulletproof-frontdesk (operational view) and elis-bulletproof-orders (data source). Use when dashboard numbers look wrong, trend arrows are frozen, reports don't match Stripe, CMS edits don't save, or before onboarding a new owner user. Read-only SQL via mcp__supabase__execute_sql (project rnszrscxwkdwvvlsihqc). Never writes to production DB. Never modifies application code without explicit user approval.
---

# Eli's Bulletproof Dashboard

The Owner Dashboard is where Eli makes business decisions. If a number is wrong here, decisions are wrong. The dashboard is not revenue-critical *by itself* — but it drives every downstream choice (whether to raise capacity, change prices, close for a holiday, fire an underperforming item). Hardcoded trend arrows and silent RPC failures are the two most common ways this surface lies.

This skill covers:

**Home + nav**
- `src/pages/OwnerDashboard.tsx` — shell + tab routing + role gate
- `src/components/dashboard/OwnerSidebar.tsx` + `DashboardHeader.tsx` — chrome
- `src/components/dashboard/QuickStatsWidget.tsx` — hero tiles (today's orders, revenue, pending, capacity utilization, AOV)
- `src/components/dashboard/TodayScheduleSummary.tsx` — upcoming-today list
- `src/components/dashboard/OwnerCalendar.tsx` — month/week calendar (~29KB)
- `src/components/dashboard/OrderCalendarView.tsx` — grid layout

**Managers (lazy-loaded)**
- `MenuManager.tsx` (~23KB) — products CRUD
- `InventoryManager.tsx` (~13KB) — ingredients CRUD
- `ReportsManager.tsx` (~12KB) — sales/trend reports

**CMS (admin/)**
- `BusinessSettingsManager.tsx` — capacity, lead time, advance window, auto-confirm, session timeout
- `BusinessHoursManager.tsx` — open/close per day
- `DeliveryZoneManager.tsx` — zones + per-zone fees (often out of sync with hardcoded $15)
- `FAQManager.tsx` + `GalleryManager.tsx` + `AnnouncementManager.tsx` — marketing content
- `ContactSubmissionsManager.tsx` — inbox for site contact form
- `OrderIssuesManager.tsx` — refund/complaint queue

**Data sources**
- RPC `get_dashboard_summary` (src/lib/api/modules/analytics.ts:27)
- RPC `track_analytics_event` (analytics.ts:157)
- Backend fallback: `/api/analytics/dashboard` (backend/routes/analytics.js, backend/routes/reports.js)
- Tables: `orders`, `analytics_events`, `audit_logs`, `products`, `ingredients`, `business_settings`, `business_hours`, `holiday_closures`, `gallery_items`, `faq_items`, `contact_submissions`, `order_issues`

**Not covered here:**
- Actual menu / product data correctness → `elis-bulletproof-inventory`
- Auth race + MFA setup → `elis-bulletproof-auth`
- Email for daily report → `elis-bulletproof-emails`
- Order creation or front desk operations → `elis-bulletproof-orders` / `elis-bulletproof-frontdesk`

---

## Known Issues (baseline — flag every audit until fixed)

From CLAUDE.md + my codebase map:
- **Hardcoded trend indicator** — arrows in QuickStatsWidget / ReportsManager are static, not derived from prior-period data.
- **Recipe management UI not built** — `product_recipes`, `order_component_recipes` tables exist but no owner UI.
- **Backend status ambiguous** — analytics.ts falls back to RPC if backend `/api/analytics/dashboard` fails. In prod, is the backend even deployed? If not, the "backend first, RPC fallback" pattern is misleading — the RPC is always used.
- **Delivery fee hardcoded $15** — PaymentCheckout.tsx hardcodes `$15` instead of reading `delivery_zones` row.
- **MFA not enforced** — comment in OwnerDashboard suggests "Set 'Require MFA for owner role' in Supabase Auth dashboard" but this is a manual config step, not verified in code.

---

## Mandatory Preflight

1. `/Users/luismiguel/Desktop/elis-dulce-tradicion/CLAUDE.md` — Known Issues section.
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-elis-dulce-tradicion/memory/MEMORY.md` — Auth lessons: dashboards should NOT duplicate ProtectedRoute auth checks.
3. Confirm Supabase project `rnszrscxwkdwvvlsihqc`.
4. State: "Preflight complete. Running [mode]."

---

## Choose a Mode

- **audit** — monthly + before any pricing / capacity decision based on dashboard data
- **diagnose** — specific "number looks wrong" report
- **scale-check** — before adding a new feature to the dashboard (to ensure it stays coherent) or a large data import

---

## Mode: audit

### Code-level invariants

1. **Role gate is enforced by ProtectedRoute ONLY — not duplicated inside OwnerDashboard.**
   - MEMORY.md: auth lessons say duplicated checks cause race → redirect loops.
   - Grep: `grep -n "user.role\|profile.role\|role !==" src/pages/OwnerDashboard.tsx`
   - Allowed: reading `profile.role` for rendering. Not allowed: `if (role !== 'owner') navigate('/login')`.

2. **`get_dashboard_summary` RPC exists and returns non-null.**
   - `src/lib/api/modules/analytics.ts:27` calls it.
   - Verify RPC exists: `SELECT proname FROM pg_proc WHERE proname = 'get_dashboard_summary';`
   - Inspect body: `SELECT prosrc FROM pg_proc WHERE proname = 'get_dashboard_summary';`
   - Returned keys should include at minimum: today_orders, today_revenue, pending_count, avg_order_value.

3. **Backend `/api/analytics/dashboard` path is documented as used-or-dead.**
   - Grep: `grep -rn "VITE_API_URL\|/api/analytics" src/lib/api/modules/analytics.ts`
   - If the backend is NOT deployed to prod, the `try { fetch backend } catch { rpc fallback }` pattern means the RPC is always the answer — code should be simplified.

4. **Trend arrows come from two-period comparison, not a constant.**
   - `QuickStatsWidget.tsx` + `ReportsManager.tsx` must compute today vs yesterday (or this week vs last).
   - Grep: `grep -n "trend\|delta\|prior_period\|previousPeriod" src/components/dashboard/QuickStatsWidget.tsx src/components/dashboard/ReportsManager.tsx`
   - If a constant `trend: 'up'` or a hardcoded percentage appears in JSX — FAIL.

5. **Revenue tile matches Stripe reconciliation.**
   - Dashboard today revenue = SUM(orders.total_amount) WHERE payment_status='paid' AND DATE(updated_at)=today.
   - Confirm which timestamp is used. `created_at` vs `updated_at` vs `completed_at` can all produce different numbers. Stripe groups by settlement date.
   - Audit query #1 below.

6. **React Query cache is invalidated on mutations.**
   - After `updateProduct`, `updateIngredient`, `updateBusinessSettings`, etc., the corresponding `queryKeys.*` should be invalidated.
   - Grep: `grep -rn "invalidateQueries\|queryKeys\." src/components/admin/ src/components/dashboard/MenuManager.tsx src/components/dashboard/InventoryManager.tsx`
   - If missing, the owner edits something and doesn't see the change until manual refresh.

7. **Lazy-loaded managers have a loading fallback.**
   - `MenuManager`, `InventoryManager`, `ReportsManager` are loaded via `React.lazy`. A Suspense boundary must wrap them.
   - Grep: `grep -n "Suspense\|lazy(\|fallback=" src/pages/OwnerDashboard.tsx`

8. **MFA enforcement documented (or wired).**
   - CLAUDE.md / OwnerDashboard has a comment about requiring MFA. Is it just a comment or is there code enforcing it?
   - Check `src/components/auth/AuthenticatorAssuranceCheck.tsx` — does any route gate on AAL2?
   - If it's only a Supabase Auth-dashboard config, note: that config is invisible in git. Document externally.

9. **CMS managers validate input server-side too.**
   - `BusinessHoursManager` should not accept open_time > close_time.
   - `DeliveryZoneManager` should not create overlapping zones (or it's an accepted design choice).
   - `FAQManager`, `GalleryManager` — display_order should be unique or the UI should handle ties.
   - Grep: `grep -rn "validation\|zod\|schema" src/components/admin/`

10. **Audit log write on every admin mutation.**
    - `audit_logs` (migration `20260211_audit_logs_system.sql`) exists.
    - Each CMS mutation should write an audit log row with actor (owner user_id), action, before/after.
    - Query: `SELECT COUNT(*) FROM audit_logs WHERE created_at > now() - interval '7 days';`
    - If zero despite admin activity, audit logging is silently missing.

11. **Reports export (CSV/PDF) is actually wired OR absent.**
    - Grep: `grep -rn "csvExport\|export.*csv\|blob" src/components/dashboard/ReportsManager.tsx`
    - If a button exists but no export logic, it's a broken affordance.

12. **Order issue / contact submission badges reflect real backlog.**
    - Sidebar should show a count of unresolved items.
    - Grep: `grep -n "contact_submissions\|order_issues\|unread" src/components/dashboard/OwnerSidebar.tsx`

### Data-level invariants

```sql
-- D1. Dashboard revenue vs. ground-truth (last 7 days, paid orders)
SELECT DATE(updated_at) AS day, COUNT(*) AS n, SUM(total_amount) AS revenue
FROM orders
WHERE payment_status = 'paid' AND updated_at > now() - interval '7 days'
GROUP BY DATE(updated_at) ORDER BY day;

-- D2. AOV this week vs last (for trend arrow verification)
SELECT
  AVG(CASE WHEN updated_at > now() - interval '7 days' THEN total_amount END) AS this_week,
  AVG(CASE WHEN updated_at BETWEEN now() - interval '14 days' AND now() - interval '7 days'
           THEN total_amount END) AS last_week
FROM orders WHERE payment_status='paid';

-- D3. Capacity utilization past 30 days
WITH cap AS (SELECT max_daily_capacity FROM business_settings LIMIT 1)
SELECT pickup_date, COUNT(*) AS booked,
       (SELECT max_daily_capacity FROM cap) AS cap,
       ROUND(100.0 * COUNT(*) / NULLIF((SELECT max_daily_capacity FROM cap), 0), 1) AS pct
FROM orders
WHERE pickup_date >= CURRENT_DATE - interval '30 days' AND status != 'cancelled'
GROUP BY pickup_date ORDER BY pickup_date DESC;

-- D4. Audit log coverage (should be non-empty if admin is active)
SELECT action, COUNT(*) FROM audit_logs
WHERE created_at > now() - interval '30 days'
GROUP BY action ORDER BY COUNT(*) DESC;

-- D5. Contact submission backlog
SELECT status, COUNT(*) FROM contact_submissions GROUP BY status;

-- D6. Order issues backlog
SELECT status, priority, COUNT(*) FROM order_issues GROUP BY status, priority;

-- D7. Analytics event coverage
SELECT event_type, COUNT(*) FROM analytics_events
WHERE created_at > now() - interval '30 days'
GROUP BY event_type ORDER BY COUNT(*) DESC;

-- D8. Inactive products still showing? (sanity)
SELECT id, name_en, is_active, updated_at FROM products WHERE is_active=false;

-- D9. Delivery zone vs hardcoded fee drift
SELECT name, zip_codes, delivery_fee FROM delivery_zones ORDER BY delivery_fee;
-- Compare to the $15 hardcode in src/pages/PaymentCheckout.tsx.
```

### Audit output template

```
## Owner Dashboard Audit — [YYYY-MM-DD]

### Code-level
- [PASS/FAIL] No duplicate role-check in OwnerDashboard
- [PASS/FAIL] get_dashboard_summary RPC exists + returns expected keys
- [PASS / NOTE] Backend analytics path: [used / dead / unclear]
- [FAIL — KNOWN GAP] Trend arrows hardcoded (cited CLAUDE.md)
- [PASS/FAIL] React Query invalidate on mutation
- [PASS/FAIL] Suspense fallback wraps lazy managers
- [NOTE] MFA enforcement: [wired in code / dashboard config only / not configured]
- [PASS/FAIL] CMS input validation
- [PASS/FAIL] audit_logs populated on admin actions
- [PASS / NOTE] Reports export: [working / button exists but unwired / absent]

### Data-level (last 30d unless noted)
- D1 revenue by day: [sample output]
- D2 AOV trend: this_week=$X vs last_week=$Y — dashboard arrow [matches / doesn't]
- D3 capacity utilization peaks: [top 3 days]
- D4 audit log coverage: N entries / [Y / N]
- D5 contact backlog: unresolved=X
- D6 order issues backlog: open=X
- D7 analytics event types tracked: [list]
- D8 inactive products still visible: X (target: 0)
- D9 delivery zones: [list] — drift from $15 hardcode: Y/N

### Known gaps (flag every audit)
- Trend indicator hardcoded → QuickStatsWidget.tsx + ReportsManager.tsx
- Recipe UI absent → gap, surfaced in elis-bulletproof-inventory
- Delivery fee hardcoded $15 → elis-bulletproof-orders / PaymentCheckout.tsx
- Backend analytics deployment status unknown
- MFA requirement is documented but not code-enforced
```

---

## Mode: diagnose

### Step 1 — Ask
- Which tile / chart / page?
- What does the dashboard say vs. what does the owner believe is true?
- Screenshot if possible.

### Step 2 — Cross-check with raw SQL
Always, before editing code: run D1-D9 for the affected period. If the dashboard disagrees with raw data, the dashboard is wrong. If the raw data disagrees with Stripe, payments side is wrong — hand off to `elis-bulletproof-payments`.

### Step 3 — Symptom matrix

| Symptom | Likely cause | Next check |
|---|---|---|
| "Today's revenue is $0 but I know we had orders" | get_dashboard_summary RPC broken OR date column mismatch (created_at vs updated_at) | Audit invariant #2, #5; D1 |
| "Trend arrow always says 'up'" | Hardcoded constant in JSX | Audit invariant #4 |
| "I edited a product but the menu still shows old version" | No queryKey invalidate on mutation | Audit invariant #6 |
| "Dashboard redirects me to /login every few minutes" | useInactivityTimeout re-added OR duplicate role check OR profile-load race | Audit invariant #1; MEMORY.md auth lessons |
| "CMS saves but reverts on next page load" | Update function returns OK but doesn't actually commit (trigger / RLS); OR ReactQuery cache not invalidated | Check RLS + trigger; audit invariant #6 |
| "Calendar shows wrong days as closed" | business_hours day_of_week convention mismatch (0=Sun vs 0=Mon) | Query F7 in frontdesk skill |
| "MenuManager fails to load" | React.lazy bundle failed to fetch (network or chunk mismatch) | Browser console; audit invariant #7 |
| "Report export produces empty CSV" | csvExport util expects different shape than API returns | Check shape; audit invariant #11 |

### Step 4 — Three-file rule
Read the three likeliest files only. Don't grep the whole dashboard tree unless ruled out.

### Step 5 — Report
Root cause + proposed patch. Do not edit without approval.

---

## Mode: scale-check

Before adding a new dashboard section or doing a large data import:

1. **New section checklist** (borrowed from maguey-bulletproof-dashboard):
   - Route added to `App.tsx` inside `OwnerDashboard` layout
   - Sidebar entry added to `OwnerSidebar.tsx`
   - Role gate via ProtectedRoute (not inside the component)
   - `data-cy` attribute for E2E
   - Uses brand tokens (gold #C6A649, charcoal #1A1A2E, cherry) + Playfair Display + Nunito fonts
   - Bilingual via `useLanguage()` (no hardcoded English)

2. **Query budget.** The dashboard home runs several queries on mount. Count them. For a 1-second initial paint target, keep it to <5 SQL calls / <2 RPC calls.

3. **Lazy-loading boundaries.** Only the three big managers are lazy. If you add a 4th heavy component, lazy-load it.

4. **Data import safety.** If importing historical orders, recompute `audit_logs` + `analytics_events` coverage so reports don't show a sudden cliff.

5. **Stripe reconciliation cadence.** The owner should reconcile dashboard daily revenue with Stripe weekly. If that's not a habit, document it.

### Output
```
## Dashboard Scale Readiness — Change: [what's being added]

- New route wired in App.tsx: Y/N
- Sidebar entry present: Y/N
- Role gate via ProtectedRoute (no duplicate): Y/N
- Theme tokens + fonts: Y/N
- Bilingual labels: Y/N
- Query count: X (target: ≤5 SQL + ≤2 RPC)
- Stripe reconciliation drill: documented / ad-hoc

Verdict: [READY / NOT READY — blockers]
```

---

## HARD RULES

- **NEVER duplicate auth / role checks** inside dashboard components. ProtectedRoute is the one source. MEMORY.md has receipts.
- **NEVER hardcode a trend value** — if you can't compute it, don't show the arrow.
- **NEVER write to production DB from this skill.** CMS edits happen through the UI, which this skill audits but does not replace.
- **NEVER remove audit_logs** writes — they are the record of who changed what.
- **NEVER "fix" a number by tweaking the display** if raw SQL disagrees. Find the pipeline bug.
- **NEVER re-enable useInactivityTimeout** without a session-refresh plan.
- **Scope:** dashboard SHELL only. Per-domain correctness belongs to the sibling skills — delegate.
