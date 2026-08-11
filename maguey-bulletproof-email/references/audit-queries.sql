-- =============================================================================
-- Maguey Bulletproof Email — Audit Queries
-- =============================================================================
-- SELECT-only. Run one at a time via mcp__supabase__execute_sql.
-- Project: Maguey Nightclub (djbzjasdrwvbsoifxqzd.supabase.co)
-- Expected: 0 rows unless noted.
--
-- SCHEMA REALITY CHECK (verified 2026-04-21):
--   email_queue columns: id, email_type, recipient_email, subject, html_body,
--     related_id, resend_email_id, status, attempt_count, max_attempts,
--     next_retry_at, last_error, error_context (jsonb), created_at, updated_at.
--     NO `sent_at` column — use `updated_at` as the sent-time proxy.
--   email_queue CHECK: email_type ∈ (ga_ticket, vip_confirmation,
--     ticket_transfer_received, ticket_transfer_sent, event_reminder_24h,
--     event_reminder_2h). status ∈ (pending, processing, sent, delivered,
--     failed). NO 'bounced' or 'complained' status values — those are recorded
--     in email_delivery_status and typically map to status='failed' here.
--   email_delivery_status columns: id, resend_email_id, event_type, event_data
--     (jsonb), created_at. NO email_queue_id FK — join via resend_email_id.
--   event_reminder_log columns: id, ticket_id, event_id, reminder_type,
--     sent_at, status.
--   newsletter_subscribers columns: id, email, subscribed_at, is_active, source.
--   Tables that DO NOT exist: alert_digest.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. CRITICAL — Emails stuck in 'pending' > 10 min (worker stopped)
-- Expected: 0 rows
-- Note: next_retry_at IS NULL means the row has never been attempted yet.
-- -----------------------------------------------------------------------------
SELECT id, email_type, recipient_email, attempt_count, next_retry_at, created_at,
       (now() - created_at) AS age
FROM email_queue
WHERE status = 'pending'
  AND (next_retry_at IS NULL OR next_retry_at < now())
  AND created_at < now() - interval '10 minutes'
ORDER BY created_at
LIMIT 100;


-- -----------------------------------------------------------------------------
-- 2. HIGH — Emails stuck in 'processing' > 5 min (worker crashed mid-send)
-- Expected: 0 rows
-- Schema note: no sent_at; updated_at flips when status moves pending→processing.
-- -----------------------------------------------------------------------------
SELECT id, email_type, recipient_email, attempt_count, updated_at,
       (now() - updated_at) AS stuck_duration
FROM email_queue
WHERE status = 'processing'
  AND updated_at < now() - interval '5 minutes';


-- -----------------------------------------------------------------------------
-- 3. CRITICAL — Bounce rate in last 7 days
-- Expected: bounce/delivered ratio < 5%. >10% threatens Resend reputation.
-- event_type values come from Resend webhook: sent, delivered, bounced, complained, opened, clicked.
-- -----------------------------------------------------------------------------
WITH recent_events AS (
  SELECT event_type, COUNT(*) AS cnt
  FROM email_delivery_status
  WHERE created_at > now() - interval '7 days'
  GROUP BY event_type
)
SELECT
  (SELECT cnt FROM recent_events WHERE event_type = 'bounced')  AS bounces,
  (SELECT cnt FROM recent_events WHERE event_type = 'delivered') AS delivered,
  (SELECT cnt FROM recent_events WHERE event_type = 'complained') AS complaints,
  ROUND(100.0 *
    COALESCE((SELECT cnt FROM recent_events WHERE event_type = 'bounced'), 0) /
    NULLIF((SELECT cnt FROM recent_events WHERE event_type IN ('delivered','bounced')), 0),
    2
  ) AS bounce_rate_pct;


