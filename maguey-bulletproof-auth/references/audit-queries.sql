-- =============================================================================
-- Maguey Bulletproof Auth — Audit Queries
-- =============================================================================
-- SELECT-only. Run one at a time via mcp__supabase__execute_sql.
-- Project: Maguey Nightclub (djbzjasdrwvbsoifxqzd.supabase.co)
-- Expected: 0 rows unless noted.
--
-- SCHEMA REALITY CHECK (verified 2026-04-21):
--   Tables in live DB: auth.users, security_alerts, security_event_logs, invitations.
--   Tables that DO NOT exist (referenced by older drafts):
--     profiles, login_activity, magic_links, user_devices, organizer_profiles.
--   security_alerts uses: acknowledged, acknowledged_by, acknowledged_at
--     (NOT resolved_at). Has: type, severity, source_ip, event_count, timestamp.
--   invitations columns: id, token, created_by, created_at, expires_at, used_at,
--     used_by, metadata. NO email or role columns — both live in metadata (jsonb).
--   auth.users COLUMN NAMES: the JSON keys the Supabase JS client exposes as
--     `user_metadata` / `app_metadata` map to Postgres columns named
--     `raw_user_meta_data` / `raw_app_meta_data`. When writing SQL against
--     auth.users directly, ALWAYS use the `raw_*_meta_data` names.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. CRITICAL — Users with unexpected role / account_type values
-- Expected: 0 rows
-- Scanner roles: owner | promoter | employee
-- Pass-lounge account_types: attendee | organizer
-- -----------------------------------------------------------------------------
SELECT id, email,
       raw_user_meta_data->>'role' AS scanner_role,
       raw_user_meta_data->>'account_type' AS pass_type,
       raw_app_meta_data->>'role' AS legacy_role,
       created_at
FROM auth.users
WHERE (raw_user_meta_data->>'role' IS NOT NULL
       AND raw_user_meta_data->>'role' NOT IN ('owner','promoter','employee'))
   OR (raw_user_meta_data->>'account_type' IS NOT NULL
       AND raw_user_meta_data->>'account_type' NOT IN ('attendee','organizer'))
   OR (raw_app_meta_data->>'role' IS NOT NULL
       AND raw_app_meta_data->>'role' NOT IN ('owner','promoter','employee','attendee','organizer'));


-- -----------------------------------------------------------------------------
-- 2. HIGH — Active invitations past expiry (cleanup candidate)
-- Expected: informational; pile-up indicates no cleanup cron
-- -----------------------------------------------------------------------------
SELECT id, token, created_by, created_at, expires_at, used_at,
       metadata->>'email' AS invited_email,
       metadata->>'role' AS invited_role,
       (now() - expires_at) AS expired_by
FROM invitations
WHERE expires_at < now() - interval '1 day'
  AND used_at IS NULL
ORDER BY expires_at DESC
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 3. HIGH — Invitations missing required metadata (can't complete signup)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, token, created_at, metadata,
       (metadata->>'email' IS NULL) AS missing_email,
       (metadata->>'role' IS NULL) AS missing_role
FROM invitations
WHERE used_at IS NULL
  AND expires_at > now()
  AND (metadata->>'email' IS NULL OR metadata->>'role' IS NULL);


-- -----------------------------------------------------------------------------
-- 4. HIGH — security_alerts unacknowledged >24h (not `resolved_at`)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, type, severity, source_ip, event_count, timestamp, acknowledged
FROM security_alerts
WHERE acknowledged = false
  AND timestamp < now() - interval '24 hours'
ORDER BY severity DESC, timestamp DESC
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 5. CRITICAL — RLS policies referencing role literals (find coverage gaps)
-- Expected: policies on money-touching tables all reference valid roles
-- -----------------------------------------------------------------------------
SELECT schemaname, tablename, policyname, cmd, roles, qual
FROM pg_policies
WHERE schemaname = 'public'
  AND (qual ILIKE '%role%' OR qual ILIKE '%account_type%')
ORDER BY tablename, cmd, policyname;


-- -----------------------------------------------------------------------------
-- 6. HIGH — Unconfirmed email but has login activity (should be blocked)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, email, email_confirmed_at, last_sign_in_at, created_at
FROM auth.users
WHERE email_confirmed_at IS NULL
  AND last_sign_in_at IS NOT NULL
ORDER BY last_sign_in_at DESC
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 7. INFO — Role distribution snapshot
-- -----------------------------------------------------------------------------
SELECT COALESCE(
         raw_user_meta_data->>'role',
         raw_user_meta_data->>'account_type',
         raw_app_meta_data->>'role',
         'unset'
       ) AS effective_role_or_type,
       COUNT(*) AS user_count
FROM auth.users
GROUP BY 1
ORDER BY user_count DESC;


-- -----------------------------------------------------------------------------
-- 8. HIGH — Security event log spikes in last 24h (signature failures etc.)
-- Expected: baseline rate; spikes = possible attack or deploy bug
-- -----------------------------------------------------------------------------
SELECT event_type,
       COUNT(*) AS event_count,
       COUNT(DISTINCT source_ip) AS distinct_ips,
       MAX(created_at) AS most_recent
FROM security_event_logs
WHERE created_at > now() - interval '24 hours'
GROUP BY event_type
ORDER BY event_count DESC;


-- -----------------------------------------------------------------------------
-- 9. MEDIUM — All public schema tables with RLS disabled (should be near 0)
-- Expected: 0 rows for tables holding customer/payment data
-- -----------------------------------------------------------------------------
SELECT schemaname, tablename
FROM pg_tables
WHERE schemaname = 'public'
  AND NOT EXISTS (
    SELECT 1 FROM pg_class c
    WHERE c.relname = pg_tables.tablename
      AND c.relnamespace = 'public'::regnamespace
      AND c.relrowsecurity = true
  )
ORDER BY tablename;


-- -----------------------------------------------------------------------------
-- 10. INFO — Recent auth.users signups (sanity check for flood / bot signups)
-- -----------------------------------------------------------------------------
SELECT date_trunc('day', created_at) AS day,
       COUNT(*) AS signups,
       COUNT(*) FILTER (WHERE email_confirmed_at IS NULL) AS unconfirmed
FROM auth.users
WHERE created_at > now() - interval '14 days'
GROUP BY 1
ORDER BY 1 DESC;
