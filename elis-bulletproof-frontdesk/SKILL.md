---
name: elis-bulletproof-frontdesk
description: Audit, diagnose, or scale-check the Eli's Dulce Tradicion Front Desk / Kitchen Display system (src/pages/FrontDesk.tsx 5-tab layout, src/components/kitchen/* including KitchenRedesignedLayout / ModernOrderCard / BakerTicketCard / WalkInOrderModal / NotificationPanel / DeliveryManagementPanel / FrontDeskInventory / UrgentOrdersBanner / FullScreenOrderAlert, realtime subscription via useOrdersFeed + useRealtimeOrders + useOptimizedRealtime, transition_order_status RPC from orders.ts, auto-confirm settings from business_settings, calendar view, walk-in order creation, order status state machine, ticket printing via PrintPreviewModal). Complement to elis-bulletproof-orders (upstream) and elis-bulletproof-dashboard (owner view). Use when new orders don't appear at the kitchen, status transitions fail or double-fire, auto-confirm misfires, walk-in creation breaks, calendar shows wrong times, the tablet goes offline, or before a holiday rush. Read-only SQL via mcp__supabase__execute_sql (project rnszrscxwkdwvvlsihqc). Never writes to production DB. Never modifies application code without explicit user approval.
---

# Eli's Bulletproof Front Desk

The Front Desk is the tablet in the kitchen. It is ALWAYS on, ALWAYS logged in, ALWAYS showing incoming orders. If the realtime subscription drops silently, the baker keeps glancing at a stale screen and a decorated cake sits in the fridge past pickup time. Every check below exists because at a real bakery, "we didn't see the order" is the #1 cause of angry customers.

This skill covers:
- `src/pages/FrontDesk.tsx` — shell, tab routing, role gate, auto-confirm toggle
- `src/components/kitchen/KitchenRedesignedLayout.tsx` — the 5-column kanban
- `src/components/kitchen/ModernOrderCard.tsx` — ticket rendering (30KB, complex)
- `src/components/kitchen/BakerTicket.tsx` + `BakerTicketCard.tsx` + `BakerWorkCard.tsx` — baker-facing card variants
- `src/components/kitchen/WalkInOrderModal.tsx` — new walk-in order
- `src/components/kitchen/NotificationPanel.tsx` — alert feed
- `src/components/kitchen/DeliveryManagementPanel.tsx` — assign + track delivery
- `src/components/kitchen/FrontDeskInventory.tsx` — live inventory panel
- `src/components/kitchen/UrgentOrdersBanner.tsx` — top-of-screen urgency bar
- `src/components/kitchen/FullScreenOrderAlert.tsx` — new-order splash
- `src/components/print/PrintPreviewModal.tsx` — ticket printing
- `src/hooks/useOrdersFeed.ts` — batched order stream
- `src/hooks/useRealtimeOrders.ts` — Supabase channel subscription
- `src/hooks/useOptimizedRealtime.ts` — batching + throttling layer
- Tables: `orders`, `order_status_history`, `business_settings`, `business_hours`
- RPC: `transition_order_status` (migration `20260206_order_status_transition_rpc.sql`)
- Settings migrations: `20260402_add_max_daily_capacity.sql`, `20260414_add_auto_confirm_settings.sql`, `20260414_add_estimated_ready_at.sql`

**Not covered here:**
- Order creation wizard → `elis-bulletproof-orders`
- Payment webhook flipping status to paid → `elis-bulletproof-payments`
- Owner-side reporting of kitchen throughput → `elis-bulletproof-dashboard`
- Ingredient deduction on status change → `elis-bulletproof-inventory`
- Status-change email → `elis-bulletproof-emails`

---

## Status State Machine (the contract)

```
pending → confirmed → in_progress → ready → out_for_delivery → delivered → completed
                                        ↘ (pickup) → completed
  ↘ cancelled  (from any non-terminal state)
```

`transition_order_status` RPC enforces this. If the UI tries an illegal transition, the RPC should reject. Any status value in the DB outside this set is a red flag.

---

## Mandatory Preflight

