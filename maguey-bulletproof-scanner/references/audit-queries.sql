-- =============================================================================
-- Maguey Bulletproof Scanner — Audit Queries
-- =============================================================================
-- SELECT-only. Run one at a time via mcp__supabase__execute_sql.
-- Project: Maguey Nightclub (djbzjasdrwvbsoifxqzd.supabase.co)
-- Expected: 0 rows unless noted.
--
-- SCHEMA REALITY CHECK (verified 2026-04-21):
--   - scan_logs columns: id, ticket_id, scanned_by, scan_result, scanned_at,
--     metadata, scan_success, device_id, scan_method. NO event_id column
--     (event_id lives in scan_logs.metadata->>'event_id' if set by app).
--   - tickets: scanned_at / is_used / status / current_status. NO checked_in_at.
--   - ticket_events: id, aggregate_id (uuid, == ticket id), event_type,
--     event_data, metadata, sequence_number, occurred_at, recorded_at,
--     correlation_id, causation_id, schema_version. NO ticket_id, NO created_at.
--   - vip_guest_passes: scanned_at (NOT checked_in_at).
--   - scanner_heartbeats: device_id, device_name, last_heartbeat, is_online,
--     pending_scans, current_event_id, current_event_name, scans_today.
--
-- Tables that do NOT exist in this DB (referenced by older skill drafts):
--   fraud_detection_logs, scanner_devices, scan_metadata, scan_velocity_metrics,
--   device_battery_logs, emergency_override_logs, ticket_failed_scans.
--   Queries that reference them are commented out and marked N/A.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. CRITICAL — Successful scan_logs must have a ticket_id
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, device_id, scanned_at, scan_method, scan_result
FROM scan_logs
WHERE scan_success = true
  AND ticket_id IS NULL
  AND scanned_at > now() - interval '30 days';


-- -----------------------------------------------------------------------------
-- 2. CRITICAL — Tickets marked scanned must have a matching scan_log
-- Expected: 0 rows
-- (tickets.scanned_at / is_used are the authoritative scan markers; there is no
-- checked_in_at column. A successful scan_logs row should pair with each.)
-- -----------------------------------------------------------------------------
SELECT t.id AS ticket_id, t.scanned_at, t.is_used, t.status
FROM tickets t
LEFT JOIN scan_logs sl
  ON sl.ticket_id = t.id AND sl.scan_success = true
WHERE (t.is_used = true OR t.status = 'scanned')
  AND t.scanned_at IS NOT NULL
  AND t.scanned_at > now() - interval '30 days'
  AND sl.id IS NULL;


-- -----------------------------------------------------------------------------
-- 3. HIGH — Offline scans stuck > 7 days
-- N/A at DB level — offline scans live in Dexie IndexedDB on each scanner
-- device. There is no scanner_offline_scans table. Check per-device via UI.
-- -----------------------------------------------------------------------------


-- -----------------------------------------------------------------------------
-- 4. HIGH — Scanner heartbeat gaps > 2h in last 7 days
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
WITH ordered AS (
  SELECT device_id, last_heartbeat,
         LAG(last_heartbeat) OVER (PARTITION BY device_id ORDER BY last_heartbeat) AS prev_beat
  FROM scanner_heartbeats
  WHERE last_heartbeat > now() - interval '7 days'
)
SELECT device_id, prev_beat AS gap_start, last_heartbeat AS gap_end,
       (last_heartbeat - prev_beat) AS gap_duration
FROM ordered
WHERE prev_beat IS NOT NULL
  AND (last_heartbeat - prev_beat) > interval '2 hours'
ORDER BY gap_duration DESC
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 5. CRITICAL — Duplicate scan_logs for same ticket within 1s (cooldown bypass)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
WITH ordered AS (
  SELECT ticket_id, scanned_at,
         LAG(scanned_at) OVER (PARTITION BY ticket_id ORDER BY scanned_at) AS prev_scan,
         device_id
  FROM scan_logs
  WHERE ticket_id IS NOT NULL
    AND scanned_at > now() - interval '30 days'
)
SELECT ticket_id, prev_scan, scanned_at, device_id,
       (scanned_at - prev_scan) AS gap
FROM ordered
WHERE prev_scan IS NOT NULL
  AND (scanned_at - prev_scan) < interval '1 second';


-- -----------------------------------------------------------------------------
-- 6. HIGH — Signature verification failures last 24h
-- Spike => wrong secret deployed, ticket re-signing needed, or attacker probing
-- -----------------------------------------------------------------------------
SELECT date_trunc('hour', scanned_at) AS hour,
       scan_result,
       COUNT(*) AS failures
