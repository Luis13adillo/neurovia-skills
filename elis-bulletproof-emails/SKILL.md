---
name: elis-bulletproof-emails
description: Audit, diagnose, or scale-check the Eli's Dulce Tradicion email delivery system (Supabase Edge Functions for transactional email via Resend — send-order-confirmation, send-ready-notification, send-status-update, send-cancelled-notification, send-failed-payment-notification, send-order-issue-notification, send-daily-report, send-contact-notification; shared emailTemplates.ts helpers; RESEND_API_KEY / FROM_EMAIL / FROM_NAME / OWNER_EMAIL env vars; bilingual English/Spanish template rendering based on order.customer_language; XSS escaping for untrusted fields; cron-driven daily report). Complement to elis-bulletproof-payments (the webhook that should trigger order-confirmation) and elis-bulletproof-orders (the data source). Use when customers report they never got a confirmation email, bilingual rendering breaks, HTML templates render raw, templates leak unescaped content, daily report doesn't arrive, or emails duplicate. Read-only SQL via mcp__supabase__execute_sql (project rnszrscxwkdwvvlsihqc). Never writes to production DB. Never modifies Edge Function code without explicit user approval.
---

# Eli's Bulletproof Emails

Email is the customer's receipt, status feed, and confirmation of commitment. When an email doesn't arrive, the customer thinks the order didn't happen. That triggers the phone call and the refund request. A critical CLAUDE.md-flagged gap: "Order confirmation email never sent" — this skill exists to pinpoint why and prevent recurrence.

This skill covers:

**Edge Functions** (all under `supabase/functions/`)
- `send-order-confirmation/index.ts` (~12KB) — post-payment receipt
- `send-ready-notification/index.ts` (~9.4KB) — "your cake is ready"
- `send-status-update/index.ts` (~10KB) — generic status transitions
- `send-cancelled-notification/index.ts` — order cancelled + refund info
- `send-failed-payment-notification/index.ts` (~6.2KB) — payment failed alert
- `send-order-issue-notification/index.ts` (~9.9KB) — issue report
- `send-daily-report/index.ts` (~14KB) — cron-driven summary to owner
- `send-contact-notification/index.ts` (~7.5KB) — contact form → owner inbox
- `_shared/emailTemplates.ts` (~7.2KB) — HTML + text generation, escape helpers

**Env vars (Supabase Edge Function secrets):**
- `RESEND_API_KEY` — Resend API
- `FROM_EMAIL` (default `orders@elisbakery.com`)
- `FROM_NAME` (default `Eli's Bakery`)
- `OWNER_EMAIL` — daily report + contact form recipient
- `FRONTEND_URL` — links back to `/order-tracking`

**Scheduling:**
- `send-daily-report` → cron from migration `20240205_cron_schedule_reports.sql`
- `scheduled-order-transitions` is not an email function but shares infrastructure

**Not covered here:**
- SMS (project is email-only at this writing — no Twilio)
- The webhook that *should* invoke `send-order-confirmation` → `elis-bulletproof-payments`
- Customer language detection / selection → `elis-bulletproof-orders`

---

## Schema Reality Check

There is NO `email_queue` or `email_delivery_log` table in this project (unlike the Maguey setup). Email sending is **synchronous inside the Edge Function**, with no persisted record of attempts. This means:
- No retry on Resend transient failure.
- No audit trail: "did Eli ever receive the daily report?" cannot be answered from the DB.
- No bounce handling.

Flag this in every audit — it is a structural gap, not a bug, and it scales poorly.

Confirm:
```sql
SELECT table_name FROM information_schema.tables
WHERE table_schema='public' AND table_name ILIKE '%email%';
```

---

## Mandatory Preflight

1. `/Users/luismiguel/Desktop/elis-dulce-tradicion/CLAUDE.md` — Known Issues: "Order confirmation email never sent".
2. Supabase project `rnszrscxwkdwvvlsihqc`. Edge Function secrets: confirm via Supabase Dashboard → Functions → Secrets.
3. State: "Preflight complete. Running [mode]."

