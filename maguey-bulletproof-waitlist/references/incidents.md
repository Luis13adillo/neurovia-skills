# Maguey Waitlist Incident Library

When a customer report or audit query points at one of these patterns, use the linked diagnosis steps. Add new incidents at the bottom with a date and a one-line postmortem.

---

## I-1. "I joined the waitlist but never got an email"

**Most likely cause:** Owner ran auto-detect (which only flips status) but never clicked manual Notify. Auto-detect does NOT enqueue an email today (see invariant #14).

**Diagnose:**
```sql
SELECT id, status, notified_at, created_at
FROM waitlist
WHERE customer_email ILIKE '<email>' AND event_name = '<event>';

SELECT id, status, attempt_count, last_error, created_at, updated_at, resend_email_id
FROM email_queue
WHERE recipient_email ILIKE '<email>' AND email_type = 'waitlist_notification'
ORDER BY created_at DESC;
```

| Outcome | Cause | Fix |
|---|---|---|
| `waitlist.status='waiting'` | Owner never notified | Owner clicks Notify in dashboard |
| `waitlist.status='notified'`, no `email_queue` row | Auto-detect path used (no email sent) | Owner clicks Notify; consider enhancement #2 below |
| `waitlist.status='notified'`, `email_queue.status='failed'` | Resend / SMTP issue | Route to `maguey-bulletproof-email` for retry/diagnosis |
| `waitlist.status='notified'`, `email_queue.status='sent'` | Customer's spam filter | Ask customer to check spam, allowlist `tickets@magueynightclub.com` |
| `waitlist.status='converted'` | They already bought | Confirm with order_id; no further action |

---

## I-2. "I see two of myself on the waitlist for the same event"

**Most likely cause:** `isOnWaitlist()` race — customer double-tapped submit before the first INSERT completed. Application-level dedupe doesn't have a UNIQUE constraint backing it.

**Diagnose:** audit-queries.sql query #2.

**Fix (per-incident):**
- Identify the older row by `created_at` and cancel the newer.
- Don't delete; cancellation preserves the audit trail.

**Fix (systemic):** Add a partial UNIQUE index on `(event_name, lower(customer_email))` WHERE `status = 'waiting'`. The migration is straightforward but requires a one-time cleanup of existing duplicates first.

---

## I-3. "Owner clicked Check All Events and 0 customers were notified despite open inventory"

**Most likely causes:**
1. Inventory math counts cancelled/refunded tickets as sold (it shouldn't — verify).
2. Customer `quantity` exceeds available seats (audit query #7) — auto-detect skips them in FIFO order.
3. `event_name` mismatch: the event was renamed in the dashboard but waitlist rows still hold the old name.

**Diagnose:**
```sql
-- Compare what auto-detect "sees" as available vs what really exists:
WITH avail AS (
  SELECT tt.event_id, tt.name AS ticket_type_name,
         tt.total_inventory,
         (SELECT count(*) FROM tickets t
            WHERE t.ticket_type_id = tt.id
              AND t.status IN ('issued','used','scanned')) AS sold
  FROM ticket_types tt WHERE tt.event_id = '<event_id>'
)
SELECT *, total_inventory - sold AS available FROM avail;

SELECT id, customer_email, ticket_type, quantity, status, created_at
FROM waitlist
WHERE event_name = '<event_name>' AND status = 'waiting'
ORDER BY created_at;
```

**Fix:** Manually click Notify on each individual entry that fits remaining capacity, OR temporarily reduce a ticket type's `total_inventory` to match what you actually want released.

---

## I-4. "We renamed an event and now waitlist rows are orphaned"

**Most likely cause:** `event_name` is a text column, not an FK. Rename in `events` does not propagate.

**Diagnose:**
```sql
SELECT w.id, w.event_name AS waitlist_event_name, e.name AS current_event_name
FROM waitlist w
JOIN events e ON e.id = w.event_id
WHERE w.event_name <> e.name AND w.status IN ('waiting','notified');
```

**Fix:**
- Run an UPDATE that syncs `waitlist.event_name = events.name` for affected rows.
- DO NOT change the FK relationship; the cascade-cleanup behavior depends on it.
- Long-term: refactor code paths to query by `event_id` instead of `event_name` (touches `WaitlistForm.tsx`, `waitlist-service.ts` x2, the saga).

---

## I-5. "Customer paid but their waitlist entry says still 'waiting'"

**Most likely cause:** Saga's `UpdateWaitlistStep` is `critical: false` and may have failed silently. Or the email used at checkout differs from the email used at signup.

**Diagnose:**
```sql
SELECT w.id, w.customer_email AS waitlist_email, w.status,
       o.id AS order_id, o.purchaser_email, o.status AS order_status, o.created_at
FROM waitlist w
LEFT JOIN orders o ON o.event_id = w.event_id AND lower(o.purchaser_email) = lower(w.customer_email)
WHERE w.event_name = '<event>' AND w.customer_email ILIKE '<email>'
ORDER BY o.created_at DESC;
```

| Outcome | Cause | Fix |
|---|---|---|
| `order` row exists and is paid, but `waitlist.status='waiting'` | Saga step failed | Manually update waitlist row to 'converted' OR re-run the saga step manually |
| Different `purchaser_email` than waitlist email | Email mismatch (typo, alias) | Manually update waitlist row to 'converted' if owner confirms it's the same person |
| No matching `order` row | They didn't actually buy yet | No action; status is correct |

**Audit query #6 surfaces these at scale.**

---

## I-6. "Auto-detect notified the wrong number of customers"

Examples:
- 5 seats opened up but only 1 customer notified.
- 5 seats opened, 5 notified, but 6 had `quantity=1` and were waiting.

**Most likely cause:** FIFO-strict behavior with mixed quantities (invariant #15). Loop exits as soon as the next customer's `quantity > remainingTickets`.

**Diagnose:** Walk the waitlist for the event in `created_at` order and simulate the loop:
```sql
SELECT id, customer_email, quantity, status, created_at
FROM waitlist
WHERE event_name = '<event>' AND status IN ('waiting','notified')
ORDER BY created_at;
```

**Fix (per-event):** Manually notify smaller-quantity entries that fit.
**Fix (systemic):** Replace the strict FIFO loop with a "best-fit" loop that skips over too-large requests instead of exiting. Tradeoff: less fair to early signups; faster total fill.

---

## I-7. "Notification email arrived but the link in it 404s"

**Most likely cause:** `VITE_PURCHASE_SITE_URL` env var on the gate-scanner Vercel project doesn't match the deployed purchase-site domain. Or the event was renamed/archived after the email was queued.

**Diagnose:**
- Read the email body in `email_queue.html_body` — check the actual URL.
- Compare against `events.name` and the deployed purchase site URL.

**Fix:**
- If env mismatch: update `VITE_PURCHASE_SITE_URL` in Vercel and redeploy gate-scanner.
- If event was renamed: customer will need to navigate from the home page; no per-email fix.

---

## I-8. "Anon waitlist insert failing with 401/403"

**Most likely cause:** RLS policy `Anon can join waitlist` was dropped or modified.

**Diagnose:**
```sql
SELECT polname, polpermissive,
       pg_get_expr(polqual, polrelid) AS using_expr,
       pg_get_expr(polwithcheck, polrelid) AS check_expr
FROM pg_policy
WHERE polrelid = 'public.waitlist'::regclass;
```

**Fix:** Re-create the policy from migration `20260421110001`:
```sql
CREATE POLICY "Anon can join waitlist"
  ON public.waitlist FOR INSERT TO anon WITH CHECK (true);
```

---

## I-9. "Mass-notify caused Resend to throttle our domain"

**Most likely cause:** Sending 500+ emails in <10 minutes from a domain with no sending history. Looks like a cold spike.

**Diagnose:**
- Check Resend Dashboard → Domains for sending health.
- Check `email_queue` for stuck `processing` rows.
- Check `email_delivery_status` for a sudden spike in `bounced` or `complained` events.

**Fix (immediate):**
- Pause auto-detect.
- Stop manual Notify clicks.
- Wait for Resend reputation to recover (hours to days).

**Fix (systemic):** Pre-event scale-check (this skill's scale-check mode). Pre-warm the domain by sending a few non-urgent emails earlier in the day. Cap notification batch rate at ~10/min for unwarmed domains.

---

## Future Enhancement Backlog

These are NOT incidents — they're known limitations to address before they become incidents:

1. **`email_queue_email_type_check` audit alert.** Add a CI check that fails if `waitlist_notification` is missing from the constraint on any deployed env.

2. **Auto-detect should enqueue emails.** Currently `autoDetectAndNotifyWaitlist()` only flips status. Refactor to call `notifyWaitlistEntry()` per row so customers actually get notified.

3. **Partial UNIQUE index for dedupe.** See I-2. Replaces the application-level race with a DB-level guarantee.

4. **Rename-safe `event_name` queries.** See I-4. Migrate to FK-based reads.

5. **SMS fallback.** Customers without a working email address will never convert. Add an opt-in SMS notification via Twilio for waitlist customers who provide a phone number.

6. **Position-in-queue updates.** Customers see their position at signup but never again. Email them periodically with updated position so they don't think they were forgotten.

7. **Auto-cancel stale 'waiting' entries.** A scheduled job that flips `waiting` → `cancelled` when the event date passes (audit query #1 catches the absence of this today).
