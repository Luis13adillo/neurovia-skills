-- =============================================================================
-- Bulletproof Services — Audit Queries
-- =============================================================================
-- SELECT-only. Run via mcp__supabase-mt__execute_sql. Project: MT Barbershop.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. CRITICAL — FK delete rules on all four service consumers must be SET NULL
-- Expected: 4 rows, delete_rule='SET NULL' for each
-- Context: post-2026-04-21 fix (commit fb35208) normalized these.
-- -----------------------------------------------------------------------------
SELECT
  tc.table_name,
  kcu.column_name,
  rc.delete_rule
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu ON tc.constraint_name = kcu.constraint_name
JOIN information_schema.referential_constraints rc ON tc.constraint_name = rc.constraint_name
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND tc.table_schema = 'public'
  AND tc.table_name IN ('bookings', 'queue_entries', 'service_transactions')
  AND kcu.column_name IN ('service_id', 'custom_service_id')
ORDER BY tc.table_name, kcu.column_name;


-- -----------------------------------------------------------------------------
-- 2. CRITICAL — Orphan booking.service_id (references missing service row)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT b.id, b.scheduled_date, b.scheduled_time, b.service_id
FROM bookings b
WHERE b.service_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM services s WHERE s.id = b.service_id)
  AND b.deleted_at IS NULL;


-- -----------------------------------------------------------------------------
-- 3. CRITICAL — Orphan booking.custom_service_id
-- Expected: 0 rows (unless service was deleted, then SET NULL should have fired)
-- -----------------------------------------------------------------------------
SELECT b.id, b.scheduled_date, b.scheduled_time, b.custom_service_id
FROM bookings b
WHERE b.custom_service_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM barber_custom_services c WHERE c.id = b.custom_service_id)
  AND b.deleted_at IS NULL;


-- -----------------------------------------------------------------------------
-- 4. HIGH — Booking with BOTH service_id AND custom_service_id (should never happen)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, scheduled_date, scheduled_time, service_id, custom_service_id
FROM bookings
WHERE service_id IS NOT NULL
  AND custom_service_id IS NOT NULL
  AND deleted_at IS NULL;


-- -----------------------------------------------------------------------------
-- 5. HIGH — Booking with neither service_id NOR custom_service_id
-- Expected: only old rows where service was hard-deleted pre-SET-NULL fix
-- If recent (created after 2026-04-21), investigate — may indicate POST logic bug.
-- -----------------------------------------------------------------------------
SELECT id, scheduled_date, scheduled_time, created_at, status
FROM bookings
WHERE service_id IS NULL
  AND custom_service_id IS NULL
  AND deleted_at IS NULL
  AND status IN ('pending','confirmed','in_progress');


-- -----------------------------------------------------------------------------
-- 6. HIGH — Active bookings with duration mismatched against source (global)
-- Expected: 0 rows
-- Note: mismatch is normal for completed/cancelled bookings if the service
-- duration was edited after the booking was made. Only flag active rows.
-- -----------------------------------------------------------------------------
SELECT b.id, b.scheduled_date, b.duration_minutes AS booking_dur, s.duration_minutes AS service_dur
FROM bookings b
JOIN services s ON b.service_id = s.id
WHERE b.duration_minutes != s.duration_minutes
  AND b.status IN ('pending','confirmed','in_progress')
  AND b.deleted_at IS NULL;


