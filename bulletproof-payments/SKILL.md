---
name: bulletproof-payments
description: Audit, diagnose, or scale-check the MT Barbershop payment collection system (PaymentCollectionModal, Stripe checkout, payment links, tips, Stripe webhooks, refunds, webhook idempotency). Complement to bulletproof-commission — this skill covers the PAYMENT UX and webhook processing; commission covers the fee ledger. Use when payments fail, tips don't record, Stripe webhooks misfire, or refund flow breaks. Read-only SQL via mcp__supabase-mt__execute_sql only. Never writes to production DB — payment data is revenue-critical.
---

# Bulletproof Payments

Payment collection is where money and trust meet. A failed webhook = unrecorded revenue. A duplicate charge = a refund request and a bad review. A missed tip = a disgruntled barber.

This skill covers:
- `PaymentCollectionModal` and its payment flow (Cash / Card / Send Link)
- `/api/payments/**` (checkout session creation, payment link generation)
- `/api/webhooks/stripe/**` (webhook processing + idempotency)
- Refund handling and reversal flows
- Tip entry (digital + cash)

**Not covered here (but tightly related):**
- Commission / fee calculation → `bulletproof-commission`
- Barber payouts → `bulletproof-commission`
- Cash fee ledger → `bulletproof-commission`

This skill does NOT replace `CLAUDE.md`, `MEMORY.md`, or the `.claude/rules/*.md` files. It READS them, then runs a structured protocol.

---

## Mandatory Preflight — BEFORE any action

1. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/CLAUDE.md` — "System G: Payment & Tip Flow" section.
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-MT-Barbershop-Systems/memory/MEMORY.md` — Zero Production Data Contamination rule (applies here as strongly as for commission).
3. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.claude/rules/debugging-protocol.md` — Sections 7, 8, **9 (Zero Production Data Contamination)**.

**ALWAYS verify schema first:**

```sql
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('stripe_webhook_events', 'service_transactions',
                     'queue_entries', 'bookings')
  AND column_name ILIKE '%stripe%' OR column_name ILIKE '%payment%' OR column_name ILIKE '%tip%'
