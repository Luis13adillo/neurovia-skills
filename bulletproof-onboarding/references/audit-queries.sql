-- =============================================================================
-- Bulletproof Onboarding — Audit Queries
-- =============================================================================
-- SELECT-only. Run via mcp__supabase-mt__execute_sql. Project: MT Barbershop.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 0. SCHEMA VERIFICATION (run on every fresh skill invocation)
-- -----------------------------------------------------------------------------
SELECT table_name, column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND (
    (table_name = 'barbers' AND column_name IN (
      'id', 'profile_id', 'is_active', 'onboarding_step', 'onboarding_step_updated_at',
      'commission_acknowledged_at', 'grace_period_ends_at',
      'image_url', 'stripe_account_id', 'stripe_charges_enabled',
      'employment_type', 'preferred_location_id',
      'booksy_sync_email', 'booksy_sync_enabled', 'slug'
    ))
    OR
    (table_name = 'profiles' AND column_name IN (
      'id', 'first_login_completed', 'email_verified', 'avatar_url',
      'role', 'last_login_at', 'pwa_install_dismissed_at'
    ))
    OR
    (table_name = 'push_subscriptions' AND column_name IN ('user_id', 'queue_token', 'endpoint'))
  )
ORDER BY table_name, column_name;


-- -----------------------------------------------------------------------------
-- 1. CRITICAL — Funnel snapshot (single-row summary)
-- Headline metric for every audit report.
-- -----------------------------------------------------------------------------
SELECT
  COUNT(*)                                                                                AS total_active,
  COUNT(*) FILTER (WHERE onboarding_step IS NULL AND commission_acknowledged_at IS NOT NULL) AS fully_onboarded,
  COUNT(*) FILTER (WHERE onboarding_step IS NOT NULL)                                     AS in_progress,
  COUNT(*) FILTER (WHERE onboarding_step IS NULL AND commission_acknowledged_at IS NULL)  AS legacy_no_ack,
  COUNT(*) FILTER (WHERE onboarding_step = 1) AS at_step1_password,
  COUNT(*) FILTER (WHERE onboarding_step = 2) AS at_step2_profile,
  COUNT(*) FILTER (WHERE onboarding_step = 3) AS at_step3_services,
  COUNT(*) FILTER (WHERE onboarding_step = 4) AS at_step4_schedule,
  COUNT(*) FILTER (WHERE onboarding_step = 5) AS at_step5_booksy,
  COUNT(*) FILTER (WHERE onboarding_step = 6) AS at_step6_payouts,
  COUNT(*) FILTER (WHERE onboarding_step = 7) AS at_step7_terms
FROM barbers
WHERE is_active = true;


-- -----------------------------------------------------------------------------
-- 2. CRITICAL — Per-barber completeness matrix (workhorse query)
-- Returns one row per active barber + every key onboarding artifact.
-- -----------------------------------------------------------------------------
SELECT
  COALESCE(NULLIF(TRIM(COALESCE(b.first_name, '') || ' ' || COALESCE(b.last_name, '')), ''),
           p.email, 'Unknown') AS name,
  b.onboarding_step,
  p.first_login_completed,
  b.commission_acknowledged_at IS NOT NULL                              AS has_commission_ack,
  (b.image_url IS NOT NULL AND b.image_url <> '')                       AS has_photo,
  EXISTS (SELECT 1 FROM barber_schedules s
          WHERE s.barber_id = b.id AND s.is_active = true)              AS has_schedule,
  (
    EXISTS (SELECT 1 FROM barber_services bs WHERE bs.barber_id = b.id)
    OR EXISTS (SELECT 1 FROM barber_custom_services bcs
               WHERE bcs.barber_id = b.id AND bcs.is_active = true)
  )                                                                     AS has_services,
  EXISTS (SELECT 1 FROM push_subscriptions ps
          WHERE ps.user_id = b.profile_id)                              AS has_push,
  b.stripe_account_id IS NOT NULL                                       AS stripe_started,
  COALESCE(b.stripe_charges_enabled, false)                             AS stripe_charges_enabled,
  b.created_at::date                                                    AS created_on,
  p.last_login_at::date                                                 AS last_login_on
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE b.is_active = true
ORDER BY b.created_at DESC;


