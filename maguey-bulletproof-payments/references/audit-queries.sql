-- =============================================================================
-- Maguey Bulletproof Payments — Audit Queries
-- =============================================================================
-- SELECT-only. NEVER INSERT / UPDATE / DELETE.
-- Run one at a time via mcp__supabase__execute_sql.
-- Project: Maguey Nightclub (djbzjasdrwvbsoifxqzd.supabase.co)
-- Expected: 0 rows unless noted.
--
-- SCHEMA NOTES (verified 2026-04-21 against live DB):
--   - `payment_failures` and `payments` tables DO NOT EXIST. Queries using them
--     will fail. They're kept below only as placeholders marked [NOT-USED].
--   - `webhook_events` columns: id, event_type, signature_hash, source_ip,
--     timestamp, expires_at, payload_hash, created_at. NO response_status /
--     error_message / received_at / event_id. This table is an audit trail of
--     signature+replay-protection, NOT a per-event response log.
--   - `saga_executions.status` enum values: pending, running, completed, failed,
--     compensating, compensated, compensation_failed. (NOT 'in_progress').
--   - `orders.payment_reference` holds the Stripe PaymentIntent id ('pi_...').
--     There is no `stripe_session_id` or `stripe_payment_intent_id` column on
--     `orders`. Session id also appears in `orders.metadata->>'sessionId'`.
--   - `vip_reservations.stripe_payment_intent_id` DOES exist (varchar).
--   - `orders` status is free-form text (no CHECK); tickets.status also free-form.
--     `tickets.current_status` has CHECK ('inside'|'outside'|'left').
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. INFO — Webhook event types seen in last 7 days (volume + replay-protection audit)
-- Note: webhook_events is a replay-protection log, not a response status log.
-- To find failed deliveries, check Stripe Dashboard → Webhooks → event log.
-- Expected: informational
-- -----------------------------------------------------------------------------
SELECT event_type,
       COUNT(*) AS event_count,
       MIN(timestamp) AS first_seen,
       MAX(timestamp) AS last_seen
FROM webhook_events
WHERE timestamp > now() - interval '7 days'
GROUP BY event_type
ORDER BY event_count DESC;


-- -----------------------------------------------------------------------------
-- 2. CRITICAL — Same Stripe event_id with different response_status
-- (means idempotency cache returned differently for retries — indicates drift)
-- Expected: 0 rows
-- Schema: webhook_idempotency uses `processed_at` (not created_at).
-- -----------------------------------------------------------------------------
SELECT idempotency_key,
       webhook_type,
       COUNT(*) AS entry_count,
       COUNT(DISTINCT response_status) AS distinct_statuses,
       array_agg(DISTINCT response_status) AS statuses
FROM webhook_idempotency
WHERE processed_at > now() - interval '7 days'
GROUP BY idempotency_key, webhook_type
HAVING COUNT(DISTINCT response_status) > 1;


-- -----------------------------------------------------------------------------
-- 3. [NOT-USED] payment_failures table does not exist in this project.
-- Payment failure tracking currently happens only via Sentry + webhook logs.
-- If/when payment_failures is created (see maguey-bulletproof-email roadmap),
-- restore this query:
--   SELECT id, order_id, stripe_event_id, failure_code, failure_message,
--          resolved_at, created_at
--   FROM payment_failures
--   WHERE resolved_at IS NULL AND created_at < now() - interval '7 days';
-- -----------------------------------------------------------------------------


-- -----------------------------------------------------------------------------
-- 4. HIGH — Revenue discrepancies open > 24h
-- Expected: 0 rows
-- Schema: revenue_discrepancies uses `checked_at` (not created_at) and has
-- discrepancy_amount, db_revenue, stripe_revenue, event_id.
-- -----------------------------------------------------------------------------
SELECT id, event_id, db_revenue, stripe_revenue, discrepancy_amount,
       discrepancy_percent, checked_at
FROM revenue_discrepancies
WHERE resolved_at IS NULL
  AND checked_at < now() - interval '24 hours'
ORDER BY checked_at DESC;


-- -----------------------------------------------------------------------------
-- 5. HIGH — Sample of recent paid orders for reconciliation
-- Manually spot-check these against Stripe Dashboard
-- Expected: informational — user verifies each exists in Stripe
-- Schema: Stripe PaymentIntent id lives in `payment_reference`; session id (if any)
-- lives in `metadata->>'sessionId'` or `metadata->>'stripeSessionId'`.
-- -----------------------------------------------------------------------------
SELECT id AS order_id,
       purchaser_email,
       total,
       status,
       payment_reference AS stripe_payment_intent_id,
       metadata->>'sessionId' AS stripe_session_id,
       created_at
FROM orders
WHERE status = 'paid'
  AND created_at > now() - interval '3 days'
ORDER BY created_at DESC
LIMIT 20;


