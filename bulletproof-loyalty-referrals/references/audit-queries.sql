-- =============================================================================
-- Bulletproof Loyalty & Referrals — Audit Queries
-- =============================================================================
-- SELECT-only. Run via mcp__supabase-mt__execute_sql. Project: MT Barbershop.
-- VERIFY SCHEMA via preflight first — column name drift is a known risk here.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 0. SCHEMA VERIFICATION
-- -----------------------------------------------------------------------------
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('customer_loyalty', 'loyalty_config',
                     'gift_cards', 'gift_card_transactions',
                     'barber_referrals', 'referral_events',
                     'upsell_rules')
ORDER BY table_name, ordinal_position;


-- -----------------------------------------------------------------------------
-- 1. CRITICAL — loyalty_config is exactly 1 row
-- Expected: 1
-- -----------------------------------------------------------------------------
SELECT COUNT(*) AS n FROM loyalty_config;


-- -----------------------------------------------------------------------------
-- 2. HIGH — loyalty_config has valid values
-- -----------------------------------------------------------------------------
SELECT id, punches_required, reward_description, is_active
FROM loyalty_config;


-- -----------------------------------------------------------------------------
-- 3. HIGH — current_punches <= total_punches_earned
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT client_phone, current_punches, total_punches_earned, rewards_redeemed
FROM customer_loyalty
WHERE current_punches > total_punches_earned;


-- -----------------------------------------------------------------------------
-- 4. MEDIUM — Loyalty math consistency
-- total_punches_earned = current_punches + (rewards_redeemed * punches_required)
-- Expected: 0 rows (allow ±1 for races)
-- -----------------------------------------------------------------------------
WITH cfg AS (SELECT punches_required FROM loyalty_config LIMIT 1)
SELECT cl.client_phone,
       cl.current_punches,
       cl.total_punches_earned,
       cl.rewards_redeemed,
       cfg.punches_required,
       cl.total_punches_earned - cl.current_punches
         - (cl.rewards_redeemed * cfg.punches_required) AS drift
FROM customer_loyalty cl
CROSS JOIN cfg
WHERE ABS(cl.total_punches_earned - cl.current_punches
          - (cl.rewards_redeemed * cfg.punches_required)) > 1
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 5. HIGH — customer_loyalty unique on client_phone
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT client_phone, COUNT(*) AS n
FROM customer_loyalty
WHERE client_phone IS NOT NULL
GROUP BY client_phone
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- 6. CRITICAL — Gift card balance math
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
WITH redemptions AS (
  SELECT gift_card_id, SUM(amount) AS total_redeemed
  FROM gift_card_transactions
  WHERE transaction_type = 'redeem'
  GROUP BY gift_card_id
)
SELECT gc.id, gc.code, gc.initial_balance, gc.current_balance,
       COALESCE(r.total_redeemed, 0) AS redeemed_via_transactions,
       ROUND((gc.initial_balance - COALESCE(r.total_redeemed, 0)
              - gc.current_balance)::numeric, 2) AS drift
FROM gift_cards gc
LEFT JOIN redemptions r ON r.gift_card_id = gc.id
WHERE ABS((gc.initial_balance - COALESCE(r.total_redeemed, 0))
          - gc.current_balance) > 0.01
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 7. HIGH — Gift card status values valid
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT status, COUNT(*) AS n
FROM gift_cards
WHERE status NOT IN ('active', 'depleted', 'expired', 'cancelled')
GROUP BY status;


-- -----------------------------------------------------------------------------
-- 8. HIGH — Depleted cards have zero balance
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, code, status, current_balance
FROM gift_cards
WHERE status = 'depleted'
  AND current_balance > 0.01;


-- -----------------------------------------------------------------------------
-- 9. MEDIUM — Active cards should have positive balance
-- Expected: 0 rows (else should be 'depleted')
-- -----------------------------------------------------------------------------
SELECT id, code, status, current_balance
FROM gift_cards
WHERE status = 'active'
  AND current_balance <= 0;


