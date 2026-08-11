# Loyalty & Referrals Scale Anti-Patterns

Report-only.

---

## 1. Loyalty config changes mid-campaign

`loyalty_config.punches_required` is a single value across all customers. If the owner changes it from 10 to 12:
- Customers at 9 punches suddenly need 3 more instead of 1
- Customers at 11 punches are now "done" but haven't claimed yet

**Recommendation:** Never change `punches_required` without a grandfather plan. Flag as decision point if user considers it.

---

## 2. Gift card liability at scale

```sql
SELECT COUNT(*) AS active_cards,
       SUM(current_balance) AS outstanding_liability,
       AVG(current_balance) AS avg_balance,
       MAX(current_balance) AS max_balance
FROM gift_cards
WHERE status = 'active';
```

Active gift card balances are money MT owes. Track trend:
```sql
SELECT DATE_TRUNC('month', created_at) AS month,
       SUM(initial_balance) AS issued,
       COUNT(*) AS cards_issued
FROM gift_cards
GROUP BY month
ORDER BY month DESC;
```

At $5k+ outstanding liability, the owner may want to audit for dormant cards (hasn't been used in 12+ months).

---

## 3. Gift card expiry policy

```sql
SELECT COUNT(*) FILTER (WHERE expires_at IS NULL) AS no_expiry,
       COUNT(*) FILTER (WHERE expires_at > now()) AS future_expiry,
       COUNT(*) FILTER (WHERE expires_at <= now() AND status = 'active') AS expired_but_active
FROM gift_cards;
```

`expired_but_active` count > 0 = cron isn't transitioning expired cards. Consider adding a cleanup cron.

---

## 4. Referral commission cost

```sql
SELECT DATE_TRUNC('month', created_at) AS month,
       COUNT(*) FILTER (WHERE event_type = 'conversion') AS conversions,
       SUM(commission_earned) FILTER (WHERE event_type = 'conversion') AS total_commissions_paid
FROM referral_events
WHERE created_at > now() - interval '12 months'
GROUP BY month
ORDER BY month DESC;
```

Track referral commissions as % of referred-revenue. At scale: ensure it's sustainable.

---

## 5. Per-barber referral code uniqueness at scale

```sql
SELECT COUNT(*) AS total_codes,
       MIN(LENGTH(code)) AS shortest_code,
       MAX(LENGTH(code)) AS longest_code
FROM barber_referrals;
```

Codes must be short enough to share (printable on cards) but long enough to avoid collisions at scale. At 10k barbers, 6-char alphanumeric = ~2 billion combos, safe. At 1M, consider 8 chars.

---

## 6. Upsell rule proliferation

```sql
SELECT COUNT(*) FILTER (WHERE is_active) AS active_rules,
       COUNT(*) AS total_rules
FROM upsell_rules;
```

Too many active rules = customer sees multiple suggestions, conversion drops. Recommend max 1-2 per trigger service.

---

## 7. Loyalty punch frequency (spam check)

```sql
SELECT client_phone, current_punches, last_punch_at,
       total_punches_earned,
       EXTRACT(EPOCH FROM (last_punch_at - (last_punch_at - interval '1 month'))) / 86400 AS days_since_first
FROM customer_loyalty
WHERE current_punches >= 10
ORDER BY current_punches DESC
LIMIT 20;
```

If someone has 20+ punches in 30 days, either they love MT or there's a bug letting punches accumulate from single services.

---

## 8. Expired rewards (unclaimed) awareness

No built-in expiry on punches. Customers can have 10 punches for years. Not a bug, but a policy question at scale:
- Do punches expire after 1 year of inactivity?
- Does reward auto-claim if customer doesn't use within N days?

Flag as policy discussion.

---

## 9. Referral attribution window

- Click happens → stored in cookie or URL param.
- If customer books 30 days later, does the referral still credit? Depends on cookie TTL + how visit/conversion events are linked.

Audit `/api/referrals/track` logic for attribution window. Flag if unclear.

---

## Output verdict template

```
## Loyalty & Referrals Scale Readiness

### Ready
- [green items]

### Must fix / decide before scaling (new campaign, new reward type)
1. [item + reason]

### Recommended
- [items — gift card expiry cron, attribution window, rule consolidation]

### Verdict
[READY / BLOCKED BY N ITEMS]
```
