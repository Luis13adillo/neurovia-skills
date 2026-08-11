-- =============================================================================
-- Maguey Bulletproof Tickets — Audit Queries
-- =============================================================================
-- ALL queries are SELECT-only. NEVER add INSERT / UPDATE / DELETE here.
-- Run one at a time via mcp__supabase__execute_sql.
-- Project: Maguey Nightclub (djbzjasdrwvbsoifxqzd.supabase.co)
--
-- Expected result for each query is 0 rows unless the comment says otherwise.
-- If actual differs, mark FAIL in the audit report.
--
-- Schema notes (verified 2026-04-21):
--   ticket_types.total_inventory       (not `capacity`)
--   ticket_types.price  numeric        (not `price_cents`)
--   orders.payment_reference           (the Stripe session/intent id)
--   promotions has no usage_count      (compute via orders.promo_code_id)
--   saga_executions.saga_name / error_details
--   revenue_discrepancies.event_id / db_revenue / stripe_revenue / discrepancy_amount / checked_at
--   ticket_transfers has no `status` column (pending = NULL transferred_at)
--   QR secret lives in vault.decrypted_secrets, not app.qr_signing_secret
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. CRITICAL — No ticket without a parent order
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT t.id AS ticket_id, t.order_id, t.event_id, t.created_at
FROM tickets t
LEFT JOIN orders o ON o.id = t.order_id
WHERE o.id IS NULL
  AND t.created_at > now() - interval '30 days';


-- -----------------------------------------------------------------------------
-- 2. CRITICAL — No order marked 'paid' without tickets (webhook/saga failure)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT o.id AS order_id, o.purchaser_email, o.total, o.created_at, o.payment_reference
FROM orders o
LEFT JOIN tickets t ON t.order_id = o.id
  AND t.status NOT IN ('cancelled', 'refunded')
WHERE o.status = 'paid'
  AND o.created_at > now() - interval '30 days'
  AND t.id IS NULL;


-- -----------------------------------------------------------------------------
-- 3. CRITICAL — No oversold ticket type
-- Expected: 0 rows
-- Uses total_inventory (the real column) and the cached tickets_sold counter.
-- -----------------------------------------------------------------------------
SELECT tt.id AS ticket_type_id,
       tt.name,
       tt.event_id,
       tt.total_inventory,
       tt.tickets_sold,
       (tt.tickets_sold - tt.total_inventory) AS oversold_by
FROM ticket_types tt
WHERE tt.total_inventory IS NOT NULL
  AND tt.tickets_sold > tt.total_inventory;


-- -----------------------------------------------------------------------------
-- 4. CRITICAL — tickets_sold counter matches actual non-cancelled ticket count
-- Expected: 0 rows (any row = counter drifted from reality)
-- -----------------------------------------------------------------------------
SELECT tt.id AS ticket_type_id,
       tt.name,
       tt.tickets_sold AS cached_count,
       COUNT(t.id) AS actual_count,
       (COUNT(t.id) - tt.tickets_sold) AS drift
FROM ticket_types tt
LEFT JOIN tickets t ON t.ticket_type_id = tt.id
  AND t.status NOT IN ('cancelled', 'refunded')
GROUP BY tt.id, tt.name, tt.tickets_sold
HAVING COUNT(t.id) <> tt.tickets_sold;


-- -----------------------------------------------------------------------------
-- 5. CRITICAL — No duplicate qr_token across tickets
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT qr_token, COUNT(*) AS dup_count, array_agg(id) AS ticket_ids
FROM tickets
WHERE qr_token IS NOT NULL
GROUP BY qr_token
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- 6. CRITICAL — Paid-order tickets must carry qr_token + qr_signature
-- Expected: 0 rows
-- Scanner rejects unsigned tickets, so any row here = a customer can't enter.
-- -----------------------------------------------------------------------------
SELECT t.id AS ticket_id,
       t.order_id,
       o.status AS order_status,
       t.qr_token IS NULL AS missing_token,
       t.qr_signature IS NULL AS missing_signature
FROM tickets t
JOIN orders o ON o.id = t.order_id
WHERE o.status = 'paid'
  AND o.created_at > now() - interval '30 days'
  AND (t.qr_token IS NULL OR t.qr_signature IS NULL);


-- -----------------------------------------------------------------------------
-- 7. HIGH — Orders stuck in 'pending' older than 24h (orphans)
-- Expected: 0 rows. Any rows = abandoned carts with no cleanup cron.
-- The cascade_order_status_to_tickets trigger cancels tickets when orders are
-- cancelled, but nothing auto-cancels pending orders. Flag for the user.
-- -----------------------------------------------------------------------------
SELECT id AS order_id,
       purchaser_email,
       total,
       payment_reference,
       created_at,
       (now() - created_at) AS age
FROM orders
WHERE status = 'pending'
  AND created_at < now() - interval '24 hours'
ORDER BY created_at DESC
LIMIT 100;


-- -----------------------------------------------------------------------------
-- 8. HIGH — Promo code redemption count > usage_limit (known race condition)
-- Expected: 0 rows.
-- promotions table has no usage_count column — derive from orders.promo_code_id.
-- -----------------------------------------------------------------------------
SELECT p.id,
       p.code,
       p.usage_limit,
       COUNT(o.id) AS redemption_count,
       (COUNT(o.id) - p.usage_limit) AS overage
