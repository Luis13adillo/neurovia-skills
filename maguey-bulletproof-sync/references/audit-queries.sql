-- =============================================================================
-- Maguey Bulletproof Sync — Audit Queries
-- =============================================================================
-- SELECT-only. Run one at a time via mcp__supabase__execute_sql.
-- Project: Maguey Nightclub (djbzjasdrwvbsoifxqzd.supabase.co)
-- Expected: 0 rows unless noted.
--
-- SCHEMA REALITY CHECK (verified 2026-04-21):
--   CRITICAL: supabase_realtime publication is EMPTY. Postgres-changes subscriptions
--     receive NO events. See query #1.
--   events.status is free-form text (no CHECK). is_active is separate boolean.
--   cross_site_sync_log columns: id, sync_type, source_site, target_sites (array),
--     status, details (jsonb), synced_by, created_at, completed_at.
--   sites columns: id, site_type, name, url, environment, is_active, description,
--     metadata, created_at, updated_at.
--   venues columns: id, name, slug, subdomain, custom_domain, organization_id,
--     is_active, settings, created_at, updated_at.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. CRITICAL — supabase_realtime publication MUST include the hot tables
-- Expected: rows for events, ticket_types, orders, vip_reservations, vip_guest_passes
-- AS OF 2026-04-21: returns 0 rows — this publication is EMPTY.
-- -----------------------------------------------------------------------------
SELECT schemaname, tablename
FROM pg_publication_tables
WHERE pubname = 'supabase_realtime'
ORDER BY tablename;


-- -----------------------------------------------------------------------------
-- 2. CRITICAL — Events with invalid status (status is free-form text; flag obvious bad values)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, name, status, is_active, event_date, created_at
FROM events
WHERE status IS NOT NULL
  AND status NOT IN ('draft','published','archived','scheduled','sold_out');


-- -----------------------------------------------------------------------------
-- 3. HIGH — Events with future date but cancellation_status='cancelled'
-- Expected: informational — these should be hidden from customers everywhere
-- -----------------------------------------------------------------------------
SELECT id, name, status, event_date, cancellation_status, cancelled_at
FROM events
WHERE cancellation_status = 'cancelled'
  AND event_date >= current_date
ORDER BY event_date;


-- -----------------------------------------------------------------------------
-- 4. MEDIUM — Published upcoming events without any image_url (UX issue)
-- Expected: informational
-- -----------------------------------------------------------------------------
SELECT id, name, event_date, image_url, flyer_url, banner_url
FROM events
WHERE status = 'published'
  AND is_active = true
  AND event_date >= current_date
  AND (image_url IS NULL OR image_url = '')
  AND (flyer_url IS NULL OR flyer_url = '')
  AND (banner_url IS NULL OR banner_url = '');


-- -----------------------------------------------------------------------------
-- 5. MEDIUM — cross_site_sync_log failures last 7 days
-- Expected: 0 rows with status='failed' / 'error'
-- -----------------------------------------------------------------------------
SELECT id, sync_type, source_site, target_sites, status, details,
       synced_by, created_at, completed_at
FROM cross_site_sync_log
WHERE status IN ('failed','error')
  AND created_at > now() - interval '7 days'
ORDER BY created_at DESC
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 6. MEDIUM — sites table — are the 3 production sites registered?
-- Expected: 3 active rows (marketing/pass-lounge/gate-scanner equivalents)
-- -----------------------------------------------------------------------------
SELECT id, site_type, name, url, environment, is_active, updated_at
FROM sites
ORDER BY site_type;


-- -----------------------------------------------------------------------------
-- 7. INFO — Events by status/cancellation summary
-- -----------------------------------------------------------------------------
SELECT status,
       cancellation_status,
       is_active,
       COUNT(*) AS count,
       MIN(event_date) AS earliest,
       MAX(event_date) AS latest
FROM events
GROUP BY status, cancellation_status, is_active
ORDER BY status NULLS FIRST, cancellation_status NULLS FIRST;


-- -----------------------------------------------------------------------------
-- 8. INFO — Storage usage for event-images bucket
-- -----------------------------------------------------------------------------
SELECT COUNT(*) AS file_count,
       ROUND(SUM((metadata->>'size')::bigint)::numeric / 1024 / 1024, 1) AS total_mb,
       MIN(created_at) AS oldest_file,
       MAX(created_at) AS newest_file
FROM storage.objects
WHERE bucket_id = 'event-images';


-- -----------------------------------------------------------------------------
-- 9. MEDIUM — venues table sanity (multi-venue readiness)
-- Expected: row(s) for Maguey Delaware
-- -----------------------------------------------------------------------------
SELECT id, name, slug, subdomain, custom_domain, is_active, created_at
FROM venues
ORDER BY created_at;


-- -----------------------------------------------------------------------------
-- 10. HIGH — branding_sync + venue_branding pairing
-- Expected: each venue has a branding row; branding_sync per site_type
-- -----------------------------------------------------------------------------
SELECT v.id AS venue_id, v.name,
       (vb.id IS NOT NULL) AS has_venue_branding,
       (SELECT COUNT(*) FROM branding_sync bs WHERE bs.site_type IS NOT NULL) AS branding_sync_rows
FROM venues v
LEFT JOIN venue_branding vb ON vb.venue_id = v.id;


-- -----------------------------------------------------------------------------
-- 11. CRITICAL — Events that *should* be broadcasting via realtime
-- Informational — shows what WOULD be visible on the marketing/purchase sites
-- if realtime were actually subscribing. When the publication is fixed, use this
-- to validate parity between DB state and what users see.
-- -----------------------------------------------------------------------------
SELECT id, name, event_date, status, cancellation_status, is_active, updated_at
FROM events
WHERE status = 'published'
  AND is_active = true
  AND COALESCE(cancellation_status, 'active') <> 'cancelled'
  AND event_date >= current_date
ORDER BY event_date;


-- -----------------------------------------------------------------------------
-- 12. INFO — Site environment config rows (env var management)
-- -----------------------------------------------------------------------------
SELECT site_type, environment, config_key, is_secret, updated_at
FROM site_environment_config
ORDER BY site_type, environment, config_key;