-- -----------------------------------------------------------------------------
-- 7. HIGH — Active bookings with duration mismatched against source (custom)
-- Expected: 0 rows (same caveat as #6)
-- -----------------------------------------------------------------------------
SELECT b.id, b.scheduled_date, b.duration_minutes AS booking_dur, c.duration_minutes AS custom_dur
FROM bookings b
JOIN barber_custom_services c ON b.custom_service_id = c.id
WHERE b.duration_minutes != c.duration_minutes
  AND b.status IN ('pending','confirmed','in_progress')
  AND b.deleted_at IS NULL;


-- -----------------------------------------------------------------------------
-- 8. HIGH — Active bookings with null / zero duration
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, scheduled_date, scheduled_time, duration_minutes, service_id, custom_service_id
FROM bookings
WHERE (duration_minutes IS NULL OR duration_minutes = 0)
  AND status IN ('pending','confirmed','in_progress')
  AND deleted_at IS NULL;


-- -----------------------------------------------------------------------------
-- 9. MEDIUM — Suspicious durations on ACTIVE walk-in services
-- Expected: 0 rows (< 10 min or > 180 min is unusual for barbershop services)
-- -----------------------------------------------------------------------------
SELECT id, name, duration_minutes, price, category
FROM services
WHERE is_active = true
  AND (duration_minutes < 10 OR duration_minutes > 180);


-- -----------------------------------------------------------------------------
-- 10. MEDIUM — Suspicious durations on ACTIVE custom services
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT c.id, c.name, c.duration_minutes, c.price, c.barber_id, b.slug
FROM barber_custom_services c
LEFT JOIN barbers b ON b.id = c.barber_id
WHERE c.is_active = true
  AND (c.duration_minutes < 10 OR c.duration_minutes > 180);


-- -----------------------------------------------------------------------------
-- 11. MEDIUM — Suspicious prices (zero / negative / extreme)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT 'services' AS src, id::text, name, price
FROM services
WHERE is_active = true AND (price <= 0 OR price > 500)
UNION ALL
SELECT 'custom' AS src, id::text, name, price
FROM barber_custom_services
WHERE is_active = true AND (price <= 0 OR price > 500)
UNION ALL
SELECT 'barber_services.custom_price' AS src, service_id::text, 'barber_id='||barber_id::text, custom_price
FROM barber_services
WHERE custom_price IS NOT NULL AND (custom_price <= 0 OR custom_price > 500);


-- -----------------------------------------------------------------------------
-- 12. HIGH — Duplicate active custom services per barber (same name)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT barber_id, lower(trim(name)) AS name_key, COUNT(*) AS n, array_agg(id) AS ids
FROM barber_custom_services
WHERE is_active = true
GROUP BY barber_id, lower(trim(name))
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- 13. MEDIUM — Upsell rules referencing inactive or missing services
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT ur.id, ur.trigger_service_id, ur.suggested_service_id, ur.is_active,
       ts.is_active AS trigger_is_active, ss.is_active AS suggested_is_active
FROM upsell_rules ur
LEFT JOIN services ts ON ts.id = ur.trigger_service_id
LEFT JOIN services ss ON ss.id = ur.suggested_service_id
WHERE ur.is_active = true
  AND (ts.id IS NULL OR ss.id IS NULL
       OR ts.is_active = false OR ss.is_active = false);


-- -----------------------------------------------------------------------------
-- 14. LOW — Category enum drift
-- Expected: subset of {haircuts, beard, combos, grooming, linework, specialty,
--                       color, treatments, addons, hair, combo}
-- -----------------------------------------------------------------------------
SELECT DISTINCT category, COUNT(*) AS n
FROM services
WHERE category IS NOT NULL
GROUP BY category
ORDER BY category;


-- -----------------------------------------------------------------------------
-- 15. LOW — Cross-barber identical custom services (consolidation candidates)
-- Shows: custom services with same name across multiple barbers
-- -----------------------------------------------------------------------------
SELECT lower(trim(name)) AS name_key,
       COUNT(DISTINCT barber_id) AS barber_count,
       array_agg(DISTINCT price) AS prices,
       array_agg(DISTINCT duration_minutes) AS durations
FROM barber_custom_services
WHERE is_active = true
GROUP BY lower(trim(name))
HAVING COUNT(DISTINCT barber_id) > 1
ORDER BY barber_count DESC;


-- -----------------------------------------------------------------------------
-- 16. HIGH — RLS enabled on all three service tables
-- Expected: 3 rows, rls_enabled=true each
-- -----------------------------------------------------------------------------
SELECT c.relname AS table_name, c.relrowsecurity AS rls_enabled
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN ('services','barber_services','barber_custom_services')
ORDER BY c.relname;


-- -----------------------------------------------------------------------------
-- 17. HIGH — Required RLS policies exist
-- Expected: services has ALL policy via is_owner(); barber_custom_services has
-- barber-scoped INSERT/UPDATE/DELETE; barber_services has SELECT-public policy.
-- -----------------------------------------------------------------------------
SELECT tablename, policyname, cmd
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('services','barber_services','barber_custom_services')
ORDER BY tablename, cmd;


-- -----------------------------------------------------------------------------
-- 18. INFO — Snapshot: active service counts per tier
-- -----------------------------------------------------------------------------
SELECT 'global_active' AS metric, COUNT(*) FROM services WHERE is_active = true
UNION ALL SELECT 'global_inactive', COUNT(*) FROM services WHERE is_active = false
UNION ALL SELECT 'barber_services_links', COUNT(*) FROM barber_services
UNION ALL SELECT 'barber_services_with_custom_price', COUNT(*) FROM barber_services WHERE custom_price IS NOT NULL
UNION ALL SELECT 'custom_active', COUNT(*) FROM barber_custom_services WHERE is_active = true
UNION ALL SELECT 'custom_inactive', COUNT(*) FROM barber_custom_services WHERE is_active = false
UNION ALL SELECT 'bookings_via_global', COUNT(*) FROM bookings WHERE service_id IS NOT NULL AND deleted_at IS NULL
UNION ALL SELECT 'bookings_via_custom', COUNT(*) FROM bookings WHERE custom_service_id IS NOT NULL AND deleted_at IS NULL;


-- -----------------------------------------------------------------------------
-- 19. INFO — Owner (Gustavo) separation check
-- Shows walk-in services he has linked via barber_services (if any) alongside
-- his personal custom services. Confirms the "MT is both owner and barber" separation.
-- -----------------------------------------------------------------------------
SELECT 'barber_service_link' AS tier, s.name, s.duration_minutes::text AS duration, s.price::text AS price,
       bs.custom_price::text AS custom_price_override
FROM barber_services bs
JOIN services s ON bs.service_id = s.id
WHERE bs.barber_id = 'b0010000-0000-0000-0000-000000000001'
UNION ALL
SELECT 'owner_custom' AS tier, name, duration_minutes::text, price::text, NULL
FROM barber_custom_services
WHERE barber_id = 'b0010000-0000-0000-0000-000000000001'
  AND is_active = true
ORDER BY tier, name;


-- -----------------------------------------------------------------------------
-- 20. INFO — Collision check: owner's custom service names that match walk-in
-- Names like this are not a bug but they are a warning — a customer booking
-- "Men's Haircut" from the owner's profile may pay the custom price while a
-- walk-in customer pays the global price. Confirm intentional.
-- -----------------------------------------------------------------------------
SELECT c.name, c.price AS owner_custom_price, c.duration_minutes AS owner_custom_dur,
       s.price AS walkin_price, s.duration_minutes AS walkin_dur
FROM barber_custom_services c
JOIN services s ON lower(trim(c.name)) = lower(trim(s.name))
WHERE c.barber_id = 'b0010000-0000-0000-0000-000000000001'
  AND c.is_active = true
  AND s.is_active = true;


-- -----------------------------------------------------------------------------
-- 21. INFO — Recent service edits (audit trail)
-- -----------------------------------------------------------------------------
SELECT 'services' AS tbl, id::text, name, updated_at
FROM services
WHERE updated_at > now() - interval '14 days'
UNION ALL
SELECT 'custom' AS tbl, id::text, name, updated_at
FROM barber_custom_services
WHERE updated_at > now() - interval '14 days'
ORDER BY updated_at DESC
LIMIT 50;
