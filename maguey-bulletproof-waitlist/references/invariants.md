# Maguey Waitlist Invariants

These hold against the live codebase + DB as of 2026-04-21. If any becomes false, fix the code or update this document — never let the audit script silently green-light drift.

---

## Schema

1. **`waitlist.status` is CHECK-constrained to `('waiting','notified','converted','cancelled')`.** Both TypeScript unions in `maguey-pass-lounge/src/lib/waitlist-service.ts` and `maguey-gate-scanner/src/lib/waitlist-service.ts` must match. Adding a value requires migration + both code edits.

2. **`waitlist.event_id` has `ON DELETE CASCADE` to `events(id)`.** Deleting an event auto-removes its waitlist rows. If you ever drop the FK, replace it with a manual cleanup job.

3. **`waitlist.event_name` (text) is the field actually queried in code paths.** The FK exists for cascade-cleanup; reads use `event_name`. If an event is renamed in the dashboard, existing `waitlist.event_name` rows will go stale and never auto-detect-match.

4. **`waitlist.quantity` CHECK > 0.** Anon insert path enforces `quantity >= 1` via Zod in `WaitlistForm.tsx`. Don't relax the DB CHECK.

5. **`email_queue.email_type` includes `waitlist_notification` since migration `20260421110004`.** If you see `waitlist_notification` rejected by the CHECK constraint, the migration didn't apply on that environment.

---

## Auth + RLS

6. **Three RLS policies on `waitlist`:**
   - `Anon can join waitlist` — INSERT only, anon role, no using/check (`true`).
   - `Owners manage waitlist` — ALL, authenticated, JWT user_metadata.role='owner' OR app_metadata.role='owner'.
   - `Service role full access waitlist` — ALL, service_role, no constraint.

   Customer-facing form uses anon. Owner dashboard uses owner JWT. Edge Functions / sagas use service_role.

7. **No client-side service-role key.** Greppable invariant: `grep -rn "SUPABASE_SERVICE_ROLE" maguey-pass-lounge/src maguey-gate-scanner/src` must return zero. Service role keys live in Edge Function secrets only.

8. **anon insert can fail-open silently.** If a future migration tightens the policy and the form starts erroring, customers see a generic toast — no audit alert exists. Run the dedupe query (audit #2) weekly: a sudden plateau is a leading indicator.

---

## Customer-side flow (maguey-pass-lounge)

9. **WaitlistForm only renders when `eventSoldOut === true` in EventDetail.tsx.** If the gate logic breaks, customers see the form even when seats are open — they sign up instead of buying.

10. **`isOnWaitlist(event_name, email)` runs BEFORE every `addToWaitlist()`.** The dedupe is application-level, not a UNIQUE constraint, so two parallel submissions in the same second can both pass the check. This is acceptable for a UI form (no rate-limited bot submissions); not acceptable for a programmatic API (which doesn't exist today).

11. **Form success state shows `getWaitlistPosition()`.** Position is 1-based among `waiting` + `notified` for the same `(event_name, ticket_type)`. Cancelled and converted entries are excluded.

12. **`autoConvertWaitlistEntry(event_name, purchaser_email)`** only updates rows where status IN `('waiting','notified')`. Will not re-convert a cancelled/converted entry. Idempotent.

---

## Owner-side flow (maguey-gate-scanner)

13. **`notifyWaitlistEntry()` is a two-step write: INSERT email_queue → UPDATE waitlist.status.** If the UPDATE fails (e.g. RLS race, revoked permission), the email STILL goes out and the dashboard is left in inconsistent state. The function does not wrap in a transaction. Acceptable risk because the email is the customer-facing event; the dashboard catches up on next refresh.

14. **`autoDetectAndNotifyWaitlist()` does NOT enqueue emails.** It only flips status to 'notified'. The dashboard's "Check All Events" button is a status-flip-only operation today. Customers status='notified' via auto-detect will not get an email until the owner manually clicks Notify or this function is enhanced to call `notifyWaitlistEntry()` per row.

15. **Auto-detect is FIFO-strict per ticket type.** It walks customers in created_at order and stops when remaining inventory < customer's quantity. A `quantity=4` customer at position 1 with only 2 seats open means the loop exits — even if positions 2 and 3 want `quantity=1` and would fit.

16. **Inventory math:** `available = total_inventory - count(tickets where status in ('issued','used','scanned'))`. `cancelled` and `refunded` tickets are NOT counted as sold. If this changes, the auto-detect will over- or under-notify.

17. **CSV export is browser-side only.** No server roundtrip; what's in the React state is what's in the file. Fields: event_name, ticket_type, customer_name, customer_email, customer_phone, quantity, status, created_at.

---

## Saga / payment integration

18. **`UpdateWaitlistStep` in `maguey-pass-lounge/src/lib/sagas/order-saga.ts` is `critical: false`.** A failure here does not roll back the paid order. Conversion is a nice-to-have; the order is the source of truth.

19. **The saga matches by `(event_name, purchaser_email)` ILIKE.** Email match is case-insensitive. Event match is exact. If a customer waitlisted for "RICO" but the event was renamed to "Rico Live", the saga won't convert them — audit query #6 surfaces this.

20. **Conversion is one-way.** Once `status='converted'`, no flow flips it back. Refunds don't reset to `waiting`. If a refunded customer joins the waitlist again, they create a new row.

---

## Email path

21. **`waitlist_notification` emails use the generic `process-email-queue` worker.** No dedicated worker. Every other email_queue invariant (retry, signature, locking) applies — see `maguey-bulletproof-email`.

22. **Email body links to `VITE_PURCHASE_SITE_URL/events/<urlencoded event_name>`.** If the env var is missing, the link defaults to `https://tickets.magueynightclub.com`. If you change the marketing/purchase domain, set the env var on the gate-scanner Vercel project.

23. **No SMS path.** Waitlist notifications are email-only. If a customer signs up with a phone but no email (current form requires email), they will never be notified. This is enforced at the form level via Zod.

---

## What an audit must verify each run

- All three RLS policies still exist and match the names above.
- `email_queue_email_type_check` still includes `waitlist_notification`.
- `waitlist_status_check` and `waitlist_quantity_check` still exist.
- The greps for invariants 7, 9, 10, 11, 13 return the expected matches.
- The audit-queries.sql expected-zero queries return zero.
- The funnel query (#8) doesn't show a sudden cliff in conversion (>50% drop month-over-month is a red flag).
