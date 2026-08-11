---
name: elis-bulletproof-payments
description: Audit, diagnose, or scale-check the Eli's Dulce Tradicion Stripe payment system (src/pages/PaymentCheckout.tsx, src/components/payment/StripeCheckoutForm.tsx, create-payment-intent Edge Function, stripe-webhook Edge Function, OrderConfirmation.tsx, verify_stripe_payment RPC, refund flow via send-failed-payment-notification + OrderIssue, webhook idempotency via stripe_webhook_events). Complement to elis-bulletproof-orders (order creation) and elis-bulletproof-emails (receipt delivery). Use when customers get charged with no order, orders get charged twice, webhooks arrive but status stays pending, refunds don't flow through, or before the Mother's Day/Valentine's surge. Read-only SQL via mcp__supabase__execute_sql (project rnszrscxwkdwvvlsihqc). NEVER writes to production DB — payment data is revenue-critical.
---

# Eli's Bulletproof Payments

Payments are the narrowest, highest-stakes surface in the whole system. A failed webhook = unrecorded revenue. A double charge = refund + bad review. A missing idempotency key = a single network retry becomes two charges. Every check below exists because of a real production failure someone has seen.

**Live Mode reminder:** Production bundle runs with `pk_live_...` against Stripe account `CBUpHY3Zt3`. Local `.env` still has `pk_test_...` and that is intentional. When debugging real customer orders, always look at Stripe Dashboard in **Live mode** — never Test mode.

This skill covers:
- `src/pages/PaymentCheckout.tsx` — PaymentIntent creation + Stripe Elements wiring
- `src/components/payment/StripeCheckoutForm.tsx` — card entry UI, confirmPayment handler
- `src/pages/OrderConfirmation.tsx` — post-payment success page
- `supabase/functions/create-payment-intent/index.ts` — creates the Stripe PaymentIntent server-side
- `supabase/functions/stripe-webhook/index.ts` — receives Stripe events, updates order row
- `supabase/functions/send-failed-payment-notification/index.ts` — alert on payment_intent.payment_failed
- `src/lib/api/modules/orders.ts:259` — `verifyPayment` RPC `verify_stripe_payment`
- `backend/routes/payments.js` — (legacy Express path; confirm whether still used in prod)
- Tables: `orders` (payment_status, stripe_payment_id, idempotency_key), ideally a `stripe_webhook_events` dedupe table
- Migrations: `20260206171327_add_idempotency_key.sql`, `20260211_automated_notifications.sql`

**Not covered here:**
- Order creation pre-payment → `elis-bulletproof-orders`
- Payment confirmation email → `elis-bulletproof-emails`
- Chargeback / dispute workflow → flag to user, handle manually via Stripe Dashboard

---

## Schema Reality Check

Confirm before relying on any field:
```sql
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema='public' AND table_name='orders'
  AND column_name IN ('payment_status', 'stripe_payment_id', 'stripe_session_id',
                      'idempotency_key', 'total_amount', 'refund_status', 'refunded_at');
```

Observed values for `payment_status` in code: `pending | paid | failed | refunded`. There is no DB CHECK constraint on this column that we've verified — enforce in code.

**Check for a webhook idempotency table:**
```sql
SELECT table_name FROM information_schema.tables
WHERE table_schema='public' AND table_name ILIKE '%webhook%';
```
If none exists, idempotency is being done in-memory or via the `idempotency_key` column alone — flag it.

---

## Mandatory Preflight

