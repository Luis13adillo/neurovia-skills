# Dashboard — Known Incidents & Fix Patterns

---

## Incident: Recent Purchases show 1% of real dollar values

**Symptom:** In the "Recent Purchases" section of the owner dashboard, an order with a real charge of $295.83 renders as `$2.96`. Owner asks "why are my orders showing as pennies?"

**Root cause:** `OwnerDashboard.tsx:518` transforms order rows with:
```ts
total: Number(order.total || 0) / 100
```
But `orders.total` is stored in **dollars** (numeric), not cents. Verified via DB query 2026-04-21: `min=$25.00, max=$950.00, avg=$295.83` — all clearly dollar values.

**Historical context:** `maguey-pass-lounge`'s VIP flow uses cents (`price_cents`), but the main orders table inherited the dollar convention from the GA path. The `/100` in RecentPurchases looks like a paste-in from the VIP flow.

**Why this is a shell-layer bug (not payments):** the divide happens inside the dashboard component for display, not in the webhook that writes the row. The canonical `orders.total` is correct. The fix is in the dashboard file.

**Debug:**
```sql
SELECT id, purchaser_email, total, subtotal, fees_total
FROM orders
ORDER BY created_at DESC
LIMIT 5;
```
If these look like dollar amounts (25.00, 95.00, 295.83), the row is fine — the display is the bug.

**Fix (requires approval):** remove the `/ 100` on OwnerDashboard.tsx:518. One line change. But before shipping, cross-check with `maguey-bulletproof-payments` — confirm there isn't a payments-layer path that writes cents to the same column for some edge case (unified GA+VIP checkout?). If payments confirms orders.total is always dollars, fix in shell. If payments says "actually, unified checkout writes cents," the fix is a migration (normalize to dollars) + the display code.

---

## Incident: Sidebar shows owner-only section to a promoter

**Symptom:** A promoter logs in at `/auth/employee` or `/auth/owner`, sees TEAM or SETTINGS in the sidebar. Or MONITORING shows up in production.

**Root cause options:**
1. A new section was added to `OwnerPortalLayout.tsx:46-93` without `ownerOnly: true`.
2. An existing section had `ownerOnly` removed during a refactor.
3. The role claim in JWT is wrong — user is actually classed as "owner" even though they should be promoter (cross-domain with `maguey-bulletproof-auth`).

**Debug:**
```ts
// In browser console after login:
const { data: { session } } = await supabase.auth.getSession();
console.log(session?.user?.user_metadata?.role);
// Should be 'promoter' for a promoter user.
```
Then walk `OwnerPortalLayout.tsx:135-146`. The filter chain: devOnly → section ownerOnly → item ownerOnly/promoterOnly. Each step should narrow the list.

**Fix:** restore `ownerOnly: true` on the offending section, OR fix the role claim via auth skill. Match the root cause — don't patch the sidebar if the JWT is genuinely labeled "owner".

---

## Incident: Dashboard stops auto-updating after purchases come in

**Symptom:** Owner buys a ticket in a test tab. Dashboard tab does NOT refresh. Revenue tile stays at yesterday's number.

**Root cause options:**
1. Supabase Realtime publication doesn't include the relevant table (e.g., `tickets` isn't in `supabase_realtime`).
2. The tab was backgrounded long enough that the Supabase client dropped the socket. `useDashboardRealtime` reconnects on `visibilitychange`, but if the tab never becomes hidden+visible again, the socket stays dead.
3. The `useDashboardRealtime` channel was removed by a re-subscription that's looping (if you see channels closing and reopening in the network panel, this is it).

**Debug:**
```sql
-- Is the table in the publication?
SELECT tablename FROM pg_publication_tables
WHERE pubname='supabase_realtime' AND tablename='tickets';
```
Browser: open dev tools → Network → WS. Look for `realtime/v1/websocket`. If it's disconnected, `isLive` is false. The dashboard doesn't render `isLive` anywhere visible — add a `console.log(isLive, lastUpdate)` in OwnerDashboard to confirm.

**Fix:**
- If the publication is missing: cross-domain with `maguey-bulletproof-sync`. Don't fix from here.
- If the socket drops on long idle: add a 60s heartbeat ping to the hook, OR add a periodic full-refresh fallback (e.g., every 5 minutes regardless of realtime state).
- If the channel is thrashing: check `setupSubscription` effect deps — if `tables` is rebuilt on every render, the channel re-subscribes forever.

---

## Incident: Top Performing Event shows an old event name

**Symptom:** Owner renamed an event from "Saturday Night Fiesta" to "Summer Launch Party". Tickets still say "Saturday Night Fiesta" in the Top Event tile.

**Root cause:** `ticketsByEvent` map is keyed on `ticket.event_name` (denormalized text column on `tickets`). Historical tickets carry the OLD name; new tickets carry the NEW name. The top-count ends up on whichever name wins.

**Why this is cross-domain:** the shell renders what it's given. The denormalization is a choice made at ticket-issue time. Coordinate with `maguey-bulletproof-events` + `maguey-bulletproof-tickets`.

**Debug:**
```sql
SELECT DISTINCT event_name, COUNT(*) AS tickets
FROM tickets
WHERE event_name ILIKE 'saturday%' OR event_name ILIKE 'summer%'
GROUP BY event_name;
```

