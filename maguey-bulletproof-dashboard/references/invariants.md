# Dashboard — Invariants

Rules the dashboard shell must obey. Grouped by concern. Numbered so audits can reference invariants by ID.

---

## Theme Tokens

The owner dashboard has one palette. New sections that introduce a second palette read as broken.

1. **Page background**: `bg-[#030d07]` on the root main area. Dashboard sidebar uses `bg-[#040d08]/95` with `backdrop-blur-2xl`. Anything else is drift.
2. **Hero card gradient**: `bg-gradient-to-br from-[#061a10] via-[#071510] to-[#050a08]` with `shadow-[0_45px_90px_rgba(3,7,23,0.7)]`. Exactly one hero per page — the one passed to `<OwnerPortalLayout hero=...>`.
3. **Inner cards**: `border border-white/10 bg-white/5` or `bg-black/40 backdrop-blur-md`. Hover: `bg-white/10`.
4. **Card radius**: `rounded-3xl` for the hero and large surface cards; `rounded-2xl` for internal tiles and list items. Never `rounded-lg`, `rounded-xl`, `rounded-md` on a dashboard surface.
5. **Primary accent**: emerald — `emerald-500`, `emerald-600`, `emerald-700`. Gradients: `from-emerald-700 via-emerald-600 to-emerald-500`. Shadows: `shadow-emerald-900/40`.
6. **Secondary accent**: amber/orange for VIP (`from-amber-500/20 to-orange-500/20`). Cyan/blue for email status (`from-cyan-500/20 to-blue-500/20`). Green for scanner status (`from-green-500/20 to-emerald-500/20`). Do not introduce indigo, purple, pink, or red as a primary accent. Red is reserved for error/failure states only.
7. **Text hierarchy**: `text-white` (primary), `text-slate-300` (body), `text-slate-400` (helper), `text-slate-500` (label), `text-slate-600` (divider). Do not use `text-gray-*`, `text-neutral-*`, or `text-zinc-*` — Tailwind's gray ramps render slightly off against `#030d07`.
8. **Uppercase label style**: `text-xs uppercase tracking-[0.3em]` for small section labels. `tracking-[0.4em]` reserved for the hero date line.
9. **Currency formatter**: `Intl.NumberFormat("en-US", { style: "currency", currency: "USD", minimumFractionDigits: 2 })`. Defined at top of `OwnerDashboard.tsx`. New components must import or receive this — never reformat inline.

---

## Layout Shell

10. Every page rendered at `/dashboard`, `/events`, `/analytics`, `/orders`, `/vip-tables`, `/customers`, `/waitlist`, `/team`, `/audit-log`, `/security`, `/staff-scheduling`, `/devices`, `/door-counters`, `/branding`, `/sites`, `/fraud-investigation`, `/queue`, `/notifications/*`, `/monitoring/*` MUST render `<OwnerPortalLayout>` as its root. Pages that bypass the layout break the sidebar-present-on-every-page promise.
11. `OwnerPortalLayout` props: `title, subtitle, description, actions, hero, children`. `title` is required. `hero` is optional but when present sits above `children` inside the max-w-7xl container.
12. The `actions` slot hosts page-level CTAs (e.g. "Create Event"). On mobile, actions render above the title block; on desktop they right-align next to the title. Don't hand-roll a header.
13. Main content area is `max-w-7xl mx-auto space-y-10`. Sections within `children` should use `section` tags with `mt-6` or a grid with `gap-6`.

---

## Sidebar + Role Gating

