---
name: maguey-bulletproof-email
description: Audit, diagnose, or scale-check the Maguey Nightclub email delivery system (email_queue table, process-email-queue Edge Function cron worker, Resend API integration, resend-webhook bounce/delivery tracking, email_delivery_status audit log, QR codes embedded as base64 data URLs in HTML, event reminders, ticket transfers, refund notifications). Use when customers don't receive confirmation emails, QR codes don't render in their inbox, bounces aren't handled, emails duplicate, or before sending a blast for a large event. Read-only SQL via mcp__supabase__execute_sql only. Never writes to production DB — delivery failures look like revenue losses.
---

# Maguey Bulletproof Email

Email is Maguey's primary delivery channel for tickets. No email = no QR code = customer shows up without proof of purchase. The email system is queue-based (reliable) + Resend-backed (deliverable) + tracked (auditable), but has moving parts that can silently break.

This skill covers:
- `maguey-pass-lounge/supabase/functions/process-email-queue/index.ts` (worker, runs every minute via pg_cron)
- `maguey-pass-lounge/supabase/functions/resend-webhook/index.ts` (Resend delivery events)
- `maguey-pass-lounge/supabase/functions/send-event-reminders/index.ts` (reminder cron)
- `maguey-gate-scanner/supabase/functions/send-email/` + `send-event-announcement/` + `newsletter-*/`
- `maguey-pass-lounge/src/lib/email-template.ts` (HTML templates)
- `maguey-pass-lounge/src/lib/vip-table-email-template.ts` (VIP template)
- Tables: `email_queue`, `email_delivery_status`, `event_reminder_log`, `alert_digest`, `newsletter_subscribers`
- RPCs: `enqueue_email`, `claim_pending_emails`, `mark_email_sent`, `mark_email_failed`, `record_email_delivery_event`

**Email types (CHECK-constrained — verified 2026-04-21):**
- `ga_ticket`, `vip_confirmation`, `ticket_transfer_received`, `ticket_transfer_sent`, `event_reminder_24h`, `event_reminder_2h`
- Adding a new type = migration to expand the CHECK constraint.

**Status enum (CHECK-constrained — verified 2026-04-21):**
- `pending`, `processing`, `sent`, `delivered`, `failed`
- NO `bounced` or `complained` as status values in the live DB. Bounce/complaint deltas are recorded in `email_delivery_status` and may flip `email_queue.status` to `failed`, not to a distinct `bounced` status.

**Not covered here:**
- Stripe webhook triggers email enqueue → `maguey-bulletproof-payments`
- QR token signing (inside RPC before email send) → `maguey-bulletproof-tickets`

---

## Schema Reality Check (verified 2026-04-21 against live DB)

**`email_queue` real columns:** `id, email_type, recipient_email, subject, html_body, related_id, resend_email_id, status, attempt_count, max_attempts, next_retry_at, last_error, error_context (jsonb), created_at, updated_at`.

- **There is NO `sent_at` column.** Use `updated_at` as the "sent at" proxy (worker updates it on each state transition, including pending→sent).
- **CHECK constraints confirmed**: email_type enum (6 values listed above) + status enum (5 values listed above). Adding types or statuses requires migration.

**`email_delivery_status` real columns:** `id, resend_email_id, event_type, event_data (jsonb), created_at`.

- **There is NO `email_queue_id` FK.** Join to `email_queue` via `resend_email_id` text match. Every older query with `JOIN ON eds.email_queue_id = eq.id` is wrong.
- `event_type` holds Resend webhook event names: `sent`, `delivered`, `bounced`, `complained`, `opened`, `clicked`, etc.

**`event_reminder_log` real columns:** `id, ticket_id, event_id, reminder_type, sent_at, status`. Has a `sent_at` column here (unlike `email_queue`). The UNIQUE constraint that makes reminders idempotent is `(ticket_id, reminder_type)`.

**`newsletter_subscribers`:** `id, email, subscribed_at, is_active, source`. No `unsubscribed_at` — flip `is_active = false` to unsubscribe.

**RPCs that exist (verified):**
- `enqueue_email`, `claim_pending_emails`, `mark_email_sent`, `mark_email_failed`, `record_email_delivery_event` — all present.

**Tables that do NOT exist** (referenced by older drafts): `alert_digest`. Remove any audit queries against it.

---

## Mandatory Preflight