---

## Choose a Mode

- **audit** — monthly + after any email-template edit + before any holiday promotion
- **diagnose** — customer said they never got email X OR the daily report stopped coming
- **scale-check** — anticipated >20 orders/day window or a blast-style announcement

---

## Mode: audit

### Code-level invariants

1. **Every email function verifies `RESEND_API_KEY` before sending.**
   - Grep: `grep -rn "RESEND_API_KEY\|Deno.env.get" supabase/functions/send-*/index.ts`
   - If missing, the function throws a cryptic error. At minimum: check key, return 500 with a clear message.

2. **Order confirmation is triggered from the stripe-webhook.**
   - This is the CLAUDE.md gap. `stripe-webhook/index.ts` should, on `payment_intent.succeeded`, call `supabase.functions.invoke('send-order-confirmation', { body: { order_id }})` OR enqueue somehow.
   - Grep: `grep -n "send-order-confirmation\|send_order_confirmation\|invoke" supabase/functions/stripe-webhook/index.ts`
   - If there's no invocation, that's the gap.

3. **Every function passes through HTML escaping for untrusted fields.**
   - `_shared/emailTemplates.ts` should export an `escape()` helper.
   - Untrusted: `customer_name`, `custom_message`, `delivery_address`, `flavor`, anything free-text.
   - Grep: `grep -rn "escape\|escapeHtml\|\.replace(/</" supabase/functions/_shared/emailTemplates.ts supabase/functions/send-*/index.ts`
   - **Known limitation:** inline CSS is typically NOT escaped in HTML emails. That's fine for trusted style strings but a hole if any user input flows into style attributes. Verify no `style="${...}"` interpolation with user data.

4. **Bilingual branch respects `order.customer_language`.**
   - Every customer-facing function reads `customer_language` (en / es) and branches template.
   - Default when null: English (or whatever the project decided — document it).
   - Grep: `grep -rn "customer_language" supabase/functions/send-*/index.ts`

5. **No duplicate sends per order per event type.**
   - Without an `email_delivery_log` table, dedupe is by-convention. At minimum, the function should be idempotent: if called twice for the same `(order_id, event_type)`, it should send twice (the invocation path is what must be deduped).
   - Flag: recommend adding an `email_sends` tracking table — but do not implement without approval.

6. **Daily report cron is active and pointed at send-daily-report.**
   - Migration `20240205_cron_schedule_reports.sql` sets up pg_cron.
   - Query:
     ```sql
     SELECT jobid, schedule, command, active FROM cron.job;
     ```
   - If `active=false` or no row, the owner is not getting daily reports.

7. **FROM_EMAIL domain is SPF/DKIM-authenticated in Resend.**
   - `elisbakery.com` must have Resend's DNS records published. Otherwise deliverability drops.
   - Verify via Resend Dashboard → Domains → elisbakery.com → Verified.
   - Not a code check but fails silently in production.

8. **Owner email is only sent to the owner.**
   - `send-daily-report` and `send-contact-notification` and `send-order-issue-notification` should send to `OWNER_EMAIL` env var, not hardcoded.
   - Grep: `grep -n "to:\|OWNER_EMAIL\|owner@elisbakery" supabase/functions/send-*/index.ts`

9. **Links in emails use `FRONTEND_URL` env var.**
   - `/order-tracking?orderNumber=X` links must use the prod URL in prod, preview URL in preview.
   - Grep: `grep -n "FRONTEND_URL\|elisbakery.com/order-tracking" supabase/functions/`

10. **Error swallowing is visible.**
    - An email function that throws should return a non-200 status, not silently `return new Response('ok')`.
    - Grep: `grep -n "catch\|try\|return new Response" supabase/functions/send-*/index.ts`