14. Sidebar section structure in `OwnerPortalLayout.tsx:46-93`: ordered list `MAIN → SALES → TEAM → SETTINGS → MONITORING`. Do not reorder. Do not add a sixth section without user approval — five is the capacity for a single-glance owner surface.
15. `ownerOnly: true` on a **section** hides the entire section from promoters. `ownerOnly: true` on an **item** hides only that item. Both apply simultaneously.
16. `promoterOnly: true` shows an item only to promoters (currently only "My Referrals").
17. `devOnly: true` on a **section** gates it behind `import.meta.env.DEV`. Currently only MONITORING. Production builds ship with no monitoring links — that is intentional per the dashboard bloat cleanup (see CLAUDE.md).
18. The filter logic lives at `OwnerPortalLayout.tsx:135-146`. Three filters run in order: devOnly → section ownerOnly → item ownerOnly/promoterOnly. Adding a new role flag means extending all three.
19. Every dashboard route in `App.tsx` must be wrapped in `<ProtectedRoute allowedRoles={[...]}>`. The current standard is `allowedRoles={['owner', 'promoter']}` for the shared surfaces. Never bare-route an owner-portal page.
20. `data-cy` attributes on sidebar buttons: the map in `OwnerPortalLayout.tsx:105-111` covers `/dashboard, /events, /team, /analytics, /orders`. New sidebar entries that will be E2E-tested must be added to this map.

---

## Realtime Subscription

21. `useDashboardRealtime` is the only dashboard-level realtime subscription. Individual components (CheckInProgress) have their own scoped subscriptions — that's fine, but they should also throttle to avoid fan-out.
22. The hook subscribes to `tables: ['tickets', 'orders', 'scan_logs', 'email_queue', 'scanner_heartbeats', 'events']`. Adding a table here only helps if that table is in the Supabase Realtime publication (see `maguey-bulletproof-sync`).
23. **GAP:** `scan_logs` triggering `fetchRevenueAndStats()` is incorrect — scan events don't change revenue. Either remove `scan_logs` from the tables list or give it a narrower callback (refresh only the CheckInProgress component). See `references/incidents.md` #6.
24. The hook reconnects on `document.visibilitychange` when the tab returns to visible. This is intentional — caught one class of "stale dashboard after laptop-lid" bug. Do not remove.
25. Hook returns `{ isLive, lastUpdate, reconnect }`. The dashboard reads `isLive` but does NOT render a visual indicator. **GAP:** a small "LIVE" pill in the header would telegraph realtime health to the owner. Defer until owner asks.

---

## Hero Tiles and Metric Correctness (shell-side only)

26. The three hero tiles (`Week Revenue, Today's Revenue, Active Events`) read `stats.weekRevenue`, `stats.todayRevenue`, `stats.activeEvents`. Their computation lives in `fetchRevenueAndStats()` (OwnerDashboard.tsx:308-449).
27. Revenue sources: `tickets.price` in DOLLARS, summed over `tickets.created_at || tickets.purchase_date` within window. Fallback to purchase_date is a workaround for legacy rows where created_at is null.
28. `stats.activeEvents` uses a SEPARATE `count: 'exact'` query (line 411-415). Don't deduplicate with the tickets fetch — they're independent, and the count query is cheap (`head: true`).
29. Week-over-week delta: `(lastSeven - previousSeven) / previousSeven * 100`. Windows are 7-day aligned at midnight local. If `previousSeven.revenue === 0`, delta is 0 (not Infinity) — line 406-408.
30. **GAP (CRITICAL):** `RecentPurchases` transform at line 518 does `total: Number(order.total || 0) / 100` — but `orders.total` is stored in DOLLARS (verified via DB query 2026-04-21: min $25.00, max $950.00). Every order displays at 1% of true value. See `references/incidents.md` #1. This is a payment-layer semantic issue — coordinate with `maguey-bulletproof-payments` for the canonical fix.
31. `averageOrderValue = totalRevenue / completedOrders.length` where `completedOrders = orders.filter(o => o.status === 'completed')`. If the payment layer emits `status='paid'` instead of `'completed'`, AOV silently reads 0.

---

## Operational Insights

32. The Operational Insights card (OwnerDashboard.tsx:901-1066) renders `insights: InsightSummary[]` built in `fetchRecentOrders()`. Always exactly 3 items: Average order value, Tickets per order, Top performing event.
33. Below the insights list, four stat rows render: Scan Status, VIP Experience, Email Delivery, Scanner Status. These are NOT part of the `insights` array — they're hard-coded JSX. A new fourth stat row requires adding JSX here, not pushing to `insights`.
34. "Top performing event" uses `ticketsByEvent` keyed on `ticket.event_name` (denormalized text). If an event is renamed after issue, the label goes stale. Flag to events skill; don't fix here.
35. Email Delivery widget shows counts from `emailStatusList.filter(e => e.status === 'delivered')` etc. Statuses it recognizes: `pending, processing, delivered, failed`. Any new email_queue status must be handled here or the tile silently ignores it.