ORDER BY table_name, ordinal_position;
```

---

## Choose a Mode

- **audit**, **diagnose**, **scale-check**, or **fix**. `audit`, `diagnose`, and `scale-check` are READ-ONLY. `fix` is the only mode that edits code, and only under the explicit gate described in its section.

---

## AUDIT RIGOR — read before starting audit mode

This skill enforces the universal Audit Rigor Standard at `~/.claude/skills/_shared/audit-rigor.md` and the domain Surface Inventory at `references/SURFACE_INVENTORY.md`. Read both before you do anything.

**Five Pillars (all mandatory):** codebase, database, queries, RLS, integrations. Missing any pillar = failed audit.

**Proof-of-Read:** every file claimed PASS in the Coverage Report MUST cite a `file.ts:LINE` from that file. No line = NOT-RUN, not PASS. This is enforced by the universal standard.

**Forcing language — copy this into your mental model:**

> Do NOT stop on first pass. You MUST work through EVERY file in SURFACE_INVENTORY.md (60+ surfaces), EVERY query in audit-queries.sql, EVERY RLS policy, EVERY trigger, and EVERY integration (Stripe, Stripe Connect, Twilio, Resend, plus all 12 webhook event branches). Stopping after one finding is a half-audit and is explicitly forbidden.
>
> Silence ≠ Pass. Self-declaration ≠ Proof. Every PASS needs a file:line citation.
>
> Obey the Cross-Surface Coupling Rules below. Skipping a coupled surface while passing its partner = coupling violation.
>
> The Coverage Report + Gap Self-Report are MANDATORY. A report missing either is rejected. If NOT-RUN > 0, the header must say "PARTIAL AUDIT".

**Payments skill is TIGHTLY coupled to commission.** Refund flow, completion handlers, and `service_transactions` writes appear in both inventories. When auditing a refund or completion incident, run BOTH skills' audits — a partial audit of only payments will miss the fee-ledger side.

---

## Cross-Surface Coupling Rules — MUST be followed

When you audit a surface on the left, you MUST also audit all surfaces on the right in the same session. These rules catch the systemic gaps where one file's behavior depends on another that looks unrelated.

| If you audit... | You MUST also audit... | Why |
|---|---|---|
| `webhooks/stripe/route.ts` `charge.refunded` branch | `queue_entries.payment_status` flip + `bookings.payment_status` flip + `service_transactions.payment_status` sync + commission-side `cash_fee_ledger.status=waived` reversal | Refund is the most error-prone event. Partial reversal = stale revenue on reports, ghost commissions, or double-pay. A refund that flips only one of these tables drifts revenue forever. |
| `webhooks/stripe/route.ts` `checkout.session.completed` (walk_in branch) | `queue_entries` payment field writes + `service_transactions` sync + stripe_payment_id persistence + tip_amount from `session.metadata` | If metadata tip_amount isn't read, tip_amount=0 in DB even though customer paid one. Exact defect observed 0/249 txns 2026-04-20. |
| `webhooks/stripe/route.ts` `checkout.session.completed` (booking branch) | `bookings` payment field writes + `service_transactions` sync + stripe_payment_id + tip_amount metadata | Same as walk-in branch but via bookings. Breaks independently. |
| `webhooks/stripe/route.ts` `checkout.session.expired` | `payment_status='paid'` guard present (`.neq('payment_status','paid')`) on all three branches | Without the guard, a late `expired` event after a successful completion flips a paid row back to failed — money lost from reports. |
| `webhooks/stripe/route.ts` idempotency (atomic INSERT on `stripe_webhook_events`) | `createAdminClient()` used (service_role) + `event.id` stored BEFORE processing + failure path marks `status='failed'` not left `processing` | Retried webhooks without dedup = double writes. Stuck `processing` rows block re-delivery. |
| `webhooks/stripe/route.ts` `account.updated` | `barbers.stripe_charges_enabled` write + downstream: `determinePaymentRouting()` reads this exact column | If the field isn't updated, Connect barbers never auto-split. |
| `payments/checkout/route.ts` | `determinePaymentRouting()` call site + `session.metadata` carries `queue_entry_id`/`booking_id` + `barber_id` + `location_id` + `tip_amount` + Stripe key mode matches env | If metadata omits any key, the webhook can't match the DB row and the completion silently drops. |
| `payments/send-link/route.ts` | Same as checkout PLUS `sendPaymentLinkSms()` (Twilio) + `sendPaymentLinkEmail()` (Resend) delivery paths | If the Twilio or Resend send throws, the link creation still succeeds — customer gets no link. |
| `PaymentCollectionModal.tsx` tip entry | PATCH body for `/api/queue/entry/[id]` + `/api/bookings/[id]` carries `tip_amount` + Zod schemas accept it + Stripe checkout metadata propagation | The UI captures the tip, but the four completion routes + both Stripe creation routes must all accept it. Any one broken = silent tip=0 as of 2026-04-20. |
| Any of the 4 completion handlers (queue/entry/[id], queue/complete, bookings/[id], bookings/quick-complete) | `payment_method` enum restricted to cash/card/link + `service_amount >= 0` + `tip_amount >= 0` + `total_amount = service + tip` + `stripe_payment_id` only when method=card/link | Completion writes payment AND fee columns. A loose validation = garbage downstream. Note: fee side is audited in commission skill — must still confirm fields exist here. |
| `barber/stripe/connect/route.ts` OAuth init | `barber/stripe/callback/route.ts` + `barbers.stripe_account_id` + `stripe_charges_enabled` writes + Connect account link expiry | Half a Connect setup = account_id without charges_enabled; barber looks "enrolled" but can't receive money. |
| `barber/stripe/callback/route.ts` | `account.updated` webhook handler (verified alive) | Callback stamps charges_enabled on first link but ongoing updates come via webhook. Both surfaces required. |
| `academy/checkout/route.ts` | webhook `checkout.session.completed` (academy branch) + `customer.subscription.created` + `invoice.payment_succeeded` + `invoice.payment_failed` + `customer.subscription.deleted` | Academy is a full subscription pipeline. Skipping any one event branch = stuck enrollment or missed charge. |
| `stripe/server.ts` `getStripeKeyMode()` | `NODE_ENV` check + Stripe key in env + any place that calls `getStripe()` | Live key in dev or test key in prod = catastrophic. This helper must be referenced everywhere Stripe fires. |
| Any write to `stripe_webhook_events` | RLS "Service role only" still present + no anon/authenticated/public policies | Exposing this table = customers can see (or worse, poison) the idempotency ledger. |

**A PASS on the left side without evidence of auditing the right side = COUPLING VIOLATION.** Report it in the Gap Self-Report.

---

## Cron Surface Must Be Enumerated

Any payments audit MUST run `ls src/app/api/cron/` and `cat vercel.json` and report:
- Any cron route that calls Stripe, references `stripe_webhook_events`, or touches `payment_status` on `queue_entries`/`bookings`/`service_transactions`
- Each cron's schedule and last-run evidence (check `owner_alerts` for failures)
- If payments expects NO cron jobs (current expected state), the report must explicitly state "no payment-specific crons found in vercel.json"

This catches systemic gaps where a hidden cron flips payment state silently.

---

## Mode: audit

### Step 0 — Universal Audit Preamble (MANDATORY — run first, always)

Run the 5 discovery queries from `~/.claude/skills/_shared/audit-rigor.md` section "Universal Audit Preamble", filled in with the payments domain values:

```sql
-- 1. Enumerate payments domain tables
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN (
    'stripe_webhook_events','queue_entries','bookings','service_transactions'
  )
