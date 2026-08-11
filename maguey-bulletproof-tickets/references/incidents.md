# Tickets — Known Incidents & Fix Patterns

Documented failure modes. Match the user's symptom here first; it's faster than re-deriving.

---

## Incident: Client-side price tampering (pre-Feb 2026)
**Symptom:** Customer checkout shows $10 but Stripe charges $100 (or vice versa).
**Root cause:** Edge Function accepted `price` from client payload and passed to Stripe without verification.
**Fix applied:** `create-checkout-session/index.ts` now fetches prices server-side via `get_current_tier_price` RPC. Client only sends `ticketTypeId` + `quantity`. Server computes total.
**How to verify fix stays intact:** grep `create-checkout-session/index.ts` for any code path that reads `price` / `amount` / `price_cents` from the request body and forwards to Stripe without going through the RPC. Zero matches expected.
**If regression:** this is P0. Prices must never come from client.

---

## Incident: QR signing secret exposed in client bundle (pre-Feb 2026)
**Symptom:** Client-side JS bundle contained `VITE_QR_SIGNING_SECRET`. An attacker could sign arbitrary QR codes and counterfeit tickets.
**Root cause:** env var prefixed with `VITE_` is bundled into client JS.
**Fix applied:** Secret moved server-side only. Stored in **Supabase Vault** (not as a DB `app.*` setting — the migration that used `ALTER DATABASE postgres SET app.qr_signing_secret` was superseded). Read at query time via `SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'qr_signing_secret'`. Signing happens inside the `sign_qr_token` RPC, called from the Stripe webhook and `create-ga-payment-intent`.
**How to verify:**
- `grep -rn "VITE_QR_SIGNING_SECRET" maguey-pass-lounge/` → 0 matches
- `grep -rn "VITE_QR_SIGNING_SECRET" maguey-gate-scanner/` → 0 matches
- Audit query #11 (the vault lookup) returns one row with `secret_length > 0`.
- `sign_qr_token` body reads from `vault.decrypted_secrets`, not `current_setting('app.qr_signing_secret')`.
**If regression:** rotate the secret immediately — `scripts/post-deploy-security.ts` has the helper, or do it manually via the Vault dashboard. Every existing QR is compromised until re-signed.

---

## Incident: Promo code used more than usage_limit
**Symptom:** Promo "LAUNCH50" had usage_limit=100 but ended up with 140 redemptions.
**Root cause:** The promo redemption path in `src/lib/orders/` checks `SELECT COUNT(*) < usage_limit` and THEN inserts a redemption row — non-atomic. Under high concurrency multiple requests pass the check before any insert, all succeed. (`promotions` table has no `usage_count` column — count is derived from `orders.promo_code_id`.)
**Current state:** KNOWN GAP. Not yet fixed.
**Workaround for big launches:** set usage_limit lower than intended (e.g., 95 for a true 100 limit) to absorb overflow. Or use a per-email uniqueness guard which is atomic.
**Proper fix (needs user approval):**
```sql
-- Make redemption atomic via a unique partial index or FOR UPDATE on promotions row:
CREATE OR REPLACE FUNCTION redeem_promo_atomic(p_code text, p_order_id uuid) RETURNS boolean ...
-- Locks promotions row FOR UPDATE, checks usage_count < usage_limit inside the transaction, UPDATEs usage_count++.
```
**How to detect drift:** audit query #9 surfaces any promo over-usage.

---

## Incident: Order stuck in 'pending' after successful Stripe charge
**Symptom:** Customer was charged in Stripe but their order stays `pending`, no tickets generated, no email received.
**Root cause chain (most common → least):**
1. Stripe webhook never delivered (check Stripe Dashboard → Webhooks → event log)
2. Webhook delivered but signature verification failed (check `stripe-webhook/index.ts` logs — 401s)
3. Webhook processed but idempotency key collision returned early (check `webhook_idempotency` table for the event id)
4. Webhook processed, saga failed mid-way, rollback compensated the tickets back out (check `saga_executions` for that order)
5. Webhook processed, tickets inserted, but `orders.status` update got rolled back (rare — atomic RPC should prevent)
**Debugging:**
- First, find the order: `SELECT id, status, payment_reference, created_at FROM orders WHERE purchaser_email = '...' ORDER BY created_at DESC LIMIT 5;` (the Stripe session or payment intent id lives in `payment_reference`)
- Check webhook_events/webhook_idempotency for that session id
- Check saga_executions for compensation traces
- Escalate to `maguey-bulletproof-payments` skill for the webhook deep-dive

---

