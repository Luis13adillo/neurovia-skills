# Tickets — Invariants (What Must Always Be True)

These are the load-bearing rules. If any of these are false in production, there is a bug.

## Pricing
1. Every ticket type offered for sale has `price > 0` and `total_inventory > 0`. (Column is `price` numeric dollars, not `price_cents`; `ticket_types` has no `is_active` column — a type is considered sellable when it has positive inventory and a price, and its parent event is `status='published'`.)
2. Prices sent to Stripe come from `get_current_tier_price` RPC. Never from client payload.
3. Promo discounts are applied server-side in the Edge Function — never trust a client-sent discounted total.

## Inventory
4. `ticket_types.tickets_sold` ≤ `ticket_types.capacity` for every row.
5. `ticket_types.tickets_sold` equals the actual count of non-cancelled/non-refunded `tickets` rows with matching `ticket_type_id` (audit query #4 proves this).
6. No ticket can exist without a parent order.
7. An order marked `paid` must have at least one ticket row attached (unless it's a VIP-only reservation handled by `vip_reservations`).

## QR Signing
8. Every ticket on a `paid` order has both `qr_token` (UUID) and `qr_signature` (HMAC base64) populated.
9. QR signatures are HMAC-SHA256(token, vault secret). The secret is stored in **Supabase Vault** at `vault.decrypted_secrets WHERE name = 'qr_signing_secret'`. It is never set as a DB-level `app.*` setting and never exposed to any client bundle. The older `current_setting('app.qr_signing_secret')` pattern is deprecated — if you see it, that's a regression.
10. The `sign_qr_token` RPC is the only code path that signs tokens. It reads from vault and raises if the vault entry is missing. Client code must not attempt signing.

## Atomicity
11. Order + ticket creation is atomic. Either all tickets exist and order = `paid`, OR order stays `pending` and no tickets were persisted.
12. `reserve_tickets_batch` RPC uses `FOR UPDATE` row locking on `ticket_types` to prevent overselling under concurrency.
13. On saga failure, `record_saga_compensation` inserts compensation records and the saga status flips to `compensated` (not just `failed`).

## Webhook Deduplication
14. `webhook_idempotency` table has a unique constraint on `(idempotency_key, webhook_type)`.
15. A second delivery of the same Stripe event returns the cached response from `webhook_idempotency` without re-processing.
16. Idempotency records auto-expire after 7 days.

## Rate Limiting
17. Every payment endpoint (`create-checkout-session`, `create-vip-payment-intent`, `confirm-vip-payment`) calls `checkRateLimit(req, 'payment')` before any DB work.
18. Rate limits are fail-open: Upstash unavailable → request proceeds rather than blocks (availability over strict limiting).

## Circuit Breaker
19. All client-initiated Stripe calls go through `stripeCircuit.execute()` in `src/lib/stripe.ts`.
20. Circuit breaker auto-transitions: CLOSED → OPEN after failure threshold → HALF_OPEN after timeout → CLOSED on success.

## Refund / Cancellation (WARNING: current gap)
21. **GAP:** `stripe-webhook/index.ts` does NOT currently handle `charge.refunded` events. Refunds issued from the Stripe Dashboard do NOT auto-update order/ticket status. Must be reconciled manually. Flag this to user in every audit.
22. Event cancellation uses `cancel-event-with-refunds/` Edge Function — this is a separate, explicit flow (not webhook-driven).

## Data Visibility
23. `events.status = 'published'` is required for purchase. Draft/archived events reject checkout.
24. `events.event_date >= today()` is required — past events cannot be purchased.
25. Orders and tickets are visible to (a) the purchaser by email JWT claim, (b) staff roles (`promoter`, `scanner`, `admin`, `service_role`). Anonymous users can INSERT but only read their own post-login.
