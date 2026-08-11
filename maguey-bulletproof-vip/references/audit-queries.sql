-- =============================================================================
-- Maguey Bulletproof VIP — Audit Queries
-- =============================================================================
-- SELECT-only. Run one at a time via mcp__supabase__execute_sql.
-- Project: Maguey Nightclub (djbzjasdrwvbsoifxqzd.supabase.co)
-- Expected: 0 rows unless noted.
--
-- SCHEMA REALITY CHECK (verified 2026-04-21 after audit)
--   vip_reservations:
--     - NO `guest_count` column. Capacity lives on event_vip_tables.capacity,
--       join via event_vip_table_id. `package_snapshot->>'guestCount'` holds
--       the customer-requested count when set.
--     - status enum `vip_reservation_status`: pending, confirmed, checked_in,
--       no_show, cancelled. NO `completed` value — reservations end at
--       checked_in or no_show.
--     - Has: id, event_id, event_vip_table_id, table_number, purchaser_*,
--       stripe_payment_intent_id, stripe_charge_id, amount_paid_cents, status,
--       confirmed_at, checked_in_at, checked_in_by, qr_code_token,
--       package_snapshot (jsonb), invite_code, refund_id, refunded_at,
--       cancellation_reason, cancelled_by, checked_in_guests,
--       purchaser_ticket_id, disclaimer_accepted_at, refund_policy_accepted_at.
--   vip_guest_passes:
--     - Columns are `pass_number` (NOT guest_number) and `qr_token`
--       (NOT qr_code_token). Status text: assigned/available/checked_in/cancelled.
--     - Has: id, reservation_id, event_id, pass_number, guest_name, guest_email,
--       guest_phone, pass_type, qr_token, qr_signature, status, shared_at,
--       shared_via, scanned_at, scanned_by, scan_location.
--   vip_linked_tickets:
--     - FK to reservation is `vip_reservation_id` (NOT reservation_id).
--     - Has: id, vip_reservation_id, order_id, ticket_id, purchased_by_email,
--       purchased_by_name, is_booker_purchase.
--   event_vip_tables:
--     - Has `price_cents` (NOT price), `capacity`, `is_available`, `tier`,
--       `bottles_included`, `champagne_included`, `package_description`,
--       `display_order`, `position_x`, `position_y`. NO `table_name`, NO
--       `is_active`, NO `price`.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. CRITICAL — Confirmed reservations must have a Stripe PI id
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, event_id, purchaser_email, status, stripe_payment_intent_id, created_at
FROM vip_reservations
WHERE status = 'confirmed'
  AND (stripe_payment_intent_id IS NULL OR stripe_payment_intent_id = '')
  AND created_at > now() - interval '30 days';


-- -----------------------------------------------------------------------------
-- 2. HIGH — Pending reservations older than 2h (stuck / orphan)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, event_id, event_vip_table_id, purchaser_email, created_at,
       (now() - created_at) AS age
FROM vip_reservations
WHERE status = 'pending'
  AND created_at < now() - interval '2 hours';


-- -----------------------------------------------------------------------------
-- 3. CRITICAL — Same table double-booked for same event
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT event_id,
       event_vip_table_id,
       COUNT(*) FILTER (WHERE status IN ('confirmed', 'checked_in')) AS active_bookings,
       array_agg(id) AS reservation_ids
FROM vip_reservations
WHERE status IN ('confirmed', 'checked_in')
GROUP BY event_id, event_vip_table_id
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- 4. CRITICAL — Confirmed reservation must have at least one guest pass
-- Expected: 0 rows
-- Note: guest_count lives on event_vip_tables.capacity (not vip_reservations)
-- -----------------------------------------------------------------------------
SELECT vr.id AS reservation_id,
       vr.purchaser_email,
       evt.capacity AS expected_passes,
       vr.status,
       COUNT(vgp.id) AS actual_pass_count
FROM vip_reservations vr
JOIN event_vip_tables evt ON evt.id = vr.event_vip_table_id
LEFT JOIN vip_guest_passes vgp ON vgp.reservation_id = vr.id
WHERE vr.status IN ('confirmed', 'checked_in')
  AND vr.created_at > now() - interval '30 days'
GROUP BY vr.id, vr.purchaser_email, evt.capacity, vr.status
HAVING COUNT(vgp.id) = 0
   OR COUNT(vgp.id) < COALESCE(evt.capacity, 1);


-- -----------------------------------------------------------------------------
-- 5. HIGH — Orphan guest passes (reservation deleted but passes lingering)
-- Expected: 0 rows (CASCADE should prevent this, but verify)
-- -----------------------------------------------------------------------------
SELECT vgp.id AS pass_id, vgp.reservation_id, vgp.guest_name, vgp.created_at
FROM vip_guest_passes vgp
LEFT JOIN vip_reservations vr ON vr.id = vgp.reservation_id
WHERE vr.id IS NULL;


-- -----------------------------------------------------------------------------
-- 6. HIGH — Duplicate ticket_id in vip_linked_tickets (UNIQUE violation)
-- Expected: 0 rows
-- Note: FK col is vip_reservation_id (NOT reservation_id)
-- -----------------------------------------------------------------------------
SELECT ticket_id, COUNT(*) AS link_count, array_agg(vip_reservation_id) AS reservation_ids
FROM vip_linked_tickets
GROUP BY ticket_id
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- 7. CRITICAL — checked_in_guests cannot exceed event_vip_tables.capacity
-- Expected: 0 rows
-- Note: capacity is on event_vip_tables (NOT vip_reservations.guest_count)
-- -----------------------------------------------------------------------------
SELECT vr.id, vr.purchaser_email, evt.capacity, vr.checked_in_guests,
       (vr.checked_in_guests - evt.capacity) AS overage
