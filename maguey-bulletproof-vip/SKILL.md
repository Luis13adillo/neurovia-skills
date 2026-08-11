---
name: maguey-bulletproof-vip
description: Audit, diagnose, or scale-check the Maguey Nightclub VIP booking system (event_vip_tables, vip_reservations, vip_guest_passes, vip_scan_logs, vip_linked_tickets, vip_bottle_config, VIPBookingForm 1335 lines, VIPFloorPlanAdmin @dnd-kit, atomic RPCs, unified GA+VIP checkout, re-entry logic, guest list invite codes). Use when a VIP booking fails, a table double-books, guest passes don't arrive, a guest can't re-enter, or before a major event with heavy VIP volume. Read-only SQL via mcp__supabase__execute_sql only. Never writes to production DB — VIP bookings carry the highest per-transaction revenue.
---

# Maguey Bulletproof VIP

VIP is Maguey's highest-margin product. A lost VIP sale is a 5-10x loss compared to GA. A VIP arriving to a confused host is a bad review on Google that hurts for months.

This skill covers:
- `maguey-pass-lounge/src/pages/VIPBookingForm.tsx` (1,335 lines)
- `maguey-pass-lounge/src/pages/VipPayment.tsx` (legacy — prefer integrated flow)
- `maguey-pass-lounge/supabase/functions/create-vip-payment-intent/index.ts`
- `maguey-pass-lounge/supabase/functions/confirm-vip-payment/index.ts`
- `maguey-pass-lounge/src/lib/vip-tables-service.ts` (bottle catalog)
- `maguey-gate-scanner/src/lib/vip-tables-admin-service.ts`
- `maguey-gate-scanner/src/components/vip/` (9 components, incl. `VIPFloorPlanAdmin` with @dnd-kit)
- Tables: `event_vip_tables`, `vip_reservations`, `vip_guest_passes`, `vip_scan_logs`, `vip_linked_tickets`, `vip_table_bottle_config`, `vip_tables` (legacy), `event_vip_configs`, `vip_table_templates`
- RPCs: `create_vip_reservation_atomic`, `check_in_vip_guest_atomic`, `create_unified_vip_checkout`, `rollback_vip_checkout`, `process_vip_scan_with_reentry`, `check_vip_linked_ticket_reentry`, `create_vip_guest_list_rpc`, `add_vip_guest_list_rpc`, `sync_vip_table_availability`, `link_ticket_to_vip`, `validate_vip_status_transition`

**Not covered here:**
- Stripe webhook processing → `maguey-bulletproof-payments`
- Scanner-side VIP check-in (pass scanning UX) → `maguey-bulletproof-scanner`
- VIP confirmation email delivery → `maguey-bulletproof-email`

---

## Mandatory Preflight

1. `/Users/luismiguel/Desktop/Maguey-Nightclub-Live/CLAUDE.md` — "VIP System" feature list, atomic RPC list, constraints.
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-Maguey-Nightclub-Live/memory/MEMORY.md` — Feb 2026 security fixes (VIP price tampering closed, anon RLS removed, rollback RPC added).
3. This skill's `references/audit-queries.sql`, `references/invariants.md`, `references/incidents.md`.

Confirm "Preflight complete. Running [mode]." Then proceed.

Supabase: `mcp__supabase__execute_sql` (project `djbzjasdrwvbsoifxqzd`). Read-only.

---

## Choose a Mode

- **audit** → full health check (weekly + before every event with VIP tables)
- **diagnose** → VIP symptom reported
- **scale-check** → before a big event (>20 VIP tables, high bottle-service revenue)

---

## Mode: audit

### Code-level invariants

1. **VIP price from DB only**
   - `create-vip-payment-intent/index.ts` line ~154-161: reads `table.price_cents` from DB.
   - Package snapshot built server-side (line ~167-178) — never accepts client-sent price.
   - Grep: `grep -n "table.price_cents\|clientPrice\|p_price_cents" create-vip-payment-intent/index.ts`
   - Regression indicator: code accepting `priceCents` from the request body.

2. **Ownership check on confirm**
   - `confirm-vip-payment/index.ts` line ~69-96: verifies `purchaser_email` matches the requesting user.
   - Grep: `grep -n "purchaser_email\|eq.*purchaser_email" confirm-vip-payment/index.ts`
   - Without this, Customer A can confirm Customer B's PI.

3. **Rate limiting on VIP endpoints**
   - Both `create-vip-payment-intent` and `confirm-vip-payment` call `checkRateLimit(req, 'payment')` at line ~15.

4. **Atomic reservation creation**
   - `create_vip_reservation_atomic` RPC must be called, not separate INSERTs.
   - RPC uses `FOR UPDATE` on `event_vip_tables` row to prevent double-booking under concurrency.
   - Generates `invite_code` inside the same transaction (migration `20260408010000`).

5. **Rollback on PI creation failure**
   - `create-vip-payment-intent/index.ts` line ~234: catches exception, calls `rollback_vip_checkout` RPC.
   - Rollback cleans up: VIP reservation row, any orphan GA ticket, restores `event_vip_tables.is_available`.

6. **Status transition validation**
   - Migration has `validate_vip_status_transition()` trigger on `vip_reservations`.
   - Valid: pending → confirmed → checked_in → completed, plus pending → cancelled.
   - Invalid state jumps rejected.

7. **VIP guest pass has QR signature**
   - `vip_guest_passes.qr_signature` populated for confirmed reservations.
   - Signing via `sign_qr_token` (same as GA tickets).

8. **VIP floor plan drag-drop persists server-side**
   - `VIPFloorPlanAdmin.tsx` uses `@dnd-kit/core`
   - On drop, updates `event_vip_tables.display_order` (or `position_x`/`position_y` fields)
   - Optimistic UI update + debounced Supabase sync

9. **Linked tickets constraint**
   - `vip_linked_tickets` has UNIQUE on `ticket_id` (one ticket can link to at most one VIP reservation).

10. **No client-side bottle price arithmetic**
    - Bottle catalog (`BOTTLE_CATALOG` in `vip-tables-service.ts`) only holds display names + IDs.
    - Prices are not on client-side bottle catalog — server resolves from `vip_table_bottle_config`.

### Data-level invariants

Run `references/audit-queries.sql`. Expected: 0 rows unless noted.

### Audit output template

```
## VIP Audit Report — [YYYY-MM-DD]