-- -----------------------------------------------------------------------------
-- 3. CRITICAL — Stuck barbers with days-stuck (outreach prioritization)
-- > 7 days stuck = personal outreach. > 30 days = deactivate or escalate.
-- Uses onboarding_step_updated_at because that timestamp tracks WIZARD activity
-- (set by saveStep on every transition). For "last seen across the app" use
-- profiles.last_login_at instead — see Query 14.
-- -----------------------------------------------------------------------------
SELECT
  b.id AS barber_id,
  COALESCE(NULLIF(TRIM(COALESCE(b.first_name, '') || ' ' || COALESCE(b.last_name, '')), ''),
           p.email) AS name,
  p.email,
  p.phone,
  b.onboarding_step,
  CASE b.onboarding_step
    WHEN 1 THEN 'Password'
    WHEN 2 THEN 'Profile'
    WHEN 3 THEN 'Services'
    WHEN 4 THEN 'Schedule'
    WHEN 5 THEN 'Booksy'
    WHEN 6 THEN 'Payouts'
    WHEN 7 THEN 'Terms (commission ack)'
  END AS stuck_at,
  b.onboarding_step_updated_at,
  EXTRACT(DAY FROM (NOW() - COALESCE(b.onboarding_step_updated_at, b.created_at)))::int AS days_stuck
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE b.is_active = true
  AND b.onboarding_step IS NOT NULL
ORDER BY b.onboarding_step_updated_at ASC NULLS FIRST;


-- -----------------------------------------------------------------------------
-- 4. HIGH — Legacy active barbers (no commission ack)
-- Targets for LegacyCommissionAckModal next time they log in.
-- -----------------------------------------------------------------------------
SELECT
  b.id AS barber_id,
  COALESCE(NULLIF(TRIM(COALESCE(b.first_name, '') || ' ' || COALESCE(b.last_name, '')), ''),
           p.email) AS name,
  p.email,
  b.created_at::date AS created_on,
  b.grace_period_ends_at,
  p.last_login_at::date AS last_login_on
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE b.is_active = true
  AND b.onboarding_step IS NULL
  AND b.commission_acknowledged_at IS NULL
ORDER BY b.created_at ASC;


-- -----------------------------------------------------------------------------
-- 5. HIGH — Push enrollment ratio (the 2026-04-20 systemic gap)
-- Target: > 80%. Below 50% = systemic UX gap.
-- -----------------------------------------------------------------------------
WITH coverage AS (
  SELECT
    b.id,
    EXISTS (SELECT 1 FROM push_subscriptions ps WHERE ps.user_id = b.profile_id) AS enrolled
  FROM barbers b
  WHERE b.is_active = true
)
SELECT
  COUNT(*)                                                            AS total_active,
  COUNT(*) FILTER (WHERE enrolled)                                    AS enrolled_count,
  ROUND(100.0 * COUNT(*) FILTER (WHERE enrolled) / NULLIF(COUNT(*),0), 1) AS enrollment_pct
FROM coverage;


-- -----------------------------------------------------------------------------
-- 6. HIGH — Stripe Connect coverage (started vs actually enabled)
-- Differentiates: never started, started but stalled, fully enabled.
-- Target enabled%: > 80%. Started-but-stalled = "send Stripe Express link" outreach.
-- -----------------------------------------------------------------------------
SELECT
  COUNT(*)                                                            AS total_active,
  COUNT(*) FILTER (WHERE stripe_account_id IS NULL)                   AS never_started,
  COUNT(*) FILTER (WHERE stripe_account_id IS NOT NULL
                     AND COALESCE(stripe_charges_enabled, false) = false) AS started_not_enabled,
  COUNT(*) FILTER (WHERE COALESCE(stripe_charges_enabled, false) = true) AS charges_enabled,
  ROUND(100.0 * COUNT(*) FILTER (WHERE COALESCE(stripe_charges_enabled, false) = true)
        / NULLIF(COUNT(*),0), 1)                                      AS enabled_pct
FROM barbers
WHERE is_active = true;


