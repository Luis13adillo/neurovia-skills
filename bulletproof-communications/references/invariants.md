# Communications Invariants

All SQL is SELECT-only. **ALWAYS verify schema first** (see preflight in SKILL.md) before trusting column names.

---

## Data-level

### 1. Opt-out is recorded when STOP is received [CRITICAL]
No direct SQL check — code-level. But verify data shape:
```sql
SELECT phone, keyword, direction, created_at
FROM sms_opt_outs
ORDER BY created_at DESC
LIMIT 20;
-- Expected: direction='in' for recent customer-initiated opt-outs
```

### 2. No send to opted-out phones [CRITICAL]
```sql
SELECT sl.id, sl.recipient_phone, sl.created_at, sl.trigger_type
FROM sms_logs sl
JOIN sms_opt_outs so ON so.phone = sl.recipient_phone
WHERE sl.status IN ('queued', 'sent', 'delivered')
  AND sl.created_at > so.created_at;
-- Expected: 0 rows (no sends after the customer opted out)
```

### 3. Reminder flags set after successful send [HIGH]
Bookings with `reminder_sent = true` should have a matching `sms_logs` entry.
```sql
SELECT b.id AS booking_id, b.client_phone, b.reminder_sent,
       COUNT(sl.id) AS matching_sms_logs
FROM bookings b
LEFT JOIN sms_logs sl
       ON sl.recipient_phone = b.client_phone
      AND sl.trigger_type ILIKE '%reminder_24%'
      AND sl.created_at > b.created_at
      AND sl.status IN ('sent', 'delivered')
WHERE b.reminder_sent = true
  AND b.deleted_at IS NULL
GROUP BY b.id, b.client_phone, b.reminder_sent
HAVING COUNT(sl.id) = 0
LIMIT 50;
-- Expected: 0 rows (every flag=true should have evidence of send)
```

### 4. No duplicate reminder SMS per booking [HIGH]
```sql
SELECT sl.recipient_phone, b.id AS booking_id, COUNT(sl.id) AS n
FROM sms_logs sl
JOIN bookings b ON b.client_phone = sl.recipient_phone
WHERE sl.trigger_type ILIKE '%reminder_24%'
  AND sl.created_at > b.created_at
  AND sl.created_at < (b.scheduled_date + b.scheduled_time + interval '1 hour')
  AND sl.status IN ('sent', 'delivered')
GROUP BY sl.recipient_phone, b.id
HAVING COUNT(sl.id) > 1
LIMIT 50;
-- Expected: 0 rows
```

### 5. Template keys are unique [HIGH]
```sql
SELECT key, COUNT(*) AS n
FROM sms_templates
GROUP BY key
HAVING COUNT(*) > 1;
-- Expected: 0 rows
```

### 6. Active templates have non-empty body [HIGH]
```sql
SELECT id, key, name, body
FROM sms_templates
WHERE is_active = true
  AND (body IS NULL OR body = '' OR length(body) < 5);
-- Expected: 0 rows
```

### 7. SMS log status values valid [HIGH]
```sql
SELECT status, COUNT(*) AS n
FROM sms_logs
WHERE status IS NOT NULL
  AND status NOT IN ('queued', 'sent', 'delivered', 'failed', 'undelivered',
                     'skipped_opt_out', 'skipped_invalid')
GROUP BY status;
-- Expected: 0 rows
```

### 8. Blast status flow valid [HIGH]
```sql
SELECT status, COUNT(*) AS n
FROM sms_blasts
WHERE status NOT IN ('draft', 'scheduled', 'sending', 'completed', 'cancelled')
GROUP BY status;
-- Expected: 0 rows
```

### 9. Blast counts consistent [MEDIUM]
```sql
SELECT id, name, recipient_count, sent_count, delivered_count, failed_count, status
FROM sms_blasts
WHERE status = 'completed'
  AND (sent_count + failed_count) != recipient_count;
-- Expected: 0 rows (every recipient is either sent or failed)
```

### 10. winback_sent uniqueness per (client, interval) [MEDIUM]
```sql
SELECT client_id, interval_weeks, COUNT(*) AS n
FROM winback_sent
GROUP BY client_id, interval_weeks
HAVING COUNT(*) > 1;
-- Expected: 0 rows
```

### 11. owner_alerts unread count is sane [LOW]
```sql
SELECT type, COUNT(*) AS unread
FROM owner_alerts
WHERE is_read = false
GROUP BY type
ORDER BY unread DESC;
-- Expected: low counts; high counts indicate owner isn't reading alerts (not a bug per se)
```

### 12. Recent opt-outs not re-messaged [CRITICAL]
```sql
-- Spot-check: show any phone that opted out in last 7 days and received a message after
SELECT sl.recipient_phone, so.created_at AS opted_out_at,
       sl.created_at AS message_sent_at, sl.status, sl.trigger_type
FROM sms_opt_outs so
JOIN sms_logs sl
     ON sl.recipient_phone = so.phone
    AND sl.created_at > so.created_at
    AND sl.status IN ('queued', 'sent', 'delivered')
WHERE so.created_at > now() - interval '7 days'
ORDER BY sl.created_at DESC
LIMIT 20;
-- Expected: 0 rows
```

---

## Code-level

### C1. Twilio webhook signature verification [CRITICAL]
- `src/app/api/webhooks/twilio/inbound/route.ts`
- `src/app/api/webhooks/twilio/status/route.ts`
- Must use `TWILIO_AUTH_TOKEN` to verify `X-Twilio-Signature` header before processing.

### C2. Opt-out check before every send [CRITICAL]
- Every sender function (BookingSMS, QueueSMS, FeedbackSMS, WinbackSMS, etc.) must query `sms_opt_outs` before dispatching.
- Grep: `grep -rn "twilio.messages.create\|sendSms" src/lib/twilio/ src/app/api/` — every result must also show opt-out check upstream.

### C3. Cron `CRON_SECRET` auth [HIGH]
- `src/app/api/cron/*/route.ts` + `src/app/api/bookings/reminders/route.ts`
- Must verify `Authorization: Bearer ${CRON_SECRET}` header.

### C4. Status precedence for webhook updates [HIGH]
- `src/app/api/webhooks/twilio/status/route.ts`
- Must not unconditionally overwrite status; check precedence (queued < sent < delivered / failed).

### C5. Reminder flag update after send success [HIGH]
- Each reminder cron must: send → check success → UPDATE flag. Never UPDATE-then-send.

### C6. No hardcoded phone numbers in templates [HIGH]
```bash
grep -rEn "\(?302\)?[- ]?[0-9]{3}[- ][0-9]{4}" src/lib/twilio/
```
Safe: references to the canonical Wilmington / Newark / New Castle numbers in historical data. Unsafe: banned numbers (see bulletproof-locations).

### C7. No n8n references (Antigravity migration) [MEDIUM]
```bash
grep -rn "n8n\|N8N_WEBHOOK" src/
```
Matches are historical. Flag but do not remove without approval.