ORDER BY table_name;
-- Expected: 4 rows. Missing = inventory drift; STOP and ask user.

-- 2. RLS policies on payments-owned and touched tables
SELECT tablename, policyname, cmd, roles
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN (
    'stripe_webhook_events','queue_entries','bookings','service_transactions'
  )
ORDER BY tablename, policyname;
-- Expected: stripe_webhook_events has EXACTLY "Service role only" (ALL). No anon/authenticated/public policies.
-- Parent tables (queue_entries/bookings/service_transactions) have their own patterns — audit in their respective skills.

-- 3. Triggers on payment-relevant tables (we share these with commission skill — must still verify they exist)
SELECT event_object_table, trigger_name, action_timing, event_manipulation
FROM information_schema.triggers
WHERE event_object_schema = 'public'
  AND event_object_table IN ('queue_entries','bookings','service_transactions')
ORDER BY event_object_table, trigger_name;
-- Expected: create_service_transaction_from_queue, create_service_transaction_from_booking.
-- service_transactions triggers (tr_referral_conversion, tr_update_daily_summary_from_txn) appear too — these are OK, owned by other skills.

-- 4. RPC functions (payments skill has none of its own — verify commission ones still present since we depend on them)
SELECT routine_name, routine_definition IS NOT NULL AS has_body
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name IN (
    'create_service_transaction_from_queue',
    'create_service_transaction_from_booking'
  );
-- Expected: 2 rows, has_body=true.

-- 5. Migration history
SELECT name, executed_at FROM supabase_migrations.schema_migrations
WHERE name ILIKE '%stripe%' OR name ILIKE '%webhook%' OR name ILIKE '%payment%'
   OR name ILIKE '%024%' OR name ILIKE '%036%' OR name ILIKE '%connect%'
ORDER BY executed_at;
-- Expected: at least 3 rows — 008_add_stripe_connect, 024_service_transactions_audit, 036_webhook_idempotency.
```

Attach all 5 result sets to the report under "Universal Preamble". Any drift = stop before domain checks.

### Code-level invariants

1. **Stripe webhook signature verification**
   - File: `src/app/api/webhooks/stripe/route.ts`
   - Must verify `stripe-signature` header using `STRIPE_WEBHOOK_SECRET`. Reject if invalid.
   - Grep: `grep -n "constructEvent\|stripe.webhooks.constructEvent" src/app/api/webhooks/stripe/route.ts`

2. **Webhook idempotency via `stripe_webhook_events` table**
   - Before processing any event, check if `stripe_event_id` already exists.
   - If yes → return 200 (already processed). Else insert and process.
   - Otherwise: retried webhooks double-charge, double-refund, double-insert.

3. **Payment method values restricted**
   - Tables: `queue_entries.payment_method`, `bookings.payment_method`, `service_transactions.payment_method`
   - Valid enum: `cash`, `card`, `link`. Any other value is a regression.

4. **Tip is always non-negative and proportional**
   - Tip > 0 means customer added a tip. Tip > 2× service_amount is likely a data-entry error — flag for manual review.
   - Tip is NEVER auto-deducted from service_amount (the total is service + tip, not service including tip).

5. **Stripe checkout session creation stores context**
   - `src/app/api/payments/checkout/route.ts` — creates Stripe checkout session with metadata.
   - Metadata must include: `queue_entry_id` OR `booking_id`, `barber_id`, `location_id`.
   - When webhook fires for `checkout.session.completed`, this metadata is how we know which DB row to update.

6. **Payment links have expiry**
   - Send-link flow creates Stripe Payment Links or checkout sessions with explicit expiry.
   - Expired links should fail gracefully, not hang the customer.

7. **Refund flow updates source row + service_transactions**
   - Stripe `charge.refunded` webhook → update `queue_entries.payment_status` or `bookings.payment_status` to 'refunded'.
   - Update matching `service_transactions.payment_status` to 'refunded'.
   - Trigger commission reversal (if fees were already settled).

### Data-level invariants

Run `references/audit-queries.sql`.

### Output template — MANDATORY Coverage Report

Every payments audit MUST produce this full block. A report without the Coverage Report section is INCOMPLETE and will be rejected.

```markdown
## Payments Audit Report — [YYYY-MM-DD]

