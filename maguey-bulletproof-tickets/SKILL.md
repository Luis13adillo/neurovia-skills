---
name: maguey-bulletproof-tickets
description: Audit, diagnose, or scale-check the Maguey Nightclub GA ticket purchase system (create-checkout-session + create-ga-payment-intent Edge Functions, src/lib/orders/ 9 modules, atomic inventory reservation, promo codes, QR token signing from Supabase Vault, ticket emails). Complement to maguey-bulletproof-payments (which covers the webhook side) and maguey-bulletproof-vip (VIP flow). Use when customers report failed purchases, missing tickets, promo code bugs, oversold events, or inventory drift. Read-only SQL via mcp__supabase__execute_sql by default; writes only with explicit user approval — ticket sales are revenue-critical.
---

# Maguey Bulletproof Tickets

Ticket purchase is where Maguey converts visitors into paying customers. A single broken checkout = lost revenue + a bad review. A single oversold event = refunds, angry customers at the door, and a scanner/dashboard mismatch.

This skill covers the GA purchase funnel:
- `maguey-pass-lounge/supabase/functions/create-checkout-session/` (Stripe Checkout Session flow)
- `maguey-pass-lounge/supabase/functions/create-ga-payment-intent/` + `confirm-ga-payment/` (Stripe Elements flow)
- `maguey-pass-lounge/src/lib/orders/` (9 modules: availability, email-refunds, index, order-creation, queries, reporting, ticket-insertion, types, user-tickets)
- `maguey-pass-lounge/src/lib/stripe.ts` (circuit breaker)
- `maguey-pass-lounge/src/pages/Checkout.tsx` + `OrderSuccess.tsx`
- Tables: `orders`, `tickets`, `ticket_types`, `ticket_type_price_tiers`, `promotions`, `ticket_transfers`, `saga_executions`, `webhook_idempotency`, `revenue_discrepancies`
- RPCs: `check_and_reserve_tickets`, `reserve_tickets_batch`, `release_reserved_tickets`, `release_tickets_batch`, `create_order_with_tickets_atomic`, `get_current_tier_price`, `advance_price_tier`, `sign_qr_token`
- Supabase Vault secret: `qr_signing_secret` (read server-side by `sign_qr_token`)

**Not covered here (delegate to other skills):**
- Stripe webhook processing + idempotency → `maguey-bulletproof-payments`
- VIP table reservations → `maguey-bulletproof-vip`
- Ticket scanning at the door → `maguey-bulletproof-scanner`
- Email delivery of QR codes → `maguey-bulletproof-email`

This skill does NOT replace `CLAUDE.md` or `MEMORY.md`. It READS them, then runs a structured protocol.

---

## Mandatory Preflight — BEFORE any action

Read in order:

1. `/Users/luismiguel/Desktop/Maguey-Nightclub-Live/CLAUDE.md` — architecture overview, credentials, "What Works (Verified)" section, constraints.
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-Maguey-Nightclub-Live/memory/MEMORY.md` — security fixes from Feb 2026, remaining blockers, role system differences.
3. This skill's `references/audit-queries.sql`, `references/invariants.md`, `references/incidents.md`.

Confirm to the user: "Preflight complete. Running [mode]." Then proceed.

**Supabase access:** use `mcp__supabase__execute_sql` (project ref `djbzjasdrwvbsoifxqzd`). Read-only. Never `apply_migration`, never `INSERT`/`UPDATE`/`DELETE`.

---

## Choose a Mode

- **audit** → full read-only health check (run weekly + before every event launch)
- **diagnose** → user has a specific ticketing symptom
- **scale-check** → prepping for a large event (>1000 tickets) or adding a new ticket tier

Pick one. Never run two modes in one invocation.

---

## Mode: audit

### Code-level invariants

Run these greps / file reads. Each has an expected result — if actual differs, FAIL.

1. **Server-side price fetching in both checkout paths**
   - Files: `create-checkout-session/index.ts` AND `create-ga-payment-intent/index.ts`
   - Must call `get_current_tier_price` RPC before computing totals — prices come from DB, NOT from client payload.
   - Must build Stripe line items / Payment Intent amount from DB values only (`dbTicket.name`, `dbTicket.price`).
   - Grep: `grep -rn "get_current_tier_price" maguey-pass-lounge/supabase/functions/create-*` → expect at least 2 hits.
   - Why: Feb 2026 security audit fix — client-sent prices were a tampering vector.

2. **Rate limiting on payment endpoints**
   - File: `create-checkout-session/index.ts` — must call `checkRateLimit(req, 'payment')` at top
   - File: `confirm-vip-payment/index.ts` — same
   - File: `create-vip-payment-intent/index.ts` — same
   - Default: 20 req/min per IP, fail-open if Upstash unavailable
   - Grep: `grep -n "checkRateLimit" supabase/functions/*/index.ts`

3. **Circuit breaker wraps Stripe calls**
   - File: `maguey-pass-lounge/src/lib/stripe.ts`
   - `createCheckoutSession()` must be wrapped in `stripeCircuit.execute()` (line ~120)
   - Why: prevents cascading failures when Stripe or Edge Function is down

4. **QR signature generation is server-side only**
   - Grep: `grep -rn "VITE_QR_SIGNING_SECRET" maguey-pass-lounge/src` → must return **zero matches**
   - Verify vault secret: `SELECT name, length(decrypted_secret) FROM vault.decrypted_secrets WHERE name = 'qr_signing_secret'` → expect 1 row with non-zero length.
   - Verify `sign_qr_token` RPC body reads from `vault.decrypted_secrets WHERE name = 'qr_signing_secret'` (NOT `current_setting('app.qr_signing_secret')` — that pattern is deprecated).
   - Why: client-exposed QR secret was removed in Feb 2026 security lockdown; secret lives in Supabase Vault, not DB settings.

5. **Atomic inventory reservation**
   - File: `maguey-pass-lounge/src/lib/orders/order-creation.ts` (969 lines)
   - Must call `reserve_tickets_batch` or `create_order_with_tickets_atomic` RPC, NOT do separate SELECT + UPDATE
   - Grep: `grep -n "reserve_tickets_batch\|create_order_with_tickets_atomic\|check_and_reserve_tickets" src/lib/orders/*.ts`

6. **No direct `INSERT INTO tickets`/`orders` from client code**
   - Grep: `grep -rn "from.*'tickets'.*insert\|from.*'orders'.*insert" maguey-pass-lounge/src` — should match only inside orders-service modules that call RPC, NOT raw inserts from pages/components

7. **Saga pattern for order creation**
   - `order-creation.ts` line ~749 must reference `mode: 'saga'` and use `executeOrderSaga` (line ~813)
   - Saga compensation path must exist (rollback on step failure)
   - Related table: `saga_executions`

8. **Orders module split intact**
   - Directory `maguey-pass-lounge/src/lib/orders/` must contain 9 modules. If consolidated back into a single `orders-service.ts` file, that's a regression — the split keeps ticket-insertion, promo, email, and query logic readable in isolation.

### Data-level invariants

Run `references/audit-queries.sql` via `mcp__supabase__execute_sql` — one SELECT at a time. Expected: 0 rows unless noted.

### Audit output template

```
## Tickets Audit Report — [YYYY-MM-DD]

### Code-level
- [PASS/FAIL] Server-side prices via get_current_tier_price (both checkout paths)
- [PASS/FAIL] Rate limiting on all payment endpoints
- [PASS/FAIL] Circuit breaker on createCheckoutSession
- [PASS/FAIL] No VITE_QR_SIGNING_SECRET in client; `qr_signing_secret` present in vault
- [PASS/FAIL] Atomic inventory via reserve_tickets_batch / create_order_with_tickets_atomic
- [PASS/FAIL] No client-side tickets/orders INSERT
- [PASS/FAIL] Saga pattern intact in order-creation.ts
- [PASS/FAIL] orders/ directory still has 9 modules
- [PASS/FAIL] increment_tickets_sold RPC exists (stripe-webhook depends on it)

### Data-level
- [PASS/FAIL] No tickets without orders (0 rows)
- [PASS/FAIL] No orders marked 'paid' without tickets (0 rows)
- [PASS/FAIL] tickets_sold never exceeds total_inventory per ticket_type (0 rows)
- [PASS/FAIL] tickets_sold counter matches actual ticket count (0 rows)
- [PASS/FAIL] No duplicate QR tokens (0 rows)
- [PASS/FAIL] No tickets with NULL qr_signature on paid orders (0 rows)
- [PASS/FAIL] chk_paid_order_has_payment_reference constraint present + validated
- [PASS/FAIL] cascade_order_status_to_tickets trigger present
- [PASS/FAIL] No promo code redemption count > usage_limit (0 rows)
- [PASS/FAIL] No pending orders >24h old (0 rows — flag cron gap if present)
- [PASS/FAIL] No unresolved revenue discrepancies (0 rows)
- [PASS/FAIL] webhook_idempotency table has unique constraint

### Failures
[If any FAIL: list the symptom and point to the exact file/line or SQL result. Do NOT fix anything in audit mode. Report and stop.]
```

If any check fails, STOP after reporting. Audit is diagnostic — escalate to `diagnose` with user approval before fixing.

---

## Mode: diagnose

### Step 1: Ask, don't assume
- Which event, which ticket type, which customer email/order ID?
- Exact error message or behavior? (screenshot preferred)
- What did the customer see in Stripe (charged? error? redirected?)
- When did it start? (correlate with `git log --oneline -20`)

Do not read files until you have the symptom.

### Step 2: Simple fixes first
- Is the event published (`events.status = 'published'`)?
- Is `ticket_types.is_active = true`?
- Is inventory actually available (`tickets_sold < capacity`)?
- Is Stripe dashboard showing the charge? (user must check)

If basic data checks reveal the issue, you're done.

### Step 3: Match against known incidents
See `references/incidents.md`. Known categories:
- **"Customer charged but no ticket"** → check `webhook_idempotency`, `saga_executions.status`, `email_queue` (escalate to `maguey-bulletproof-payments` if Stripe webhook failed)
- **"Oversold event / duplicate ticket numbers"** → atomicity broken in `reserve_tickets_batch` or someone added a raw INSERT
- **"Promo code used more than usage_limit"** → race condition in the promo redemption path — known issue, non-atomic COUNT-then-INSERT
- **"Price mismatch between site and Stripe"** → client price leaked through (shouldn't be possible post-Feb-2026, but verify)
- **"Ticket exists but QR missing"** → `sign_qr_token` RPC failure; secret now lives in `vault.decrypted_secrets`, verify with query #12 in audit-queries.sql
- **"Order stuck in 'pending'"** → webhook didn't fire, OR create-ga-payment-intent crashed mid-flow (check `payment_reference` on the order — NULL means PI was never created/linked)

### Step 4: 3-file rule
If no known incident matches: read at most 3 files based on error location. Stop after 3. Report findings to user.

### Step 5: Two-strike rule
If first fix fails, second attempt MUST use a different approach. Stop after second failure. Report.

### Step 6: Stay in scope
Ticket bug → fix ticket code. Do NOT "also refactor" auth, VIP, scanner while you're in there.

---

## Mode: scale-check

Before every major event (holiday shows, concerts, big DJ nights). Output: "ready / not ready" checklist.

### 1. Inventory atomicity stress points
- Run query #3 in `audit-queries.sql` — any ticket_type where `tickets_sold > capacity`?
- Run query #10 — concurrent reservation collisions last 7 days?
- Verify `reserve_tickets_batch` RPC uses `FOR UPDATE` row lock (read migration).

### 2. Rate limit headroom
- Current `payment` tier: 20 req/min per IP. For a 2000-ticket event with flash sale → expect 100+ req/sec burst.
- Check Upstash limits: is the Upstash free tier enough for expected traffic? (flag if >50k requests/day expected)

### 3. Stripe checkout session expiry
- File: `create-checkout-session/index.ts` — what's the `expires_at` on sessions? Stripe default is 24h. If custom, flag.
- Abandoned sessions at scale = orphan pending orders.

### 4. Email queue throughput
- `email_queue` worker runs every 1min, max 10 emails per run = 600/hour.
- For a 1000-ticket event where all purchases happen in a 2-hour window → 500 emails/hour = safe.
- For 5000 tickets in 1 hour → BOTTLENECK. Escalate to `maguey-bulletproof-email`.

### 5. Database connection pool
- Supabase Pro tier connection limits. Run: `SELECT count(*) FROM pg_stat_activity;` → should be <60% of limit under normal load.

### 6. Circuit breaker thresholds
- `stripe.ts` circuit breaker: check failure threshold + timeout. For launch day, ensure timeout isn't too aggressive (false positives).

### 7. Promo code atomicity (known gap)
- `promotions-service.ts` — `usage_limit` check is NOT atomic (count query after check).
- If promo has usage_limit=100 and 1000 people redeem in 5s, could exceed by 10-50. Flag this as "known risk for high-concurrency events."

### 8. Abandoned pending orders
- `create-ga-payment-intent` inserts tickets + order at status='pending' before Stripe PI succeeds. Abandoned carts stay `pending` forever unless something cancels them.
- Note: `expire_stale_reservations` and `release_reservation` RPCs exist but are no-op stubs. There is no working reservation-expiry cron.
- The `cascade_order_status_to_tickets` trigger (added 2026-04-21) flips tickets to cancelled when an order is cancelled, but nothing auto-cancels the parent order.
- For a large event: count pending orders >1h old and review before sales day to avoid phantom inventory.

### Scale-check output template

```
## Ticket Scale Readiness — Event: [name], Expected: [X] tickets, Date: [YYYY-MM-DD]

### Inventory integrity: [READY / NOT READY]
### Rate limit capacity: [READY / NOT READY]
### Stripe session config: [notes]
### Email throughput: [X emails/hr capacity vs Y expected]
### DB connection headroom: [X / Y max]
### Circuit breaker: [thresholds]
### Promo code atomicity: [KNOWN GAP — impact assessment]
### Stale reservation cleanup: [cron active? last run?]

### Verdict: [READY / NOT READY — with numbered must-fix list if NOT]
```

Do NOT make fixes in scale-check mode.

---

## Downstream Consumers (what the ticket purchase feeds)

A ticket purchase must propagate to every consumer within ~5s:

| Consumer | Location | Reads |
|---|---|---|
| OrderSuccess page | `maguey-pass-lounge/src/pages/OrderSuccess.tsx` | order + tickets by session_id |
| Customer email (QR) | `process-email-queue` → Resend | email_queue row, ticket qr_token + signature |
| Owner dashboard | `maguey-gate-scanner/src/pages/OwnerDashboard.tsx` | real-time `orders` subscription, revenue counter |
| Scanner | `maguey-gate-scanner/src/pages/Scanner.tsx` → Dexie cache | pre-event `tickets` download for offline |
| Marketing site | `maguey-nights` (indirect) | `ticket_types.tickets_sold` for sold-out badge |
| Analytics | `maguey-gate-scanner/src/pages/*Analytics*.tsx` | real-time event totals |

**Propagation invariants:**
1. Stripe webhook completes → `orders.status = 'paid'` within the webhook's 5s budget.
2. Ticket insertions and QR signatures atomic with order status update.
3. `email_queue` row inserted (type=`ga_ticket`) BEFORE webhook returns 200.
4. Realtime subscription on `orders` fires on dashboard within 1s.
5. `ticket_types.tickets_sold` updates (via `increment_tickets_sold` RPC) — marketing site sold-out badge reflects within ~2s.

If a consumer doesn't see the ticket, trace the chain back until you find the break.

---

## HARD RULES

- **DEFAULT read-only.** All investigation uses `mcp__supabase__execute_sql` for SELECTs and greps for code. No writes by default — not even for test data.
- **Writes require explicit user approval.** If an audit uncovers bad data or you want to add a constraint/trigger/migration, present the proposed SQL, wait for a clear "yes" on that specific change, then execute via `mcp__supabase__apply_migration` (schema) or `execute_sql` (data). Re-verify with the same audit query after. Write context: user approval is scoped to the exact change approved, not to the whole session.
- **NEVER modify atomic RPCs** (`create_order_with_tickets_atomic`, `reserve_tickets_batch`, `sign_qr_token`, `create_unified_vip_checkout`) without explicit user approval. They are the load-bearing inventory/QR/VIP contract.
- **NEVER expand scope.** Ticket bug → ticket fix only. If the issue crosses into VIP/payments/scanner/email, flag it in the report and switch skill (or ask).
- **ALWAYS use `mcp__supabase__`** (Maguey's project `djbzjasdrwvbsoifxqzd`).
- **ALWAYS verify** prices come from DB (`get_current_tier_price`) in both checkout paths — never trust client.
- **Edge Function code changes do NOT auto-deploy.** Git push deploys Vercel (the 3 React apps). Edge Function deploy needs `supabase functions deploy <name>` from `maguey-pass-lounge/`. Flag this in every response that touches a file under `supabase/functions/`.
- **Branch workflow:** any code change goes on a `fix/…` or `feature/…` branch. Merge to main only with explicit user approval. Let `maguey-bulletproof-ship` handle the actual push.
- **User reports override queries.** If user says "the customer was charged" and your query says order status is pending, trust the user and look for the broken link (webhook, idempotency, email).

---

## What to Return

- **audit** → completed report (pass/fail per check) with file:line or SQL result for failures
- **diagnose** → reproduction + proposed fix in one file, OR "I don't know — here's what I found, need direction"
- **scale-check** → ready/not-ready checklist with numbered must-fixes

Never silently retry. Never keep reading files hoping for clarity.
