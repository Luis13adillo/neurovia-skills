# Communications Scale Anti-Patterns

Report-only.

---

## 1. SMS volume vs. Twilio capacity

```sql
SELECT DATE_TRUNC('day', created_at) AS day, COUNT(*) AS total
FROM sms_logs
WHERE created_at > now() - interval '30 days'
GROUP BY day
ORDER BY day DESC;
```

Twilio long-codes = ~1 msg/sec per number. At ~100 bookings/day with reminders + feedback + winback, you're at ~300-500 msgs/day. Safe for a long-code. At 10x: consider a Twilio short-code or A2P 10DLC.

---

## 2. Opt-out rate vs regulatory thresholds

```sql
WITH stats AS (
  SELECT
    (SELECT COUNT(*) FROM sms_opt_outs WHERE created_at > now() - interval '30 days') AS opt_outs_30d,
    (SELECT COUNT(DISTINCT recipient_phone) FROM sms_logs WHERE created_at > now() - interval '30 days' AND status IN ('sent','delivered')) AS unique_recipients_30d
)
SELECT opt_outs_30d, unique_recipients_30d,
       ROUND(100.0 * opt_outs_30d / NULLIF(unique_recipients_30d, 0), 2) AS opt_out_pct
FROM stats;
```

FCC / Twilio guideline: keep opt-out rate < 2%. Above 5% triggers carrier filtering (messages get blocked).

---

## 3. Location-specific Twilio numbers

Current: single `TWILIO_PHONE_NUMBER` serves all locations. Customers see the same number regardless of where they booked.

At 4-5 locations with distinct brand voices: consider one number per location. Schema change:
- Add `locations.twilio_from_number` column.
- Sender resolves from `booking.location.twilio_from_number`.

Flag as future consideration; don't implement.

---

## 4. Template volume at scale

```sql
SELECT category, COUNT(*) AS template_count, COUNT(*) FILTER (WHERE is_active) AS active
FROM sms_templates
GROUP BY category;
```

If many categories with few actives → template sprawl. Consolidate.

---

## 5. Cron job parallelism

Current crons run serially on Vercel:
- `/api/bookings/reminders` — every 15 min
- `/api/cron/feedback` — every 30 min
- `/api/cron/service-reminder` — every 5 min
- `/api/cron/winback` — daily 10am
- `/api/cron/academy-reminders` — daily 9am
- `/api/cron/grace-period-notifications` — daily 9am

At 10x volume, the feedback cron (30 min window, processing N completed services) may exceed Vercel's function timeout (10s Hobby, 60s Pro). Flag for batch/worker split if timeouts start appearing.

---

## 6. sms_logs volume

```sql
SELECT COUNT(*) AS total_logs, MIN(created_at) AS oldest, MAX(created_at) AS newest
FROM sms_logs;
```

At ~500 msgs/day × 365 = ~180k rows/year. Query performance OK. At 10x, consider partitioning or archival policy.

---

## 7. Webhook endpoint rate limiting

`/api/webhooks/twilio/inbound` and `/status` are public endpoints. Even with signature verification, they should rate-limit to prevent DoS:
- Verify a rate limit exists (`src/lib/rate-limit/`).
- Signature rejection doesn't cost CPU — verify early.

---

## 8. Antigravity workflow coverage

Adding new automations:
- Should route through Antigravity (per MEMORY.md policy).
- Any new inline automation code is a migration regression.

```bash
grep -rn "createWorkflow\|antigravity" src/
```

If matches exist in code (beyond webhook receivers), investigate.

---

## 9. Email vs SMS parity

- Email templates live in `src/lib/email/`.
- SMS templates live in `src/lib/twilio/` + `sms_templates` table.
- Dual-channel comms (e.g., booking confirmation SMS + email) should reference the same source data.

Flag if duplicate content is maintained separately in code — single source better.

---

## Output verdict template

```
## Communications Scale Readiness

### Ready
- [green items]

### Must fix / decide before scaling
1. [item + reason]

### Recommended
- [items — A2P 10DLC registration, per-location numbers, Antigravity consolidation]

### Verdict
[READY / BLOCKED BY N ITEMS]
```