11. **Resend bounce webhooks are NOT handled.**
    - Known gap: no `resend-webhook` Edge Function in this project. Bounces are invisible.
    - Flag as structural gap, not bug.

### Data-level + operational checks

```sql
-- E1. Cron job status (daily report)
SELECT jobid, schedule, command, active FROM cron.job
WHERE command ILIKE '%send-daily-report%' OR command ILIKE '%daily_report%';

-- E2. Orders in last 7d where we would have wanted to send confirmation
SELECT COUNT(*) AS paid_orders_7d
FROM orders
WHERE payment_status = 'paid' AND created_at > now() - interval '7 days';
-- Compare to Resend dashboard delivery count.

-- E3. Orders with status=ready where we would have wanted send-ready-notification
SELECT id, order_number, customer_email, status, updated_at
FROM orders
WHERE status = 'ready' AND updated_at > now() - interval '7 days';

-- E4. Orders with payment_status=failed — did customer get a failure email?
SELECT id, order_number, customer_email, payment_status, updated_at
FROM orders
WHERE payment_status = 'failed' AND updated_at > now() - interval '30 days';

-- E5. Contact submissions in last 7d — did the owner get each?
SELECT id, name, email, created_at, status
FROM contact_submissions
WHERE created_at > now() - interval '7 days'
ORDER BY created_at DESC;
```

**Resend Dashboard cross-check:**
- Log into Resend → Logs
- Filter by date range (last 7 days)
- Compare count to E2. If our DB says 30 paid orders and Resend says 5 delivered, we have a gap.
- Check "bounced" and "complained" columns. Any non-zero bounce is a customer data quality problem (typo email).

### Audit output template

```
## Emails Audit — [YYYY-MM-DD]

### Code-level
- [PASS/FAIL] Every function verifies RESEND_API_KEY
- [PASS/FAIL — KNOWN GAP from CLAUDE.md] stripe-webhook invokes send-order-confirmation
- [PASS/FAIL] HTML escaping in shared templates
- [PASS/FAIL] Bilingual branch on customer_language
- [NOTE] No email_delivery_log / dedupe table (structural gap)
- [PASS/FAIL] Daily report cron active
- [PASS/FAIL] FROM_EMAIL domain DKIM/SPF verified in Resend
- [PASS/FAIL] Owner-recipient functions use OWNER_EMAIL env
- [PASS/FAIL] Links use FRONTEND_URL
- [PASS/FAIL] Errors surface as non-200
- [NOTE] No Resend bounce webhook

### Data-level (last 7d)
- E1 daily report cron: active / inactive
- E2 paid orders count: X (compare to Resend delivered)
- E3 ready-status count: X
- E4 failed payments: X
- E5 contact submissions: X

### Resend dashboard reconciliation
- Delivered (7d): ___
- Bounced: ___
- Delta vs our DB expectations: ___

### Structural gaps (flag every audit)
- No email_delivery_log for audit trail
- No Resend bounce webhook
- Stripe → send-order-confirmation invocation path (KNOWN CLAUDE.md gap)
```

---

## Mode: diagnose

### Step 1 — Ask
- Which email type is missing? (confirmation / ready / status / cancelled / etc.)
- Customer email / order_number.
- Did any email arrive, or zero?
- When was the last time this email type *did* work?

### Step 2 — Resend dashboard first
Before any code grep: open Resend → Logs. Filter by `to:` email address. If there's no row at all for that address + date, the function never fired (or never reached Resend). If there's a row with status `bounced` or `complained`, the function fired but the mailbox rejected.

### Step 3 — Symptom matrix

