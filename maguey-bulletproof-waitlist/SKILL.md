---
name: maguey-bulletproof-waitlist
description: Audit, diagnose, or scale-check the Maguey Nightclub waitlist system — the demand-capture flow on sold-out events. Covers the customer-facing WaitlistForm on the purchase site (maguey-pass-lounge), the `waitlist` table + RLS in production, the owner-side WaitlistManagement page in maguey-gate-scanner, the auto-detection scan loop, the "tickets-available" notification email path through `email_queue` + Resend, and the order-saga `UpdateWaitlistStep` that flips entries to `converted` when a waitlisted customer pays. Use when waitlist signups don't appear in the dashboard, notification emails don't go out, conversion drops, duplicate waitlist entries appear, or before a sold-out event where you want to convert the queue at door-open. Read-only SQL via `mcp__supabase__execute_sql` only. Never writes to production DB.
---

# Maguey Bulletproof Waitlist

The waitlist is Maguey's recovery channel for sold-out events. It captures demand that would otherwise leak to competitors, and converts it the moment seats free up (cancellations, refunds, capacity bumps). Each missed conversion is direct lost revenue.

This skill covers:
- `maguey-pass-lounge/src/components/WaitlistForm.tsx` (customer signup form, mounted on sold-out events)
- `maguey-pass-lounge/src/lib/waitlist-service.ts` (purchase-site service: addToWaitlist, isOnWaitlist, getWaitlistPosition, autoConvertWaitlistEntry)
- `maguey-pass-lounge/src/pages/EventDetail.tsx` (mounting site for the form — fires when `eventSoldOut === true`)
- `maguey-pass-lounge/src/lib/sagas/order-saga.ts` `UpdateWaitlistStep` (idempotent conversion on paid order)
- `maguey-gate-scanner/src/pages/WaitlistManagement.tsx` (owner dashboard surface — KPIs, segment filters, manual notify, CSV export)
- `maguey-gate-scanner/src/lib/waitlist-service.ts` (owner-side service: getAllWaitlistEntries, updateWaitlistEntryStatus, autoDetectAndNotifyWaitlist, checkAndNotifyEventWaitlist, notifyWaitlistEntry)
- `maguey-pass-lounge/supabase/functions/process-email-queue/index.ts` (cron worker that dispatches the queued waitlist notification emails via Resend)
- Tables: `waitlist`, `email_queue` (used for waitlist_notification type), `events`, `ticket_types`, `tickets`, `orders`

**Status enum (CHECK-constrained — verified 2026-04-21):**
- `waiting`, `notified`, `converted`, `cancelled`. Adding values requires a migration.

**Email type used:**
- `waitlist_notification` — added to `email_queue.email_type` CHECK constraint via migration `20260421110004`. Owner notify button enqueues this type; the generic `process-email-queue` worker dispatches it.

**Not covered here:**
- Email worker, retry, Resend webhook, bounce tracking → `maguey-bulletproof-email`
- Stripe webhook firing the order-saga that flips converted → `maguey-bulletproof-payments`
- Inventory math that drives the "is the event sold out" gate → `maguey-bulletproof-tickets`

---

## Schema Reality Check (verified 2026-04-21 against live DB)

**`waitlist` real columns:** `id (uuid), event_id (uuid, FK events with ON DELETE CASCADE), event_name (text), ticket_type (text), customer_name (text), customer_email (text), customer_phone (text nullable), quantity (int CHECK > 0, default 1), status (text CHECK in waiting/notified/converted/cancelled, default 'waiting'), created_at (timestamptz), notified_at (timestamptz nullable), converted_at (timestamptz nullable), metadata (jsonb default '{}')`.

- **The waitlist references events both by `event_id` (FK) and `event_name` (text).** `event_name` is the field actually queried in the current code paths — the FK is for ON DELETE CASCADE cleanup. If an event is renamed, existing `waitlist.event_name` rows go stale; consider migrating to `event_id`-only joins long-term.
- Indexes: `(event_name, status, created_at)` for the auto-detect path, `(customer_email)` for dedupe.
- RLS: anon can INSERT (signup from unauthenticated purchase site), owner role can SELECT/UPDATE/DELETE all, service_role bypass.