**Fix (requires approval):** either (a) change the dashboard query to JOIN on events.name via event_id (canonical source), or (b) backfill historical tickets.event_name rows on event rename. Option (a) is cheaper and better — the dashboard already has event_id on tickets. Flag as a cross-domain refactor.

---

## Incident: Active Events count is wrong by 1+

**Symptom:** Sidebar says "3 Active Events" but the owner just archived one and expects 2.

**Root cause options:**
1. `stats.activeEvents` uses `events.is_active=true AND event_date >= now()`. If the archived event still has `is_active=true`, it still counts. Archive flow must flip `is_active=false`.
2. Client cached stale state — Realtime update on events table should fire `fetchUpcomingEvents`, but that doesn't refresh the `stats.activeEvents` count. Look at `fetchRevenueAndStats` which has its own `activeEvents` count query.
3. Timezone: `event_date` is a date (no time). `new Date().toISOString()` includes time. Comparing a date to a timestamp, Postgres coerces — usually correct, but worth a sanity check.

**Debug:**
```sql
SELECT id, name, event_date, is_active, status
FROM events
WHERE is_active = true
  AND event_date >= current_date
ORDER BY event_date;
-- count this list by hand, compare to dashboard tile.
```

**Fix:** if archive flow forgot to flip is_active, that's an events-skill bug. If the dashboard just has stale state, add events to `useDashboardRealtime` callbacks — actually already is (line 681 maps events to fetchUpcomingEvents) but NOT to fetchRevenueAndStats. Adding the events callback to fetchRevenueAndStats would fix this.

---

## Incident: scan_logs INSERT triggers dashboard-wide revenue refetch

**Symptom (internal — not owner-facing):** Browser perf panel shows a flood of `tickets` SELECTs during a scan burst, even though scans don't change revenue.

**Root cause:** `OwnerDashboard.tsx:678` maps `scan_logs` realtime to `fetchRevenueAndStats`. Scans don't change revenue (revenue is at purchase, not scan), so this is wasted work.

**Fix (low-risk):** change the `onTableUpdate.scan_logs` callback to refresh CheckInProgress only (or drop it — CheckInProgress has its own scan_logs subscription). Zero behavioral change for the owner; fewer queries under load.

---

## Incident: Email Delivery widget says "0 delivered" but emails are landing

**Symptom:** Customer reports receiving ticket confirmation email. Dashboard Email Delivery widget says 0 delivered.

**Root cause options:**
1. The `related_id` on the email_queue row doesn't match the order/ticket the dashboard is looking up. The widget builds a Map of `related_id → status` (OwnerDashboard.tsx:232) — if `related_id` is NULL on new-format emails, the Map misses them.
2. The widget counts `emailStatusList` filtered by `status === 'delivered'`. If process-email-queue sets `status='sent'` instead of `'delivered'`, count is zero.
3. Resend webhook hasn't fired — the row went to 'sent' internally but 'delivered' requires the Resend callback. Cross-domain with `maguey-bulletproof-email`.

**Debug:**
```sql
SELECT status, COUNT(*) FROM email_queue
WHERE created_at > now() - interval '24 hours'
GROUP BY status;
```
If 'sent' is non-zero but 'delivered' is zero, the resend-webhook hasn't fired for these. Hand off to email skill.

---

## Incident: "% Sold" on Upcoming Events is wildly off

**Symptom:** Owner sees "45% sold" on an event that is actually 2/500 tickets sold (0.4%).

**Root cause:** `fetchEventTicketTypes()` aliases `total_inventory AS capacity`. If all tiers have `total_inventory = NULL`, `capacityFromTiers` is 0, and the code falls through to hardcoded `capacity = 100` (OwnerDashboard.tsx:582). 2/100 = 2% — not 45%, so not this exact case. BUT if one tier has `total_inventory = 10` and another has NULL, sum is 10, and 2/10 = 20%.

**Why this is shell-layer:** the dashboard chose to fall back to 100 instead of "unknown". A better UX is to show "—%" when capacity isn't set.

**Fix (low-risk):** change the fallback from `100` to a sentinel, and render "—" in the UI when capacity is unknown. Also: audit-queries.sql query #6 flags events with NULL-inventory tiers — run it before a big event.

---

## Incident: New section rendered without OwnerPortalLayout looks broken

**Symptom:** Owner reports "the new Refunds page looks weird — no sidebar, different background".

**Root cause:** Developer didn't wrap the new page in `<OwnerPortalLayout>`. Easy to miss because the page renders content without errors.

**Fix:** wrap in `<OwnerPortalLayout title="Refunds">{content}</OwnerPortalLayout>`. Also run through `references/new-section-checklist.md` — sidebar entry, data-cy, role gating, theme tokens.

---

## Incident: dashboard `navigationItems` array is dead code

**Symptom (code-hygiene only — not owner-facing):** `OwnerDashboard.tsx:692-785` defines a 90-line array that is never rendered.

**Root cause:** The array was the main-area navigation grid before the sidebar took over. It was left behind in a refactor.

**Why flag it:** computing a 90-line array on every render is a small perf hit, and it confuses future maintainers. But it's not urgent. Mention in an audit report; don't fix unilaterally.

**Fix (requires approval):** delete the array and its `navigationItems` variable. Check that `NavigationGrid.tsx` isn't imported anywhere else before touching it.
