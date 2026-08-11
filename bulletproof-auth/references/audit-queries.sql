-- =============================================================================
-- Bulletproof Auth — Audit Queries
-- =============================================================================
-- SELECT-only. Run via mcp__supabase-mt__execute_sql. Project: MT Barbershop.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. CRITICAL — Every profile has a valid role
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, email, role
FROM profiles
WHERE role IS NULL
   OR role NOT IN ('owner', 'barber', 'student', 'client');


-- -----------------------------------------------------------------------------
-- 2. CRITICAL — Every barber has matching profile with role in (barber, owner)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT b.id AS barber_id, b.profile_id, p.email, p.role
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE p.id IS NULL
   OR p.role NOT IN ('barber', 'owner');


-- -----------------------------------------------------------------------------
-- 3. HIGH — Every auth.users user has a matching profile
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT u.id, u.email
FROM auth.users u
LEFT JOIN profiles p ON p.id = u.id
WHERE p.id IS NULL;


-- -----------------------------------------------------------------------------
-- 4. CRITICAL — Real owner account integrity (info@mtbarbershop.com)
-- Expected: 1 row, role='owner', linked to barbers.id='b0010000...'
-- -----------------------------------------------------------------------------
SELECT p.id AS profile_id,
       p.email,
       p.role,
       p.first_login_completed,
       b.id AS barber_id,
       b.is_active AS barber_active
FROM profiles p
LEFT JOIN barbers b ON b.profile_id = p.id
WHERE p.email = 'info@mtbarbershop.com';


-- -----------------------------------------------------------------------------
-- 5. HIGH — Dev owner account integrity (dev@mtbarbershop.com)
-- Expected: 1 row, role='owner', linked to barbers.id='a274e1cf...'
-- -----------------------------------------------------------------------------
SELECT p.id AS profile_id,
       p.email,
       p.role,
       b.id AS barber_id,
       b.is_active AS barber_active
FROM profiles p
LEFT JOIN barbers b ON b.profile_id = p.id
WHERE p.email = 'dev@mtbarbershop.com';


-- -----------------------------------------------------------------------------
-- 6. HIGH — Test barber accounts are inactive
-- Expected: 3 rows, all is_active=false
-- -----------------------------------------------------------------------------
SELECT b.id AS barber_id, b.is_active, p.email, p.role
FROM barbers b
JOIN profiles p ON p.id = b.profile_id
WHERE b.id IN (
  'b0020000-0000-0000-0000-000000000002',
  'b0030000-0000-0000-0000-000000000003',
  'b0040000-0000-0000-0000-000000000004'
);


-- -----------------------------------------------------------------------------
-- 7. CRITICAL — No duplicate emails in profiles
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT email, COUNT(*) AS n, array_agg(id) AS profile_ids
FROM profiles
WHERE email IS NOT NULL
GROUP BY email
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- 8. HIGH — Currently active lockouts (informational)
-- -----------------------------------------------------------------------------
SELECT al.id, al.profile_id, p.email, al.failed_attempts,
       al.locked_until, al.locked_at
FROM auth_lockouts al
LEFT JOIN profiles p ON p.id = al.profile_id
WHERE al.locked_until > now()
ORDER BY al.locked_until DESC;


-- -----------------------------------------------------------------------------
-- 9. LOW — Old / stale lockout records (hygiene)
-- Expected: few/none; cleanup optional
-- -----------------------------------------------------------------------------
SELECT al.id, al.profile_id, al.failed_attempts,
       al.locked_until, al.locked_at
FROM auth_lockouts al
WHERE al.locked_until < now() - interval '30 days';


-- -----------------------------------------------------------------------------
-- 10. MEDIUM — Expired sessions still in active_sessions (cleanup cron signal)
-- Expected: 0 rows (cleanup should remove these)
-- -----------------------------------------------------------------------------
SELECT COUNT(*) AS stale_sessions,
       MIN(expires_at) AS oldest_expired,
       MAX(expires_at) AS most_recent_expired
FROM active_sessions
WHERE expires_at < now();


-- -----------------------------------------------------------------------------
-- 11. HIGH — Multiple concurrent active sessions per profile
-- Expected: 0 rows (concurrent login enforcement kicks old sessions)
-- -----------------------------------------------------------------------------
SELECT profile_id, COUNT(*) AS active_count
FROM active_sessions
WHERE expires_at > now()
GROUP BY profile_id
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- 12. MEDIUM — auth_events event_type distribution (last 30 days)
-- Expected: subset of known event types
-- -----------------------------------------------------------------------------
SELECT event_type, COUNT(*) AS n
FROM auth_events
WHERE created_at > now() - interval '30 days'
GROUP BY event_type
ORDER BY n DESC;


-- -----------------------------------------------------------------------------
-- 13. MEDIUM — Recent login failures (suspicious pattern detection)
-- -----------------------------------------------------------------------------
SELECT email,
       COUNT(*) FILTER (WHERE event_type = 'login_failed') AS failures,
       COUNT(*) FILTER (WHERE event_type = 'login_success') AS successes,
       COUNT(DISTINCT ip_address) AS unique_ips
FROM auth_events
WHERE created_at > now() - interval '7 days'
  AND email IS NOT NULL
GROUP BY email
HAVING COUNT(*) FILTER (WHERE event_type = 'login_failed') >= 5
ORDER BY failures DESC
LIMIT 20;


-- -----------------------------------------------------------------------------
-- 14. MEDIUM — Barbers with first_login_completed but no login_success events
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT p.id, p.email, p.first_login_completed, p.role,
       COUNT(ae.id) AS login_success_events
FROM profiles p
LEFT JOIN auth_events ae ON ae.profile_id = p.id
                         AND ae.event_type = 'login_success'
WHERE p.role = 'barber'
  AND p.first_login_completed = true
GROUP BY p.id, p.email, p.first_login_completed, p.role
HAVING COUNT(ae.id) = 0;


-- -----------------------------------------------------------------------------
-- 15. LOW — Barbers with unreasonable grace_period_ends_at
-- Expected: 0 rows, except test barbers with sentinel dates
-- -----------------------------------------------------------------------------
SELECT b.id, b.slug, b.grace_period_ends_at, b.is_active, p.email
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE b.grace_period_ends_at < '2024-01-01'
   OR b.grace_period_ends_at > now() + interval '1 year';


-- -----------------------------------------------------------------------------
-- 16. INFO — Role distribution
-- -----------------------------------------------------------------------------
SELECT role, COUNT(*) AS n
FROM profiles
GROUP BY role
ORDER BY n DESC;


-- -----------------------------------------------------------------------------
-- 17. INFO — Active sessions by device type (scale indicator)
-- -----------------------------------------------------------------------------
SELECT device_type, browser, COUNT(*) AS active_sessions
FROM active_sessions
WHERE expires_at > now()
GROUP BY device_type, browser
ORDER BY active_sessions DESC;


-- -----------------------------------------------------------------------------
-- 18. INFO — Recent auth event timeline (last 24 hours)
-- -----------------------------------------------------------------------------
SELECT event_type, COUNT(*) AS events,
       COUNT(DISTINCT profile_id) AS unique_users
FROM auth_events
WHERE created_at > now() - interval '24 hours'
GROUP BY event_type
ORDER BY events DESC;