**No other `waitlist_*` tables exist.** The `event_reminder_log` UNIQUE-style "soft idempotency" pattern is NOT used here — instead, the customer-side `isOnWaitlist()` check prevents duplicate signups in the same `(event_name, customer_email, status='waiting')` window.

**`email_queue.email_type` includes `waitlist_notification` (verified 2026-04-21).**

---

## Mandatory Preflight

1. `/Users/luismiguel/Desktop/Maguey-Nightclub-Live/CLAUDE.md` — note the dual-app split (purchase site = customer signup; scanner = owner management).
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-Maguey-Nightclub-Live/memory/MEMORY.md` — confirm the `waitlist` table migration is applied (it is, 2026-04-21).
3. This skill's `references/audit-queries.sql`, `references/invariants.md`, `references/incidents.md`.

**Re-verify schema before diagnosing:**
```sql
SELECT column_name, data_type FROM information_schema.columns
WHERE table_schema='public' AND table_name='waitlist'
ORDER BY ordinal_position;
-- Expected: id, event_id, event_name, ticket_type, customer_name, customer_email,
--           customer_phone, quantity, status, created_at, notified_at,
--           converted_at, metadata.

SELECT pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conname IN ('waitlist_status_check', 'waitlist_quantity_check');
-- Expected: status enum + quantity > 0.

SELECT pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conname = 'email_queue_email_type_check';
-- Must contain 'waitlist_notification'.
```

Confirm "Preflight complete. Running [mode]." Supabase: `mcp__supabase__execute_sql` project `djbzjasdrwvbsoifxqzd`.

---

## Choose a Mode

- **audit** → weekly + after each high-demand event
- **diagnose** → "I joined the waitlist but never got notified" report
- **scale-check** → before announcing a known-soldout headliner

---

## Mode: audit

### Code-level invariants

1. **Customer signup is the only public write path**
   - `WaitlistForm.tsx` is the only component that calls `addToWaitlist()`.
   - Mounted from `EventDetail.tsx` and gated by `eventSoldOut === true`.
   - Grep: `grep -rn "addToWaitlist\|<WaitlistForm" maguey-pass-lounge/src --include="*.tsx" --include="*.ts"`
   - Expect: imports in `WaitlistForm.tsx` only; usage in `EventDetail.tsx` only.

2. **isOnWaitlist dedupes signups**
   - `WaitlistForm.tsx` calls `isOnWaitlist(eventName, email)` BEFORE inserting.
   - Prevents the same customer from spamming the queue for one event.
   - Grep: `grep -n "isOnWaitlist" maguey-pass-lounge/src/components/WaitlistForm.tsx`

3. **Owner notify enqueues email + flips status atomically**
   - `notifyWaitlistEntry()` in `maguey-gate-scanner/src/lib/waitlist-service.ts` inserts into `email_queue` (type='waitlist_notification') THEN flips status to 'notified'.
   - If the email insert fails, the status flip does NOT happen (try/throw structure).
   - Grep: `grep -n "notifyWaitlistEntry\|waitlist_notification" maguey-gate-scanner/src/lib/waitlist-service.ts`

4. **Auto-detection respects available inventory**
   - `autoDetectAndNotifyWaitlist()` and `checkAndNotifyEventWaitlist()` only notify up to `availability.available` customers per ticket type.
   - Skips customers whose `quantity > remainingTickets`.
   - Reading from `ticket_types.total_inventory - count(tickets where status in ('issued','used','scanned'))`.
   - Grep: `grep -n "checkTicketTypeAvailability\|remainingTickets" maguey-gate-scanner/src/lib/waitlist-service.ts`

5. **Saga conversion is idempotent and non-critical**
   - `UpdateWaitlistStep` in `order-saga.ts` is `critical: false` — waitlist conversion failures don't roll back paid orders.
   - Calls `autoConvertWaitlistEntry()` which only updates rows in 'waiting' or 'notified' status (never re-flips a 'cancelled' or 'converted').
   - Grep: `grep -n "UpdateWaitlistStep\|autoConvertWaitlistEntry\|critical: false" maguey-pass-lounge/src/lib/sagas/order-saga.ts`

6. **RLS allows anon insert, owner read/write**
   - `waitlist` table has `Anon can join waitlist` (INSERT only), `Owners manage waitlist` (ALL), `Service role full access waitlist` (ALL).
   - Migration `20260421110001`. Verify policies still match.

7. **No client-side service-role usage**
   - WaitlistForm uses anon Supabase client. The owner page uses owner JWT.
   - Grep: `grep -rn "SUPABASE_SERVICE_ROLE\|service_role" maguey-pass-lounge/src maguey-gate-scanner/src --include="*.ts" --include="*.tsx"`
   - Expect: 0 matches in client code.

8. **CSV export is the only data egress**
   - `WaitlistManagement.tsx` `exportWaitlist` builds CSV in browser, blob-downloads. No third-party API call.

9. **Notification email template is branded + has CTA link**
   - `notifyWaitlistEntry()` html_body must include event name, ticket type, quantity, and a link to the purchase site event page (`VITE_PURCHASE_SITE_URL`).
   - Grep: `grep -n "VITE_PURCHASE_SITE_URL\|tickets.magueynightclub.com" maguey-gate-scanner/src/lib/waitlist-service.ts`

10. **Status enum migration locked**
    - Adding statuses (e.g. 'expired') requires a migration that updates the CHECK constraint AND the TypeScript union in both `waitlist-service.ts` files.
    - Grep: `grep -n "waiting.*notified.*converted.*cancelled\|status:.*waiting" maguey-pass-lounge/src/lib/waitlist-service.ts maguey-gate-scanner/src/lib/waitlist-service.ts`

### Data-level invariants

Run `references/audit-queries.sql`.

### Audit output template

```
## Waitlist Audit Report — [YYYY-MM-DD]