| Symptom | Likely cause | Check |
|---|---|---|
| "Customer never got confirmation" | stripe-webhook → send-order-confirmation invocation broken (CLAUDE.md gap) | Invariant #2 |
| "Got confirmation twice" | Stripe webhook retried, function not idempotent | Webhook event.id dedup in `elis-bulletproof-payments`; invariant #5 |
| "Email came in the wrong language" | customer_language null or mis-detected | Invariant #4; check Order.tsx / i18n language selection |
| "HTML is raw code in email" | Template returned text/plain but browser treats as HTML, OR `dangerouslyRender` not set | Inspect function's `Content-Type` header when invoking Resend |
| "Customer name shows `<script>alert(1)</script>`" | Escape helper missing | Invariant #3 — P0 |
| "Daily report stopped" | Cron job inactive OR send-daily-report deployment failed | Invariant #6; `supabase functions logs send-daily-report` |
| "Owner got another owner's address" | OWNER_EMAIL env var misconfigured OR hardcoded wrong | Invariant #8 |
| "Email link goes to localhost" | FRONTEND_URL env var wrong in prod | Invariant #9 |

### Step 4 — Check Edge Function logs
```bash
supabase functions logs send-order-confirmation --project-ref rnszrscxwkdwvvlsihqc
```

### Step 5 — Report + recommend
Root cause, proposed patch, and: "Before shipping, I need to send one real test email to yourself in dev."

---

## Mode: scale-check

Before a blast or a high-volume window:

1. **Resend rate limits.** Free plan: 100 emails/day. Paid plan: scales. Confirm which plan is active. A Mother's Day promotion blasting to 500 contacts on a free plan = silent drops.
2. **SPF/DKIM propagation.** If domain was recently added, DNS can take 24-48h. Check verification status in Resend.
3. **Template size.** Large HTML templates with inline base64 images can exceed Resend's 40MB limit — but well under for text emails. Confirm no reference_image_url embedded as base64; pass as external URL instead.
4. **Edge Function cold-start.** First email after idle is slow. Under sudden burst (20 orders in 1 min), some cold-starts may exceed 10s timeout. Edge Functions auto-warm; bursts should recover.
5. **Unsubscribe compliance.** Transactional emails don't strictly need unsubscribe, but marketing (AnnouncementManager?) does. If marketing emails get added without List-Unsubscribe headers → spam folder and potential CAN-SPAM issue.
6. **Bilingual subject lines.** Subject line is often the plaintext fallback. Verify subject is translated along with body.

### Output
```
## Emails Scale Readiness — Window: [dates], Expected volume: [N/day]

- Resend plan + daily limit: [plan] / [limit]
- Domain verified (SPF + DKIM): Y/N
- RESEND_API_KEY set in prod functions: Y/N
- FROM_EMAIL matches verified domain: Y/N
- Bilingual subject lines verified: Y/N
- Test email sent to self in last 24h: Y/N

Verdict: [READY / NOT READY — blocker list]
```

---

## Critical Flow: order confirmation email

**Intended:**
1. Customer pays → `stripe-webhook` receives `payment_intent.succeeded`
2. Webhook updates `orders.payment_status='paid'`
3. Webhook calls `supabase.functions.invoke('send-order-confirmation', { body: { order_id }})`
4. `send-order-confirmation` reads order row, picks template language, renders HTML + text, calls Resend API
5. Customer gets email within ~30s

**Observed (CLAUDE.md gap):**
- Step 3 may not be happening. Email function exists but is never invoked. The customer is charged but never receives the receipt.

---

## HARD RULES

- **NEVER hardcode an email address** in a send function. Use `OWNER_EMAIL`, `FROM_EMAIL` env vars.
- **NEVER skip escape() on customer-entered fields.** Customer names can contain HTML.
- **NEVER test by blasting real customers.** Use your own email address for dev testing.
- **NEVER add a marketing email without an unsubscribe mechanism.**
- **NEVER silently swallow** a Resend error — log it, return a non-200.
- **NEVER write to production DB** from this skill.
- **Scope:** if a fix crosses into webhook invocation, hand off to `elis-bulletproof-payments`. If it crosses into template content UX, note it and stop.
