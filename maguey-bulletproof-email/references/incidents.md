# Email — Known Incidents & Fix Patterns

---

## Incident: Customer paid but no email arrived
**Symptom:** Order is `paid`, tickets exist, no email in inbox (customer also checked spam).
**Root cause chain:**
1. `email_queue` row never inserted → Stripe webhook failed to enqueue. Check webhook logs.
2. Row inserted but status='failed' → read `last_error`. Common: Resend API auth error, wrong FROM address, malformed HTML.
3. Row status='sent' but no delivery follow-up → Resend webhook isn't reaching us (endpoint URL stale after deploy).
4. Row status='delivered' → it arrived. Customer must check spam, promotions tab, filters.
5. Recipient's email provider blocks us → reputation issue; check Resend dashboard for bounce/complaint trends.

**Debug:**
```sql
SELECT id, email_type, status, attempt_count, last_error, resend_email_id, sent_at, created_at
FROM email_queue
WHERE recipient_email = '<email>'
  AND created_at > now() - interval '7 days'
ORDER BY created_at DESC;

SELECT * FROM email_delivery_status WHERE email_queue_id = '<id>' ORDER BY created_at;
```

---

## Incident: Entire queue backed up (thousands pending)
**Symptom:** Nobody is getting emails. `email_queue WHERE status='pending'` count is huge and growing.
**Root cause options:**
1. pg_cron stopped (Supabase incident, plan downgrade, manual disable)
2. Worker throws immediately (recent deploy broke it)
3. Resend API outage

**Debug:**
```sql
-- Is the job scheduled?
SELECT * FROM cron.job WHERE command ILIKE '%email%';
-- Last run time?
SELECT jobid, job_pid, database, username, command, status, start_time, end_time
FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE command ILIKE '%email%')
ORDER BY start_time DESC LIMIT 5;
```
**Fix:** re-enable cron if disabled, redeploy Edge Function if broken, wait for Resend recovery.

---

## Incident: Same customer received 3 copies of confirmation email
**Symptom:** Customer complains about duplicate emails. All identical.
**Root cause options:**
1. Multiple `email_queue` rows for same related_id (Stripe webhook fired multiple times before idempotency caught it — rare)
2. Worker double-claimed a row (optimistic lock broken)
3. Resend retried our API call on a timeout, both delivered

**Debug:** audit query #5 surfaces duplicates.
**Fix:** if duplicate email_queue rows: check webhook idempotency (escalate to `maguey-bulletproof-payments`). If single row sent multiple times: review worker `claim_pending_emails` for lock semantics.

---

## Incident: Bounce rate climbing; emails going to spam
**Symptom:** Many customers report tickets in spam. Bounce rate above 5%.
**Root cause options:**
1. SPF, DKIM, DMARC not fully configured on `magueynightclub.com` in Resend Dashboard
2. Sending from a new IP without warm-up (Resend handles this, but verify)
3. Email body contains spam triggers (all caps, too many links, "free", "click here")
4. Newsletter list has stale addresses → high bounces hurt transactional reputation

**Fix:**
- Resend Dashboard → Domains → verify all DNS records green
- Review email templates for spam words
- Clean newsletter list (remove addresses bounced 3+ times)
- Warm up separate domain for newsletters if volume is high (e.g. `news.magueynightclub.com`)

---

## Incident: VIP email body exceeds 10MB
**Symptom:** VIP confirmation with 10 guests fails to send. Error: "Email size exceeds limit."
**Root cause:** 10 guests × ~50KB QR each = ~500KB + HTML overhead. If table has bottles + special requests with large text, body can balloon.
**Fix options:**
1. Smaller QR images (lower resolution) — trade-off: harder to scan
2. Host QR images on Supabase Storage, reference by URL instead of base64 — trade-off: if URL breaks, QR breaks
3. Split: purchaser email + individual guest emails via invite_code flow (already supported)

---

## Incident: Ticket transfer emails not firing
**Symptom:** Ticket transferred in UI, sender sees success, but neither party gets email.
**Root cause options:**
1. Transfer flow doesn't call `enqueue_email` for both sides
2. email_type 'ticket_transfer_received'/'ticket_transfer_sent' not in CHECK constraint
3. Template function missing for these types

**Debug:**
```sql
SELECT * FROM email_queue WHERE email_type LIKE 'ticket_transfer%'
  AND related_id = '<transfer_id>' ORDER BY created_at DESC;
```
If no rows: transfer code path not enqueuing. Check `20260331000002_add_ticket_transfer.sql` + related API.

---

## Incident: Event reminder fires twice
**Symptom:** Customer reports getting 24h reminder email twice.
**Root cause:** `event_reminder_log` UNIQUE(ticket_id, reminder_type) constraint missing or was dropped.
**Debug:**
```sql
SELECT * FROM information_schema.table_constraints
WHERE table_name = 'event_reminder_log' AND constraint_type = 'UNIQUE';
```
**Fix (requires migration):** add back the UNIQUE constraint.

---

## Incident: Newsletter subscribers getting ticket emails
**Symptom:** Someone who unsubscribed from newsletter still gets "your ticket" email. They complain.
**Not a bug** — transactional emails (ticket confirmations) are legally required per CAN-SPAM even to unsubscribers.
**UX improvement:** include one-liner in ticket email: "You're receiving this because you purchased a ticket. This is not a marketing email."
**Do not** skip sending transactional based on newsletter unsubscribe status — customer won't receive proof of purchase.

---

## Incident: Resend webhook signature verification failing
**Symptom:** `resend-webhook` returns 401 for all incoming events.
**Root cause options:**
1. `RESEND_WEBHOOK_SECRET` env var stale after Resend rotated their signing secret
2. Svix library version mismatch with signature format
3. Request body parsing corrupted signature (must use raw body)

**Fix:**
1. Resend Dashboard → Webhooks → [endpoint] → signing secret → copy → update Supabase Edge Function secret → redeploy
2. Verify Svix library version in `package.json`
3. Ensure `await req.text()` is used (not `req.json()`) before signature verify

---

## Pattern: Email debugging tips
- Test customer: `testcustomer@maguey.com` / `MagueyNighclub123`. Use for test flows; don't spam real accounts.
- Resend Dashboard → Emails → search by recipient or message ID for granular delivery trace.
- Resend gives extensive logs: opened, clicked, bounced with reason. Use these before assuming "email lost."
- For local dev: Resend has a test mode. Set `RESEND_API_KEY=re_test_*` in local `.env` to avoid real sends.