FROM vip_reservations vr
JOIN event_vip_tables evt ON evt.id = vr.event_vip_table_id
WHERE vr.checked_in_guests > COALESCE(evt.capacity, 0);


-- -----------------------------------------------------------------------------
-- 8. HIGH — is_available mismatch with reservation state
-- Expected: 0 rows
-- A table with a confirmed/checked_in reservation should NOT be is_available=true
-- -----------------------------------------------------------------------------
SELECT evt.id AS table_id,
       evt.event_id,
       evt.table_number,
       evt.is_available,
       vr.id AS reservation_id,
       vr.status AS reservation_status
FROM event_vip_tables evt
JOIN vip_reservations vr ON vr.event_vip_table_id = evt.id
WHERE evt.is_available = true
  AND vr.status IN ('confirmed', 'checked_in');


-- -----------------------------------------------------------------------------
-- 9. CRITICAL — Confirmed reservation must have signed guest passes
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT vgp.id AS pass_id,
       vgp.reservation_id,
       vr.purchaser_email,
       vgp.qr_token IS NULL AS missing_token,
       vgp.qr_signature IS NULL AS missing_signature
FROM vip_guest_passes vgp
JOIN vip_reservations vr ON vr.id = vgp.reservation_id
WHERE vr.status IN ('confirmed', 'checked_in')
  AND vr.created_at > now() - interval '30 days'
  AND (vgp.qr_token IS NULL OR vgp.qr_signature IS NULL);


-- -----------------------------------------------------------------------------
-- 10. MEDIUM — Scan logs referencing non-existent passes
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT vsl.id AS scan_log_id, vsl.pass_id, vsl.scanned_at
FROM vip_scan_logs vsl
LEFT JOIN vip_guest_passes vgp ON vgp.id = vsl.pass_id
WHERE vgp.id IS NULL
  AND vsl.pass_id IS NOT NULL;


-- -----------------------------------------------------------------------------
-- 11. MEDIUM — Tables missing bottle config (informational, not always a bug)
-- Expected: rows where event_vip_tables lacks vip_table_bottle_config
-- -----------------------------------------------------------------------------
SELECT evt.id AS table_id,
       evt.event_id,
       evt.table_number,
       evt.tier,
       evt.price_cents,
       (vtbc.id IS NOT NULL) AS has_bottle_config
FROM event_vip_tables evt
LEFT JOIN vip_table_bottle_config vtbc ON vtbc.event_vip_table_id = evt.id
LEFT JOIN events e ON e.id = evt.event_id
WHERE e.status = 'published'
  AND e.event_date >= current_date
ORDER BY evt.event_id, evt.table_number;


-- -----------------------------------------------------------------------------
-- 12. HIGH — Rollback didn't fire: pending reservation with failed/missing PI
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT vr.id AS reservation_id,
       vr.event_vip_table_id,
       vr.stripe_payment_intent_id,
       vr.status,
       evt.is_available,
       vr.created_at
FROM vip_reservations vr
JOIN event_vip_tables evt ON evt.id = vr.event_vip_table_id
WHERE vr.status = 'pending'
  AND vr.created_at < now() - interval '1 hour'
  AND evt.is_available = false;  -- table still marked unavailable despite stale pending


-- -----------------------------------------------------------------------------
-- 13. INFO — Reservation summary per upcoming event
-- -----------------------------------------------------------------------------
SELECT e.id AS event_id,
       e.name,
       e.event_date,
       COUNT(vr.id) FILTER (WHERE vr.status = 'confirmed') AS confirmed,
       COUNT(vr.id) FILTER (WHERE vr.status = 'pending') AS pending,
       COUNT(vr.id) FILTER (WHERE vr.status = 'checked_in') AS checked_in,
       COUNT(evt.id) AS total_tables,
       COUNT(evt.id) FILTER (WHERE evt.is_available = true) AS still_available
FROM events e
LEFT JOIN event_vip_tables evt ON evt.event_id = e.id
LEFT JOIN vip_reservations vr ON vr.event_id = e.id
WHERE e.status = 'published'
  AND e.event_date >= current_date
  AND e.event_date < current_date + interval '30 days'
GROUP BY e.id, e.name, e.event_date
ORDER BY e.event_date;


-- -----------------------------------------------------------------------------
-- 14. MEDIUM — Guest passes usage summary per confirmed reservation
-- Expected: informational
-- Note: pass status is one of assigned/available/checked_in/cancelled
-- -----------------------------------------------------------------------------
SELECT vr.id AS reservation_id,
       vr.invite_code,
       evt.capacity,
       COUNT(vgp.id) FILTER (WHERE vgp.status IN ('assigned','available')) AS unused_passes,
       COUNT(vgp.id) FILTER (WHERE vgp.status = 'checked_in') AS used_passes
FROM vip_reservations vr
JOIN event_vip_tables evt ON evt.id = vr.event_vip_table_id
LEFT JOIN vip_guest_passes vgp ON vgp.reservation_id = vr.id
WHERE vr.status = 'confirmed'
  AND vr.created_at > now() - interval '7 days'
GROUP BY vr.id, vr.invite_code, evt.capacity;