FROM promotions p
LEFT JOIN orders o ON o.promo_code_id = p.id
  AND o.status = 'paid'
WHERE p.usage_limit IS NOT NULL
GROUP BY p.id, p.code, p.usage_limit
HAVING COUNT(o.id) > p.usage_limit;


-- -----------------------------------------------------------------------------
-- 9. HIGH — Saga executions failed without compensation
-- Expected: 0 rows. Any row = an order mid-flow that never reached paid OR
-- compensated, so the customer either over-charged or saw a broken checkout.
-- -----------------------------------------------------------------------------
SELECT id, saga_name, current_step, status, error_details, created_at
FROM saga_executions
WHERE status = 'failed'
  AND created_at > now() - interval '7 days'
ORDER BY created_at DESC;


-- -----------------------------------------------------------------------------
-- 10. MEDIUM — Revenue discrepancies recorded
-- Expected: 0 rows. Any open row = reconciliation found DB vs Stripe mismatch.
-- -----------------------------------------------------------------------------
SELECT id,
       event_id,
       db_revenue,
       stripe_revenue,
       discrepancy_amount,
       resolved_at,
       checked_at
FROM revenue_discrepancies
WHERE resolved_at IS NULL
ORDER BY checked_at DESC
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 11. MEDIUM — QR signing secret is present in Supabase Vault
-- Expected: 1 row with secret_length > 0.
-- If 0 rows OR secret_length = 0 → QR signing will throw, new paid tickets
-- won't get signed, scanner will reject them at the door.
-- -----------------------------------------------------------------------------
SELECT name, length(decrypted_secret) AS secret_length
FROM vault.decrypted_secrets
WHERE name = 'qr_signing_secret';


-- -----------------------------------------------------------------------------
-- 12. MEDIUM — Active ticket types have sane pricing + inventory
-- Expected: 0 rows. Any row = a sellable ticket type with bad config.
-- Uses the real columns: price (numeric dollars) and total_inventory.
-- -----------------------------------------------------------------------------
SELECT id, event_id, name, price, total_inventory
FROM ticket_types
WHERE (total_inventory IS NULL OR total_inventory <= 0)
   OR (price IS NULL OR price < 0);


-- -----------------------------------------------------------------------------
-- 13. MEDIUM — Published future events have at least one ticket type
-- Expected: 0 rows. Any row = a published event that can't be purchased.
-- -----------------------------------------------------------------------------
SELECT e.id, e.name, e.event_date, e.status
FROM events e
LEFT JOIN ticket_types tt ON tt.event_id = e.id
WHERE e.status = 'published'
  AND e.event_date >= current_date
  AND tt.id IS NULL;


-- -----------------------------------------------------------------------------
-- 14. LOW — Pending ticket transfers older than 7 days
-- Expected: any rows are worth reviewing.
-- Schema: ticket_transfers uses `transferred_at IS NULL` for pending,
-- not a `status` column.
-- -----------------------------------------------------------------------------
SELECT id, ticket_id, from_email, to_email, transferred_at
FROM ticket_transfers
WHERE transferred_at IS NULL
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 15. MEDIUM — Skill-added guard rails present
-- Expected: all three booleans true. Any false = someone dropped the guards
-- introduced by migration 20260421000000_cancel_cascade_and_paid_integrity.
-- -----------------------------------------------------------------------------
SELECT
  EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'public.orders'::regclass
      AND tgname = 'cascade_order_status_to_tickets'
  ) AS cascade_trigger_present,
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.orders'::regclass
      AND conname = 'chk_paid_order_has_payment_reference'
      AND convalidated = true
  ) AS paid_integrity_constraint_validated,
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.webhook_idempotency'::regclass
      AND contype = 'u'
  ) AS webhook_idempotency_unique_present;


-- -----------------------------------------------------------------------------
-- 16. MEDIUM — Required RPCs exist in the DB
-- Expected: all booleans true. Any false = code path will throw at runtime.
-- `increment_tickets_sold` is called by stripe-webhook but historically has
-- been missing from the DB on some branches — explicitly check for it.
-- -----------------------------------------------------------------------------
SELECT
  EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'get_current_tier_price') AS get_current_tier_price,
  EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'reserve_tickets_batch') AS reserve_tickets_batch,
  EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'release_reserved_tickets') AS release_reserved_tickets,
  EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'create_order_with_tickets_atomic') AS create_order_with_tickets_atomic,
  EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'sign_qr_token') AS sign_qr_token,
  EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'advance_price_tier') AS advance_price_tier,
  EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'increment_tickets_sold') AS increment_tickets_sold;


-- -----------------------------------------------------------------------------
-- 17. INFO — Last 24h purchase summary (sanity check, not a pass/fail)
-- -----------------------------------------------------------------------------
SELECT
  COUNT(*) FILTER (WHERE status = 'paid') AS paid_orders,
  COUNT(*) FILTER (WHERE status = 'pending') AS pending_orders,
  COUNT(*) FILTER (WHERE status = 'cancelled') AS cancelled_orders,
  COUNT(*) FILTER (WHERE status = 'refunded') AS refunded_orders,
  SUM(total) FILTER (WHERE status = 'paid') AS gross_revenue
FROM orders
WHERE created_at > now() - interval '24 hours';