FROM scan_logs
WHERE scan_result IN ('invalid_signature', 'unsigned_qr', 'verification_failed', 'invalid_format')
  AND scanned_at > now() - interval '24 hours'
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;


-- -----------------------------------------------------------------------------
-- 7. MEDIUM — scan_velocity_metrics out of normal range
-- N/A — scan_velocity_metrics table does not exist in this DB.
-- Closest available: count scans per device per minute from scan_logs.
-- -----------------------------------------------------------------------------
SELECT device_id,
       date_trunc('minute', scanned_at) AS minute,
       COUNT(*) AS scans_per_minute
FROM scan_logs
WHERE scanned_at > now() - interval '7 days'
  AND device_id IS NOT NULL
GROUP BY 1, 2
HAVING COUNT(*) > 20  -- Flag >20 scans/minute (likely bot or stuck loop)
ORDER BY 3 DESC
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 8. HIGH — fraud_detection_logs with unresolved flags
-- N/A — fraud_detection_logs table does not exist in this DB.
-- If fraud detection is added, restore this query. For now: see query #7.
-- -----------------------------------------------------------------------------


-- -----------------------------------------------------------------------------
-- 9. MEDIUM — Emergency overrides in last 7 days (operational context)
-- N/A — emergency_override_logs table does not exist in this DB.
-- -----------------------------------------------------------------------------


-- -----------------------------------------------------------------------------
-- 10. HIGH — Tickets scanned for WRONG event
-- Requires scan_logs.event_id column (added by migration
-- 20260421_add_event_id_to_scan_logs.sql — ships with scanner-hardening fix).
-- Until that migration ships, event_id may live in scan_logs.metadata->>'event_id'.
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
-- After migration (preferred):
-- SELECT sl.id AS scan_log_id, sl.ticket_id, sl.event_id AS scanned_event,
--        t.event_id AS ticket_event, sl.scanned_at
-- FROM scan_logs sl
-- JOIN tickets t ON t.id = sl.ticket_id
-- WHERE sl.event_id IS NOT NULL
--   AND sl.event_id <> t.event_id
--   AND sl.scanned_at > now() - interval '7 days';

-- Pre-migration fallback (reads metadata jsonb):
SELECT sl.id AS scan_log_id,
       sl.ticket_id,
       (sl.metadata->>'event_id')::uuid AS scanned_event_metadata,
       t.event_id AS ticket_event,
       sl.scanned_at
FROM scan_logs sl
JOIN tickets t ON t.id = sl.ticket_id
WHERE sl.metadata ? 'event_id'
  AND (sl.metadata->>'event_id')::uuid <> t.event_id
  AND sl.scanned_at > now() - interval '7 days';


-- -----------------------------------------------------------------------------
-- 11. INFO — Scanner device inventory and activity
-- N/A — no scanner_devices registration table. Use scanner_heartbeats + scan_logs.
-- -----------------------------------------------------------------------------
SELECT sh.device_id,
       sh.device_name,
       sh.last_heartbeat,
       sh.is_online,
       sh.pending_scans,
       sh.scans_today,
       (SELECT COUNT(*) FROM scan_logs sl
        WHERE sl.device_id = sh.device_id
          AND sl.scanned_at > now() - interval '7 days') AS scans_last_7d
FROM scanner_heartbeats sh
ORDER BY sh.last_heartbeat DESC
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 12. INFO — ticket_events event sourcing volume (uses occurred_at, not created_at)
-- Should grow linearly with scans. Sharp drop = event sourcing broken.
-- -----------------------------------------------------------------------------
SELECT date_trunc('day', COALESCE(occurred_at, recorded_at)) AS day,
       event_type,
       COUNT(*) AS event_count
FROM ticket_events
WHERE COALESCE(occurred_at, recorded_at) > now() - interval '14 days'
GROUP BY 1, 2
ORDER BY 1 DESC, 2;


-- -----------------------------------------------------------------------------
-- 13. CRITICAL — VIP guest pass scans not logged to vip_scan_logs
-- vip_guest_passes uses `scanned_at` (not `checked_in_at`).
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT vgp.id AS pass_id,
       vgp.scanned_at,
       vgp.status,
       (SELECT COUNT(*) FROM vip_scan_logs vsl WHERE vsl.pass_id = vgp.id) AS scan_log_count
FROM vip_guest_passes vgp
WHERE vgp.status = 'checked_in'
  AND vgp.scanned_at > now() - interval '30 days'
  AND NOT EXISTS (SELECT 1 FROM vip_scan_logs vsl WHERE vsl.pass_id = vgp.id)
LIMIT 50;
