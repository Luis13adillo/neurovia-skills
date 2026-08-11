# Payments — Invariants

## Schema Reality Check (verified 2026-04-21)
Before using examples in this file or in `incidents.md`, remember the actual schema:
- `orders.payment_reference` (text) — holds `pi_...`. **No** `stripe_payment_intent_id`, `stripe_session_id`, `refunded_at`, or `refund_amount` columns on `orders`.
- Session id (when available) lives in `orders.metadata->>'sessionId'`.
- `vip_reservations.stripe_payment_intent_id` (varchar) — separate from orders.
- `webhook_events` columns: `id, event_type, signature_hash, source_ip, timestamp, expires_at, payload_hash, created_at` — an audit trail of signatures, NOT per-event response logs.
- `webhook_idempotency` columns: `id, idempotency_key, webhook_type, processed_at, response_data, response_status, expires_at, metadata`.
- `saga_executions.status` enum: `pending, running, completed, failed, compensating, compensated, compensation_failed` (no `in_progress`).
- Tables **that do not exist** in this project despite appearing in old references: `payment_failures`, `payments`.
- `email_queue.email_type` CHECK constraint currently allows: `ga_ticket, vip_confirmation, ticket_transfer_received, ticket_transfer_sent, event_reminder_24h, event_reminder_2h`. Adding types requires a migration.
- `orders.status` / `tickets.status` are free-form text (no CHECK constraint); 'refunded' is a safe new value. `tickets.current_status` IS constrained to ('inside','outside','left') and is used by the scanner for re-entry — do not overload.

If this list goes stale, rerun the Mandatory Preflight schema query.

## Signature Verification
1. Every webhook POST is signature-verified BEFORE any DB mutation.
2. Comparison is constant-time (XOR loop), not string equality.
3. Missing or invalid signature → 401. No bypass path exists.
4. The webhook secret comes from `Deno.env.get('STRIPE_WEBHOOK_SECRET')`. Never VITE_ prefixed. Never embedded in client code.

## Idempotency
5. Every webhook event is keyed by the Stripe `event.id` in `webhook_idempotency`.
6. Duplicate deliveries return the cached `response_data` + `response_status` without re-processing business logic.
7. Unique constraint on `(idempotency_key, webhook_type)` prevents race between two concurrent retries.
8. Records expire after 7 days.

## Event Handlers
9. `checkout.session.completed` → order + tickets created atomically, QR signed server-side, email enqueued.
10. `payment_intent.succeeded` → VIP reservation marked `confirmed`, guest passes generated.
11. **GAP — acknowledged**: `charge.refunded` not handled. Manual reconciliation needed for Dashboard-initiated refunds.
12. **GAP — acknowledged**: `payment_intent.payment_failed` logs to `payment_failures` but does NOT email customer.
13. Unknown event types are acknowledged with 200 and logged (don't error — Stripe would retry).

## Atomicity
14. Webhook handler's order-creation path calls `create_order_with_tickets_atomic` (or equivalent transactional code). No partial states.
15. `sign_qr_token` RPC is called for every created ticket. If secret is unset, RPC fails and the saga rolls back.
16. `increment_tickets_sold` is called per ticket_type to maintain the cached counter.

## Rate Limiting
17. Webhook endpoint is NOT rate-limited (Stripe retries depend on it being always-accepted).
18. All OTHER payment endpoints (`create-checkout-session`, `create-vip-payment-intent`, `confirm-vip-payment`) ARE rate-limited at 20 req/min per IP.

## Logging & Audit
19. Every webhook delivery results in a `webhook_events` row (audit trail).
20. Every processed event updates `webhook_idempotency`.
21. Payment failures get a `payment_failures` row.
22. Revenue mismatches between DB and Stripe populate `revenue_discrepancies` via the `verify-revenue` Edge Function (manual or scheduled).

## Rollback / Compensation
23. VIP payment intent creation failure calls `rollback_vip_checkout` RPC to clean up reservation + any linked GA ticket + restore table availability.
24. Saga compensation records are in `saga_executions` with `status = 'compensated'` and step-by-step undo tracking.

## Secrets Hygiene
25. No VITE_-prefixed Stripe secrets anywhere. Publishable key is ok (it's public by design).
26. Webhook secret is different between Stripe Test and Live modes — must be rotated when switching.
27. Key rotation procedure: update Supabase Edge Function secret → redeploy function → update Stripe Dashboard endpoint → test with Stripe CLI before customer-facing traffic.

## Per-Handler Isolation
31. Every `if (event.type === ...)` block wraps its logic in try/catch and calls `captureError(err, { event_type, requestId })` on failure.
    Reason: a handler that throws bubbles up to the outer webhook try/catch, which returns 500. Stripe then retries the SAME event delivery, and every other event type riding that delivery gets re-processed. Per-handler isolation keeps one failure from corrupting sibling handlers' idempotency state.

## Outbound Stripe Idempotency
32. Every outbound Stripe API call that creates or mutates state passes an `idempotency_key`. Applies to `refunds.create`, `paymentIntents.create`, `customers.create`, `checkout.sessions.create`, etc.
    Reason: Stripe's idempotency layer prevents duplicate creation on retry, but only if a key is supplied. Without it, a network blip during a 1000-order event cancellation can double-refund some subset.
33. The idempotency key is deterministic per logical operation, not random. Example: `refund-<order_id>`, not `refund-<timestamp>`. Determinism is what makes retries safe.

## Consumer-Status Consistency
34. Any status value this layer writes to `orders.status`, `tickets.status`, or `vip_reservations.status` must be rejected (or otherwise correctly handled) by every downstream consumer.
    Reason: writing `status = 'refunded'` on a ticket is cosmetic unless the scanner rejects that value. The scanner is owned by `maguey-bulletproof-scanner`, but this layer is responsible for verifying the contract before shipping a status write.
35. Before adding a new status value, grep the scanner (`simple-scanner.ts`), the dashboard view code, the customer-facing account page, and any state-transition cron. If any consumer ignores the new value silently, coordinate the fix across skills before shipping here.

## Non-negotiables
28. No code path allows the client to dictate price.
29. No code path inserts tickets without an atomic ordering + QR sign step.
30. No code path marks an order `paid` without corresponding ticket rows.