-- -----------------------------------------------------------------------------
-- 10. CRITICAL — Gift card codes unique
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT code, COUNT(*) AS n
FROM gift_cards
GROUP BY code
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- 11. HIGH — Gift card transaction types valid
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT transaction_type, COUNT(*) AS n
FROM gift_card_transactions
WHERE transaction_type NOT IN ('purchase', 'redeem', 'refund')
GROUP BY transaction_type;


-- -----------------------------------------------------------------------------
-- 12. CRITICAL — Referral codes unique
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT code, COUNT(*) AS n, array_agg(id) AS referral_ids
FROM barber_referrals
GROUP BY code
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- 13. HIGH — Referral aggregate counters match events
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
WITH event_counts AS (
  SELECT referral_id,
         COUNT(*) FILTER (WHERE event_type = 'click')      AS clicks,
         COUNT(*) FILTER (WHERE event_type = 'visit')      AS visits,
         COUNT(*) FILTER (WHERE event_type = 'conversion') AS conversions
  FROM referral_events
  GROUP BY referral_id
)
SELECT br.id,
       br.code,
       br.total_clicks,      ec.clicks      AS events_clicks,
       br.total_visits,      ec.visits      AS events_visits,
       br.total_conversions, ec.conversions AS events_conversions
FROM barber_referrals br
LEFT JOIN event_counts ec ON ec.referral_id = br.id
WHERE br.total_clicks      != COALESCE(ec.clicks, 0)
   OR br.total_visits      != COALESCE(ec.visits, 0)
   OR br.total_conversions != COALESCE(ec.conversions, 0)
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 14. HIGH — Referral event types valid
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT event_type, COUNT(*) AS n
FROM referral_events
WHERE event_type NOT IN ('click', 'visit', 'conversion')
GROUP BY event_type;


-- -----------------------------------------------------------------------------
-- 15. HIGH — Referrals reference valid barber
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT br.id, br.code, br.barber_id
FROM barber_referrals br
LEFT JOIN barbers b ON b.id = br.barber_id
WHERE b.id IS NULL;


-- -----------------------------------------------------------------------------
-- 16. MEDIUM — Active upsell rules reference valid services
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT ur.id,
       ur.trigger_service_id,
       ur.suggested_service_id,
       ts.id IS NOT NULL AS trigger_exists,
       ss.id IS NOT NULL AS suggested_exists
FROM upsell_rules ur
LEFT JOIN services ts ON ts.id = ur.trigger_service_id
LEFT JOIN services ss ON ss.id = ur.suggested_service_id
WHERE ur.is_active = true
  AND (ts.id IS NULL OR ss.id IS NULL);


-- -----------------------------------------------------------------------------
-- 17. LOW — Upsell discount percentages reasonable
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, discount_percentage
FROM upsell_rules
WHERE discount_percentage < 0
   OR discount_percentage > 100;


-- -----------------------------------------------------------------------------
-- 18. INFO — Top loyalty customers
-- -----------------------------------------------------------------------------
SELECT client_phone, current_punches, total_punches_earned, rewards_redeemed,
       last_punch_at, total_spent
FROM customer_loyalty
ORDER BY total_punches_earned DESC
LIMIT 20;


-- -----------------------------------------------------------------------------
-- 19. INFO — Gift card liability
-- -----------------------------------------------------------------------------
SELECT COUNT(*) AS active_cards,
       ROUND(SUM(current_balance)::numeric, 2) AS outstanding_liability,
       ROUND(AVG(current_balance)::numeric, 2) AS avg_balance,
       ROUND(MAX(current_balance)::numeric, 2) AS max_balance
FROM gift_cards
WHERE status = 'active';


-- -----------------------------------------------------------------------------
-- 20. INFO — Referral performance per barber
-- -----------------------------------------------------------------------------
SELECT b.slug,
       br.code,
       br.total_clicks,
       br.total_visits,
       br.total_conversions,
       br.total_revenue,
       ROUND(100.0 * br.total_conversions / NULLIF(br.total_visits, 0), 1) AS conv_pct
FROM barber_referrals br
JOIN barbers b ON b.id = br.barber_id
WHERE br.is_active = true
  AND br.total_clicks > 0
ORDER BY br.total_conversions DESC
LIMIT 30;