1. `/Users/luismiguel/Desktop/elis-dulce-tradicion/CLAUDE.md` — Stripe is live; `pk_live_...` in prod.
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-elis-dulce-tradicion/memory/MEMORY.md` — Stripe account `CBUpHY3Zt3`, Live mode rule.
3. Supabase project `rnszrscxwkdwvvlsihqc`.
4. Read both Edge Function sources before opining: `supabase/functions/create-payment-intent/index.ts`, `supabase/functions/stripe-webhook/index.ts`.
5. State: "Preflight complete. Running [mode]."

---

## Choose a Mode

- **audit** — monthly, plus before any pricing change, plus before a holiday surge
- **diagnose** — a specific payment symptom (double charge, hanging pending, missing refund)
- **scale-check** — expected >50 orders/day window

All modes are **read-only**. Stripe reads use the Stripe Dashboard in Live mode; this skill never runs Stripe API test charges against live keys.

---

## Mode: audit

### Code-level invariants

1. **Stripe webhook signature verification is on and unforgiving.**
   - `supabase/functions/stripe-webhook/index.ts` must verify `stripe-signature` header via `stripe.webhooks.constructEventAsync` with `STRIPE_WEBHOOK_SECRET`.
   - No bypass, no dev-only flag that skips verification.
   - Grep: `grep -n "constructEvent\|webhooks.construct\|STRIPE_WEBHOOK_SECRET" supabase/functions/stripe-webhook/index.ts`
   - Failure mode if missing: anyone on the internet can POST a fake `checkout.session.completed` and mark orders paid.

2. **Webhook idempotency via event.id dedupe.**
   - Stripe delivers at-least-once. Before acting on an event, the handler must check `event.id` against a dedupe store.
   - If no `stripe_webhook_events` table exists, look for an in-function cache — in-memory is NOT safe (Edge Functions can run multiple instances).
   - Grep: `grep -n "event\.id\|stripe_webhook_events\|already_processed" supabase/functions/stripe-webhook/index.ts`
   - Failure mode: retried webhook flips status twice, fires confirmation email twice, or double-runs a side effect.

3. **`create_new_order` payload carries an idempotency_key.**
   - Client should generate a UUID and pass it both to `create_new_order` AND as `idempotency_key` on the Stripe PaymentIntent create call.
   - Grep: `grep -n "idempotencyKey\|idempotency_key" src/pages/Order.tsx src/pages/PaymentCheckout.tsx src/lib/api/modules/orders.ts supabase/functions/create-payment-intent/index.ts`
   - A network retry after a successful but slow response should return the same PaymentIntent, not create a second.

4. **PaymentIntent metadata contains `order_id` AND `order_number`.**
   - Without metadata, the webhook has no way to know which order this charge belongs to.
   - Grep: `grep -n "metadata" supabase/functions/create-payment-intent/index.ts`
   - Every `payment_intent.succeeded` event must be able to resolve an order row via metadata alone.

5. **Server recomputes `amount` before creating PaymentIntent.**
   - Client must not tell the server "charge $60" — the server looks up the order row and uses `total_amount` from the DB.
   - Grep: `grep -n "amount\|total_amount" supabase/functions/create-payment-intent/index.ts`
   - Failure mode: customer edits request in DevTools to charge $1.

6. **`verify_stripe_payment` RPC actually verifies with Stripe.**
   - `src/lib/api/modules/orders.ts:259` calls `sb.rpc('verify_stripe_payment', { p_payment_id })`.
   - Under the hood this RPC should NOT just read the local `orders` row — it should hit Stripe's API and confirm the charge is real + succeeded. Otherwise it's just a tautology.
   - Verify the RPC body: `SELECT prosrc FROM pg_proc WHERE proname = 'verify_stripe_payment';`
   - **If the RPC just reads orders.payment_status**, it's a stub. That's the "payment verification endpoint missing" gap from CLAUDE.md.

7. **Webhook handles the full event set needed.**
   - At minimum: `payment_intent.succeeded`, `payment_intent.payment_failed`, `charge.refunded`, `charge.dispute.created`.
   - Grep: `grep -n "case \|event\.type" supabase/functions/stripe-webhook/index.ts`
   - Refund handler must flip `orders.payment_status = 'refunded'` and enqueue a refund email.

8. **Failed payment triggers the notification.**
   - On `payment_intent.payment_failed`, the webhook should invoke `send-failed-payment-notification` or enqueue it.
   - Grep: `grep -n "send-failed-payment\|payment_failed" supabase/functions/stripe-webhook/index.ts`

9. **OrderConfirmation.tsx does NOT trust the URL alone.**
   - The success page (`/order-confirmation?orderId=...`) should call `verifyPayment` before showing a green "Payment successful" state. An attacker can hit that URL without paying.
   - Grep: `grep -n "verifyPayment\|payment_status\|stripe_payment" src/pages/OrderConfirmation.tsx`

10. **Stripe keys are in Edge Function secrets, never in frontend bundle.**
    - `STRIPE_SECRET_KEY` must be set via `supabase secrets set`, never exposed as `VITE_*`.
    - Grep: `grep -rn "VITE_STRIPE_SECRET\|STRIPE_SECRET" src/` → should return nothing.

11. **Backend `backend/routes/payments.js` status — is it even used?**
    - If the actual flow goes through Supabase Edge Function, the Express route is dead code. Confirm by grepping the frontend: `grep -rn "VITE_API_URL.*payments\|/api/payments/create-intent" src/`
    - Dead code on the payment path is a maintenance landmine — someone will "fix" one side and forget the other.

12. **Refund path exists and is reachable.**
    - Refund UI in `OrderIssue.tsx` — does it call a real backend? Or is the button decorative?
    - Grep: `grep -n "refund" src/pages/OrderIssue.tsx backend/routes/cancellation.js`
    - CLAUDE.md flags this as a known gap. Report the current reality.

### Data-level invariants

```sql
-- P1. Paid but no stripe_payment_id (orphan paid row)
SELECT id, order_number, total_amount, payment_status, stripe_payment_id, created_at
FROM orders
WHERE payment_status = 'paid' AND stripe_payment_id IS NULL
  AND created_at > now() - interval '30 days';

