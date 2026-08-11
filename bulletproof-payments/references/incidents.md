# Payments Incident Registry

---

## Stripe Webhook Idempotency

**Symptom:**
- Customer is charged twice for the same service
- Two `service_transactions` rows for one queue entry
- Stripe dashboard shows one payment, DB shows two

**Root cause:**
Stripe retries webhooks when the endpoint times out, returns 5xx, or takes too long. Without idempotency, each retry re-processes the event and re-inserts rows.

**Correct pattern (migration 036):**
1. `stripe_webhook_events` table has UNIQUE(stripe_event_id).
2. On every webhook, FIRST check: `SELECT 1 FROM stripe_webhook_events WHERE stripe_event_id = $1`.
3. If found → return 200 immediately (no re-processing).
4. Else INSERT the event, THEN process.

**Diagnose checklist:**
1. Grep `src/app/api/webhooks/stripe/route.ts` for `stripe_webhook_events`.
2. Verify the check happens BEFORE any DB mutation.
3. If duplicates occurred, query `SELECT stripe_event_id, COUNT(*) FROM stripe_webhook_events GROUP BY stripe_event_id HAVING COUNT(*) > 1` — should be 0.
4. Check Stripe dashboard webhook log for the event ID in question — was it retried?

---

## Webhook Signature Verification Failure

**Symptom:**
- Stripe dashboard shows webhook delivery succeeding (200)
- But no DB mutation happened
- Logs show "signature verification failed" or similar

**Root cause:**
`STRIPE_WEBHOOK_SECRET` env var mismatch between Stripe dashboard and Vercel. When rotating secrets, the endpoint must pick up the new secret before Stripe starts signing with it.

**Correct pattern:**
- Use `stripe.webhooks.constructEvent(body, signature, endpointSecret)` — throws on invalid signature.
- Wrap in try/catch and return 400 on invalid signature.

**Diagnose:**
1. Check Vercel env: `STRIPE_WEBHOOK_SECRET` current value.
2. Stripe dashboard → Webhooks → endpoint → Signing secret. Compare.
3. Check Vercel function logs for the specific event ID.

---

## Metadata Lost Between Checkout and Webhook

**Symptom:**
- Stripe dashboard shows a successful charge
- DB has no `service_transactions` row, or row exists but no `queue_entry_id` / `booking_id`
- Can't tie the Stripe charge back to the service

**Root cause:**
Checkout session was created without metadata (or metadata was lost). When `checkout.session.completed` fires, the webhook handler can't find the source row.

**Correct pattern:**
```typescript
// src/app/api/payments/checkout/route.ts
await stripe.checkout.sessions.create({
  metadata: {
    queue_entry_id: entryId,  // or booking_id
    barber_id: barberId,
    location_id: locationId,
    service_amount: amount.toString(),
  },
  ...
});
```

**In the webhook:**
```typescript
const queueEntryId = event.data.object.metadata.queue_entry_id;
// Use this to UPDATE queue_entries.payment_status
```

**Diagnose:**
1. Read the checkout session creation code. Is metadata set?
2. Read the webhook handler. Does it pull metadata correctly?
3. Check the specific Stripe session in the dashboard — click the session to see raw metadata.

---

## Tip Entry Lost

**Symptom:**
- Customer adds $10 tip on PaymentCollectionModal
- `service_transactions.tip_amount = 0` after service completes

**Possible root causes:**
1. Tip state wasn't submitted with the payment API call
2. Tip was submitted but the API route ignored it
3. Tip was submitted, stored on `queue_entries.tip_amount`, but the `service_transactions` trigger didn't copy it

**Diagnose:**
1. Read `PaymentCollectionModal` component — verify tip is in the submitted payload.
2. Read the receiving API route — verify tip is persisted to `queue_entries` / `bookings`.
3. Check the trigger that creates `service_transactions` from `queue_entries` / `bookings` — verify `tip_amount` is copied.

---

## Refund Without Commission Reversal

**Symptom:**
- Customer requests refund via Stripe dashboard
- `service_transactions.payment_status` → 'refunded'
- But `cash_fee_ledger` still shows `owed`, and `daily_summaries.total_owner_fees` still includes the fee

**Root cause:**
Refund webhook handler doesn't trigger commission reversal.

**Correct pattern:**
On `charge.refunded`:
1. Find `service_transactions` by `stripe_payment_id`.
2. UPDATE it: `payment_status = 'refunded'`.
3. UPDATE source row (queue_entries / bookings): same.
4. REVERSE fee: either delete the `cash_fee_ledger` row OR set `status = 'waived'` with a note.
5. Recalculate `daily_summaries` for that (day, barber, location).

**This is not fully implemented per planning docs.** Flag if user reports a refund mismatch.

---

## Send Link 404

**Symptom:**
- Barber taps "Send Link"
- SMS arrives with payment URL
- Customer clicks → Stripe page shows "This payment link has expired or is invalid"

**Possible root causes:**
1. Link was created successfully but DB never got the URL → SMS had wrong URL
2. Link was created with a short expiry and customer waited too long
3. Stripe test/live mode mismatch (link in test, customer clicks in live)

**Diagnose:**
1. Look up the service_transaction by queue_entry_id/booking_id. What's `stripe_payment_link`?
2. Copy the URL → try clicking it yourself.
3. Stripe dashboard → Payment Links → search by URL ID. What's its status?
4. Verify env: `STRIPE_SECRET_KEY` is `sk_live_*` in production, not `sk_test_*`.

---

## PaymentCollectionModal Stuck State

**Symptom:**
- Barber selects Card, Stripe redirect opens
- Customer completes payment
- Modal stays on "Processing..." indefinitely

**Root cause:**
Modal waits for webhook via polling `queue_entries.payment_status`. If:
- Webhook signature fails (see above)
- Webhook took >30s and Stripe gave up
- Modal's polling logic has a bug

... the UI never moves on.

**Diagnose:**
1. Query DB: is `payment_status = 'paid'` yet?
2. If yes → modal polling is broken.
3. If no → webhook didn't fire or failed. Check Stripe dashboard + Vercel logs.
4. Barber should be able to manually mark "Paid" as an override — verify that fallback exists.

---

## Quick Match Table

| Symptom | Likely incident | First file to read |
|---|---|---|
| Duplicate charges | webhook idempotency failure | `src/app/api/webhooks/stripe/route.ts` |
| Webhook silently not processing | signature or secret mismatch | Vercel env + Stripe dashboard |
| Stripe charge with no DB row | metadata not set on checkout session | `src/app/api/payments/checkout/route.ts` |
| Tip lost | frontend or API dropped tip param | `PaymentCollectionModal.tsx` |
| Refund without commission reversal | not implemented | the refund webhook handler |
| Payment link 404 | expired or mode mismatch | Stripe dashboard + env check |
| Modal stuck on Processing | webhook missed or polling bug | both |