## Incident: Oversold event / duplicate ticket positions
**Symptom:** Event sold 520 tickets when capacity was 500. Or two customers got the same `ticket_number`.
**Root cause possibilities:**
1. Someone bypassed `reserve_tickets_batch` RPC and did a raw INSERT (grep for direct `tickets` inserts in src/lib/orders/)
2. `reserve_tickets_batch` missing `FOR UPDATE` lock on ticket_types row (read the migration)
3. `tickets_sold` counter out of sync with actual ticket count (audit query #4)
**Fix pattern:** always via atomic RPC with row lock. Never directly update `tickets_sold` from app code — rely on `increment_tickets_sold` RPC (called from stripe-webhook).

---

## Incident: Ticket exists but QR signature missing
**Symptom:** `tickets.qr_token` is populated but `tickets.qr_signature` is NULL on a paid order.
**Root cause candidates:**
1. `sign_qr_token` RPC failed silently — the vault entry `qr_signing_secret` is missing or empty (usually after a Vault reset, project restore, or a deploy that didn't re-seed the secret).
2. The ticket was inserted through a path that bypassed `sign_qr_token` entirely — e.g. a manual INSERT from an admin script or a test fixture pushed to prod. Also check whether the parent order has `payment_reference` populated; if both `payment_reference` and `payment_provider` are NULL, it almost certainly came from a manual path, not from Stripe.
**Fix:**
```sql
-- Verify the vault secret is set (audit query #11):
SELECT name, length(decrypted_secret) AS secret_length
FROM vault.decrypted_secrets
WHERE name = 'qr_signing_secret';
-- If missing or length 0, re-seed it. The helper is scripts/post-deploy-security.ts
-- (or set manually via the Vault dashboard). NEVER hard-code the secret in SQL.
```
**After fix:** existing affected tickets need back-signing. Query them, call `sign_qr_token` per ticket, UPDATE `qr_signature`. This is a WRITE operation — requires explicit user approval. Be especially careful to distinguish *real paid customers* (where you want to sign) from *test/manual orders* (where the correct move is often to cancel the order and its tickets instead).

---

## Incident: Email never delivered after successful purchase
**Symptom:** Customer paid, order is `paid`, tickets exist, but no confirmation email arrives.
**Not a tickets bug.** Escalate to `maguey-bulletproof-email`.
**Quick triage:**
- `SELECT * FROM email_queue WHERE related_id = '<order_id>' ORDER BY created_at DESC;`
- If row status is `failed` — check `last_error`
- If row status is `delivered` — email was sent; check customer's spam folder
- If no row at all — the webhook didn't enqueue. Check Stripe webhook logs.

---

## Incident: Checkout page hangs on "redirecting to Stripe…"
**Symptom:** User clicks checkout, page spins, never redirects.
**Root cause possibilities:**
1. Stripe circuit breaker opened (too many failures) → `stripeCircuit` in OPEN state
2. Edge Function cold start + rate limit hit
3. Event or ticket_type not found (returns 404, client doesn't handle)
**Check:**
- Browser console for errors from `/functions/v1/create-checkout-session`
- Edge Function logs in Supabase Dashboard
- `checkPaymentAvailability()` return value — if false, circuit breaker is open
**Fix:** if circuit breaker is stuck open, it auto-transitions to HALF_OPEN after timeout (see `stripe.ts` constants). For immediate recovery, restart the Edge Function (Supabase Dashboard → Edge Functions → redeploy).

---

## Incident: Ticket transfer completes but recipient gets no email
**Symptom:** Transfer status = `completed` but recipient didn't receive `ticket_transfer_received` email.
**Root cause:** `email_queue` row for transfer type not enqueued OR worker dropped it.
**Check:** `SELECT * FROM email_queue WHERE email_type = 'ticket_transfer_received' AND related_id = '<transfer_id>'`
**Escalate to `maguey-bulletproof-email`.**

---

## Pattern: "The customer says X, but the DB says Y"
**Rule:** the customer is usually right. Find the UI code path they saw. Don't assume they misread.
**Common cause:** UI reads from `tickets` joined with `orders`, but a stale cache or frozen realtime subscription shows outdated data. Refresh the customer's page. If it persists, check the subscription status.

---

## Pattern: Regression after refactor
**Known refactor points from MEMORY.md / CLAUDE.md:**
- `orders-service.ts` was split into `src/lib/orders/` (9 modules as of 2026-04-21). If code reverts to a single flat file, re-introduced bugs from the pre-split era may resurface.
- `AuthContext.tsx` was split into 3 hooks. Related to ticket ownership checks (`attendee_email`).

**Check before any big fix:** did the file structure change recently? `git log --oneline -20 src/lib/orders/ src/contexts/AuthContext.tsx`
