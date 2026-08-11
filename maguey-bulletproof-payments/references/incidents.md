# Payments — Known Incidents & Fix Patterns

---

## Incident: charge.refunded event not handled (KNOWN GAP — P1)
**Symptom:** Owner refunds a customer in Stripe Dashboard. Customer's order stays `paid` in Maguey. Their ticket still scans green at the door.
**Root cause:** `stripe-webhook/index.ts` handles only `checkout.session.completed` (line ~715) and `payment_intent.succeeded` (line ~1179). No `charge.refunded` or `charge.dispute.created` handler.
**Current workaround:** owner must manually update the order status in Supabase after refunding in Stripe. Error-prone.

**Actual schema (verified 2026-04-21):**
- `orders.payment_reference` (text) stores the Stripe PaymentIntent id (`pi_...`). There is **no** `orders.stripe_payment_intent_id`, no `refunded_at`, no `refund_amount` column. Track refund metadata in `orders.metadata` (jsonb) instead.
- `vip_reservations.stripe_payment_intent_id` (varchar) DOES exist for the VIP path.
- `tickets.status` has no CHECK constraint — 'refunded' is a safe new value. `tickets.current_status` is constrained to ('inside'|'outside'|'left') — scanner uses this for re-entry; don't touch.
- `email_queue.email_type` has a CHECK constraint that must be expanded via migration before enqueuing a new type. Current values: `ga_ticket`, `vip_confirmation`, `ticket_transfer_received`, `ticket_transfer_sent`, `event_reminder_24h`, `event_reminder_2h`.
- No `enqueue_email` RPC — the webhook uses a local `queueEmail(supabase, {...})` helper in the same file.

**Proper fix (requires user approval) — corrected for actual schema:**
```typescript
// In stripe-webhook/index.ts, add AFTER the payment_intent.succeeded block closes
// (search for "end of payment_intent.succeeded handler") and BEFORE the idempotency success update.
if (event.type === "charge.refunded") {
  const charge = event.data.object;
  const paymentIntentId = charge.payment_intent as string;
  const isFullRefund = charge.amount_refunded === charge.amount;

  logger.info("charge.refunded received", { paymentIntentId, amountRefunded: charge.amount_refunded, isFullRefund });

  // 1. Try GA order path (orders.payment_reference holds the PI)
  const { data: order } = await supabase
    .from("orders")
    .select("id, status, purchaser_email, metadata")
    .eq("payment_reference", paymentIntentId)
    .maybeSingle();

  if (order) {
    if (isFullRefund) {
      await supabase.from("orders").update({
        status: "refunded",
        metadata: {
          ...(order.metadata ?? {}),
          refund: {
            amount: charge.amount_refunded,
            stripe_charge_id: charge.id,
            refunded_at: new Date().toISOString(),
          },
        },
      }).eq("id", order.id);

      await supabase.from("tickets")
        .update({ status: "refunded" })
        .eq("order_id", order.id);
      // NOTE: scanner rejects non-active statuses — verify with maguey-bulletproof-scanner.
    } else {
      // Partial refund — owner intent unclear. Log to revenue_discrepancies for manual handling.
      await supabase.from("revenue_discrepancies").insert({
        event_id: null,
        db_revenue: order.total ?? 0,
        stripe_revenue: (order.total ?? 0) - (charge.amount_refunded / 100),
        discrepancy_amount: charge.amount_refunded / 100,
        metadata: { order_id: order.id, stripe_charge_id: charge.id, reason: "partial_refund" },
      });
      logger.warn("Partial refund — not auto-applied", { orderId: order.id });
    }
  }

  // 2. Try VIP reservation path (separate column)
  const { data: vipRes } = await supabase
    .from("vip_reservations")
    .select("id, status")
    .eq("stripe_payment_intent_id", paymentIntentId)
    .maybeSingle();

  if (vipRes && isFullRefund) {
    await supabase.from("vip_reservations")
      .update({ status: "refunded" })
      .eq("id", vipRes.id);
    // NOTE: also consider freeing event_vip_tables availability — delegate to maguey-bulletproof-vip.
  }

  // Email notification: DEFER to maguey-bulletproof-email.
  // Requires new email_type value + template + constraint migration. Ship refund status first,
  // then add email in a separate PR so each change is independently testable.
}
```