1. `/Users/luismiguel/Desktop/Maguey-Nightclub-Live/CLAUDE.md` — "Email" under What Works section.
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-Maguey-Nightclub-Live/memory/MEMORY.md` — Feb 2026 fix (removed VITE_EMAIL_API_KEY from client).
3. This skill's `references/audit-queries.sql`, `references/invariants.md`, `references/incidents.md`.

**Re-verify schema before diagnosing:**
```sql
SELECT column_name FROM information_schema.columns
WHERE table_schema='public' AND table_name='email_queue' ORDER BY ordinal_position;
-- Expected: id, email_type, recipient_email, subject, html_body, related_id,
--           resend_email_id, status, attempt_count, max_attempts, next_retry_at,
--           last_error, error_context, created_at, updated_at.
-- If a `sent_at` column appears, update this skill — migration added it.
```

Confirm "Preflight complete. Running [mode]." Supabase: `mcp__supabase__execute_sql` project `djbzjasdrwvbsoifxqzd`.

---

## Choose a Mode

- **audit** → weekly + after DNS/SPF/DKIM changes or Resend dashboard edits
- **diagnose** → email-not-received report
- **scale-check** → before a flash sale (>500 emails in <1 hour)

---

## Mode: audit

### Code-level invariants

1. **Resend secrets server-only**
   - `RESEND_API_KEY` in Supabase Edge Function secrets
   - `RESEND_WEBHOOK_SECRET` (Svix signature) for resend-webhook
   - `EMAIL_FROM_ADDRESS` env var (defaults to `tickets@magueynightclub.com`)
   - Grep: `grep -rn "VITE_EMAIL\|VITE_RESEND\|RESEND_API_KEY" --include="*.ts" --include="*.tsx" maguey-pass-lounge/src maguey-gate-scanner/src maguey-nights/src`
   - Must return 0 matches. (Feb 2026 lockdown.)

2. **Worker uses optimistic locking**
   - `process-email-queue/index.ts` — SELECT pending emails, UPDATE status='processing' atomically (only if still 'pending').
   - Prevents two concurrent workers from sending same email twice.
   - Grep: `grep -n "pending.*processing\|optimistic\|FOR UPDATE" process-email-queue/index.ts`

3. **Retry with exponential backoff**
   - Retry schedule: 1min → 2min → 4min → 8min → 16min (cap 30min) + 10% jitter
   - Max attempts: 5
   - Grep: `grep -n "next_retry_at\|attempt_count\|backoff" process-email-queue/index.ts`

4. **Bounce webhook verifies signature**
   - `resend-webhook/index.ts` — verify Svix signature with `RESEND_WEBHOOK_SECRET`
   - Reject if invalid (401)

5. **Delivery events logged to email_delivery_status**
   - Every Resend event (sent, delivered, bounced, complained) captured for audit trail
   - Grep: `grep -n "email_delivery_status\|record_email_delivery_event" resend-webhook/index.ts`

6. **Email type CHECK constraint active**
   - Migration `20260331000003_expand_email_queue_types.sql` — CHECK on `email_type` enum
   - No free-form email_type values allowed

7. **QR codes are base64 inline (no external links)**
   - `email-template.ts` + `vip-table-email-template.ts` — QR rendered as `<img src="data:image/png;base64,...">`
   - Advantages: works offline once email loaded, no broken external links
   - Trade-off: large email size (~50KB per QR). Verify no email exceeds Resend's size limits (10MB per message)

8. **Idempotent event reminders**
   - `event_reminder_log` table: UNIQUE(ticket_id, reminder_type)
   - `send-event-reminders` inserts here before enqueuing email → second call same day is rejected at DB level

9. **Cron schedule configured**
   - `process-email-queue` should be scheduled every 1 minute via pg_cron
   - Query: `SELECT * FROM cron.job WHERE jobname ILIKE '%email%';`
   - Must see a job pointing to the email queue worker

10. **Email from domain verified in Resend**
    - `EMAIL_FROM_ADDRESS` (e.g. `tickets@magueynightclub.com`) must be from a domain with SPF/DKIM/DMARC configured in Resend.
    - Verify at Resend Dashboard → Domains.

### Data-level invariants

Run `references/audit-queries.sql`.

### Audit output template

```
## Email Audit Report — [YYYY-MM-DD]

### Code-level
- [PASS/FAIL] Resend secrets server-only (no VITE_)
- [PASS/FAIL] Optimistic locking in worker
- [PASS/FAIL] Exponential backoff retry
- [PASS/FAIL] Webhook signature verification
- [PASS/FAIL] Delivery events logged
- [PASS/FAIL] email_type CHECK constraint
- [PASS/FAIL] QR codes base64 inline
- [PASS/FAIL] Idempotent reminders via event_reminder_log
- [PASS/FAIL] pg_cron schedule active
- [PASS/FAIL/EXTERNAL] Resend domain verified

