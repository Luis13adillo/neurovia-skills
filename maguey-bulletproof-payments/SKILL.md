---
name: maguey-bulletproof-payments
description: Audit, diagnose, or scale-check the Maguey Nightclub Stripe webhook + payment processing layer (stripe-webhook 1650 lines, idempotency via webhook_idempotency, signature verification, payment_failures, revenue_discrepancies, refund handling, event cancellation flow). Complement to maguey-bulletproof-tickets (purchase funnel) and maguey-bulletproof-vip (VIP payment intents). Use when webhooks misfire, duplicate charges appear, refunds don't propagate, revenue reconciliation drifts, or Stripe events aren't processed. Read-only SQL via mcp__supabase__execute_sql only. Never writes to production DB — payment data is revenue-critical.
---

# Maguey Bulletproof Payments

Payment processing is where Maguey's money and trust meet. A failed webhook leaves revenue unrecorded. A duplicate charge turns into a refund request and a bad review. A missed refund puts a customer at the door with a voided ticket the system still believes is valid.

This skill covers:
- `maguey-pass-lounge/supabase/functions/stripe-webhook/index.ts` (1,650 lines) — event processor
- Signature verification (constant-time HMAC-SHA256) at `verifyStripeSignature`
- Idempotency via `webhook_idempotency` table + `check_webhook_idempotency` / `update_webhook_idempotency` RPCs
- Refund handling (**known gap**: `charge.refunded` event NOT currently processed)
- `cancel-event-with-refunds/` Edge Function (event-level cancellation)
- `notify-payment-failure/` Edge Function
- `verify-revenue/` Edge Function
- Tables (verified 2026-04-21): `webhook_idempotency`, `webhook_events`, `revenue_discrepancies`, `saga_executions`. (`payment_failures` and `payments` are referenced in some older incident write-ups but DO NOT EXIST in this project — see `references/invariants.md` Schema Reality Check.)

**Not covered here (delegate):**
- GA purchase funnel (create-checkout-session, orders-service) → `maguey-bulletproof-tickets`
- VIP payment intent + confirmation → `maguey-bulletproof-vip`
- Email delivery after webhook → `maguey-bulletproof-email`

This skill does NOT replace `CLAUDE.md` or `MEMORY.md`. It READS them, then runs a structured protocol.

---

## Mandatory Preflight — BEFORE any action

Read these first, in order:
1. `/Users/luismiguel/Desktop/Maguey-Nightclub-Live/CLAUDE.md` — payment flow, "Resolved Blockers" (QR + webhook signature mandatory since Feb 2026).
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-Maguey-Nightclub-Live/memory/MEMORY.md` — security fixes, remaining Stripe prod-keys blocker, schema reality notes.
3. This skill's `references/invariants.md` (contract), `references/audit-queries.sql` (data checks), `references/incidents.md` (fix patterns), `references/preflight-checks.md` (full verification protocol), `references/disputes.md` (if refunds or disputes are in scope).

Then run these quick checks. Each one catches a class of error that otherwise produces misleading work. Full details in `references/preflight-checks.md`:

**a. Schema reality** — run the SQL below. Compare output against the Schema Reality Check in `invariants.md`. Stale schema notes = audit findings that aren't real.

```sql
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('webhook_idempotency', 'webhook_events',
                     'revenue_discrepancies', 'saga_executions', 'orders',
                     'tickets', 'vip_reservations', 'email_queue')
