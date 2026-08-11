-- =============================================================================
-- Maguey Bulletproof Client Profile — Audit Queries
-- =============================================================================
-- SELECT-only. Run one at a time via mcp__supabase__execute_sql.
-- Project: Maguey Nightclub (djbzjasdrwvbsoifxqzd.supabase.co)
-- Expected: 0 rows unless noted.
--
-- SCHEMA REALITY CHECK (verified 2026-04-21):
--   The following tables/views/RPCs DO NOT EXIST in the live DB:
--     profiles, user_loyalty, user_devices, referrals, magic_links,
--     login_activity, customer_stats (view), get_customer_visit_count (RPC)
--   Queries that reference them are kept as `-- [GATED]` templates. Each gates
--   itself with a schema-existence check and SKIPs if the table is missing.
--
--   Tables that DO exist: orders, tickets, ticket_transfers, auth.users,
--   ticket_types, events, newsletter_subscribers.
--
--   orders real columns: id, user_id, purchaser_email, purchaser_name,
--     event_id, subtotal, fees_total, total, payment_provider,
--     payment_reference, status, created_at, updated_at, metadata, promo_code_id.
--   tickets.attendee_email is the JWT-filter key.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. CRITICAL (LIVE) — Refunded tickets that would still show in user history
-- Expected: 0 rows (but currently >0 because user-tickets.ts lacks filter)
-- This proves the bug is real-world impacting before even fixing the code.
-- -----------------------------------------------------------------------------
SELECT t.id AS ticket_id,
       t.attendee_email,
       t.status,
       e.name AS event_name,
       e.event_date
FROM tickets t
JOIN events e ON e.id = t.event_id
WHERE t.status IN ('refunded', 'cancelled')
  AND e.event_date >= current_date
ORDER BY e.event_date
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 2. [GATED] profiles RLS policies (skip if table missing)
-- Expected once deployed: SELECT/UPDATE policies keyed to auth.uid() = id
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema='public' AND table_name='profiles') THEN
    RAISE NOTICE 'profiles exists — run the SELECT below manually:';
    -- SELECT policyname, cmd, qual FROM pg_policies
    -- WHERE tablename = 'profiles' ORDER BY cmd, policyname;
  ELSE
    RAISE NOTICE 'profiles does NOT exist in live DB — migration not deployed. SKIP.';
  END IF;
END $$;


-- -----------------------------------------------------------------------------
-- 3. CRITICAL (LIVE) — Orphan ticket_transfers (no matching ticket)
-- Expected: 0 rows
-- Column note: ticket_transfers uses transferred_at, not created_at.
-- Real columns: id, ticket_id, from_email, from_name, to_email, to_name,
--               event_id, event_name, ticket_type_name, transferred_at.
-- -----------------------------------------------------------------------------
SELECT tt.id AS transfer_id,
       tt.ticket_id,
       tt.from_email,
       tt.to_email,
       tt.transferred_at
FROM ticket_transfers tt
LEFT JOIN tickets t ON t.id = tt.ticket_id
WHERE t.id IS NULL
  AND tt.transferred_at > now() - interval '60 days';


-- -----------------------------------------------------------------------------
-- 4. INFO (LIVE) — Customer-identity snapshot: guest vs registered
-- -----------------------------------------------------------------------------
SELECT
  COUNT(*) AS total_orders,
  COUNT(DISTINCT LOWER(purchaser_email)) AS distinct_customers,
  COUNT(*) FILTER (WHERE user_id IS NOT NULL) AS registered_user_orders,
  COUNT(*) FILTER (WHERE user_id IS NULL) AS guest_orders,
  ROUND(100.0 * COUNT(*) FILTER (WHERE user_id IS NULL) / NULLIF(COUNT(*), 0), 1) AS guest_pct
FROM orders
WHERE status = 'paid';


-- -----------------------------------------------------------------------------
-- 5. INFO (LIVE) — Top customers by LTV (derived from orders)
-- Since customer_stats view is missing, derive here:
-- -----------------------------------------------------------------------------
SELECT LOWER(purchaser_email) AS email,
       MAX(purchaser_name) AS name,
       COUNT(*) AS total_orders,
       SUM(total) AS total_spent,
       MIN(created_at) AS first_visit,
       MAX(created_at) AS last_visit,
       EXTRACT(DAY FROM (now() - MAX(created_at))) AS days_since_last_visit
FROM orders
WHERE status = 'paid'
GROUP BY LOWER(purchaser_email)
ORDER BY total_spent DESC NULLS LAST
LIMIT 20;