### Universal Preamble
- Tables enumerated: 4/4 PASS | X/4 FAIL (list missing)
- RLS policies found: X (expected: stripe_webhook_events has 1 "Service role only")
- Triggers found: X/2 (create_service_transaction_from_queue + create_service_transaction_from_booking)
- RPCs found: X/2
- Migrations confirmed: X/3

### Stripe config
- Stripe key mode: [live | test | unconfigured] (expected: live in prod)
- STRIPE_WEBHOOK_SECRET: [present | missing]
- Webhook idempotency: [working | broken]

### Findings
[Ranked critical/high/medium/low with file:line anchors and $ at risk]

---

## Coverage Report (MANDATORY)

### Pillar 1 — Codebase (29 files from SURFACE_INVENTORY.md sections 1-7) — PROOF-OF-READ REQUIRED
| # | File | Verdict | Evidence (file:line — what was checked) |
|---|---|---|---|
| 1 | src/app/api/payments/checkout/route.ts | PASS/FAIL/NOT-RUN | e.g. "checkout/route.ts:88 — session.metadata carries queue_entry_id + tip_amount" |
| 2 | src/app/api/payments/send-link/route.ts | | |
| 3 | src/app/api/webhooks/stripe/route.ts | | |
| ... | [all 29] | | |

Files audited with proof-of-read: N / 29 (target: 29/29). Every PASS MUST have a file:line citation. Any PASS without evidence = treated as NOT-RUN.

### Pillar 2 — Database (4 tables from SURFACE_INVENTORY.md section 8)
| Table | Row count | Status dist | NULL violations | Verdict |
|---|---|---|---|---|
| stripe_webhook_events | | status: processed:X processing:X failed:X | | |
| queue_entries (payment cols) | | payment_method dist | | |
| bookings (payment cols) | | payment_method dist | | |
| service_transactions (payment cols) | | payment_method / payment_status dist | | |

Tables audited: N / 4

### Pillar 3 — Queries (all in references/audit-queries.sql)
| # | Query | Verdict | Rows |
|---|---|---|---|
| 1 | [name] | | |
| ... | [all] | | |

Queries run: N / total. Skipped: [empty — or list with reason].

### Pillar 4 — RLS
| Table | Policies found | Expected | Verdict |
|---|---|---|---|
| stripe_webhook_events | | 1 (Service role only) | |

RLS tables audited: 1 / 1 (payment-owned only; parent tables audited in their own skills)

### Pillar 5 — Integrations (SURFACE_INVENTORY.md sections 9, 12, 14)
| Integration | Verdict | Note |
|---|---|---|
| Trigger: create_service_transaction_from_queue | | |
| Trigger: create_service_transaction_from_booking | | |
| Stripe SDK key detection (live/test) | | |
| Stripe webhook signature verification | | |
| Stripe webhook idempotency (atomic insert) | | |
| Stripe Connect OAuth flow | | |
| Stripe Connect account.updated → stripe_charges_enabled | | |
| Twilio payment-link SMS | | |
| Resend payment-link email | | |
| Webhook handler: checkout.session.completed (academy) | | |
| Webhook handler: checkout.session.completed (walk_in_payment / barber_checkout) | | |
| Webhook handler: checkout.session.completed (booking_payment / booking_checkout) | | |
| Webhook handler: checkout.session.expired (all 3 branches) | | |
| Webhook handler: customer.subscription.created | | |
| Webhook handler: invoice.payment_succeeded | | |
| Webhook handler: invoice.payment_failed | | |
| Webhook handler: customer.subscription.deleted | | |
| Webhook handler: charge.refunded (queue + booking) | | |
| Webhook handler: payment_intent.payment_failed | | |
| Webhook handler: payout.paid/failed/updated | | |
| Webhook handler: account.updated | | |

