-- =============================================================================
-- Bulletproof Push Notifications — Audit Queries
-- =============================================================================
-- SELECT-only. Run via mcp__supabase-mt__execute_sql. Project: MT Barbershop.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 0. SCHEMA VERIFICATION
-- Expected columns: id, endpoint, p256dh, auth, user_id, queue_token,
--                   created_at, updated_at
-- -----------------------------------------------------------------------------
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'push_subscriptions'
ORDER BY ordinal_position;


-- -----------------------------------------------------------------------------
-- 1. CRITICAL — No orphaned subscriptions (both user_id and queue_token null)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, endpoint, created_at
FROM push_subscriptions
WHERE user_id IS NULL AND queue_token IS NULL;


-- -----------------------------------------------------------------------------
-- 2. CRITICAL — Endpoint uniqueness (duplicates cause duplicate pushes)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT endpoint,
       COUNT(*) AS n,
       array_agg(id) AS subscription_ids
FROM push_subscriptions
GROUP BY endpoint
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- 3. HIGH — user_id references valid profile
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT ps.id, ps.user_id, ps.created_at
FROM push_subscriptions ps
LEFT JOIN profiles p ON p.id = ps.user_id
WHERE ps.user_id IS NOT NULL
  AND p.id IS NULL;


-- -----------------------------------------------------------------------------
-- 4. HIGH — Cryptographic keys present
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, endpoint
FROM push_subscriptions
WHERE p256dh IS NULL OR p256dh = ''
   OR auth IS NULL OR auth = '';


-- -----------------------------------------------------------------------------
-- 5. MEDIUM — Endpoint is HTTPS URL
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, substring(endpoint, 1, 80) AS endpoint_prefix
FROM push_subscriptions
WHERE endpoint NOT LIKE 'https://%'
LIMIT 20;


-- -----------------------------------------------------------------------------
-- 6. HIGH — Barber subscription coverage (every active barber has ≥1)
-- Expected: 0 rows (every active barber subscribed)
-- -----------------------------------------------------------------------------
SELECT b.id AS barber_id, b.slug,
       p.first_name, p.last_name, p.email
FROM barbers b
JOIN profiles p ON p.id = b.profile_id
LEFT JOIN push_subscriptions ps ON ps.user_id = p.id
WHERE b.is_active = true
GROUP BY b.id, b.slug, p.first_name, p.last_name, p.email
HAVING COUNT(ps.id) = 0
ORDER BY b.slug;


-- -----------------------------------------------------------------------------
-- 7. MEDIUM — Owner subscription coverage
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT p.id, p.email, p.first_name, p.last_name
FROM profiles p
LEFT JOIN push_subscriptions ps ON ps.user_id = p.id
WHERE p.role = 'owner'
GROUP BY p.id, p.email, p.first_name, p.last_name
HAVING COUNT(ps.id) = 0;


-- -----------------------------------------------------------------------------
-- 8. INFO — Subscription age distribution
-- -----------------------------------------------------------------------------
SELECT
  COUNT(*) FILTER (WHERE created_at > now() - interval '7 days')    AS new_7d,
  COUNT(*) FILTER (WHERE created_at > now() - interval '30 days')   AS new_30d,
  COUNT(*) FILTER (WHERE updated_at > now() - interval '7 days')    AS updated_7d,
  COUNT(*) FILTER (WHERE updated_at <= now() - interval '30 days')  AS stale_30d,
  COUNT(*) FILTER (WHERE updated_at <= now() - interval '90 days')  AS stale_90d,
  COUNT(*) AS total
FROM push_subscriptions;


-- -----------------------------------------------------------------------------
-- 9. INFO — Coverage by role
-- -----------------------------------------------------------------------------
SELECT p.role,
       COUNT(DISTINCT p.id)                                AS total_profiles,
       COUNT(DISTINCT p.id) FILTER (WHERE ps.id IS NOT NULL) AS with_subscription,
       ROUND(100.0 * COUNT(DISTINCT p.id) FILTER (WHERE ps.id IS NOT NULL)
             / NULLIF(COUNT(DISTINCT p.id), 0), 1)         AS coverage_pct
FROM profiles p
LEFT JOIN push_subscriptions ps ON ps.user_id = p.id
WHERE p.role IN ('owner', 'barber', 'student')
GROUP BY p.role
ORDER BY coverage_pct ASC;


-- -----------------------------------------------------------------------------
-- 10. INFO — Devices per barber (operational redundancy check)
-- -----------------------------------------------------------------------------
SELECT b.slug, p.first_name, p.last_name,
       COUNT(ps.id) AS device_count,
       MAX(ps.updated_at) AS last_activity
FROM barbers b
JOIN profiles p ON p.id = b.profile_id
LEFT JOIN push_subscriptions ps ON ps.user_id = p.id
WHERE b.is_active = true
GROUP BY b.slug, p.first_name, p.last_name
ORDER BY device_count DESC, b.slug;


-- -----------------------------------------------------------------------------
-- 11. MEDIUM — Recent queue_token subscriptions (customer tracker)
-- Expected: correlates with recent queue entries
-- -----------------------------------------------------------------------------
SELECT DATE_TRUNC('day', ps.created_at) AS day,
       COUNT(*) AS new_customer_subscriptions
FROM push_subscriptions ps
WHERE ps.queue_token IS NOT NULL
  AND ps.created_at > now() - interval '14 days'
GROUP BY day
ORDER BY day DESC;