-- -----------------------------------------------------------------------------
-- 6. CRITICAL — saga_executions stuck in flight > 1h
-- Expected: 0 rows
-- Schema: status enum is 'running' (not 'in_progress'). Column is `saga_name`.
-- -----------------------------------------------------------------------------
SELECT id, saga_name, current_step, status, started_at,
       (now() - started_at) AS stuck_duration
FROM saga_executions
WHERE status IN ('running', 'pending', 'compensating')
  AND started_at < now() - interval '1 hour';


-- -----------------------------------------------------------------------------
-- 7. INFO — webhook_idempotency table size + TTL compliance
-- Expected: row count < 100k (if much higher, expiry not running)
-- Schema: uses `processed_at` (not created_at); `expires_at` present.
-- -----------------------------------------------------------------------------
SELECT COUNT(*) AS total_rows,
       COUNT(*) FILTER (WHERE processed_at < now() - interval '7 days') AS older_than_7d,
       COUNT(*) FILTER (WHERE expires_at < now()) AS past_expiry_rows,
       MIN(processed_at) AS oldest_entry,
       MAX(processed_at) AS newest_entry
FROM webhook_idempotency;


-- -----------------------------------------------------------------------------
-- 8. CRITICAL — Potential refunds not reflected (KNOWN GAP)
-- Orders where metadata hints refund but status still 'paid'
-- Also: use this to manually reconcile against Stripe Dashboard refund list
-- Expected: 0 rows in normal ops; >0 indicates manual reconciliation backlog
-- Schema: use `payment_reference` instead of `stripe_session_id`.
-- -----------------------------------------------------------------------------
SELECT o.id AS order_id,
       o.purchaser_email,
       o.total,
       o.status,
       o.payment_reference,
       o.created_at,
       o.updated_at
FROM orders o
WHERE o.status = 'paid'
  AND o.metadata::text ILIKE '%refund%'
  AND o.created_at > now() - interval '30 days';


-- -----------------------------------------------------------------------------
-- 9. HIGH — Orphan pending orders older than 24h (webhook never arrived)
-- Expected: 0 rows ideally (or low count if customers abandoned cart pre-checkout)
-- Schema: Stripe PaymentIntent id lives in `payment_reference`.
-- -----------------------------------------------------------------------------
SELECT id, purchaser_email, total, payment_reference, created_at,
       (now() - created_at) AS age
FROM orders
WHERE status = 'pending'
  AND created_at < now() - interval '24 hours'
ORDER BY created_at DESC
LIMIT 100;


-- -----------------------------------------------------------------------------
-- 10. HIGH — VIP reservations confirmed in DB but no matching webhook idempotency entry
-- (indicates client confirmed but webhook never fired — consistency at risk)
-- Expected: 0 rows
-- Schema: webhook_events has no event_id column; use webhook_idempotency instead.
-- That table stores the Stripe `event.id` in `idempotency_key`, not the PI id,
-- so the direct JOIN is imperfect — inspect `metadata` payload for the PI.
-- -----------------------------------------------------------------------------
SELECT vr.id AS reservation_id,
       vr.stripe_payment_intent_id,
       vr.status,
       vr.purchaser_email,
       vr.created_at
FROM vip_reservations vr
LEFT JOIN webhook_idempotency wi
  ON wi.webhook_type = 'stripe'
  AND wi.metadata::text ILIKE '%' || vr.stripe_payment_intent_id || '%'
WHERE vr.status = 'confirmed'
  AND vr.stripe_payment_intent_id IS NOT NULL
  AND wi.id IS NULL
  AND vr.created_at > now() - interval '7 days';


-- -----------------------------------------------------------------------------
-- 11. [DUPLICATE OF 1] — kept for backward-compat with older runs; see Query 1.
-- -----------------------------------------------------------------------------


-- -----------------------------------------------------------------------------
-- 12. [NOT-USED] `payments` table does not exist in this project.
-- Payment state lives on the `orders` row (status + payment_reference + metadata)
-- and on `vip_reservations` for VIP flow. No separate payments ledger.
-- -----------------------------------------------------------------------------


-- -----------------------------------------------------------------------------
-- 13. INFO — 24h revenue summary from DB (cross-check with Stripe dashboard)
-- -----------------------------------------------------------------------------
SELECT
  date_trunc('hour', created_at) AS hour,
  COUNT(*) FILTER (WHERE status = 'paid') AS paid_count,
  SUM(total) FILTER (WHERE status = 'paid') AS paid_cents,
  COUNT(*) FILTER (WHERE status = 'refunded') AS refunded_count,
  SUM(total) FILTER (WHERE status = 'refunded') AS refunded_cents
FROM orders
WHERE created_at > now() - interval '24 hours'
GROUP BY 1
ORDER BY 1 DESC;