-- P2. stripe_payment_id present but payment_status != paid (webhook lag or failed to update)
SELECT id, order_number, payment_status, stripe_payment_id, created_at
FROM orders
WHERE stripe_payment_id IS NOT NULL
  AND payment_status NOT IN ('paid', 'refunded')
  AND created_at < now() - interval '30 minutes';

-- P3. Duplicate stripe_payment_id across orders (double-created order, single charge)
SELECT stripe_payment_id, COUNT(*) n
FROM orders
WHERE stripe_payment_id IS NOT NULL
GROUP BY stripe_payment_id
HAVING COUNT(*) > 1;

-- P4. Duplicate idempotency_key (would mean the DB constraint allowed it through)
SELECT idempotency_key, COUNT(*) n
FROM orders
WHERE idempotency_key IS NOT NULL
GROUP BY idempotency_key
HAVING COUNT(*) > 1;

-- P5. Amount mismatch risk — orders where delivery+subtotal+tax != total
SELECT id, order_number, subtotal, delivery_fee, tax, total_amount,
       (COALESCE(subtotal,0) + COALESCE(delivery_fee,0) + COALESCE(tax,0)) AS computed
FROM orders
WHERE created_at > now() - interval '30 days'
  AND ABS((COALESCE(subtotal,0) + COALESCE(delivery_fee,0) + COALESCE(tax,0)) - COALESCE(total_amount,0)) > 0.02;

-- P6. Refunded-but-status-stuck
SELECT id, order_number, status, payment_status, refunded_at, updated_at
FROM orders
WHERE payment_status = 'refunded' AND status NOT IN ('cancelled', 'refunded')
  AND refunded_at > now() - interval '30 days';

-- P7. Total revenue reconciliation (compare vs Stripe Dashboard for same window)
SELECT DATE(created_at) AS day, COUNT(*) n, SUM(total_amount) AS revenue
FROM orders
WHERE payment_status = 'paid' AND created_at > now() - interval '7 days'
GROUP BY DATE(created_at)
ORDER BY day;

-- P8. Failed payments in last 7d (if high, UX problem)
SELECT DATE(created_at) AS day, COUNT(*) n
FROM orders
WHERE payment_status = 'failed' AND created_at > now() - interval '7 days'
GROUP BY DATE(created_at);
```

### Audit output template

```
## Payments Audit — [YYYY-MM-DD]

