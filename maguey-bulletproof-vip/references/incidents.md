# VIP — Known Incidents & Fix Patterns

---

## Incident: Two parties booked same VIP table
**Symptom:** query #3 returns rows — two confirmed reservations for same event_vip_table_id.
**Root cause options:**
1. Someone bypassed `create_vip_reservation_atomic` and did direct INSERTs (check recent migrations or code changes)
2. `FOR UPDATE` lock missing from the RPC (compare migration)
3. `is_available` check happens OUTSIDE the locked section → TOCTOU race
**Fix:** always call RPC, which wraps `SELECT ... FOR UPDATE` + insert in a single transaction. Verify by reading the migration definition:
```sql
SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname = 'create_vip_reservation_atomic';
```

---

## Incident: Paid but no invite code received
**Symptom:** Stripe shows PI succeeded, reservation is `confirmed` in DB, but customer never got the email with invite code.
**Root cause chain:**
1. Polling on client exhausted before webhook fired (the 10×2s = 20s poll window is sometimes too short on Edge Function cold starts)
2. Email not enqueued for that reservation
3. Email enqueued but `process-email-queue` dropped it
**Debug:**
```sql
SELECT * FROM email_queue WHERE email_type = 'vip_confirmation' AND related_id = '<reservation_id>';
```
- If row exists and status='delivered' → check customer's spam
- If row missing → webhook didn't enqueue (check webhook logs around PI succeeded for this reservation)
- If row exists with status='failed' → `last_error` tells you why

---

## Incident: Guest can't re-enter after stepping outside
**Symptom:** Guest with valid VIP pass gets "already scanned" rejection on second scan.
**Root cause:** `check_vip_linked_ticket_reentry` not returning `allow_reentry=true`, OR the guest's scan path is using the GA-only logic not the VIP-aware one.
**Debug:**
```sql
-- Is the ticket linked?
SELECT * FROM vip_linked_tickets WHERE ticket_id = '<ticket_id>';

-- Reservation active?
SELECT id, status, checked_in_guests FROM vip_reservations WHERE id = '<reservation_id>';

-- Recent scans for this pass?
SELECT * FROM vip_scan_logs WHERE pass_id = '<pass_id>' ORDER BY scanned_at DESC LIMIT 5;
```
**Fix:** ensure scanner code calls `check_vip_linked_ticket_reentry` BEFORE the duplicate-scan check. Linked VIP tickets must allow re-entry by design (guest gets OK to exit and return).

---

## Incident: Pending reservation orphaned (rollback didn't fire)
**Symptom:** query #12 returns rows — `vip_reservations.status = 'pending'` older than 1h with `event_vip_tables.is_available = false` (blocked).
**Root cause:** `rollback_vip_checkout` wasn't called — exception path in `create-vip-payment-intent` either didn't reach catch block, or RPC itself failed silently.
**Manual cleanup (requires user approval — this is a WRITE):**
```sql
-- Find orphans:
SELECT vr.id, vr.event_vip_table_id FROM vip_reservations vr
WHERE vr.status = 'pending' AND vr.created_at < now() - interval '1 hour';

-- Fix each (example — do NOT run without user approval):
SELECT rollback_vip_checkout(p_reservation_id := '<id>', p_ticket_id := NULL, p_table_id := '<table_id>');
```
**Prevention:** add monitoring — cron every 5 min that calls `rollback_vip_checkout` on any pending >30 min. Requires user approval.

---

## Incident: Floor plan drag saves to wrong position
**Symptom:** Admin drags a VIP table in the floor plan editor. UI shows new position but on refresh it jumps back.
**Root cause:** optimistic update succeeded in React state but server UPDATE failed or was debounced past component unmount.
**Debug:**
- Network tab: did the PATCH/UPDATE to `event_vip_tables` return 200?
- Does the component call `await supabase.from('event_vip_tables').update(...).eq('id', ...)` in the drag-end handler?
- Is there a race between drag-end → save → another drag starts before save completes?
**Fix:** ensure drop handler awaits the save before letting the UI accept another drag. Or implement a save queue per-table.

---

## Incident: Bottle config mismatch — customer selects bottle not in catalog
**Symptom:** Customer chose "Espolon Reposado" but event's `vip_table_bottle_config` doesn't include it. Confirmation email shows generic "bottles by host".
**Root cause:** client-side catalog filter (`BOTTLE_CATALOG` filtered by config) mismatched server-side resolution.
**Fix:** make the Edge Function reject bottle IDs not in the config, with clear error. Don't silently accept and ignore.

---

## Incident: Celebrant name on reservation but not shown at door
**Symptom:** Customer filled "birthday" celebration + celebrantName="Sofia". Host at door doesn't see it.
**Root cause:** `vip_reservations.package_snapshot` stores the data but owner dashboard VIP list doesn't surface it.
**Debug:** check what the owner dashboard VIP list component displays. Should render `package_snapshot.celebration` + `celebrantName` prominently.
**Fix:** surface the data in the host-facing UI.

---

## Incident: Guest list invite codes reused
**Symptom:** `invite_code` shared publicly, 100 people use it instead of the intended 20.
**Root cause:** invite_code has no usage_limit enforcement.
**Current state:** by design, invite codes are unlimited — anyone with the code can claim a linked GA ticket.
**Fix (requires user approval):** add `guest_count_limit` to `vip_reservations` + check in `create_unified_vip_checkout` that guest count not exceeded. Or: rate-limit by invite_code in the Edge Function.

---

## Incident: 1335-line VIPBookingForm.tsx has ownership check bypass?
**Symptom:** Form validation passes for any email but Stripe charge attempts someone else's PI.
**Root cause:** sessionStorage-based state passing between pages (from VipPayment.tsx legacy flow) might not validate on target page.
**Fix:** verify `confirm-vip-payment` Edge Function checks ownership (line ~69-96). Client-side form is a UX helper, not security. Server is source of truth.

---

## Incident: Confirmed reservation with no guest passes
**Symptom:** query #4 returns rows.
**Root cause:** webhook `payment_intent.succeeded` handler failed between marking reservation confirmed and generating passes.
**Recovery (requires approval — WRITE):**
```sql
-- Re-generate passes via RPC (if it exists):
SELECT regenerate_vip_guest_passes(p_reservation_id := '<id>');
-- Or manually trigger the handler by replaying the Stripe event from Dashboard.
```
**Prevention:** the pass generation should happen INSIDE the atomic status transition, not as a follow-up step.