-- -----------------------------------------------------------------------------
-- 12. MEDIUM — queue_token subscriptions without matching queue entry
-- (might be fine if entry was cleaned up, but flag recent ones)
-- Expected: few/none in last 7 days
-- -----------------------------------------------------------------------------
SELECT ps.id, ps.queue_token, ps.created_at
FROM push_subscriptions ps
LEFT JOIN queue_entries qe ON qe.tracking_token = ps.queue_token
WHERE ps.queue_token IS NOT NULL
  AND qe.id IS NULL
  AND ps.created_at > now() - interval '7 days'
LIMIT 20;


-- -----------------------------------------------------------------------------
-- 13. INFO — Endpoint domain distribution (push service providers)
-- -----------------------------------------------------------------------------
SELECT
  CASE
    WHEN endpoint LIKE 'https://fcm.googleapis.com/%' THEN 'FCM (Chrome/Android)'
    WHEN endpoint LIKE 'https://android.googleapis.com/%' THEN 'FCM legacy'
    WHEN endpoint LIKE 'https://updates.push.services.mozilla.com/%' THEN 'Firefox'
    WHEN endpoint LIKE 'https://%.push.apple.com/%' THEN 'APNs (Safari/iOS)'
    WHEN endpoint LIKE 'https://%.notify.windows.com/%' THEN 'WNS (Edge)'
    ELSE 'Other'
  END AS provider,
  COUNT(*) AS n
FROM push_subscriptions
GROUP BY provider
ORDER BY n DESC;


-- -----------------------------------------------------------------------------
-- 14. INFO — Subscription turnover (new vs replaced)
-- -----------------------------------------------------------------------------
SELECT
  COUNT(*) FILTER (WHERE created_at = updated_at) AS never_updated,
  COUNT(*) FILTER (WHERE updated_at > created_at + interval '1 hour') AS updated_later,
  COUNT(*) AS total
FROM push_subscriptions;


-- -----------------------------------------------------------------------------
-- 15. INFO — Eligible subscribers per audience
-- Classifies code-plane failures as LIVE (active subscribers) vs LATENT
-- (no subscribers yet). Pair with invariant C13 grep.
-- -----------------------------------------------------------------------------
SELECT 'barbers_active_with_subs' AS audience,
       COUNT(DISTINCT b.id) AS n
FROM barbers b
JOIN push_subscriptions ps ON ps.user_id = b.profile_id
WHERE b.is_active = true

UNION ALL

SELECT 'clients_with_profile_subs' AS audience,
       COUNT(DISTINCT c.profile_id) AS n
FROM clients c
JOIN push_subscriptions ps ON ps.user_id = c.profile_id
WHERE c.profile_id IS NOT NULL

UNION ALL

SELECT 'owners_with_subs' AS audience,
       COUNT(DISTINCT p.id) AS n
FROM profiles p
JOIN push_subscriptions ps ON ps.user_id = p.id
WHERE p.role = 'owner'

UNION ALL

SELECT 'queue_token_subs_last_7d' AS audience,
       COUNT(*) AS n
FROM push_subscriptions
WHERE queue_token IS NOT NULL
  AND created_at > now() - interval '7 days';

-- Usage:
-- If "clients_with_profile_subs" = 0 and the code-plane check flagged a bug in
-- the client-booking push path, classify as LATENT (fix when wiring the feature).
-- If > 0 and a bug is flagged, classify as LIVE (fix with urgency).


-- -----------------------------------------------------------------------------
-- 16. RACE — Duplicate barber notifications for the same entry within 10s
-- Detects race conditions (C16) and browser dedupe failures (missing `tag`)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT related_id,
       COUNT(*) AS dupes,
       MIN(created_at) AS first_fired,
       MAX(created_at) AS last_fired,
       array_agg(DISTINCT type) AS types
FROM barber_notifications
WHERE created_at > now() - interval '7 days'
GROUP BY related_id
HAVING COUNT(*) > 1
   AND (MAX(created_at) - MIN(created_at)) < interval '10 seconds'
ORDER BY dupes DESC, first_fired DESC
LIMIT 20;


-- -----------------------------------------------------------------------------
-- 17. TRIGGER PARITY — Active barbers who should have a push sub but don't
-- Active barbers without any push subscription will silently miss Call Next
-- alerts on their phone. This is an onboarding gap — cross-reference
-- `bulletproof-onboarding` skill for the remediation flow.
-- Expected: 0 rows (every active barber enrolled)
-- -----------------------------------------------------------------------------
SELECT b.id AS barber_id,
       b.slug,
       p.first_name,
       p.last_name,
       p.email,
       b.onboarding_step
FROM barbers b
JOIN profiles p ON p.id = b.profile_id
LEFT JOIN push_subscriptions ps ON ps.user_id = p.id
WHERE b.is_active = true
GROUP BY b.id, b.slug, p.first_name, p.last_name, p.email, b.onboarding_step
HAVING COUNT(ps.id) = 0
ORDER BY b.slug;


-- -----------------------------------------------------------------------------
-- 18. iOS COVERAGE — APNs (Apple) vs FCM (Android/Chrome) distribution
-- Low APNs share + high active iOS traffic (check analytics separately) may
-- indicate the iOS PWA install gate (C15) is missing or the install friction
-- is too high.
-- -----------------------------------------------------------------------------
SELECT
  CASE
    WHEN endpoint LIKE 'https://%.push.apple.com/%' THEN 'APNs (iOS Safari PWA)'
    WHEN endpoint LIKE 'https://fcm.googleapis.com/%' THEN 'FCM (Chrome/Android)'
    WHEN endpoint LIKE 'https://updates.push.services.mozilla.com/%' THEN 'Firefox'
    WHEN endpoint LIKE 'https://%.notify.windows.com/%' THEN 'WNS (Edge)'
    ELSE 'Other'
  END AS provider,
  COUNT(*) AS n,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_total
FROM push_subscriptions
GROUP BY provider
ORDER BY n DESC;
