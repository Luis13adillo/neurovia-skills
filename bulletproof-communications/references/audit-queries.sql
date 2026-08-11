-- =============================================================================
-- Bulletproof Communications — Audit Queries
-- =============================================================================
-- SELECT-only. Run via mcp__supabase-mt__execute_sql. Project: MT Barbershop.
-- ALWAYS run schema verification (in SKILL.md preflight) BEFORE these queries.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 0. SCHEMA VERIFICATION — confirm column names before trusting the queries below
-- -----------------------------------------------------------------------------
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('sms_templates', 'sms_blasts', 'sms_logs',
                     'sms_opt_outs', 'owner_alerts', 'communication_settings',
                     'winback_sent', 'saved_audiences')
ORDER BY table_name, ordinal_position;


-- -----------------------------------------------------------------------------
-- 1. CRITICAL — No SMS sent to opted-out phones (TCPA compliance)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT sl.id,
       sl.recipient_phone,
       sl.trigger_type,
       sl.status,
       sl.created_at AS sent_at,
       so.created_at AS opted_out_at,
       so.keyword
FROM sms_logs sl
JOIN sms_opt_outs so ON so.phone = sl.recipient_phone
WHERE sl.status IN ('queued', 'sent', 'delivered')
  AND sl.created_at > so.created_at;


-- -----------------------------------------------------------------------------
-- 2. HIGH — Duplicate 24h reminders per booking
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT sl.recipient_phone,
       b.id AS booking_id,
       COUNT(sl.id) AS reminder_count,
       array_agg(sl.id ORDER BY sl.created_at) AS sms_log_ids
FROM sms_logs sl
JOIN bookings b ON b.client_phone = sl.recipient_phone
WHERE sl.trigger_type ILIKE '%reminder_24%'
  AND sl.created_at > b.created_at
  AND sl.created_at < (b.scheduled_date + b.scheduled_time + interval '1 hour')
  AND sl.status IN ('queued', 'sent', 'delivered')
GROUP BY sl.recipient_phone, b.id
HAVING COUNT(sl.id) > 1
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 3. HIGH — reminder_sent = true but no matching SMS log
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT b.id AS booking_id, b.client_phone, b.reminder_sent, b.scheduled_date
FROM bookings b
LEFT JOIN sms_logs sl
       ON sl.recipient_phone = b.client_phone
      AND sl.trigger_type ILIKE '%reminder_24%'
      AND sl.created_at > b.created_at
      AND sl.status IN ('sent', 'delivered', 'skipped_opt_out')
WHERE b.reminder_sent = true
  AND b.deleted_at IS NULL
  AND b.created_at > now() - interval '30 days'
  AND sl.id IS NULL
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 4. HIGH — Duplicate template keys
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT key, COUNT(*) AS n, array_agg(id) AS template_ids
FROM sms_templates
GROUP BY key
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- 5. HIGH — Active templates with empty or trivial body
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, key, name, body
FROM sms_templates
WHERE is_active = true
  AND (body IS NULL OR body = '' OR length(body) < 5);


-- -----------------------------------------------------------------------------
-- 6. HIGH — SMS log status values in valid enum
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT status, COUNT(*) AS n
FROM sms_logs
WHERE status IS NOT NULL
  AND status NOT IN ('queued', 'sent', 'delivered', 'failed', 'undelivered',
                     'skipped_opt_out', 'skipped_invalid')
GROUP BY status;


-- -----------------------------------------------------------------------------
-- 7. HIGH — Blast status values valid
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT status, COUNT(*) AS n
FROM sms_blasts
WHERE status NOT IN ('draft', 'scheduled', 'sending', 'completed', 'cancelled')
GROUP BY status;


-- -----------------------------------------------------------------------------
-- 8. MEDIUM — Completed blasts where sent + failed != recipient count
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, name, recipient_count, sent_count, failed_count, delivered_count, status
FROM sms_blasts
WHERE status = 'completed'
  AND (COALESCE(sent_count, 0) + COALESCE(failed_count, 0)) != recipient_count;


-- -----------------------------------------------------------------------------
-- 9. MEDIUM — winback_sent uniqueness per (client, interval)
-- Expected: 0 rows (UNIQUE constraint should prevent this)
-- -----------------------------------------------------------------------------
SELECT client_id, interval_weeks, COUNT(*) AS n
FROM winback_sent
GROUP BY client_id, interval_weeks
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- 10. INFO — SMS volume last 30 days
-- -----------------------------------------------------------------------------
SELECT DATE_TRUNC('day', created_at) AS day,
       COUNT(*)                                      AS total,
       COUNT(*) FILTER (WHERE status = 'delivered')  AS delivered,
       COUNT(*) FILTER (WHERE status = 'failed')     AS failed,
       COUNT(*) FILTER (WHERE status = 'skipped_opt_out') AS skipped
FROM sms_logs
WHERE created_at > now() - interval '30 days'
GROUP BY day
ORDER BY day DESC;


-- -----------------------------------------------------------------------------
-- 11. INFO — Opt-out rate (last 30 days)
-- -----------------------------------------------------------------------------
WITH stats AS (
  SELECT
    (SELECT COUNT(*) FROM sms_opt_outs
      WHERE created_at > now() - interval '30 days') AS opt_outs_30d,
    (SELECT COUNT(DISTINCT recipient_phone) FROM sms_logs
      WHERE created_at > now() - interval '30 days'
        AND status IN ('sent','delivered')) AS unique_recipients_30d
)
SELECT opt_outs_30d,
       unique_recipients_30d,
       ROUND(100.0 * opt_outs_30d / NULLIF(unique_recipients_30d, 0), 2) AS opt_out_pct
FROM stats;


-- -----------------------------------------------------------------------------
-- 12. INFO — Recent owner_alerts by type
-- -----------------------------------------------------------------------------
SELECT type, COUNT(*) AS total,
       COUNT(*) FILTER (WHERE is_read = false) AS unread
FROM owner_alerts
WHERE created_at > now() - interval '30 days'
GROUP BY type
ORDER BY total DESC;


-- -----------------------------------------------------------------------------
-- 13. INFO — SMS trigger_type distribution
-- -----------------------------------------------------------------------------
SELECT trigger_type,
       COUNT(*) AS total,
       COUNT(*) FILTER (WHERE status = 'delivered') AS delivered,
       COUNT(*) FILTER (WHERE status = 'failed')    AS failed
FROM sms_logs
WHERE created_at > now() - interval '30 days'
GROUP BY trigger_type
ORDER BY total DESC;


-- -----------------------------------------------------------------------------
-- 14. INFO — Pending / scheduled blasts
-- -----------------------------------------------------------------------------
SELECT id, name, status, scheduled_at, recipient_count, created_by
FROM sms_blasts
WHERE status IN ('draft', 'scheduled', 'sending')
ORDER BY scheduled_at NULLS LAST, created_at DESC;