### Code-level
- [PASS/FAIL] VIP price fetched from DB (not client)
- [PASS/FAIL] Ownership check on confirm-vip-payment
- [PASS/FAIL] Rate limiting on both VIP Edge Functions
- [PASS/FAIL] Atomic reservation creation with FOR UPDATE
- [PASS/FAIL] Rollback RPC on PI creation failure
- [PASS/FAIL] Status transition validator active
- [PASS/FAIL] QR signature populated on guest passes
- [PASS/FAIL] Floor plan persistence
- [PASS/FAIL] UNIQUE(ticket_id) on vip_linked_tickets
- [PASS/FAIL] No client-side bottle pricing

### Data-level
- [PASS/FAIL] No confirmed reservations without Stripe PI id (query #1)
- [PASS/FAIL] No reservations stuck pending >2h (query #2)
- [PASS/FAIL] No table double-booked for same event (query #3)
- [PASS/FAIL] No confirmed reservation without guest passes (query #4)
- [PASS/FAIL] No orphan guest passes without reservation (query #5)
- [PASS/FAIL] No duplicate linked_ticket rows (query #6)
- [PASS/FAIL] checked_in_guests never > reservation.guest_count (query #7)
- [PASS/FAIL] is_available correctly reflects reservation state (query #8)
- [PASS/FAIL] No guest_passes with NULL qr_signature on confirmed reservation (query #9)
- [PASS/FAIL] No scan_logs for non-existent passes (query #10)

### Failures
[List with file/line or SQL rows. Report only. Do not fix in audit mode.]
```

---

## Mode: diagnose

### Step 1: Ask
- Event date, purchaser email, reservation ID, table number.
- What did customer see? At which step? (booking form / payment / confirmation / re-entry at door)
- Stripe Dashboard: does the PI show succeeded?
- Did they get the invite code email?

### Step 2: Simple checks
- `SELECT * FROM vip_reservations WHERE purchaser_email = '...' ORDER BY created_at DESC LIMIT 3;`
- Status? `stripe_payment_intent_id` populated? `invite_code` populated?
- Corresponding `vip_guest_passes` rows? Expected count = `guest_count`.
- `event_vip_tables.is_available` flipped?

### Step 3: Match against incidents
See `references/incidents.md`. Key categories:
- **"Two parties booked same table"** → atomic RPC bypassed or FOR UPDATE lock missing
- **"Paid but no invite code"** → `create_vip_reservation_atomic` succeeded but email never sent (escalate to email skill)
- **"Guest can't re-enter"** → `check_vip_linked_ticket_reentry` not returning allow_reentry=true; missing `vip_linked_tickets` row
- **"Floor plan drag saves wrong position"** → optimistic update failed, server state reverted
- **"Orphan reservation after failed payment"** → rollback RPC didn't fire; manual cleanup needed

### Step 4-6: 3-file rule, Two-strike rule, Stay in scope — same as other skills.

---

## Mode: scale-check

Before a high-VIP event (New Year's, Valentine's, major DJ):

### 1. Table capacity vs projected demand
- Count `event_vip_tables` for the event vs expected VIP sales
- Flag if >90% pre-booked — launch day concurrency risk

### 2. FOR UPDATE lock behavior
- `create_vip_reservation_atomic` uses row lock. Under extreme concurrency (50+ people trying to book same VIP table at midnight drop):
  - Test the RPC with `pgbench` or Supabase concurrency tests
  - Verify `is_available` update is inside the locked section
- Flag: any code path that reads `event_vip_tables.is_available` without locking, then conditionally inserts

### 3. Invite code generation speed
- Invite code uses UUID/random. Generation is fast; should not be a bottleneck.
- Verify uniqueness constraint exists (check migration).

### 4. Guest list scale
- `create_vip_guest_list_rpc` / `add_vip_guest_list_rpc` — for large parties (20-50 guests), does it handle bulk insert efficiently?
- Guest pass generation: 1 QR per guest = 50 HMAC operations. Should be <1s for the batch.

### 5. Floor plan rendering
- `VIPFloorPlanAdmin` with 50+ tables on drag-drop: performance concerns?
- React re-render on every drag move (dnd-kit default) → throttle if >30 tables.

### 6. Bottle config completeness
- For every `event_vip_tables` row, does `vip_table_bottle_config` exist?
- Missing config → UI shows "Bottle selection will be confirmed by your host" (fallback) — acceptable but signals incomplete setup.

### 7. Unified checkout path
- `create_unified_vip_checkout` RPC — combined GA + VIP transaction.
- Verify it still rolls back ATOMICALLY if either GA ticket generation or VIP reservation fails.

### Output

```
## VIP Scale Readiness — Event: [name], Date: [YYYY-MM-DD], VIP tables: [X]

### Capacity: [projected demand vs available]
### Concurrency: [atomic RPC lock verified]
### Invite code gen: [speed test]
### Guest list bulk: [passes capacity]
### Floor plan perf: [table count vs known threshold]
### Bottle config completeness: [X/Y tables have config]
### Unified checkout rollback: [verified]

### Verdict: [READY / NOT READY + must-fix list]
```

No writes in scale-check.

---

## Critical Flows

### FLOW A: Solo VIP booking (no GA ticket)
1. Customer browses `/vip` on pass-lounge → selects table
2. Fills VIPBookingForm (firstName, lastName, email, phone, guestCount, celebration, bottle prefs, special requests, agreedToTerms)
3. Client calls `createVipPaymentIntent` (Edge Function):
   a. Rate limit check
   b. Validate event + table available
   c. Fetch `table.price_cents` from DB
   d. Build package_snapshot (server-side prices)
   e. Call `create_vip_reservation_atomic` (FOR UPDATE on table, insert reservation, generate invite_code, QR tokens)
   f. Create Stripe PaymentIntent with metadata (reservationId, tableId, vipPriceCents)
   g. Link PI to reservation
   h. On exception → `rollback_vip_checkout` RPC
4. Stripe Elements confirms PI on client
5. Client calls `confirmVipPayment`:
   a. Rate limit check
   b. Verify PI status = succeeded
   c. Validate PI metadata matches reservation
   d. Update reservation status = confirmed (ownership check on email)
   e. Update `event_vip_tables.is_available = false`
6. Poll for invite_code (10 retries, 2s interval) — fallback UI if timeout
7. Webhook `payment_intent.succeeded` arrives (often parallel to step 5) — idempotently confirms, generates `vip_guest_passes`, enqueues email
8. Customer receives email with table info + guest passes (QR per guest)

### FLOW B: Unified VIP + GA checkout
- `create_unified_vip_checkout` RPC creates GA ticket + VIP reservation + links them (vip_linked_tickets)
- Purchaser has GA ticket that links to VIP table

### FLOW C: Guest list invite
- Purchaser shares invite_code with guests
- Each guest visits checkout URL with vip code param
- Guest buys own GA ticket, which links to the VIP reservation
- Guest gets their own `vip_guest_pass` (separate QR)

### FLOW D: VIP check-in at the door
1. Scanner reads QR (GA ticket OR guest pass)
2. For GA ticket with VIP link: calls `check_vip_linked_ticket_reentry(ticket_id)`
3. Returns: `is_vip_linked`, `allow_reentry`, `reservation_id`, `table_number`
4. Scanner shows VIP success overlay with table info
5. `process_vip_scan_with_reentry` RPC logs scan:
   - First entry: `scan_type = 'first_entry'`, increments `checked_in_guests`
   - Re-entry: `scan_type = 'reentry'`, no counter increment
6. `vip_scan_logs` row created for audit

---

## HARD RULES

- **NEVER write to prod DB.** Read-only via MCP.
- **NEVER modify atomic RPCs** (`create_vip_reservation_atomic`, `rollback_vip_checkout`, etc.) without user approval + pgbench concurrency test.
- **NEVER bypass ownership check** on `confirm-vip-payment`. Without it, an attacker with a PI id can confirm any reservation.
- **NEVER trust client-sent prices or bottle configs.** Always resolve server-side.
- **Branch workflow:** fix/... or feature/... branches; no direct-to-main for VIP changes.
- **User reports override queries.** Customer says "I was charged but table shows available" → check Stripe first, then check rollback RPC logs, then our DB.

---

## What to Return

- **audit** → pass/fail report + failures with row counts
- **diagnose** → single-file fix + repro, OR "need direction"
- **scale-check** → ready/not-ready checklist