1. `/Users/luismiguel/Desktop/elis-dulce-tradicion/CLAUDE.md` — Known Issues: "Calendar view not rendered", "Walk-in order creation not yet built", "Auto-confirm setting" (new addition).
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-elis-dulce-tradicion/memory/MEMORY.md` — FrontDesk uses `isDarkMode` state (not CSS class); `'baker'` role internal, "Front Desk" user-facing; `useInactivityTimeout` was removed.
3. Supabase project `rnszrscxwkdwvvlsihqc`.
4. State: "Preflight complete. Running [mode]."

---

## Choose a Mode

- **audit** — weekly + after any realtime-related refactor
- **diagnose** — baker reports a specific symptom
- **scale-check** — holiday week / new feature on the tablet

---

## Mode: audit

### Code-level invariants

1. **Realtime subscription handles all four lifecycle states.**
   - Supabase channel callbacks: `SUBSCRIBED`, `TIMED_OUT`, `CLOSED`, `CHANNEL_ERROR`.
   - Silent failure = kitchen staff staring at a stuck screen.
   - Grep: `grep -n "SUBSCRIBED\|TIMED_OUT\|CLOSED\|CHANNEL_ERROR\|status" src/hooks/useRealtimeOrders.ts src/hooks/useOptimizedRealtime.ts src/hooks/useOrdersFeed.ts`
   - Expected: on `TIMED_OUT` or `CLOSED`, the hook re-subscribes with backoff and surfaces a visible banner.

2. **Heartbeat / visible connection indicator.**
   - FrontDesk should show a green/red dot reflecting the realtime connection state.
   - Grep: `grep -rn "isConnected\|isConnecting\|connectionStatus" src/components/kitchen/ src/pages/FrontDesk.tsx`

3. **Polling fallback exists.**
   - If realtime drops, a 30-60s polling fallback keeps the list fresh.
   - Grep: `grep -n "setInterval\|poll\|refetchInterval" src/hooks/useRealtimeOrders.ts src/hooks/useOrdersFeed.ts src/pages/FrontDesk.tsx`

4. **`orders` is in the realtime publication.**
   ```sql
   SELECT schemaname, tablename FROM pg_publication_tables
   WHERE pubname='supabase_realtime' AND tablename='orders';
   ```
   If empty, every INSERT/UPDATE silently fails to propagate — audit FAIL.

5. **Only legal status transitions are called.**
   - Every `transition_order_status({p_order_id, p_new_status})` call matches the state machine above.
   - Grep: `grep -rn "transition_order_status\|p_new_status" src/`
   - Walk through each call site: what's the source state? Is the target legal?

6. **Optimistic UI reverts on RPC failure.**
   - If the baker taps "Mark Ready" and the RPC rejects (race with another device), UI must revert and show an error toast.
   - Grep: `grep -n "onError\|rollback\|invalidateQueries" src/hooks/useRealtimeOrders.ts src/components/kitchen/*.tsx`

7. **Auto-confirm honors the toggle and the delay.**
   - `business_settings.auto_confirm_enabled` + `auto_confirm_prep_minutes` (migration `20260414_add_auto_confirm_settings.sql`).
   - Auto-confirm should NOT fire while the toggle is off. It should NOT fire immediately — must respect the configured delay.
   - Grep: `grep -rn "auto_confirm_enabled\|auto_confirm_prep_minutes\|autoConfirm" src/pages/FrontDesk.tsx supabase/functions/scheduled-order-transitions/`

8. **`scheduled-order-transitions` Edge Function is the auto-confirm worker.**
   - Cron job (migration `20240205_cron_schedule_reports.sql` or its descendant) invokes this.
   - It should: select eligible orders (status='pending' AND created_at + prep_minutes <= now()), call `transition_order_status`, log to `order_status_history`.
   - Grep: `grep -n "select\|transition_order_status\|auto" supabase/functions/scheduled-order-transitions/index.ts`

9. **Calendar view uses business_hours and pickup_date.**
   - `src/components/dashboard/OrderCalendarView.tsx` or similar — renders scheduled orders on a grid.
   - CLAUDE.md flags "Calendar view not rendered" as a known issue. Confirm current state.
   - Grep: `grep -rn "OrderCalendarView\|OrderScheduler" src/pages/FrontDesk.tsx`

10. **Max daily capacity fallback is NOT hardcoded to 10 silently.**
    - `FrontDesk.tsx` line ~65 reads `businessSettings?.max_daily_capacity || 10`. If `business_settings` is empty, the visible capacity defaults to 10.
    - Either (a) business_settings must be seeded in prod (audit query #6), or (b) the fallback should be `null` with a visible "not configured" banner.

11. **Walk-in order modal completes the full creation path.**
    - `WalkInOrderModal.tsx` should call the same `create_new_order` RPC as the customer wizard. No sideways DB insert bypassing server-side pricing/capacity.
    - Grep: `grep -n "create_new_order\|insert.*orders" src/components/kitchen/WalkInOrderModal.tsx`
    - CLAUDE.md flags walk-in as "just built" — verify end-to-end.

12. **`useInactivityTimeout` is NOT re-added.**
    - MEMORY.md records it caused session instability and was removed. Grep: `grep -rn "useInactivityTimeout" src/pages/FrontDesk.tsx src/components/kitchen/` → should return nothing (or only a comment explaining why it's gone).

13. **`isDarkMode` state is wired to Tailwind `dark:` variants.**
    - MEMORY.md: FrontDesk uses `isDarkMode` state, not a CSS class toggle. Children need `className={isDarkMode ? 'dark' : ''}` wrapper for `dark:` variants to apply.
    - Grep: `grep -n "isDarkMode" src/pages/FrontDesk.tsx`

14. **FrontDeskInventory uses its own realtime channel.**
    - Line 74 confirmed: `supabase.channel('inventory-health-monitor')`. That's a separate channel from orders — if channel multiplexing is wrong, either can break.

15. **Ticket printing renders all required fields.**
    - `PrintPreviewModal.tsx` should include: order_number, customer_name, customer_phone, pickup_date/time, cake_size, bread_type, filling, premium_fillings, custom_message (including allergies if captured there), delivery vs pickup, delivery address.
    - Grep: `grep -n "custom_message\|delivery_address\|pickup_date" src/components/print/PrintPreviewModal.tsx`

### Data-level invariants

```sql
-- F1. Orders stuck in pending past their pickup time
SELECT id, order_number, pickup_date, pickup_time, status, payment_status, created_at
FROM orders
WHERE status = 'pending'
  AND payment_status = 'paid'
  AND (pickup_date + pickup_time::time) < now() - interval '2 hours';

-- F2. Orders in in_progress for absurdly long (likely forgotten)
SELECT id, order_number, status, updated_at
FROM orders
WHERE status = 'in_progress'
  AND updated_at < now() - interval '8 hours';

-- F3. Illegal status values (pattern drift)
SELECT DISTINCT status FROM orders;

-- F4. Status history with impossible transitions (confirm RPC guard works)
WITH t AS (
  SELECT order_id, status, created_at,
         LAG(status) OVER (PARTITION BY order_id ORDER BY created_at) AS prev_status
  FROM order_status_history
)
SELECT * FROM t
WHERE prev_status = 'cancelled' AND status NOT IN ('cancelled')
   OR prev_status = 'completed' AND status NOT IN ('completed')
   OR prev_status = 'delivered' AND status NOT IN ('delivered', 'completed');

-- F5. Auto-confirm misfire check — orders that auto-confirmed before prep delay
SELECT o.id, o.order_number, o.created_at,
       h.created_at AS confirmed_at,
       EXTRACT(EPOCH FROM (h.created_at - o.created_at))/60 AS minutes_to_confirm
FROM orders o
JOIN order_status_history h ON h.order_id = o.id AND h.status = 'confirmed'
WHERE o.created_at > now() - interval '7 days'
  AND EXTRACT(EPOCH FROM (h.created_at - o.created_at))/60 < 0.5;  -- confirmed in <30s = suspicious

-- F6. business_settings sanity
SELECT max_daily_capacity, auto_confirm_enabled, auto_confirm_prep_minutes,
       minimum_lead_time_hours, maximum_advance_days, session_timeout_minutes
FROM business_settings LIMIT 5;
-- Expect exactly 1 row with sensible non-null values.

-- F7. business_hours sanity
SELECT day_of_week, is_open, open_time, close_time FROM business_hours ORDER BY day_of_week;
-- Expect 7 rows (0-6). No duplicates. For open days, open < close.

-- F8. Orders with estimated_ready_at far in the past (migration 20260414 added this)
SELECT id, order_number, status, estimated_ready_at
FROM orders
WHERE estimated_ready_at IS NOT NULL
  AND estimated_ready_at < now() - interval '12 hours'
  AND status NOT IN ('delivered', 'completed', 'cancelled');
```

### Audit output template

```
## Front Desk Audit — [YYYY-MM-DD]

### Code-level
- [PASS/FAIL] Realtime lifecycle states handled
- [PASS/FAIL] Connection indicator visible
- [PASS/FAIL] Polling fallback exists
- [PASS/FAIL] orders table in supabase_realtime publication
- [PASS/FAIL] All transition calls use legal states
- [PASS/FAIL] Optimistic UI reverts on failure
- [PASS/FAIL] Auto-confirm respects toggle + delay
- [PASS/FAIL] scheduled-order-transitions handles auto-confirm
- [PASS/FAIL / GAP] Calendar view rendered
- [PASS/FAIL] max_daily_capacity fallback not silently 10
- [PASS/FAIL] Walk-in modal uses create_new_order RPC
- [PASS] useInactivityTimeout absent
- [PASS/FAIL] isDarkMode wrapper applied
- [PASS/FAIL] Inventory channel separate
- [PASS/FAIL] Print preview includes all fields

### Data-level
- F1 stuck-past-pickup: X (target: 0)
- F2 in_progress >8h: X
- F3 status value set: [list — expect only legal values]
- F4 illegal transitions in history: X (target: 0)
- F5 suspicious fast auto-confirms: X
- F6 business_settings rows: X (expect: 1)
- F7 business_hours rows: X (expect: 7, no dup days)
- F8 stale estimated_ready_at: X

### Red flags
[Items > 0 on F1/F4/F5]
```

---

## Mode: diagnose

### Step 1 — Ask
- What's on the baker's screen? ("no orders showing" / "orders not updating" / "can't mark ready" / "walk-in won't save")
- Time of last known good state.
- Browser refresh tried? If yes, did orders re-appear?

### Step 2 — Symptom matrix

| Symptom | Likely cause | Next check |
|---|---|---|
| "No new orders appearing" | Realtime channel CLOSED without reconnect; OR orders table not in supabase_realtime publication; OR RLS blocking baker role | Audit invariant #1, #4 |
| "Orders list is empty but I know there's an order" | RLS denies baker; OR the query filters by a column the baker's JWT doesn't include | Inspect RLS on orders for baker role |
| "Tapped 'Start' and it bounced back" | RPC rejected illegal transition; OR stale cached state | Read last row in order_status_history for that order |
| "Two bakers tapped and it double-fired" | Optimistic UI didn't dedupe; OR the RPC isn't atomic | Audit invariant #6; inspect RPC body |
| "Walk-in order saved but doesn't show in list" | Walk-in path inserted directly instead of using create_new_order → payment_status stays NULL → filter hides it | Audit invariant #11 |
| "Auto-confirm fires too fast / not at all" | business_settings toggle / delay misconfigured OR cron not running | Query F6; supabase functions logs scheduled-order-transitions |
| "Calendar shows wrong hours" | business_hours empty or day_of_week mismatch (0=Sunday vs 0=Monday) | Query F7 |
| "Tablet went to login screen on its own" | useInactivityTimeout snuck back in OR Supabase session expired | Audit invariant #12; check Supabase auth settings session TTL |
| "Dark mode doesn't apply to all cards" | isDarkMode wrapper missing on child container | Audit invariant #13 |

### Step 3 — Three-file rule
Read the three likeliest files. Hold off on wider grepping unless ruled out.

### Step 4 — Report
Root cause + proposed fix. Do not edit without approval.

---

## Mode: scale-check

Before a holiday week:

1. **Realtime scalability.** With one table (`orders`) in postgres_changes, every INSERT fires a RLS check per subscriber. At Eli's volume (1 owner + 1-2 bakers + a handful of staff tablets), this is fine. But note that as you add the customer-facing tracking realtime subscription, each customer on `/order-tracking` adds a subscriber to the same table. If that ever goes >50 simultaneous, migrate to broadcast.
2. **Channel leak check.** If a component un-mounts without `supabase.removeChannel(channel)`, the channel pool grows unbounded. Grep: `grep -rn "removeChannel\|useEffect.*channel" src/hooks/ src/components/kitchen/`
3. **Tablet OS awake.** Safari/Chrome suspend websockets on background tabs. The tablet should stay foreground. If it doesn't, consider adding a visibility change listener that re-establishes on focus.
4. **Printer readiness.** If ticket printing is relied upon, confirm browser print dialog still works cross-browser. Print is NOT reliable over ngrok / local tunneled previews.
5. **Inventory deduction latency.** When status → in_progress, `deductInventoryForOrder` fires. Under a sudden burst (10 orders all confirmed at once), is the deduction serialized or parallel? See `elis-bulletproof-inventory`.
6. **Session stability.** MEMORY.md: `useInactivityTimeout` was removed for this reason. Supabase JWT default TTL is 1 hour with silent refresh. Confirm refresh actually works by leaving the tablet idle overnight and checking in the morning.

### Output
```
## Front Desk Scale Readiness — Window: [dates]

- orders in supabase_realtime publication: Y/N
- Subscriber count projection: X (kitchen devices) + Y (customer tracking)
- Channel cleanup verified: Y/N
- Print path verified on target printer: Y/N
- business_settings + business_hours seeded: Y/N
- Tablet wake/sleep behavior tested: Y/N

Verdict: [READY / NOT READY — blocker list]
```

---

## Critical Flow: paid order arrives in the kitchen

1. Customer completes payment → stripe-webhook flips `orders.payment_status='paid'`
2. `useRealtimeOrders` receives an UPDATE event (or INSERT if walk-in) → pushes into local state
3. `useOrdersFeed` debounces → renders in the Pending column
4. `UrgentOrdersBanner` shows if pickup time is within urgency window
5. `FullScreenOrderAlert` pops up with sound (per business_settings)
6. Baker taps "Confirm" → optimistic UI → calls `transition_order_status(order_id, 'confirmed')`
7. RPC writes `orders.status='confirmed'` + inserts `order_status_history` row
8. Realtime UPDATE → card moves to Confirmed column on ALL connected devices
9. Baker taps "Start" → status='in_progress' → inventory deduction fires
10. Baker taps "Ready" → status='ready' → `send-ready-notification` email fires
11. If delivery: DeliveryManagementPanel assigns → status='out_for_delivery' → status='delivered'
12. If pickup: customer picks up → status='completed'

## Critical Flow: walk-in at the counter

1. Staff taps "+" / "Walk-in" → `WalkInOrderModal` opens
2. Fills cake specs + customer contact + payment (cash/card at register)
3. Modal calls `create_new_order` RPC → returns order_number
4. Prints ticket via `PrintPreviewModal`
5. Order appears in Pending column (same path as customer order, but `payment_status` may be set to 'paid' if cash taken OR 'pending' if card will be run separately)

---

## HARD RULES

- **NEVER write to the production DB.** Read-only via `mcp__supabase__execute_sql` project `rnszrscxwkdwvvlsihqc`.
- **NEVER re-add `useInactivityTimeout`** without a plan for session refresh. MEMORY.md flagged it as session-breaking.
- **NEVER insert `orders` rows directly** from the walk-in modal — always through `create_new_order` so capacity / pricing / idempotency apply.
- **NEVER disable realtime** "to test" without re-enabling. Leaving the kitchen without realtime = immediate revenue loss.
- **NEVER loosen orders RLS** to make a query work — verify the baker role JWT is what's expected.
- **NEVER mutate `order_status_history`** — it is the audit trail.
- **Scope:** if a fix touches payments, emails, or inventory, hand off to the matching skill.