---

## Check-In Progress + Upcoming Events

36. `CheckInProgress` has its own realtime subscription on `tickets UPDATE` (no event_id filter when rendered from the dashboard home). On a scan burst, every scan fires a refetch. Acceptable for now; flag for throttle if scan volume spikes (see scale-check mode).
37. Check-in detection: `scanned_at !== null OR status IN ('scanned','used')`. Two sources of truth — status column + scanned_at timestamp. If they drift (scan without timestamp, timestamp without status), the count can differ from the tile. Flag to scanner skill.
38. `UpcomingEventsCard` shows up to 4 events. "Sellout" status at ≥85% sold, "monitor" at ≥60%. These thresholds are hard-coded in OwnerDashboard.tsx:584-586 — document them anywhere an owner reads "sellout", because they are NOT runtime-configurable.
39. Capacity per event derives from `sum(ticket_types.total_inventory) for event_id`. If all tiers are NULL-inventory, capacity falls back to 100 (line 582). This is a placeholder — flag in audit if > 10% of events hit the fallback.

---

## Email Delivery + Scanner Status Widgets

40. Both widgets poll via `fetchEmailStatuses()` / `fetchScannerStatuses()` on initial load and via realtime callbacks. There is no periodic refresh on a timer — state freshness depends on the realtime publication.
41. Email retry button calls `retryFailedEmail(id)` from `email-status-service.ts`. Success → toast + refetch. Failure → destructive toast. The button is inside the owner dashboard but the underlying service belongs to `maguey-bulletproof-email`.
42. Scanner status online/offline is read directly from `scanner_heartbeats.is_online`. The dashboard does NOT compute staleness here. Scanner skill owns staleness detection.

---

## Navigation Grid / Legacy NavigationGrid

43. `OwnerDashboard.tsx:692-785` defines a `navigationItems` array with Site Management, Events, Analytics, Team, Customers, Devices, Security, Door Counters, Audit Log, Notifications, Scheduling. **This array is currently unused** — it was the old main-area navigation grid, superseded by the sidebar. Either wire it back (new use case) or delete it (dead code). Flag to user, don't silently remove.
44. `NavigationGrid.tsx` component still exists in `components/dashboard/`. Same dead-code status. Check whether any OTHER page uses it before any cleanup.

---

## Data-cy Attributes (E2E hooks)

45. E2E specs in `e2e/specs/` look for: `data-cy="revenue-card"`, `data-cy="dashboard-container"`, `data-cy="scanner-status"`, `data-cy="check-in-progress"`, `data-cy="upcoming-events"`, `data-cy="sidebar-dashboard"`, `data-cy="sidebar-events"`, `data-cy="sidebar-team"`, `data-cy="sidebar-analytics"`, `data-cy="sidebar-orders"`.
46. Do not remove a data-cy attribute without updating the corresponding Cypress spec.
47. New top-level sections on the dashboard that will be covered by E2E should add a `data-cy` at the section level.

---

## Known Gaps (not a fix list — awareness only)

48. **`orders.total / 100` divide bug** — every dollar-stored order is displayed at 1%. Cross-domain with bulletproof-payments.
49. **`scan_logs` in realtime table list triggers revenue refetch** — wasteful, should be removed or narrowed (#23).
50. **Stale `tickets.event_name` breaks Top Event after rename** — cross-domain with bulletproof-events.
51. **No realtime health indicator** — `isLive` tracked but not shown to owner.
52. **Dead `navigationItems` in OwnerDashboard.tsx** — computed then not rendered (#43).
53. **`fetchTicketsData()` has no date window or LIMIT** — will OOM the client around 10k+ tickets. Scale-check mode catches this.
54. **`events.metadata.location` is the source for "location" on UpcomingEventsCard** — fragile; `events.venue_name` exists and should be preferred.
55. **PromoterDashboard.tsx exists but is not covered here yet** — if PromoterDashboard drifts from the shell rules (own background color, own card radius), flag as a future audit scope expansion.