-- -----------------------------------------------------------------------------
-- 7. MEDIUM — Profile photo coverage (public team page polish)
-- -----------------------------------------------------------------------------
SELECT
  COUNT(*) AS total_active,
  COUNT(*) FILTER (WHERE image_url IS NOT NULL AND image_url <> '') AS has_photo,
  ROUND(100.0 * COUNT(*) FILTER (WHERE image_url IS NOT NULL AND image_url <> '')
        / NULLIF(COUNT(*),0), 1) AS photo_pct
FROM barbers
WHERE is_active = true;


-- -----------------------------------------------------------------------------
-- 8. MEDIUM — Active barbers with no schedule (invisible to booking flow)
-- -----------------------------------------------------------------------------
SELECT b.id AS barber_id,
       COALESCE(NULLIF(TRIM(COALESCE(b.first_name, '') || ' ' || COALESCE(b.last_name, '')), ''),
                p.email) AS name
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE b.is_active = true
  AND NOT EXISTS (
    SELECT 1 FROM barber_schedules s
    WHERE s.barber_id = b.id AND s.is_active = true
  )
ORDER BY b.created_at DESC;


-- -----------------------------------------------------------------------------
-- 9. MEDIUM — Active barbers with no services (invisible to booking + queue)
-- -----------------------------------------------------------------------------
SELECT b.id AS barber_id,
       COALESCE(NULLIF(TRIM(COALESCE(b.first_name, '') || ' ' || COALESCE(b.last_name, '')), ''),
                p.email) AS name
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE b.is_active = true
  AND NOT EXISTS (SELECT 1 FROM barber_services bs WHERE bs.barber_id = b.id)
  AND NOT EXISTS (SELECT 1 FROM barber_custom_services bcs
                  WHERE bcs.barber_id = b.id AND bcs.is_active = true)
ORDER BY b.created_at DESC;


-- -----------------------------------------------------------------------------
-- 10. INFO — PWA install banner dismissal (post 2026-04-20 migration only)
-- Returns nothing meaningful until profiles.pwa_install_dismissed_at exists.
-- -----------------------------------------------------------------------------
SELECT
  COUNT(*)                                                  AS total_barber_profiles,
  COUNT(*) FILTER (WHERE pwa_install_dismissed_at IS NOT NULL) AS dismissed,
  COUNT(*) FILTER (WHERE pwa_install_dismissed_at IS NULL)  AS still_showing
FROM profiles p
WHERE p.role = 'barber'
  AND EXISTS (SELECT 1 FROM barbers b WHERE b.profile_id = p.id AND b.is_active = true);


-- -----------------------------------------------------------------------------
-- 11. INFO — Cohort onboarding velocity (median time invite → completion)
-- Useful before sizing a new hiring cohort.
-- -----------------------------------------------------------------------------
SELECT
  PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (commission_acknowledged_at - created_at)) / 86400.0) AS median_days_to_complete,
  PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (commission_acknowledged_at - created_at)) / 86400.0) AS p90_days_to_complete,
  COUNT(*) AS sample_size
FROM barbers
WHERE commission_acknowledged_at IS NOT NULL
  AND created_at > NOW() - INTERVAL '6 months';


-- -----------------------------------------------------------------------------
-- 12. INFO — Single-barber drilldown (parameterize barber_id)
-- Replace 'BARBER_UUID_HERE' before running.
-- -----------------------------------------------------------------------------
SELECT
  b.id,
  COALESCE(NULLIF(TRIM(COALESCE(b.first_name, '') || ' ' || COALESCE(b.last_name, '')), ''),
           p.email) AS name,
  p.email,
  p.phone,
  p.first_login_completed,
  p.last_login_at,
  b.is_active,
  b.onboarding_step,
  b.onboarding_step_updated_at,
  b.commission_acknowledged_at,
  b.grace_period_ends_at,
  (b.image_url IS NOT NULL AND b.image_url <> '')           AS has_photo,
  b.stripe_account_id IS NOT NULL                           AS stripe_started,
  COALESCE(b.stripe_charges_enabled, false)                 AS stripe_charges_enabled,
  b.booksy_sync_enabled,
  EXISTS (SELECT 1 FROM barber_schedules s
          WHERE s.barber_id = b.id AND s.is_active = true)  AS has_schedule,
  (SELECT COUNT(*) FROM barber_services bs WHERE bs.barber_id = b.id)              AS global_service_count,
  (SELECT COUNT(*) FROM barber_custom_services bcs
   WHERE bcs.barber_id = b.id AND bcs.is_active = true)                            AS custom_service_count,
  (SELECT COUNT(*) FROM push_subscriptions ps WHERE ps.user_id = b.profile_id)     AS push_subscription_count,
  EXTRACT(DAY FROM (NOW() - COALESCE(b.onboarding_step_updated_at, b.created_at)))::int AS days_since_wizard_activity,
  EXTRACT(DAY FROM (NOW() - p.last_login_at))::int                                    AS days_since_last_login
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE b.id = 'BARBER_UUID_HERE';


