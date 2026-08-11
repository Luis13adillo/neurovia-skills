---
name: maguey-bulletproof-dashboard
description: Audit, diagnose, or scale-check the Maguey Nightclub owner dashboard shell — the surface the owner actually looks at every day. Covers OwnerDashboard.tsx home (hero revenue tiles, Operational Insights, VIP stat card, Email Delivery widget, Scanner Status widget, Recent Purchases, Check-In Progress, Upcoming Events), AdvancedAnalytics.tsx (/analytics KPIs + recharts), OwnerPortalLayout.tsx sidebar (role-based + dev-only gating, 5 sections MAIN/SALES/TEAM/SETTINGS/MONITORING), useDashboardRealtime hook (realtime subscription to tickets/orders/scan_logs/email_queue/scanner_heartbeats/events), theme tokens (#030d07 bg, emerald-700→500 gradient, rounded-3xl glass cards, slate-* text scale), ProtectedRoute wiring via App.tsx, and the "adding a new dashboard section" checklist (route + sidebar entry + layout wrapper + role gating + data-cy + theme consistency). Use when dashboard metrics look wrong, a new sidebar entry is needed, hero tiles drift from reality, realtime stops updating, sections render with inconsistent theme, or before adding a new section so it ships looking native. Read-only SQL via mcp__supabase__execute_sql only. Never writes to production DB. This is the dashboard SHELL skill — per-domain correctness (events, tickets, VIP, scanner, payments, email, auth, waitlist, customers) belongs to the sibling bulletproof skills; delegate to them.
---

# Maguey Bulletproof Dashboard

The owner dashboard is what the owner sees first, every day. If a tile is wrong by a factor of 100, he loses trust in the whole system. If the sidebar shows a promoter an owner-only link, that's a role-scoping leak. If a new section ships with a different card radius or a purple accent, the dashboard stops feeling like one product.

This skill covers the **shell** — the chrome around the data. Per-domain data correctness (how a revenue number is computed from the events/orders flow, how VIP tables are seeded, how scans land in scan_logs) lives in the matching sibling skill. If an audit finding crosses a domain boundary, name it in scope 2 of the report and point at the right sibling.

## Scope

**In scope:**
- `maguey-gate-scanner/src/pages/OwnerDashboard.tsx` (dashboard home, 1084 lines)
- `maguey-gate-scanner/src/pages/AdvancedAnalytics.tsx` (/analytics page)
- `maguey-gate-scanner/src/pages/PromoterDashboard.tsx` (promoter-flavored dashboard)
- `maguey-gate-scanner/src/components/layout/OwnerPortalLayout.tsx` (sidebar + main shell)
- `maguey-gate-scanner/src/components/layout/ProtectedRoute.tsx` (role gating)
- `maguey-gate-scanner/src/components/dashboard/*` (CheckInProgress, RecentPurchases, UpcomingEventsCard, MetricCard, QuickStats, RevenueCard, RevenueTrend, NavigationGrid, NotificationFeed, ActivityFeed, etc. — 24 components)
- `maguey-gate-scanner/src/hooks/useDashboardRealtime.ts`
- `maguey-gate-scanner/src/lib/email-status-service.ts` + `scanner-status-service.ts` (surfaced by the dashboard but owned here from the UI side only)
- Theme tokens: the dark-emerald palette used across the owner portal
- Route + sidebar wiring in `maguey-gate-scanner/src/App.tsx`

**Not in scope — delegate:**
- Event create/cancel/archive correctness → `maguey-bulletproof-events`
- Cross-site event propagation → `maguey-bulletproof-sync`
- Order/ticket data semantics (what a row means, RPCs) → `maguey-bulletproof-tickets`
- Stripe webhook / refund / revenue reconciliation → `maguey-bulletproof-payments`
- VIP tables correctness (/vip-tables) → `maguey-bulletproof-vip`
- Scanner state machine and QR verification → `maguey-bulletproof-scanner`
- Email queue worker internals → `maguey-bulletproof-email`
- Waitlist flow → `maguey-bulletproof-waitlist`
- Customer profile surface (/customers internals) → `maguey-bulletproof-client-profile`
- ProtectedRoute auth resolution, role literals, middleware → `maguey-bulletproof-auth`

The pattern: **this skill checks the tile on the dashboard. The sibling skill checks whether the number in the tile is right.** The "Recent Purchases / 100 bug" in `references/incidents.md` is a good example of where the boundary lives — the rendering code is ours, the revenue semantics are `bulletproof-payments`'.

---

## Schema Reality Check (verified 2026-04-21 against live DB)

The dashboard reads from 7 tables. Here's what each actually contains and the dashboard-relevant columns:

**`orders`:** `id, user_id, purchaser_email, purchaser_name, event_id, subtotal (numeric), fees_total (numeric), total (numeric, DOLLARS), payment_provider, payment_reference, status (text, free-form), created_at, updated_at, metadata (jsonb), promo_code_id, referral_code`.
- **`orders.total` is in DOLLARS** (verified: min $25.00, max $950.00, avg $295.83). The RecentPurchases transform in `OwnerDashboard.tsx:518` does `Number(order.total || 0) / 100` — THIS IS A BUG that displays every order at 1% of its true value. See `references/incidents.md` #1.
- `orders.status` is free-form text. Values seen: `pending, paid, completed, refunded`. No CHECK constraint — dashboard code branches on specific strings.
- **No `completed_at` column.** The dashboard's RecentPurchases transform falls back to `created_at` (line 521). Fine as long as no tile claims "completion time".

**`tickets`:** `id, order_id, ticket_type_id, event_id, attendee_name, attendee_email, seat_label, qr_code_value, status (text), issued_at, scanned_at, created_at, updated_at, qr_token, qr_signature, qr_code_url, price (numeric, DOLLARS), fee_total, metadata, ticket_id (text, legacy), event_name, ticket_type, guest_name, guest_email, qr_code_data, is_used, purchase_date, current_status (inside|outside|left), entry_count, exit_count, last_entry_at, last_exit_at, scanned_by, transfer_count, original_attendee_email, original_attendee_name`.
- **`tickets.price` is in DOLLARS** (verified: all rows $25.00). Dashboard sums this directly — correct.
- `tickets.event_name` is a denormalized copy. The dashboard's `ticketsByEvent` map keys on this text. If an event is renamed after tickets are issued, the map goes stale. Not a dashboard bug per se — flag to events skill if the owner complains "top event shows old name".
- `scanned_at IS NOT NULL` and/or `status IN ('scanned','used')` = checked in. CheckInProgress uses both paths (line 60-61).

**`events`:** see `maguey-bulletproof-events` for full schema. Dashboard reads: `id, name, event_date (date), is_active (boolean NOT NULL), metadata (jsonb)`.
- `metadata->>'location'` — the dashboard reads this for the upcoming events card. Fragile: if metadata is NULL or missing `location`, the card shows `null`. Prefer a first-class `venue_name` column (which exists) or a fallback.

**`ticket_types`:** `id, event_id, code, name, price (numeric dollars), fee, limit_per_order, total_inventory (int, NULL allowed), description, tickets_sold`.
- Dashboard `fetchEventTicketTypes()` aliases `total_inventory AS capacity` for the upcoming events "percent sold" tile. If `total_inventory IS NULL`, capacity is treated as 0 → falls through to fallback 100. Warn if many events hit the fallback.

**`scanner_heartbeats`:** `device_id (text NOT NULL), device_name, last_heartbeat, is_online (boolean NOT NULL), pending_scans (int NOT NULL), current_event_id, current_event_name, scans_today (int NOT NULL), created_at, updated_at`.
- `is_online` is a stored column, not derived. If the row stops getting updated, `is_online=true` can be stale. Scanner skill owns staleness detection; dashboard trusts the column.

**`email_queue`:** `id, email_type, recipient_email, subject, html_body, related_id, resend_email_id, status (text), attempt_count, max_attempts, next_retry_at, last_error, error_context, created_at, updated_at`.
- Dashboard's "Email Delivery" widget fetches `related_id → status` map. Statuses seen: `pending, processing, delivered, failed`. Retry button POSTs via `email-status-service.retryFailedEmail()`.

**`scan_logs`:** `id, ticket_id, scanned_by (uuid), scan_result (text NOT NULL), scanned_at, metadata, scan_success (boolean), device_id, scan_method, event_id, scan_duration_ms, override_used`.
- The dashboard subscribes to scan_logs realtime changes to refresh revenue tiles (which is odd — scans don't change revenue; correct would be to only refresh CheckInProgress). See `references/invariants.md` #12.

**Supabase Realtime publication:** queried `pg_publication_tables WHERE pubname='supabase_realtime'` and got 0 rows. That means EITHER the publication is not named `supabase_realtime` (different project config) OR the publication is empty. Either way — the `useDashboardRealtime` hook subscribes to 7 tables; the dashboard won't auto-refresh unless those tables are members of whatever publication is active. Verify via `maguey-bulletproof-sync`'s audit queries before declaring realtime "working".

---

## Mandatory Preflight

Run these in order before any mode:

1. `/Users/luismiguel/Desktop/Maguey-Nightclub-Live/CLAUDE.md` — the "What Works" and "What's Hardcoded" sections. The dashboard is listed under What Works, so callouts here are the canonical truth.
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-Maguey-Nightclub-Live/memory/MEMORY.md` — role systems (owner/promoter/employee on the scanner app), deploy workflow (2-step), known gaps.
3. This skill's `references/audit-queries.sql`, `references/invariants.md`, `references/incidents.md`, `references/new-section-checklist.md`.
4. Confirm: **"Preflight complete. Running [mode]."** Then choose a mode.

Supabase access: `mcp__supabase__execute_sql`, project `djbzjasdrwvbsoifxqzd`. **Read-only.** Any write requires explicit user approval in the same turn.

---

## Choose a Mode

- **audit** → routine dashboard health check, or before a demo / owner-facing walkthrough
- **diagnose** → owner reports a specific symptom ("revenue tile shows $3", "sidebar missing entry for promoter", "dashboard stopped auto-updating")
- **scale-check** → before a big-traffic night (NYE, Halloween) where the dashboard will be under real-time load
- **add-section** → owner wants a new dashboard area; run the checklist so it ships theme-native and role-gated correctly

---

## Mode: audit

### Step 1 — Theme and layout consistency

Run these greps. Each should produce a uniform set of results across dashboard pages:

```bash
# 1. Every owner-portal page should wrap itself in OwnerPortalLayout
grep -l "OwnerPortalLayout" src/pages/*.tsx

# 2. Background should be consistent — dashboard dark-emerald
grep -n "bg-\[#030d07\]\|bg-\[#040d08\]\|from-\[#061a10\]" src/components/layout/OwnerPortalLayout.tsx src/pages/OwnerDashboard.tsx

# 3. Card radius — should be rounded-3xl (hero) or rounded-2xl (inner cards). Flag rounded-lg or rounded-xl as drift.
grep -rn "rounded-[a-z0-9]*" src/pages/OwnerDashboard.tsx src/components/dashboard/*.tsx | grep -v "rounded-full" | grep -v "rounded-2xl\|rounded-3xl" | head -20

# 4. Text palette — slate-100/200/300/400/500 for main hierarchy. Flag gray-* or neutral-* drift.
grep -rn "text-gray-\|text-neutral-\|text-zinc-" src/pages/OwnerDashboard.tsx src/components/dashboard/*.tsx src/components/layout/OwnerPortalLayout.tsx

# 5. Accent — emerald-500/600/700 for primary, amber-* for VIP. Flag blue/purple/red as wrong accent.
grep -n "from-indigo-\|from-purple-\|from-blue-\|from-red-\|from-pink-" src/components/layout/OwnerPortalLayout.tsx src/pages/OwnerDashboard.tsx
```

Full theme token rules in `references/invariants.md` "Theme Tokens" section.

### Step 2 — Sidebar and role gating

```bash
# Every route in App.tsx that renders an owner-portal page should have allowedRoles=['owner','promoter']
grep -n "Route path=\"/" src/App.tsx | grep -v "ProtectedRoute"   # expect 0 matches for all dashboard paths

# Every sidebar item that's owner-sensitive should carry ownerOnly: true
grep -n "ownerOnly\|promoterOnly\|devOnly" src/components/layout/OwnerPortalLayout.tsx

# Monitoring section must be devOnly (production owner should not see it)
grep -B2 -A3 "devOnly: true" src/components/layout/OwnerPortalLayout.tsx
```

Walk the sidebar in both roles mentally:
- Log in as `owner` → MAIN, SALES, TEAM, SETTINGS, MONITORING (MONITORING only in dev build).
- Log in as `promoter` → MAIN (Dashboard, Events), SALES (no CRM ownerOnly items, no Waitlist ownerOnly items, My Referrals promoterOnly visible). No TEAM, no SETTINGS, no MONITORING.

Flag any sidebar item that doesn't obey the filter.

### Step 3 — Hero tile correctness

The dashboard home shows 3 hero tiles: **Week Revenue, Today's Revenue, Active Events**. For each, verify:

1. The number comes from the right source. Week/Today revenue = sum of `tickets.price` (dollars) within range. Active Events = `count(events WHERE is_active=true AND event_date >= today)`.
2. Week-over-week delta uses same-size windows (days 0–6 vs days 7–13 — not a calendar week vs partial).
3. Currency formatter applied consistently. If one tile shows `$1,234.00` and another shows `$1234`, flag inconsistency.

The Operational Insights card holds: Average order value, Tickets per order, Top performing event. Check:
- AOV = totalRevenue / completedOrders.length. Completed = `status === 'completed'`. If you see AOV = $0 and orders exist with `status='paid'`, that's a status-vocabulary drift (`paid` vs `completed`).
- Tickets per order = totalTicketsSold / completedOrders.length. Same denominator concern.
- Top performing event is built from `ticketsByEvent` keyed on `ticket.event_name` (denormalized). Stale rename = stale label (see schema note above).

### Step 4 — Realtime coverage

```bash
# Which tables does the hook subscribe to?
grep -n "tables: \[" src/pages/OwnerDashboard.tsx src/hooks/useDashboardRealtime.ts
```

Cross-check against Supabase Realtime publication (via SQL):
```sql
SELECT tablename FROM pg_publication_tables WHERE pubname='supabase_realtime' ORDER BY tablename;
```

- Every table in `tables: [...]` must appear in the publication, otherwise the subscription silently does nothing.
- If the publication query returns empty, the dashboard gets zero live updates. Route that finding to `maguey-bulletproof-sync` (owner of realtime publication config).

### Step 5 — Data-level audit

Run `references/audit-queries.sql` queries #1–#10. All should return 0 rows unless noted.

### Audit output template

```
## Dashboard Audit Report — [YYYY-MM-DD]

### Theme / layout
- [PASS/FAIL] Every dashboard page wraps in OwnerPortalLayout
- [PASS/FAIL] Background consistent (#030d07 / #040d08)
- [PASS/FAIL] Card radius uniform (rounded-3xl hero, rounded-2xl inner)
- [PASS/FAIL] Text palette slate-* (no gray-/neutral-/zinc-)
- [PASS/FAIL] Accent emerald + amber (no indigo/purple/blue/red drift)

### Sidebar / role gating
- [PASS/FAIL] Every dashboard route is ProtectedRoute-wrapped with allowedRoles
- [PASS/FAIL] Monitoring section devOnly
- [PASS/FAIL] Owner-only items carry ownerOnly flag
- [PASS/FAIL] Promoter view excludes TEAM and SETTINGS sections

### Hero tiles
- [PASS/FAIL] Week Revenue source = sum(tickets.price) in window
- [PASS/FAIL] Today's Revenue same source, today window
- [PASS/FAIL] Active Events count from events table (is_active + future date)
- [PASS/FAIL] WoW delta uses same-size windows
- [PASS/FAIL] Currency formatter consistent across tiles

### Operational Insights
- [PASS/FAIL] AOV denominator matches order-status vocabulary
- [PASS/FAIL] Tickets-per-order denominator matches
- [PASS/FAIL] Top event label resolves to current event name (not stale)

### Realtime
- [PASS/FAIL] Every subscribed table in supabase_realtime publication
- [PASS/FAIL] useDashboardRealtime's per-table callback fires only on relevant tables (scan_logs should NOT refresh revenue tile)

### Data-level (see audit-queries.sql)
- [PASS/FAIL] Query #1: no orders with `status='completed'` but 0 tickets
- [PASS/FAIL] Query #2: no `orders.total` values >1M or <0 (sanity)
- [PASS/FAIL] Query #3: no events in upcoming list with NULL name
- [PASS/FAIL] Query #4: no duplicate scanner_heartbeats device_ids
- [PASS/FAIL] Query #5: no email_queue entries stuck in 'processing' >1h
- [PASS/FAIL] Query #6: ticket_types.total_inventory IS NULL count low
- [PASS/FAIL] Query #7: events.metadata missing 'location' key count
- [PASS/FAIL] Query #8: orders.status vocabulary set is {pending,paid,completed,refunded}
- [PASS/FAIL] Query #9: tickets.status vocabulary set expected
- [PASS/FAIL] Query #10: scan_logs in last 24h with scan_success=false rate

### Cross-domain findings (delegate)
- [List of items that belong to sibling skills, with pointer]

### Failures
[List with file:line references]
```

---

## Mode: diagnose

### Step 1 — Clarify
Ask the owner:
- Which tile or section? (screenshot if possible)
- What value is shown vs. what is expected?
- Which role was logged in? (owner / promoter)
- Dev build or production? (changes MONITORING visibility)

### Step 2 — Match to incident catalog
Open `references/incidents.md` and match the symptom. The biggest hits:
- Tile shows $X.YY when real value is $X·100 → RecentPurchases/100 bug
- Sidebar missing an entry for promoter → role gating mismatch
- Dashboard doesn't auto-refresh after a purchase → realtime publication gap
- Top event shows old name after rename → denormalized `tickets.event_name` drift
- Email Delivery widget says "0 delivered" but emails are landing → `related_id` map key mismatch

### Step 3 — Three-file rule
Identify the data source (the fetch function in OwnerDashboard.tsx), the component that renders it, and the service file in between. Touch only those three. Anything beyond goes to a sibling skill.

### Step 4 — Two-strike rule
If the first hypothesis fails, pick one alternative and stop. Don't shotgun fixes across the dashboard.

### Step 5 — Stay in scope
If diagnosis points at order/ticket/VIP/scanner/email business logic, hand off to the right sibling skill with a specific pointer (file:line + symptom). Do not try to fix it from here.

---

## Mode: scale-check

Before a peak-load night (NYE, Halloween, any 1000+ ticket event):

### 1. Tile refresh cadence under load
Every `postgres_changes` event from the subscribed tables triggers a re-fetch. During checkout bursts, tickets/orders fire INSERTs dozens per minute. Re-fetches in OwnerDashboard are 3 heavy queries (tickets, orders, events). Projection:
- 100 INSERTs/min × 3 queries = 300 DB round-trips/min = ~5 qps just from one dashboard
- Multiple owner-dashboard tabs open = multiplier

Recommendation: throttle per-table callbacks. Currently `onTableUpdate.orders` calls both `fetchRevenueAndStats` and `fetchRecentOrders`. Consider a 2s debounce in `useDashboardRealtime`.

### 2. `fetchTicketsData` query size
The dashboard SELECTs `tickets.*` with no LIMIT and no date filter. At 10,000+ lifetime tickets, this returns the whole table every refresh. Scale ceiling is the browser's memory, not the DB. Recommend adding a 90-day window when the row count crosses 5k.

### 3. CheckInProgress event fan-out
`CheckInProgress` fetches tickets for every upcoming event (up to 5) in parallel Promise.all. On scan bursts, the postgres_changes UPDATE refreshes ALL of them for every single scan. On a 500-ticket event during a 5-min scan rush that's 500 × 5 = 2,500 queries. Flag for throttling or for filtering to the active event only.

### 4. Sidebar + header under narrow viewports
Sidebar is fixed 288px. On a staff iPhone in landscape (844×390) it's a drawer. Confirm the mobile drawer close-on-navigate behavior still works (`OwnerPortalLayout.tsx:184-186`).

### Output

```
## Dashboard Scale Readiness — [event date], expected N tickets

### Tile refresh load: [N requests/min projected]
### Ticket query bound: [rows at current growth rate]
### CheckInProgress fan-out: [queries per scan × scan rate]
### Mobile drawer: [PASS/FAIL]

### Verdict: [READY / NEEDS THROTTLE / NEEDS QUERY BOUND]
```

---

## Mode: add-section

When the owner asks for a new dashboard area (e.g., "add a Feedback section", "add a Refunds page"), walk through `references/new-section-checklist.md` front-to-back. The checklist ensures the new page:

1. Registers in `App.tsx` with `<ProtectedRoute allowedRoles={['owner','promoter']}>` (or owner-only if staff-private).
2. Wraps in `<OwnerPortalLayout title={...} actions={...} hero={...}>` so the shell stays uniform.
3. Gets a sidebar entry in `OwnerPortalLayout.tsx` under the right section (MAIN / SALES / TEAM / SETTINGS / MONITORING) with correct role flags.
4. Uses the theme tokens from `references/invariants.md` (bg, card radius, text palette, accents).
5. Adds a `data-cy` attribute on the sidebar link for E2E hooks.
6. If monitoring/debug-only → carries `devOnly: true` on the section AND on the route (`requireDev` on ProtectedRoute).
7. If it reads live data → uses `useDashboardRealtime` or documents why it doesn't.

**Do not** write code from inside this skill — the checklist is a gate, not a generator. Flag the gaps, let the executor skill (a normal Claude turn) write the code.

---

## HARD RULES

- **Never write to production DB.** Read-only SQL only. Any proposed write requires explicit user approval in the same turn.
- **Never modify application code without explicit user approval.** This skill audits, diagnoses, and plans. The actual fix is a separate turn.
- **Never edit a sibling skill's reference files.** If you find a boundary bug (e.g., the `orders.total / 100` issue is really a bulletproof-payments concern), note it in scope 2 of the report and point at the sibling skill. The sibling owns the fix.
- **Branch workflow:** any fix branches from main as `fix/dashboard-<symptom>` or `feature/dashboard-<section>`.
- **User reports override queries.** If the owner says "the week revenue is wrong," trust that before the DB numbers. Queries confirm or deny the hypothesis; they don't override the owner's lived experience.
- **Per-domain bugs delegate out.** If the root cause of a dashboard symptom lives in events/tickets/VIP/scanner/payments/email/auth/waitlist/customers/sync, the sibling skill owns the fix. This skill owns the rendering shell.

---

## Reference Files

- `references/audit-queries.sql` — SELECT-only SQL queries #1–#10 for data-level invariants.
- `references/invariants.md` — Code-level invariants. Theme tokens, sidebar rules, realtime rules, role-gating rules.
- `references/incidents.md` — Known dashboard incidents + fix pattern. Includes the RecentPurchases/100 bug discovered 2026-04-21.
- `references/new-section-checklist.md` — Front-to-back checklist for adding a new dashboard area.