Integrations audited: N / 21

### Coupling Checks (from Cross-Surface Coupling Rules table)
| Coupling | Both sides audited? | Note |
|---|---|---|
| charge.refunded → {queue_entries.payment_status flip, bookings.payment_status flip, service_transactions sync, cash_fee_ledger reversal} | YES/NO | |
| checkout.session.completed (walk_in) → {queue_entries payment fields, service_transactions sync, stripe_payment_id, tip_amount from metadata} | YES/NO | |
| checkout.session.completed (booking) → {bookings payment fields, service_transactions sync, stripe_payment_id, tip_amount from metadata} | YES/NO | |
| checkout.session.expired → {.neq('payment_status','paid') guard on all three branches} | YES/NO | |
| webhook idempotency → {createAdminClient used, event.id stored BEFORE processing, failed path marks status='failed'} | YES/NO | |
| account.updated → {barbers.stripe_charges_enabled write, determinePaymentRouting() reads it} | YES/NO | |
| payments/checkout → {determinePaymentRouting call, session.metadata carries queue/booking id + barber_id + location_id + tip_amount, key mode matches env} | YES/NO | |
| payments/send-link → {same as checkout + Twilio sendPaymentLinkSms + Resend sendPaymentLinkEmail delivery} | YES/NO | |
| PaymentCollectionModal tip entry → {4 completion PATCH bodies + 2 Stripe creation metadata paths all propagate tip_amount} | YES/NO | |
| 4 completion handlers → {payment_method enum cash/card/link, non-negative amounts, total=service+tip, stripe_payment_id only on card/link} | YES/NO | |
| Connect OAuth init → {callback + stripe_account_id + stripe_charges_enabled + link expiry} | YES/NO | |
| Connect callback → {account.updated webhook alive} | YES/NO | |
| academy/checkout → {5 academy webhook branches: session.completed, subscription.created, invoice.payment_succeeded, invoice.payment_failed, subscription.deleted} | YES/NO | |
| getStripeKeyMode → {NODE_ENV check, env key present, callers of getStripe()} | YES/NO | |
| stripe_webhook_events writes → {RLS "Service role only" still present, no anon/authenticated/public policies} | YES/NO | |

Coupling violations: N  **(must be 0 — any NO row is a violation)**

---

## Gap Self-Report (MANDATORY)

| # | Gap | Why it matters | Severity |
|---|---|---|---|
| G1 | [e.g. Did not open src/app/api/academy/verify-payment/route.ts] | Academy post-checkout verification — could miss stuck enrollments | Unknown |

Surfaces in SURFACE_INVENTORY.md NOT audited this run: <comma-separated item numbers>.
Questions requiring external verification (Stripe Dashboard, Twilio console, Resend dashboard): <list>.

If zero gaps: write "No gaps identified. All 60 surfaces audited with proof-of-read + all coupling checks passed."

---

## Totals

- Surfaces audited with proof-of-read: X / 60 (XX%)
- FAILs: N
- NOT-RUNs: N
- Coupling violations: N (must be 0)