-- -----------------------------------------------------------------------------
-- 13. INFO — Find barbers by location (location-scoped diagnose)
-- Replace 'LOCATION_UUID_HERE'. Returns barbers attached via active schedule
-- OR via preferred_location_id. Pass each id into Query 12 for full state.
-- -----------------------------------------------------------------------------
WITH via_schedule AS (
  SELECT DISTINCT b.id
  FROM barbers b
  JOIN barber_schedules s ON s.barber_id = b.id
  WHERE s.location_id = 'LOCATION_UUID_HERE'
    AND s.is_active = true
    AND b.is_active = true
),
via_preferred AS (
  SELECT id FROM barbers
  WHERE preferred_location_id = 'LOCATION_UUID_HERE'
    AND is_active = true
)
SELECT
  b.id AS barber_id,
  COALESCE(NULLIF(TRIM(COALESCE(b.first_name, '') || ' ' || COALESCE(b.last_name, '')), ''),
           p.email) AS name,
  p.email,
  b.preferred_location_id = 'LOCATION_UUID_HERE' AS location_is_preferred,
  EXISTS(SELECT 1 FROM barber_schedules s WHERE s.barber_id = b.id
         AND s.location_id = 'LOCATION_UUID_HERE' AND s.is_active = true) AS has_schedule_at_location
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE b.id IN (SELECT id FROM via_schedule UNION SELECT id FROM via_preferred)
ORDER BY name;


-- -----------------------------------------------------------------------------
-- 14. INFO — True "last seen" via profiles.last_login_at
-- Distinct from Query 3, which uses onboarding_step_updated_at (freezes when
-- wizard completes). Use this to find dormant fully-onboarded barbers.
-- -----------------------------------------------------------------------------
SELECT
  b.id,
  COALESCE(NULLIF(TRIM(COALESCE(b.first_name, '') || ' ' || COALESCE(b.last_name, '')), ''),
           p.email) AS name,
  p.last_login_at,
  EXTRACT(DAY FROM (NOW() - p.last_login_at))::int AS days_since_login
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE b.is_active = true
  AND b.onboarding_step IS NULL
  AND b.commission_acknowledged_at IS NOT NULL
  AND p.last_login_at < NOW() - INTERVAL '30 days'
ORDER BY p.last_login_at ASC NULLS FIRST;


-- -----------------------------------------------------------------------------
-- 15. HIGH — Fully-onboarded barbers with optional gaps (Stripe / push / photo)
-- The "hidden" leak — barbers who completed the wizard but skipped optional
-- steps that block real work. As of 2026-04-20 this is the dominant gap.
-- -----------------------------------------------------------------------------
SELECT
  b.id,
  COALESCE(NULLIF(TRIM(COALESCE(b.first_name, '') || ' ' || COALESCE(b.last_name, '')), ''),
           p.email) AS name,
  p.email,
  p.phone,
  NOT COALESCE(b.stripe_charges_enabled, false) AS missing_stripe_enabled,
  NOT EXISTS (SELECT 1 FROM push_subscriptions ps WHERE ps.user_id = b.profile_id) AS missing_push,
  (b.image_url IS NULL OR b.image_url = '')                                        AS missing_photo,
  b.grace_period_ends_at::date                                                     AS grace_ends
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE b.is_active = true
  AND b.onboarding_step IS NULL
  AND b.commission_acknowledged_at IS NOT NULL
  AND (
    NOT COALESCE(b.stripe_charges_enabled, false)
    OR NOT EXISTS (SELECT 1 FROM push_subscriptions ps WHERE ps.user_id = b.profile_id)
    OR (b.image_url IS NULL OR b.image_url = '')
  )