**Also needs (out of scope for this skill):**
- `email_queue_email_type_check` migration to add `refund_confirmation` — delegate to `maguey-bulletproof-email`.
- Verify scanner rejects `tickets.status = 'refunded'` — delegate to `maguey-bulletproof-scanner`.
- VIP table availability restore on refund — delegate to `maguey-bulletproof-vip`.
- Separate handlers for `charge.dispute.created` and `payment_intent.payment_failed` — distinct gaps.

**Test:** `stripe listen --forward-to <project>.supabase.co/functions/v1/stripe-webhook` + `stripe trigger charge.refunded` on a test charge.

---

## Incident: Duplicate processing of the same webhook
**Symptom:** Customer emailed twice with the same QR code. Order shows 2 ticket rows instead of 1 (or inventory deducted 2x).
**Root cause:** idempotency check broken or bypassed. Stripe retries webhooks aggressively on 5xx.
**Debug:**
```sql
-- Did we see the same event_id twice?
SELECT * FROM webhook_events WHERE event_id = 'evt_XXX' ORDER BY received_at;
-- Is idempotency record present?
SELECT * FROM webhook_idempotency WHERE idempotency_key = 'evt_XXX';
```
**Common causes:**
1. Idempotency RPC threw an error → webhook code `continue`s instead of rejecting (line ~673 fail-open comment)
2. Retried event arrived after 7-day TTL cleared the idempotency row → processed fresh
3. Bug: different `webhook_type` values treated as distinct (check the RPC's unique constraint)

**Fix pattern:** verify idempotency is mandatory (not fail-open) for money-moving events. Fail-open is acceptable for GET-like reads; webhooks must be strict.

---

## Incident: Signature verification 401 — Stripe retrying indefinitely
**Symptom:** Stripe Dashboard shows the webhook returning 401 over and over. Customer paid, but order remains `pending`.
**Root cause options:**
1. Wrong `STRIPE_WEBHOOK_SECRET` (test vs live mismatch — common after key rotation)
2. Body was parsed/mutated before signature check (must be raw text)
3. Proxy/WAF stripping the `stripe-signature` header

**Fix:**
1. Verify `STRIPE_WEBHOOK_SECRET` in Supabase Dashboard → Edge Functions → Secrets matches the endpoint secret in Stripe Dashboard → Developers → Webhooks → [endpoint] → Signing secret.
2. Log the raw body length and `stripe-signature` header value when verification fails (but NOT in production — debug-only).
3. Use `req.text()` (raw body) before JSON parsing. Never `await req.json()` then re-stringify.

---

## Incident: Order stuck in 'pending' after Stripe charge succeeded
**Symptom:** Customer was charged (Stripe shows `succeeded`), but Maguey order stays `pending`.
**Root cause chain:**
1. Webhook never delivered → check Stripe Dashboard → Webhooks → event log
2. Webhook delivered, 401 → see above (signature)
3. Webhook delivered, 500 → check Edge Function logs for exception
4. Webhook processed but transaction rolled back → check `saga_executions` for that order
5. Webhook processed, order updated, but realtime subscription showing stale → user refresh

**Debug flow:**
```sql
-- Find the order:
SELECT id, status, stripe_session_id, created_at FROM orders
WHERE purchaser_email = '...' ORDER BY created_at DESC LIMIT 5;

-- Check if webhook saw it:
SELECT * FROM webhook_events WHERE event_id IN (
  -- find event_id in Stripe Dashboard for that session
  'evt_XXX'
);

-- Check idempotency:
SELECT * FROM webhook_idempotency WHERE idempotency_key = 'evt_XXX';

-- Check saga:
SELECT * FROM saga_executions WHERE metadata::text LIKE '%<order_id>%';
```

**Recovery:** if Stripe has the charge and our DB doesn't, the safest action is to manually trigger the webhook again. In Stripe Dashboard → Webhooks → [endpoint] → [event] → Resend. Idempotency cache handles re-delivery.

---

## Incident: VIP reservation confirmed via client but webhook never fired
**Symptom:** `vip_reservations.status = 'confirmed'` via client-side `confirm-vip-payment` call, but `webhook_events` has no corresponding `payment_intent.succeeded` record for the PI.
**Root cause options:**
1. Stripe Dashboard → Webhooks — is `payment_intent.succeeded` enabled for the endpoint? If not, only client-side confirmation happens. Missing guest passes + VIP email.
2. Webhook endpoint mis-configured (wrong URL) → client confirmation succeeded but Stripe couldn't reach webhook
3. Webhook threw exception in PI handler → log scan required

**Risk:** customer has confirmed VIP (Stripe has money) but Maguey has no guest passes. They arrive, scanner can't find their party, awkward. Check `vip_guest_passes` for the reservation.

**Fix:** always ensure `payment_intent.succeeded` is enabled in Stripe webhook endpoint settings.

---

## Incident: payment_intent.payment_failed — customer not notified
**Symptom:** Stripe dashboard shows customer's payment failed. No email sent to them.
**Root cause:** webhook calls `notify-payment-failure` Edge Function but the function doesn't actually enqueue an email. It only logs to `payment_failures` table.
**Current gap:** no `payment_failed` email template, no `email_queue` enqueue.
**Fix pattern (needs approval):**
1. Add `email_type = 'payment_failed'` to email_queue CHECK constraint
2. Create template in `src/lib/email-template.ts`
3. In `notify-payment-failure`, also enqueue: `supabase.rpc('enqueue_email', { p_type: 'payment_failed', p_recipient: customer_email, ... })`

---

## Incident: Event cancellation refunds only partial
**Symptom:** `cancel-event-with-refunds` processed 50 of 100 orders. Error partway through. Some customers refunded, others not. No easy "retry" button.
**Root cause:** function iterates serially without checkpoint. If it fails at order 50, restart re-processes 1-49 (potential double refund — Stripe idempotency keys rescue, but UI is confusing).
**Workaround:** the function uses Stripe idempotency keys so re-running is safe, but ensure:
- Each refund call uses `idempotency_key = 'refund-<order_id>'`
- Orders already refunded skip Stripe call on re-run
**Fix (needs approval):** add checkpoint to `cancel-event-with-refunds` — record last processed order_id, resume from there on re-run.

---

## Incident: webhook_idempotency table bloats
**Symptom:** query #7 shows millions of rows. Webhook handler starts timing out on idempotency lookup.
**Root cause:** TTL expiry not being enforced (old `expires_at` rows not deleted).
**Fix:**
- Check for cleanup cron / pg_cron: `SELECT * FROM cron.job WHERE command ILIKE '%webhook_idempotency%';`
- If missing, schedule: `SELECT cron.schedule('purge-webhook-idempotency', '0 3 * * *', 'DELETE FROM webhook_idempotency WHERE expires_at < now()');` — but this is a WRITE, requires user approval.

---

## Pattern: Stripe test vs live key mismatch
After switching to production keys (remaining P0 blocker):
- `VITE_STRIPE_PUBLISHABLE_KEY` on client (Vercel env) → `pk_live_...`
- `STRIPE_SECRET_KEY` on Edge Function → `sk_live_...`
- `STRIPE_WEBHOOK_SECRET` on Edge Function → live endpoint's signing secret (different from test!)
- Stripe Dashboard webhook endpoint must point to production Supabase URL

Common post-switch bugs:
- Used test secret for live signing → all webhooks return 401
- Updated secret key but forgot webhook secret → same symptom
- Left `pk_test` on client → customer checkout redirects to Stripe Test mode