### Code-level
- [PASS/FAIL] Webhook signature verification
- [PASS/FAIL] Webhook event.id idempotency
- [PASS/FAIL] Client sends idempotency_key to create-payment-intent
- [PASS/FAIL] PaymentIntent metadata includes order_id + order_number
- [PASS/FAIL] Server recomputes amount before PaymentIntent create
- [PASS/FAIL] verify_stripe_payment actually verifies (not a stub)
- [PASS/FAIL] Webhook handles succeeded/failed/refunded/dispute
- [PASS/FAIL] Failed payment notification wired
- [PASS/FAIL] OrderConfirmation.tsx calls verifyPayment before showing success
- [PASS/FAIL] No STRIPE_SECRET_KEY in frontend bundle
- [NOTE] backend/routes/payments.js: [in-use / dead-code]
- [FAIL / KNOWN GAP] Refund path: [UI exists / backend exists / end-to-end]

### Data-level (last 30d)
- P1 orphan paid rows: X (target: 0)
- P2 webhook lag >30min: X (target: 0)
- P3 dup stripe_payment_id: X (target: 0)
- P4 dup idempotency_key: X (target: 0)
- P5 amount mismatch: X (target: 0)
- P6 refunded but status stuck: X (target: 0)
- P7 revenue reconciliation with Stripe Dashboard: [match / delta X]
- P8 failed payment rate: X/day (baseline <1% of attempts)

### Red flags
[Anything non-zero on P1-P6]

### Reconcile against Stripe Dashboard (Live mode) for yesterday
- Stripe charges count: ___
- Our orders (payment_status='paid') count: ___
- Delta: ___
```

---

## Mode: diagnose

### Step 1 — Ask
- Order number OR stripe_payment_id OR customer email.
- Symptom wording verbatim from the user.
- Stripe Dashboard Live mode: does the charge exist? succeeded? refunded?

### Step 2 — First queries
```sql
SELECT id, order_number, customer_email, total_amount,
       payment_status, status, stripe_payment_id, idempotency_key,
       created_at, updated_at, refunded_at
FROM orders WHERE order_number = '<X>' OR stripe_payment_id = '<pi_...>';

SELECT * FROM order_status_history WHERE order_id = '<id>' ORDER BY created_at;
```

### Step 3 — Symptom matrix

| Symptom | Likely cause | Check |
|---|---|---|
| "Charged but no order in system" | PaymentIntent succeeded, webhook failed/blocked | Stripe Dashboard → event → delivery attempts; `supabase functions logs stripe-webhook` |
| "Charged twice" | Missing idempotency key on PaymentIntent create; OR user clicked pay twice | P3 + P4; inspect Stripe Dashboard for two PIs with same amount same minute |
| "Status still pending after 20 min" | Webhook never fired OR fired but handler crashed | Stripe event delivery log; Edge Function logs |
| "Refunded in Stripe, still showing unpaid in dashboard" | `charge.refunded` handler missing or broken | Grep stripe-webhook for refund case; P6 |
| "Total on receipt != cart" | Delivery fee hardcoded + server recompute off | P5; inspect create-payment-intent amount calc |
| "Payment declined, customer got no email" | `payment_intent.payment_failed` handler missing | Grep webhook for `payment_failed`; Edge Function logs for send-failed-payment-notification |
| "Attacker loaded /order-confirmation?orderId=X without paying" | OrderConfirmation.tsx shows success from URL only | Audit item #9 |
| "Payment button does nothing" | Stripe Elements not mounted; publishable key wrong | Browser console; confirm pk_live_* loads in prod bundle |

### Step 4 — Stripe Dashboard verification
- Log into Stripe → **Live mode** → Events → filter by PI id or by timestamp.
- For webhook events: Developers → Webhooks → the endpoint → click an event to see delivery attempts + response body.
- If Stripe shows `200 OK` and our DB still says `pending`, the bug is in the handler's write path, not delivery.

### Step 5 — Report, do not fix
Root-cause + proposed patch. Ask user to approve before editing.

---

## Mode: scale-check

Before a surge window:

1. **Edge Function cold start budget.** Both `create-payment-intent` and `stripe-webhook` cold-start. At surge start, the first 1-3 calls are slow. Pre-warm by hitting the endpoint once.
2. **Stripe rate limits.** 100 req/s steady, 300 burst. A bakery won't hit this — but webhook retries during an outage can pile up.
3. **Webhook processing time.** Stripe times out at ~10s. If the handler does slow work (emailing, image ops), it risks timeout → retry → duplicates.
4. **`supabase_realtime` coverage.** If the frontdesk relies on realtime to see paid orders appear, the `orders` table must be in the realtime publication. Check: `SELECT schemaname, tablename FROM pg_publication_tables WHERE pubname='supabase_realtime';`
5. **Refund capacity.** If one event goes wrong and 50 orders need refunds, do you have a script or is it manual one-by-one in Stripe Dashboard? (Manual is fine for Eli's volume, but know the answer.)
6. **Idempotency under concurrency.** Confirm DB unique constraint on `orders.idempotency_key` (not just app-level check).
   ```sql
   SELECT indexname, indexdef FROM pg_indexes
   WHERE tablename='orders' AND indexdef ILIKE '%idempotency%';
   ```

### Output
```
## Payments Scale Readiness — Window: [date range], Expected orders/day: [N]