ORDER BY b.grace_period_ends_at ASC NULLS LAST;


-- -----------------------------------------------------------------------------
-- 16. CRITICAL — Orphaned auth users / barbers (cascade rollback failure)
-- create-barber should reverse-cascade-delete on failure. Orphans here mean
-- the rollback path broke at some point.
-- 0 rows expected.
-- -----------------------------------------------------------------------------
-- 16a. profiles without barbers (where role='barber')
SELECT p.id, p.email, p.created_at
FROM profiles p
LEFT JOIN barbers b ON b.profile_id = p.id
WHERE p.role = 'barber'
  AND b.id IS NULL
ORDER BY p.created_at DESC;

-- 16b. barbers without matching profiles
SELECT b.id, b.first_name, b.last_name, b.profile_id, b.created_at
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE p.id IS NULL
ORDER BY b.created_at DESC;

-- 16c. barbers without staff_status (non-fatal but should be 0 for active barbers)
SELECT b.id,
       COALESCE(NULLIF(TRIM(COALESCE(b.first_name, '') || ' ' || COALESCE(b.last_name, '')), ''),
                'Unknown') AS name
FROM barbers b
WHERE b.is_active = true
  AND NOT EXISTS (SELECT 1 FROM staff_status ss WHERE ss.barber_id = b.id)
ORDER BY b.created_at DESC;


-- -----------------------------------------------------------------------------
-- 17. CRITICAL — Data corruption: invalid onboarding_step values
-- Step values must be NULL or 1..7. Anything else = corruption.
-- 0 rows expected.
-- -----------------------------------------------------------------------------
SELECT id,
       COALESCE(NULLIF(TRIM(COALESCE(first_name, '') || ' ' || COALESCE(last_name, '')), ''),
                'Unknown') AS name,
       onboarding_step
FROM barbers
WHERE onboarding_step IS NOT NULL
  AND (onboarding_step < 1 OR onboarding_step > 7);


-- -----------------------------------------------------------------------------
-- 18. CRITICAL — Inconsistent state: completed wizard but step still set
-- If first_login_completed=true AND commission_acknowledged_at IS NOT NULL,
-- then onboarding_step MUST be NULL. Otherwise data corruption.
-- 0 rows expected.
-- -----------------------------------------------------------------------------
SELECT b.id,
       COALESCE(NULLIF(TRIM(COALESCE(b.first_name, '') || ' ' || COALESCE(b.last_name, '')), ''),
                'Unknown') AS name,
       p.first_login_completed,
       b.commission_acknowledged_at,
       b.onboarding_step
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE b.commission_acknowledged_at IS NOT NULL
  AND b.onboarding_step IS NOT NULL;


-- -----------------------------------------------------------------------------
-- 19. INFO — Slug collision check (multiple barbers sharing a slug)
-- Slug auto-generation has a count-suffix path; verify it's working.
-- 0 rows expected.
-- -----------------------------------------------------------------------------
SELECT slug, COUNT(*) AS n, array_agg(id) AS barber_ids
FROM barbers
WHERE slug IS NOT NULL
GROUP BY slug
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- 20. INFO — Inviting velocity (recent invites + outcomes)
-- Useful for "are recent cohorts healthier than older cohorts?"
-- -----------------------------------------------------------------------------
SELECT
  DATE_TRUNC('week', b.created_at)::date AS cohort_week,
  COUNT(*) AS invited,
  COUNT(*) FILTER (WHERE b.commission_acknowledged_at IS NOT NULL) AS completed,
  ROUND(100.0 * COUNT(*) FILTER (WHERE b.commission_acknowledged_at IS NOT NULL)
        / NULLIF(COUNT(*),0), 1) AS completion_pct
FROM barbers b
WHERE b.created_at > NOW() - INTERVAL '12 weeks'
GROUP BY 1
ORDER BY 1 DESC;