ORDER BY table_name, ordinal_position;
```

**b. Base-file parse** — before proposing ANY edit to `stripe-webhook/index.ts`:
```bash
deno check maguey-pass-lounge/supabase/functions/stripe-webhook/index.ts 2>&1 | tail -10
```
If "source code could not be parsed" — STOP. The file is already broken (happened in session of 2026-04-21). Proposing additions on broken code produces misleading diffs. Fix or flag the base file first.

**c. Disk vs. deployed** — for any gap finding that will drive action, confirm the disk version is what Stripe is actually hitting. See §3 of `preflight-checks.md`.

**d. Stripe Dashboard endpoint config** — code that consumes an event type is useless if Stripe isn't configured to send it. See §4 of `preflight-checks.md`.

**e. Scanner status cross-check** — before writing any ticket status, grep `simple-scanner.ts` to confirm the scanner actually rejects that value. As of 2026-04-21 the scanner only flags `status === 'scanned'`; writing `status = 'refunded'` without a scanner update lets refunded tickets scan green.

Announce: "Preflight complete. Running [mode]." Then proceed.

Supabase MCP: `mcp__supabase__execute_sql` (project `djbzjasdrwvbsoifxqzd`). Read-only.

---

## Choose a Mode

- **audit** → full read-only webhook health check (run weekly)
- **diagnose** → specific payment symptom reported
- **scale-check** → before a flash sale / large event where webhook volume will spike

---

## Mode: audit

### Code-level invariants

1. **Mandatory Stripe signature verification**
   - File: `maguey-pass-lounge/supabase/functions/stripe-webhook/index.ts` line ~552-600
   - Must call `verifyStripeSignature(rawBody, signature, secret)` before any DB work.
   - Must reject (401) if signature missing OR invalid. No "bypass for testing" branch.
   - Must use **constant-time comparison** (XOR loop), not `===`.
   - Grep: `grep -n "verifyStripeSignature\|stripe-signature\|constructEvent" supabase/functions/stripe-webhook/index.ts`

2. **Idempotency check BEFORE signature verification fail-open**
   - Line ~645-686: calls `check_webhook_idempotency(p_idempotency_key)` with the Stripe event ID.
   - If RPC returns a cached response → return 200 with cached body (don't re-process).
   - Grep: `grep -n "check_webhook_idempotency\|update_webhook_idempotency" stripe-webhook/index.ts`

3. **Webhook handlers cover all money-moving events**
   - Currently handled: `checkout.session.completed` (line ~715), `payment_intent.succeeded` (line ~1179). A `charge.refunded` handler was added on branch `fix/charge-refunded-handler` (2026-04-21); verify it merged.
   - **GAP — flag this every audit**: `charge.refunded` auto-processing. Refunds from Stripe Dashboard must update `orders.status`, `tickets.status`, and `vip_reservations.status`. If missing, refunded customers still scan green at the door. Fix template in `references/incidents.md`.
   - **GAP — equal priority**: `charge.dispute.created` NOT handled. Disputes pull funds from Stripe balance immediately and have a 7–21 day response window. Ignoring them auto-loses the money. Full pattern in `references/disputes.md`.
   - **GAP**: `payment_intent.payment_failed` not handled. Customer receives no email explaining the decline. No `payment_failures` row inserted.
   - Grep: `grep -nE "event\.type\s*===" stripe-webhook/index.ts` to enumerate handled events.

4. **Atomic order/ticket mutation via RPC**
   - `checkout.session.completed` path must call `create_order_with_tickets_atomic` OR manipulate via the `orders/tickets` tables inside a single transaction.
   - Must call `increment_tickets_sold` (line ~1408) after ticket insert.
   - Must call `sign_qr_token` (line ~103) for each ticket — never sign client-side.

5. **VIP webhook path uses rollback RPC on failure**
   - `payment_intent.succeeded` handler: on failure, calls `rollback_vip_checkout` (line ~234).
   - No partial VIP state left if anything fails between PI creation and confirmation.

6. **Webhook secret is server-only**
   - Env var: `STRIPE_WEBHOOK_SECRET` (set in Supabase Edge Function secrets).
   - Grep client bundles: `grep -rn "STRIPE_WEBHOOK_SECRET\|VITE_STRIPE_WEBHOOK" maguey-pass-lounge/src maguey-gate-scanner/src maguey-nights/src` → must return 0 matches.

7. **Test vs live key separation**
   - `VITE_STRIPE_PUBLISHABLE_KEY` on client: check env/vercel config. Currently still `pk_test_*` per MEMORY.md (1-of-9 deployment blockers).
   - Server-side `STRIPE_SECRET_KEY` in Edge Function secrets: must match environment.
   - Mismatch (e.g. test publishable + live secret) causes signature validation + session creation failures.

8. **Webhook events logged**
   - `webhook_events` table should receive an INSERT per processed event (audit trail).
   - Check migration `20250614000000_webhook_replay_protection.sql` for replay protection on `webhook_events`.
   - **Watchout (2026-04-21):** query returned 0 rows in this table. Either logging is not wired to the handlers or rows are purged aggressively. Reconcile: if logging is expected, trace why it's not writing; if expected-empty, remove this invariant.

9. **Every event handler wraps its logic in try/catch**
   - Each `if (event.type === ...)` block catches its own exceptions and calls `captureError` (Sentry).
   - Without per-handler isolation, one handler's thrown exception rolls back the outer webhook response to 500 — Stripe then retries, and every OTHER event type in the same delivery window gets re-processed. Bad for idempotency + observability.
   - Check: each handler has a surrounding `try { ... } catch (err) { logger.error(...); captureError(err, {...}); }` block. If absent, flag as FAIL.

10. **Outbound Stripe calls carry idempotency keys**
    - `cancel-event-with-refunds/` loops through orders issuing refunds. Each refund API call needs `idempotency_key: 'refund-<order_id>'` (or similar). Without it, a retry after a network blip double-refunds.
    - Grep: `grep -rn "idempotency_key\|idempotencyKey" maguey-pass-lounge/supabase/functions/cancel-event-with-refunds/` → must show usage on every refund/create call.
    - Applies equally to any other outbound Stripe write (payment_intents.create, refunds.create, customers.create).

11. **Consumer-status consistency**
    - This skill writes statuses like `'refunded'`, `'disputed'` to `orders.status` and `tickets.status`. The scanner (`maguey-gate-scanner/src/lib/simple-scanner.ts`) decides whether to admit a ticket at the door. If the two sides disagree, refunded/disputed tickets still scan green.
    - Before writing a new status value, grep the scanner for its rejection logic and confirm the new status is rejected. As of 2026-04-21 the scanner only flags `status === 'scanned'`. Shipping `status = 'refunded'` without a scanner update is cosmetic.
    - Cross-skill: fixes to the scanner belong to `maguey-bulletproof-scanner`. This skill MUST verify the contract before shipping, even though the fix lives elsewhere.

### Data-level invariants

Run `references/audit-queries.sql` via `mcp__supabase__execute_sql` — one at a time. Expected: 0 rows unless noted.

### Audit output template

```
## Payments Audit Report — [YYYY-MM-DD]