-- -----------------------------------------------------------------------------
-- 4. HIGH — Emails marked 'sent' with no delivery_status follow-up >2h
-- (Resend webhook not reaching us; can't confirm delivery)
-- Expected: 0 rows
-- Join: via resend_email_id text match (no FK in live schema).
-- Use updated_at (there is no sent_at) as the "sent time" proxy.
-- -----------------------------------------------------------------------------
SELECT eq.id, eq.recipient_email, eq.resend_email_id, eq.updated_at AS sent_approx,
       (now() - eq.updated_at) AS age
FROM email_queue eq
LEFT JOIN email_delivery_status eds ON eds.resend_email_id = eq.resend_email_id
WHERE eq.status = 'sent'
  AND eq.updated_at < now() - interval '2 hours'
  AND eds.id IS NULL;


-- -----------------------------------------------------------------------------
-- 5. HIGH — Duplicate emails for same recipient + related_id + type
-- Expected: 0 rows (idempotency violation)
-- -----------------------------------------------------------------------------
SELECT recipient_email, email_type, related_id,
       COUNT(*) AS dup_count,
       array_agg(id) AS email_ids
FROM email_queue
WHERE related_id IS NOT NULL
  AND created_at > now() - interval '30 days'
GROUP BY recipient_email, email_type, related_id
HAVING COUNT(*) > 1
ORDER BY dup_count DESC;


-- -----------------------------------------------------------------------------
-- 6. MEDIUM — Orphan email_delivery_status rows (no matching email_queue via resend_email_id)
-- Expected: low (some Resend events arrive before we store the resend_email_id)
-- -----------------------------------------------------------------------------
SELECT eds.id, eds.resend_email_id, eds.event_type, eds.created_at
FROM email_delivery_status eds
LEFT JOIN email_queue eq ON eq.resend_email_id = eds.resend_email_id
WHERE eq.id IS NULL
  AND eds.created_at > now() - interval '30 days'
ORDER BY eds.created_at DESC
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 7. HIGH — Duplicate reminder emails for same ticket + reminder_type
-- Expected: 0 rows (event_reminder_log UNIQUE constraint should prevent)
-- -----------------------------------------------------------------------------
SELECT ticket_id, reminder_type, COUNT(*) AS dup_count
FROM event_reminder_log
GROUP BY ticket_id, reminder_type
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- 8. INFO — Email volume + status distribution (last 7 days)
-- Expected: informational
-- Note: avg "send delay" uses updated_at (when status became 'sent').
-- -----------------------------------------------------------------------------
SELECT email_type,
       status,
       COUNT(*) AS cnt,
       AVG(EXTRACT(EPOCH FROM (updated_at - created_at))) AS avg_transition_sec
FROM email_queue
WHERE created_at > now() - interval '7 days'
GROUP BY email_type, status
ORDER BY email_type, status;


-- -----------------------------------------------------------------------------
-- 9. CRITICAL — Paid orders without ga_ticket email enqueued
-- Expected: 0 rows (every paid order must have an email queued)
-- related_id is uuid in email_queue; cast order id to text only if needed.
-- -----------------------------------------------------------------------------
SELECT o.id AS order_id,
       o.purchaser_email,
       o.status,
       o.created_at
FROM orders o
LEFT JOIN email_queue eq
  ON eq.related_id = o.id
  AND eq.email_type = 'ga_ticket'
WHERE o.status = 'paid'
  AND o.created_at > now() - interval '30 days'
  AND eq.id IS NULL;


-- -----------------------------------------------------------------------------
-- 10. HIGH — pg_cron job schedule (verify worker is scheduled)
-- Expected: at least one active job pointing to email processing / send
-- -----------------------------------------------------------------------------
SELECT jobid, schedule, command, active, jobname
FROM cron.job
WHERE command ILIKE '%email%' OR jobname ILIKE '%email%';


-- -----------------------------------------------------------------------------
-- 11. INFO — Largest email bodies (QR-heavy VIP emails stress Resend size limit)
-- -----------------------------------------------------------------------------
SELECT id, email_type, recipient_email,
       LENGTH(html_body) AS body_bytes,
       created_at
FROM email_queue
WHERE created_at > now() - interval '7 days'
ORDER BY LENGTH(html_body) DESC
LIMIT 20;


-- -----------------------------------------------------------------------------
-- 12. MEDIUM — Failed emails grouped by error (last 7 days)
-- Use to spot systemic issues vs one-offs
-- -----------------------------------------------------------------------------
SELECT last_error,
       COUNT(*) AS occurrences,
       MAX(created_at) AS most_recent
FROM email_queue
WHERE status = 'failed'
  AND created_at > now() - interval '7 days'
GROUP BY last_error
ORDER BY occurrences DESC
LIMIT 30;


-- -----------------------------------------------------------------------------
-- 13. MEDIUM — newsletter_subscribers + transactional email sanity
-- Unsubscribed newsletter users should STILL receive transactional emails
-- (ga_ticket / vip_confirmation / ticket_transfer_* / event_reminder_*) —
-- this is legally required and expected. This query lets you verify.
-- Expected: informational
-- -----------------------------------------------------------------------------
SELECT eq.email_type,
       COUNT(*) AS transactional_to_unsubscribed
FROM email_queue eq
JOIN newsletter_subscribers ns ON ns.email = eq.recipient_email
WHERE ns.is_active = false
  AND eq.email_type IN ('ga_ticket','vip_confirmation','ticket_transfer_received','ticket_transfer_sent','event_reminder_24h','event_reminder_2h')
  AND eq.created_at > now() - interval '7 days'
GROUP BY eq.email_type;
