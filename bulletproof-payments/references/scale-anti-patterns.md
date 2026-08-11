# Payments Scale Anti-Patterns

Report-only.

---

## 1. Webhook processing time

Stripe requires 2xx response within 30 seconds. Slow DB writes + many concurrent webhooks = timeouts = retries = idempotency stress.

Query for recent webhook latency (informational):
```sql
SELECT AVG(EXTRACT(EPOCH FROM (processed_at - NOW()))) AS avg_lag_seconds,
       COUNT(*) AS events_last_hour
FROM stripe_webhook_events
WHERE processed_at > now() - interval '1 hour';
```

At 10x volume, move heavy work (commission calc, SMS) to async queue.

---

## 2. Payment method distribution

```sql
SELECT payment_method, COUNT(*) AS n,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM service_transactions
WHERE service_completed_at > now() - interval '30 days'
GROUP BY payment_method;
```

High cash % = high commission ledger work for owner. High card % = more Stripe fees but cleaner accounting.

---

## 3. Refund rate

```sql
SELECT COUNT(*) FILTER (WHERE payment_status = 'refunded') AS refunds,
       COUNT(*) AS total,
       ROUND(100.0 * COUNT(*) FILTER (WHERE payment_status = 'refunded') / NULLIF(COUNT(*), 0), 2) AS refund_pct
FROM service_transactions
WHERE service_completed_at > now() - interval '30 days';
```

>1% refund rate = investigate. >3% = systemic issue.

---

## 4. Stripe Connect adoption rate

```sql
SELECT
  COUNT(*) FILTER (WHERE stripe_account_id IS NOT NULL AND stripe_charges_enabled = true) AS with_connect,
  COUNT(*) FILTER (WHERE stripe_account_id IS NULL OR stripe_charges_enabled = false) AS without_connect,
  COUNT(*) AS total
FROM barbers
WHERE is_active = true;
```

The more barbers with Connect, the less owner carries on barber_payouts. Scale: push barbers to enable Connect.

---

## 5. Webhook events volume

```sql
SELECT DATE_TRUNC('day', processed_at) AS day, COUNT(*) AS events
FROM stripe_webhook_events
WHERE processed_at > now() - interval '30 days'
GROUP BY day
ORDER BY day DESC;
```

If volume spikes disproportionately vs transactions, could indicate webhook retries (idempotency stress test).

---

## 6. Checkout session expiry defaults

Stripe checkout sessions default to 24h expiry. Payment links default to never-expire.

For security: sessions created for specific queue entries should expire in ~2h (customer should pay during or shortly after the service). Verify in `src/app/api/payments/checkout/route.ts`.

---

## 7. PCI scope

MT never touches raw card numbers — Stripe Checkout hosts the form. This keeps MT out of PCI scope. Any change that puts card input on MT's domain = MASSIVE compliance cost.

**Flag any code that starts handling raw card data directly.** Grep:
```bash
grep -rEn "cardNumber|creditCard|card_number" src/
```

Expected: zero matches (everything goes through Stripe).

---

## 8. Manual override audit

The "Mark as paid manually" override (if present) bypasses Stripe. Useful for "customer paid via Venmo outside the app" scenarios, but can mask missing webhooks.

Audit monthly for overused manual overrides:
```sql
-- If manual override logs a distinct status or note
SELECT COUNT(*) FROM service_transactions
WHERE payment_method = 'cash'
  AND stripe_payment_id IS NOT NULL; -- inconsistent: cash but has stripe id
```

---

## Output verdict template

```
## Payments Scale Readiness

### Ready
- [green items]

### Must fix / decide before scaling
1. [item + reason]

### Recommended
- [items]

### Verdict
[READY / BLOCKED BY N ITEMS]
```