### Code-level
- [PASS/FAIL] Public write path is WaitlistForm only
- [PASS/FAIL] isOnWaitlist dedupe before insert
- [PASS/FAIL] notifyWaitlistEntry enqueues email + flips status atomically
- [PASS/FAIL] Auto-detect respects inventory
- [PASS/FAIL] UpdateWaitlistStep critical:false + idempotent
- [PASS/FAIL] RLS: anon insert, owner all, service_role all
- [PASS/FAIL] No service_role in client bundles
- [PASS/FAIL] CSV is the only data egress
- [PASS/FAIL] Notification template includes CTA link
- [PASS/FAIL] Status enum unchanged (4 values)

### Data-level
- [PASS/FAIL] No 'waiting' entries older than the event_date (query #1)
- [PASS/FAIL] No duplicate (event_name, customer_email, status='waiting') rows (query #2)
- [PASS/FAIL] No 'notified' entries without a corresponding email_queue row (query #3)
- [PASS/FAIL] Conversion lag P95 within target (query #4)
- [PASS/FAIL] No orphan entries pointing to deleted events (query #5)
- [PASS/FAIL] No 'converted' entries without a matching paid order (query #6)
- [PASS/FAIL] No quantity > available inventory (informational, query #7)

### Conversion funnel last 30 days
- Waiting:    [X]
- Notified:   [Y]  (notify rate Y/X = ?)
- Converted:  [Z]  (conversion rate Z/Y = ?)
- Cancelled:  [W]

### Failures
[List]
```

---

## Mode: diagnose

### Step 1: Ask
- Customer email?
- Which event?
- When did they sign up?
- Did they get the "you're on the waitlist" confirmation in the form?
- Did they later get the "tickets available" email?
- Did they end up buying?

### Step 2: Pull the customer's row
```sql
SELECT id, event_name, ticket_type, customer_name, customer_email, customer_phone,
       quantity, status, created_at, notified_at, converted_at, metadata
FROM waitlist
WHERE customer_email ILIKE '<email>'
ORDER BY created_at DESC;
```

### Step 3: Pull the email send (if status >= 'notified')
```sql
SELECT eq.id, eq.email_type, eq.status, eq.attempt_count, eq.last_error,
       eq.created_at, eq.updated_at, eq.resend_email_id,
       eds.event_type AS delivery_event, eds.created_at AS delivery_at
FROM email_queue eq
LEFT JOIN email_delivery_status eds ON eds.resend_email_id = eq.resend_email_id
WHERE eq.email_type = 'waitlist_notification'
  AND eq.recipient_email ILIKE '<email>'
ORDER BY eq.created_at DESC, eds.created_at DESC;
```

### Step 4: Match against incidents (see `references/incidents.md`)
- Row not in `waitlist` → form submission failed (RLS? network? duplicate?)
- Status `waiting` weeks later → owner never clicked notify, auto-detect never found inventory
- Status `notified`, no `email_queue` row → notify button hit a transient failure between INSERT and UPDATE
- Status `notified`, email_queue.status='failed' → Resend / SMTP issue (route to `maguey-bulletproof-email`)
- Status `notified`, email_queue.status='sent', no `email_delivery_status` event → Resend webhook not firing (route to `maguey-bulletproof-email`)
- Status `notified`, customer never bought → expected; conversion is voluntary
- Status `converted` but no `orders` row matches → audit query #6 should catch this

### Step 5: 3-file rule
Don't read more than 3 files when diagnosing. If the answer isn't in `waitlist-service.ts`, the email_queue row, and the WaitlistForm component, escalate to a deeper audit instead of grep-spelunking.

### Step 6: Two-strike
If after 2 hypotheses the customer's issue still isn't reproduced, ask for: browser console screenshot at signup, the time of attempted purchase after notification, and the device/network they were on (Wi-Fi vs cellular often matters for embedded payment flows).

---

## Mode: scale-check

Before a known-soldout event (announced sellout, headliner with hype, etc.) where you'll convert the waitlist at door-open or capacity bump:

### 1. Queue depth
```sql
SELECT event_name, count(*) AS waiting,
       sum(quantity) AS tickets_demanded
FROM waitlist
WHERE status = 'waiting'
GROUP BY event_name
ORDER BY waiting DESC;
```
- Big numbers = strong demand. If >100 waiting and you're about to release 20 seats, expect cancellations from the long tail (people who bought elsewhere).

### 2. Email worker capacity
- `process-email-queue` runs every 60s, max 10 emails per run = **600/hr**.
- 100 notifications fires in <2 min. 1000 notifications takes ~100 min.
- For mass-notify events, consider boosting the cron to 30s OR temporarily raising the batch LIMIT.
- Cross-check via `maguey-bulletproof-email` scale-check.

### 3. Inventory race condition
- When you click "Check All Events" and 5 customers each have `quantity=4` but only 10 seats are open, only the first 2 customers get notified (10/4 = 2.5, rounded down by the loop).
- The 3rd customer's `quantity=4` is skipped, even though `quantity=2` rows after them in the queue could still be filled.
- This is a known FIFO-strict behavior. If demand is mixed-quantity, manually notify smaller-quantity entries to maximize seat fill.

### 4. Stripe race during burst conversion
- 10 customers all click "Get My Tickets" at the same second after the email blast. The atomic ticket-reserve RPC prevents overselling, but losers see "sold out" again.
- That's correct behavior; the failure path is the customer experience (no graceful fallback into "rejoin waitlist").
- Pre-event: confirm `WaitlistForm` is still gated by `eventSoldOut` so they can re-add themselves.

### 5. Notification deliverability
- If you mass-notify 500 people in 10 minutes, Resend may flag the burst. Pre-event:
  - Verify SPF/DKIM/DMARC for `magueynightclub.com` (Resend dashboard → Domains).
  - Pre-warm: send a few non-urgent emails earlier in the day so the burst doesn't look like a cold spike.

### 6. RLS load
- `Owners manage waitlist` policy uses `auth.jwt() -> 'user_metadata' ->> 'role' = 'owner'`. Cheap to evaluate but runs per row. For >10K rows, consider a RPC with `SECURITY DEFINER` that loads the dashboard list.

### Output

```
## Waitlist Scale Readiness — Event: [name], Date: [YYYY-MM-DD]

### Queue depth
- Waiting:        [X] customers, [Y] tickets demanded
- Notified (open):[Z] (waiting on response)
- Inventory open: [N] tickets

### Email worker capacity
- Backlog at 600/hr will clear in ~[X] minutes
- Recommended: [boost worker cadence? YES/NO]

### Inventory math gotchas
- Mixed-quantity entries that may be skipped: [list IDs]

### Resend reputation
- Domain SPF/DKIM/DMARC: [PASS/FAIL/EXTERNAL — check Resend Dashboard]
- Burst risk if mass-notifying: [LOW/MEDIUM/HIGH]

### Verdict: [READY / NOT READY]
```

---

## Critical Flow: Customer signup → Conversion

1. Customer hits sold-out event page → `EventDetail.tsx` renders `<WaitlistForm>` (anon).
2. `WaitlistForm` calls `isOnWaitlist(eventName, email)` — if true, friendly error.
3. If new, calls `addToWaitlist(...)` — INSERT into `waitlist` (anon RLS allows).
4. Form shows "You're on the waitlist! Position #N" via `getWaitlistPosition()`.
5. Time passes. Either:
   - **Owner clicks Notify in the dashboard:**
     - `notifyWaitlistEntry()` INSERTs into `email_queue` (type=`waitlist_notification`).
     - Sets `waitlist.status='notified'`, `notified_at=now()`.
     - `process-email-queue` cron worker picks up the row within ~1 min, renders + sends via Resend.
   - **OR owner runs Auto-Detection:**
     - `autoDetectAndNotifyWaitlist()` walks all events with waiting customers.
     - For each, `checkTicketTypeAvailability()` computes free seats.
     - Notifies up to N customers in created_at order.
     - **GAP**: this path only flips status; it does NOT enqueue an email. The owner must follow up with the manual Notify button OR a future enhancement should call `notifyWaitlistEntry()` from inside the loop.
6. Customer clicks the email CTA → lands on event page → buys.
7. Stripe webhook fires `checkout.session.completed` → order-saga executes.
8. `UpdateWaitlistStep` calls `autoConvertWaitlistEntry(event_name, purchaser_email)`:
   - Finds the waitlist row with matching `(event_name, customer_email)` in status `waiting` or `notified`.
   - Sets `status='converted'`, `converted_at=now()`.
   - Critical=false, so a saga failure here doesn't break the order.

### Typical latency
- Signup form → `waitlist` row: <1 sec.
- Notify click → email in inbox: 60–90 sec.
- Notification → conversion (if customer acts): minutes to hours; many never convert.

### Breakpoints
| Step | Failure | Symptom |
|---|---|---|
| 3 | RLS rejects anon insert | Form shows error, no row created |
| 5a-i | Notify click fails on email_queue insert | Status stays 'waiting'; toast error |
| 5a-ii | Email queue insert succeeds, status update fails | Email goes out, dashboard shows wrong state (rare race) |
| 5b | Auto-detect path | No email sent; status='notified' but customer never knows |
| 6 | Email lands in spam | Status='notified' forever, no conversion |
| 8 | Saga fails to find waitlist row | Customer is on the list but status stays 'notified' even after purchase (audit query #6 catches this) |

---

## HARD RULES

- **NEVER write to prod DB** except through the documented application paths (form insert, owner update, saga conversion).
- **NEVER bypass `isOnWaitlist`** — duplicate signups break inventory math in auto-detect.
- **NEVER use service_role in client bundles** — anon RLS is the contract.
- **NEVER widen the status CHECK constraint without updating the TypeScript union** in both waitlist-service.ts files.
- **NEVER mass-notify without scale-check first** — Resend reputation is hard to recover.
- **NEVER test by inserting fake waitlist entries against the live DB.** Use a local Supabase or staging branch.
- **Branch workflow:** fix/... or feature/... branches.
- **User reports override queries.** "I joined but never heard back" → check spam first, then your DB row, then the email_queue row.