-- -----------------------------------------------------------------------------
-- 6. MEDIUM (LIVE) — Newsletter subscribers that are NOT in auth.users
-- (just informational — guests can subscribe without signing up)
-- -----------------------------------------------------------------------------
SELECT ns.email, ns.is_active, ns.source, ns.subscribed_at
FROM newsletter_subscribers ns
LEFT JOIN auth.users u ON LOWER(u.email) = LOWER(ns.email)
WHERE u.id IS NULL
ORDER BY ns.subscribed_at DESC
LIMIT 20;


-- -----------------------------------------------------------------------------
-- 7. [GATED] Backup code sampling (skip if profiles missing)
-- Only meaningful after the 2FA migration lands. Flags plaintext vs hashed.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema='public' AND table_name='profiles' AND column_name='backup_codes') THEN
    RAISE NOTICE 'backup_codes column exists — inspect a sample row:';
    -- SELECT id, array_length(backup_codes,1) AS count,
    --        LENGTH(backup_codes[1]) AS first_len,
    --        (LENGTH(backup_codes[1]) > 30) AS probably_hashed
    -- FROM profiles WHERE array_length(backup_codes,1) > 0 LIMIT 5;
  ELSE
    RAISE NOTICE 'backup_codes column missing. SKIP.';
  END IF;
END $$;


-- -----------------------------------------------------------------------------
-- 8. INFO (LIVE) — auth.users growth + unconfirmed email backlog
-- -----------------------------------------------------------------------------
SELECT
  COUNT(*) AS total_users,
  COUNT(*) FILTER (WHERE email_confirmed_at IS NULL) AS unconfirmed,
  COUNT(*) FILTER (WHERE email_confirmed_at IS NULL
                   AND created_at < now() - interval '30 days') AS stale_unconfirmed,
  COUNT(*) FILTER (WHERE last_sign_in_at > now() - interval '30 days') AS active_last_30d
FROM auth.users;


-- -----------------------------------------------------------------------------
-- 9. HIGH (LIVE) — Orders with missing purchaser_email (can't be shown to a user)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, user_id, purchaser_email, status, total, created_at
FROM orders
WHERE (purchaser_email IS NULL OR purchaser_email = '')
  AND created_at > now() - interval '90 days';


-- -----------------------------------------------------------------------------
-- 10. MEDIUM (LIVE) — Tickets with attendee_email mismatch vs their order's purchaser_email
-- Expected: only mismatches for legitimate transfers
-- Use this to spot irregular ticket_email drift.
-- -----------------------------------------------------------------------------
SELECT t.id AS ticket_id,
       t.attendee_email,
       o.purchaser_email,
       o.id AS order_id,
       EXISTS (SELECT 1 FROM ticket_transfers tt WHERE tt.ticket_id = t.id) AS was_transferred
FROM tickets t
JOIN orders o ON o.id = t.order_id
WHERE LOWER(COALESCE(t.attendee_email, '')) <> LOWER(COALESCE(o.purchaser_email, ''))
  AND t.created_at > now() - interval '60 days'
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 11. [GATED] customer_stats view sanity (skip if missing)
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.views
             WHERE table_schema='public' AND table_name='customer_stats') THEN
    RAISE NOTICE 'customer_stats view exists — run SELECT count(*) FROM customer_stats;';
  ELSE
    RAISE NOTICE 'customer_stats view does NOT exist. CustomerManagement.tsx will not work until deployed. SKIP.';
  END IF;
END $$;


-- -----------------------------------------------------------------------------
-- 12. MEDIUM (LIVE) — newsletter_subscribers is_active distribution
-- Informational: is_active=false = unsubscribed
-- -----------------------------------------------------------------------------
SELECT is_active,
       COUNT(*) AS subscriber_count,
       MIN(subscribed_at) AS oldest,
       MAX(subscribed_at) AS newest
FROM newsletter_subscribers
GROUP BY is_active;


-- -----------------------------------------------------------------------------
-- 13. HIGH (LIVE) — Guest orders where purchaser_email matches an auth.users email
-- (customer signed up AFTER buying; linking user_id would improve their account view)
-- Expected: informational; high count = opportunity to backfill user_id
-- -----------------------------------------------------------------------------
SELECT COUNT(*) AS unlinked_orders_with_account,
       COUNT(DISTINCT LOWER(o.purchaser_email)) AS distinct_customers
FROM orders o
JOIN auth.users u ON LOWER(u.email) = LOWER(o.purchaser_email)
WHERE o.user_id IS NULL
  AND o.status = 'paid';