- Webhook endpoint reachable + signed: Y/N
- Idempotency unique index on orders: Y/N
- Recent failed-payment rate: X%
- Stripe Dashboard reconciliation for last 7d: match / delta
- Refund drill: documented / ad-hoc
- Stripe keys confirmed LIVE in prod Vercel env: Y/N

Verdict: [READY / NOT READY — blocker list]
```

---

## Critical Flow: end-to-end payment

1. Customer completes wizard → Order.tsx calls `api.createOrder(payload, { idempotency_key })`
2. `create_new_order` RPC writes row with payment_status='pending', returns `{ id, order_number, total_amount }`
3. Redirect to `/checkout?orderId=X`
4. `PaymentCheckout.tsx` calls `supabase.functions.invoke('create-payment-intent', { body: { order_id }})`
5. Edge Function reads order row, confirms total_amount, creates PaymentIntent with metadata `{ order_id, order_number }` and an idempotency key derived from order_id
6. Returns `client_secret` to the page
7. Customer enters card → Stripe Elements submits → `stripe.confirmPayment({ return_url: '/order-confirmation?orderId=X' })`
8. Stripe processes → redirects to return_url
9. In parallel, Stripe fires webhook → `stripe-webhook` Edge Function → verifies signature → dedupe by event.id → updates `orders.payment_status='paid'`, stores stripe_payment_id → enqueues confirmation email
10. `OrderConfirmation.tsx` loads → calls `verifyPayment(stripe_payment_id)` → shows green success only after server confirms
11. FrontDesk sees the paid order appear via realtime → kitchen starts

## Critical Flow: refund

1. Owner goes to Stripe Dashboard (Live mode) → Payments → selects charge → Refund
2. Stripe fires `charge.refunded` webhook → handler sets `payment_status='refunded'`, `refunded_at=now()`, optionally `status='cancelled'`
3. `send-cancelled-notification` or similar email function fires
4. Order disappears from kitchen active queue

---

## HARD RULES

- **NEVER run test charges against live Stripe keys.** Use `sk_test_*` in local dev only.
- **NEVER write to the production DB.** Read-only is the default.
- **NEVER modify webhook signature verification** to "make it work." A failing signature is diagnostic, not an obstacle.
- **NEVER delete rows from a webhook dedupe table** — corrupts idempotency.
- **NEVER expose `STRIPE_SECRET_KEY` to the frontend bundle.** If grep finds it in `src/`, treat as a P0 incident.
- **NEVER trust `OrderConfirmation.tsx` URL params.** Always verify.
- **ALWAYS check Stripe Dashboard in Live mode** for real customer orders. Test mode shows nothing useful.
- **Scope:** if a fix crosses into order creation, email, or dashboard, hand off to the matching skill.