### Data-level
- [PASS/FAIL] No emails stuck in 'pending' >10 min (query #1)
- [PASS/FAIL] No emails stuck in 'processing' >5 min (query #2)
- [PASS/FAIL] Bounce rate <5% (query #3)
- [PASS/FAIL] No email_queue entries without delivery events after 'sent' (query #4)
- [PASS/FAIL] No duplicate emails to same recipient for same related_id (query #5)
- [PASS/FAIL] Orphan email_delivery_status without email_queue parent (query #6)
- [PASS/FAIL] Reminder log shows no duplicate enqueues (query #7)
- [PASS/FAIL] Newsletter subscribers not receiving ticket emails (query #8)

### Failures
[List]
```

---

## Mode: diagnose

### Step 1: Ask
- Customer email?
- What email were they expecting (ticket confirmation, VIP, reminder)?
- When did they purchase/event?
- Did they check spam folder?

### Step 2: Simple checks
```sql
-- Find the email row:
SELECT id, email_type, recipient_email, subject, status, attempt_count,
       last_error, resend_email_id, next_retry_at, created_at, sent_at
FROM email_queue
WHERE recipient_email = '<email>'
  AND created_at > now() - interval '7 days'
ORDER BY created_at DESC;

-- Find delivery events:
SELECT * FROM email_delivery_status
WHERE email_queue_id IN (SELECT id FROM email_queue WHERE recipient_email = '<email>' ORDER BY created_at DESC LIMIT 5)
ORDER BY created_at DESC;
```

### Step 3: Match against incidents (see `references/incidents.md`)
- Row status='pending' but old → worker not running or stuck
- Row status='failed' → read `last_error`
- Row status='sent' + no delivery_status → Resend webhook not firing
- Row status='delivered' → email was sent; customer's spam filter is the issue
- No row at all → nothing enqueued; check trigger (Stripe webhook? reminder cron? transfer flow?)

### Step 4-6: 3-file rule, Two-strike, stay in scope.

---

## Mode: scale-check

Before a flash sale / big event where email volume will spike:

### 1. Worker throughput
- `process-email-queue` runs every 1 min, max 10 emails per run = **600/hour** theoretical.
- For 1000 tickets sold in 2 hours: 500 confirmation emails/hr = within capacity.
- For 5000 tickets sold in 1 hour: 5000 emails/hr = **BOTTLENECK**. Worker needs boost:
  - Increase batch size (change `claim_pending_emails` LIMIT)
  - Reduce cron interval (every 30s instead of 60s)
  - Run multiple workers in parallel (requires lock hygiene audit)

### 2. Resend rate limits
- Resend free tier: 100 emails/day. Pro tier: 50,000/month (~1666/day avg, burstable).
- If Maguey on free: **BLOCKER**. Must upgrade before scale event.

### 3. Queue depth alarm
- Set up a cron that alerts if `email_queue WHERE status='pending'` count > 50 for more than 5 min.
- Early warning for worker issues.

### 4. Bounce monitoring
- If bounce rate climbs >5%, Resend may throttle sending reputation.
- Newsletter quality matters — clean list before large blast.

### 5. Template rendering cost
- VIP emails with multiple guest passes: each base64 QR ~30-50KB. 8-guest VIP = ~400KB email body.
- Large emails are slower to send + risk spam filter flagging.

### Output

```
## Email Scale Readiness — Event: [name], Expected recipients: [X] in [Y window]

### Worker capacity: [X emails/hr achievable vs Y needed]
### Resend tier: [free/pro/enterprise] — [enough headroom?]
### Queue depth alarm: [configured? YES/NO]
### Current bounce rate: [X%]
### Large VIP email risk: [any scheduled?]

### Verdict: [READY / NOT READY]
```

---

## Critical Flow: Ticket purchase email

1. Stripe webhook receives `checkout.session.completed`
2. Webhook inserts rows: `orders`, `tickets` (with signed QR tokens), `email_queue` (type=`ga_ticket`, related_id=order_id)
3. Webhook returns 200 to Stripe
4. pg_cron fires `process-email-queue` (every 1 min)
5. Worker: `claim_pending_emails(limit := 10)` — atomically grabs up to 10 pending, sets status='processing'
6. For each: render template with QR codes (base64), POST to Resend API
7. On Resend success: `mark_email_sent(id, resend_email_id)` — status='sent', stores Resend ID for webhook correlation
8. On failure: `mark_email_failed(id, error_message)` — increments attempt_count, sets next_retry_at with backoff
9. Resend delivers to customer's inbox
10. Resend fires webhook events: `email.sent` → `email.delivered` (or `email.bounced`/`email.complained`)
11. `resend-webhook` verifies signature, looks up by `resend_email_id`, updates status, logs to `email_delivery_status`

### Typical latency: 60-120 seconds from purchase to customer inbox.

**Breakpoints:**
| Step | Failure | Symptom |
|---|---|---|
| 2 | Webhook didn't enqueue | No email_queue row for order |
| 4 | pg_cron not running | Emails pile up in 'pending' |
| 6 | Resend API error | Email row goes to 'failed' with error |
| 10 | Customer's ISP marks spam | email_delivery_status shows 'bounced' or no follow-up events |
| 11 | Webhook not received | Status stuck at 'sent' without 'delivered' confirmation |

---

## HARD RULES

- **NEVER write to prod DB** except through approved RPCs.
- **NEVER send email from client code.** All sends go through `email_queue` + worker.
- **NEVER put RESEND_API_KEY in VITE_ env vars.** It's server-only.
- **NEVER disable the email_type CHECK constraint** — free-form types lead to silent template mismatches.
- **NEVER test with real customer emails** without explicit user approval. Use `testcustomer@maguey.com` for testing.
- **Branch workflow:** fix/... or feature/... branches.
- **User reports override queries.** "I never got my ticket" → check spam first, then your DB.