**If NOT-RUNs > 0 OR coupling violations > 0, the report header MUST say "PARTIAL PAYMENTS AUDIT — N surfaces unaudited, M coupling violations" instead of "Payments Audit Report".**
```

Stop only after every row above is filled. "Stop on first fail" is NOT the protocol — complete the full coverage sweep, then report.

---

## Mode: diagnose

1. Ask for symptom. Examples:
   - "Customer paid via Stripe, but queue entry still shows pending"
   - "Refund processed in Stripe, commission ledger still shows owed"
   - "Two charges for the same service"
   - "Tip was added but service_transaction shows tip=0"
   - "Send Link SMS says payment link but customer gets 404"
   - "Stripe dashboard shows successful charge but we have no service_transaction row"

2. Match against `references/incidents.md`.

3. **NEVER test a payment "to see if it works."** Use Stripe's test mode in a local dev env. Never run test charges against production Stripe keys.

---

## Mode: scale-check

1. **Webhook processing time**
   - Stripe requires webhook 200 response within ~30s. Long processing = timeouts = retries = duplicates.
   - Audit: Is DB work done inline, or queued?

2. **Stripe rate limits**
   - Stripe API: 100 req/sec steady, 300 burst. Scale: at 10k daily transactions (not current), need async queueing.

3. **Payment method distribution**
```sql
SELECT payment_method, COUNT(*) AS n,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM service_transactions
WHERE service_completed_at > now() - interval '30 days'
GROUP BY payment_method
ORDER BY n DESC;
```
Cash % is relevant for Commission ledger volume. Card % is relevant for Stripe Connect readiness.

4. **Refund rate** (chargeback risk indicator)
```sql
SELECT COUNT(*) AS refunds_30d
FROM service_transactions
WHERE payment_status = 'refunded'
  AND service_completed_at > now() - interval '30 days';
```
>1% refund rate is a signal to investigate service quality or payment UX.

## Mode: fix

The only mode that writes code. Closes the loop between "audit/diagnose found X" and "X is fixed + verified." Does NOT commit, does NOT push, does NOT touch the production DB. See `references/fix-patterns.md` for the canonical patterns.

### Activation is EXPLICIT

Fix mode fires ONLY when the user types one of:
- `apply pattern N` — N is a pattern number from `references/fix-patterns.md`
- `fix <symptom-phrase>` — natural-language form; the skill maps to a pattern and CONFIRMS before doing anything
- `enter fix mode` followed by a scope

Any other phrasing → audit/diagnose instead. An audit finding NEVER auto-triggers a fix.

### Workflow (strict — every step, no shortcuts)

1. **Scope declaration.** Restate in 1–2 sentences which pattern (number + name), which file(s) will change, any mirror-page impact.
2. **Preflight.** Read the target file. Confirm the "before" block from `fix-patterns.md → Pattern N` still matches current code — imports, function signatures, surrounding context, NOT line numbers (which drift). If drift → STOP and report what differs. Do NOT apply a stale pattern.
3. **Scope audit.** Confirm the fix touches ONLY files named in the pattern's Before/After blocks. If a fix would require touching an unrelated system → STOP and ask for approval before expanding.
4. **Diff proposal.** Show the exact `old_string` / `new_string` the skill will pass to `Edit`. Wait for the user to type `yes` / `apply` / `proceed`. No implicit approval.
5. **Apply.** Single `Edit` call. ONE pattern per fix-mode invocation. Never bundled.
6. **Post-fix verification.** `npx tsc --noEmit` passes. Re-run the pattern's post-fix grep and/or SQL check — must pass. For UI patterns, explicitly tell the user "you must test this in the browser before shipping — I can't verify UI."
7. **Mirror check.** If the fix touches any page in the Cross-Dashboard Code Mirroring map (`.claude/rules/context-awareness.md`), invoke the `mirror-check` skill before handoff.
8. **Handoff to `bulletproof-ship`.** Fix mode DOES NOT commit, stage, or push. Propose a branch name (`fix/<domain>-<pattern-slug>`) and a commit message in MT's conventional format, then tell the user to invoke `bulletproof-ship`.

### Integration with other skills

| Skill | Role |
|---|---|
| `bulletproof-ship` | Final step. Commit + push + deploy safety. Mandatory. |
| `mirror-check` | Cross-dashboard enforcement for any dashboard-touching fix. |
| `safe-query` | If a pattern requires DB writes (rare), route through safe-query. |

---

## HARD RULES (stronger than usual because revenue)

- NEVER write to production DB.
- NEVER run test charges against production Stripe keys. Use `sk_test_*` keys in local dev only.
- NEVER trigger a manual refund via this skill. Use the owner dashboard Stripe tools.
- NEVER modify `stripe_webhook_events` (corrupting idempotency causes double-processing).
- NEVER change the webhook signature verification.
- ALWAYS use `mcp__supabase-mt__`.
- Branch workflow. Stay in scope.