### Preflight
- [PASS/FAIL] Schema reality matches invariants.md
- [PASS/FAIL] stripe-webhook/index.ts parses (deno check)
- [PASS/FAIL/SKIPPED] Disk version matches deployed version
- [PASS/FAIL/SKIPPED] Stripe Dashboard endpoint has required events enabled
- [PASS/FAIL] Scanner status-check contract verified

### Code-level
- [PASS/FAIL] Stripe signature verification mandatory (constant-time)
- [PASS/FAIL] Idempotency check via webhook_idempotency
- [PASS/FAIL/KNOWN-GAP] charge.refunded handler present
- [PASS/FAIL/KNOWN-GAP] charge.dispute.created handler present
- [PASS/FAIL/KNOWN-GAP] payment_intent.payment_failed → customer notification
- [PASS/FAIL] Atomic order/ticket mutation via RPC
- [PASS/FAIL] VIP rollback on failure
- [PASS/FAIL] Webhook secret server-only
- [PASS/FAIL] Test/Live key consistency (note: prod blocker still open)
- [PASS/FAIL] Every event handler has try/catch + captureError
- [PASS/FAIL] Outbound Stripe calls carry idempotency_key
- [PASS/FAIL] Consumer-status consistency (statuses written here are rejected by scanner)

### Data-level
- [INFO] Webhook event type distribution last 7d (query #1 — informational, not pass/fail)
- [PASS/FAIL] No duplicate processing of same Stripe event (0 rows — query #2)
- [N/A] payment_failures table does not exist in this project — query #3 skipped
- [PASS/FAIL] No revenue_discrepancies open >24h (0 rows — query #4)
- [PASS/FAIL] No orders paid without matching Stripe record (spot check — query #5)
- [PASS/FAIL] No saga_executions stuck in running/pending/compensating >1h (0 rows — query #6)
- [INFO] webhook_idempotency table size + TTL health (query #7)
- [PASS/FAIL] Stripe refunds not reflected in orders (MANUAL — query #8)
- [PASS/FAIL] No orphan pending orders >24h (query #9)
- [PASS/FAIL] No VIP reservations confirmed without webhook trace (query #10)

### Failures
[List each with file/line or SQL row count. Do NOT fix in audit mode. Report and stop.]

### Known Gaps (persistent)
- **charge.refunded** — handler drafted on `fix/charge-refunded-handler` (2026-04-21). If not yet merged, refunds from Stripe Dashboard don't propagate. Full fix template + schema-correct SQL in `references/incidents.md`. Depends on scanner also rejecting `status='refunded'` (cross-skill: `maguey-bulletproof-scanner`) and on email delegate (`maguey-bulletproof-email`).
- **charge.dispute.created** — not handled. Disputes pull funds immediately and auto-lose if unanswered within 7–21 days. Full pattern, handler skeleton, and cross-skill dependencies in `references/disputes.md`.
- **payment_intent.payment_failed** — not handled. No `payment_failures` row inserted (table does not exist anyway), no customer email queued.
- **webhook_events empty** — table has 0 rows. Either logging is not wired or rows are purged. Reconcile before trusting Q11 event distribution.
```

If any FAIL, STOP after reporting. Audit is diagnostic.

---

## Mode: diagnose

### Step 1: Ask, don't assume
- Order ID / Stripe session ID / payment intent ID?
- Customer email?
- What did customer see? What does Stripe Dashboard show?
- What does the order status show in Supabase?
- Timestamp of the charge? (cross-reference Stripe events dashboard)

### Step 2: Simple checks
- Stripe Dashboard: was the webhook delivery attempted? Did it succeed? What was the response status?
- Supabase: does `webhook_idempotency` have a row for this Stripe event_id?
- `orders` row status?
- `webhook_events` row for the Stripe event?

### Step 3: Match against incidents
See `references/incidents.md`. Categories:
- **Duplicate charge** → idempotency not working; check webhook_idempotency for same event_id with different responses
- **Missing order after payment** → webhook received but saga failed; check saga_executions
- **Refund not reflected** → known gap, charge.refunded not handled; manual update required
- **Signature verification errors (401 in Stripe Dashboard)** → wrong webhook secret, or body parsing issue
- **"Event type not handled" in webhook logs** → Stripe sending events we don't consume; usually safe to ignore, verify it's not a money-moving event

### Step 4: 3-file rule
If no incident match: read at most 3 files based on the symptom location. Stop, report to user.

### Step 5: Two-strike rule
Second fix must differ from first. Stop after second failure, report.

### Step 6: Stay in scope
Payment bug → payment code. Avoid refactoring tickets, VIP, or auth during the same pass — delegate to the sibling skill named in the symptom-to-skill table above.

---

## Mode: scale-check

Before a flash sale or large event. Webhook volume scales with purchases × Stripe retries.

### 1. Webhook handler timing
- Stripe expects 2xx within 5s, else retries.
- Current webhook does: idempotency check + signature verify + DB writes + email enqueue + response.
- Average handler latency: measure from logs. If >3s, flag for optimization.
- Slow handler at scale = Stripe retry storm = duplicate processing stress on idempotency.

### 2. Idempotency table size
- Query #7: count rows in `webhook_idempotency` within last 7 days (TTL).
- If millions of rows → index lookup gets slow. Consider pg index on `(idempotency_key, webhook_type)`.

### 3. Stripe rate limits
- Stripe API: 100 read + 100 write req/sec per account. Webhook processing doesn't typically hit this, but `verify-revenue` cron might (fetches all PaymentIntents).

### 4. Saga throughput
- Every order goes through saga. Under flash-sale load, saga_executions table grows fast.
- Ensure compensations execute in <5s. Check query #6 for stuck sagas.

### 5. Payment Intent confirmation race
- VIP flow: client calls `confirm-vip-payment` after Stripe confirms PI. If client disconnects mid-flow, webhook should eventually handle `payment_intent.succeeded`.
- Verify the webhook handler idempotently handles VIP confirmation even if the client RPC already ran.

### 6. Refund burst (event cancellation)
- `cancel-event-with-refunds/` iterates through orders, issues Stripe refunds serially.
- For a 1000-ticket event → 1000 Stripe API calls. Verify it handles rate limits + partial failures.

### Output

```
## Payment Scale Readiness — Event: [name], Expected: [X tickets] flash window [Y min]

### Webhook latency p95: [Xms]
### Idempotency table health: [row count, TTL compliance]
### Saga throughput capacity: [current executions/min vs projected]
### Payment Intent confirmation idempotency: [VERIFIED / NOT VERIFIED]
### Refund batch capacity: [can cancel N tickets in M minutes]

### Verdict: [READY / NOT READY — must-fix list]
```

No fixes in scale-check mode.

---

## Critical Flows & Downstream Consumers

### FLOW A: Successful GA checkout webhook
1. Stripe POSTs `checkout.session.completed` to webhook URL
2. Webhook: verify signature → idempotency check → process
3. Atomic: create tickets, set order `paid`, sign QR tokens, increment `tickets_sold`
4. Enqueue `ga_ticket` email in `email_queue`
5. Return 200 to Stripe
6. Email worker picks up row, sends via Resend
7. Real-time subscription fires → Owner Dashboard revenue counter updates
8. Marketing site sold-out badge updates (if last ticket)

**Breakpoints to check if something fails:**
| Step | Symptom | Check |
|---|---|---|
| 2 | "401 signature invalid" in Stripe | STRIPE_WEBHOOK_SECRET mismatch |
| 2 | Idempotency cache stale | webhook_idempotency table for event_id |
| 3 | Order paid but no tickets | saga_executions; escalate to maguey-bulletproof-tickets |
| 4 | No email row | stripe-webhook error logs, email_queue insert path |
| 6 | Email row stuck in pending | maguey-bulletproof-email |
| 7 | Dashboard doesn't update | realtime publication; escalate to maguey-bulletproof-sync |

### FLOW B: VIP payment
1. Client calls `create-vip-payment-intent` (Edge Function): creates PI, seeds metadata `type=vip_table`, reservation linked
2. Stripe Elements confirms PI on client
3. Client calls `confirm-vip-payment` (Edge Function): updates reservation to `confirmed`, marks table `is_available=false`
4. In parallel, Stripe webhook fires `payment_intent.succeeded` → webhook handler (line ~1179) idempotently marks reservation (if not already) + generates guest passes + sends VIP email

**Breakpoints:**
- Client confirm fails but webhook succeeds → reservation still gets confirmed via webhook (resilience)
- Webhook fails but client confirm succeeds → reservation is confirmed but passes/email may be missing
- Both fail → rollback_vip_checkout should clean up

### FLOW C: Event cancellation
1. Owner clicks "Cancel event" in dashboard
2. `cancel-event-with-refunds` Edge Function enumerates paid orders
3. For each: Stripe refund → update orders.status='refunded' → update tickets.status='refunded' → enqueue refund email
4. Event marked `cancellation_status='cancelled'`

**Note:** this flow DOES handle refunds (explicit API-driven). The GAP is only for ad-hoc refunds issued from the Stripe Dashboard.

---

## HARD RULES

- **NEVER write to prod DB.** Read-only via `mcp__supabase__execute_sql`.
- **NEVER modify the webhook handler without explicit user approval.** It's 1,650 lines of production-critical code. Fixes must be scoped to a single event handler, tested against signed test events.
- **NEVER bypass signature verification.** Not "for testing", not "temporarily". If signatures fail, fix the secret.
- **NEVER disable idempotency.** Retries will double-charge / double-email.
- **ALWAYS test webhook changes against Stripe CLI** (`stripe listen --forward-to ...`) before deploying.
- **Branch workflow:** fix/... or feature/... branches. No direct-to-main for webhook changes.
- **User reports override queries.** Customer says "I was charged twice" → check Stripe Dashboard first, then our DB.

---

## When Firecrawl Is Useful

Useful:
- Stripe changelog: did they deprecate a webhook event?
- Supabase release notes: did RPC behavior change?
- Stripe idempotency best practices (confirm our pattern matches latest guidance)

Not useful:
- "How do other nightclubs handle refunds?" (different schema, different trust model)
- Generic Stripe tutorials (we have a custom implementation with VIP dual-path)

---

## What to Return

- **audit** → report with pass/fail + known-gap call-outs
- **diagnose** → single-file fix + repro case, OR "here's what I know, need direction"
- **scale-check** → ready/not-ready + must-fix list

Never silently retry. Never read more than 3 files without user direction.

---

## Reference Files

Load these as needed — progressive disclosure keeps the SKILL.md lean.

- **`references/invariants.md`** — Canonical contract for the payment layer. Schema reality check at the top; signature, idempotency, handler, atomicity, rate-limit, logging, rollback, secrets invariants below. Load when auditing code-level contracts or adjudicating a disputed finding.
- **`references/audit-queries.sql`** — SELECT-only read-path queries numbered 1–13. Load before running audit mode data checks. Every query has a schema note clarifying which columns are real.
- **`references/incidents.md`** — Known-incident fix patterns including the full schema-correct `charge.refunded` handler, duplicate-processing debug path, signature 401 causes, order-stuck-pending triage, partial-refund cancellation. Load when symptom matches an entry.
- **`references/disputes.md`** — `charge.dispute.created` full pattern: event list, handler skeleton, status model, cross-skill dependencies. Load whenever disputes, chargebacks, or `charge.dispute.*` events are in scope.
- **`references/preflight-checks.md`** — Full protocol for the 6 preflight checks summarized in the SKILL.md preflight. Load when a preflight check fails or needs a deeper verification path.

## Changelog

- **2026-04-21** — charge.refunded handler drafted on `fix/charge-refunded-handler`. Skill expanded with preflight-checks.md, disputes.md, and invariants 9–11 (per-handler try/catch, outbound idempotency, consumer-status consistency). Stale `payment_failures`/`payments` table references removed from SKILL.md body.
