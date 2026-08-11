# Communications Incident Registry

---

## Automation Platform Change — n8n → Antigravity

**Status:** Ongoing. Per MEMORY.md: all automations moved from n8n to `antigravity.google`. n8n is no longer in use but env vars (`N8N_WEBHOOK_URL`, `N8N_WEBHOOK_SECRET`) may remain in `.env.local.example` for historical reference.

**Implication for this skill:**
- Any new SMS automation should be built in Antigravity, not inline code.
- When diagnosing "SMS didn't fire," check Antigravity workflow execution before suspecting code.
- Do NOT reference n8n in conversations with the user — they explicitly stated this.

**Files that may still reference n8n (grep):**
```bash
grep -rn "n8n\|N8N_WEBHOOK" src/ .env.local.example
```
Matches are historical, not live. Flag if found but don't remove without approval.

---

## TCPA Opt-Out Compliance

**Symptom:**
- Customer replies STOP but still receives a booking reminder the next day
- Legal letter mentions "unsolicited SMS"

**Root cause:**
- `src/app/api/webhooks/twilio/inbound/route.ts` recognized the STOP but failed to INSERT into `sms_opt_outs`
- OR: opt-out inserted correctly but sender code didn't check `sms_opt_outs` before sending

**Correct flow:**
1. Twilio receives STOP from customer, POSTs to `/api/webhooks/twilio/inbound`.
2. Signature verified (`X-Twilio-Signature` with `TWILIO_AUTH_TOKEN`).
3. Body parsed for opt-out keywords: STOP, STOPALL, UNSUBSCRIBE, CANCEL, END, QUIT (case-insensitive).
4. INSERT into `sms_opt_outs` with `phone`, `keyword`, `direction='in'`.
5. Every subsequent send function calls `isOptedOut(phone)` before sending:
   - `SELECT 1 FROM sms_opt_outs WHERE phone = $1 LIMIT 1;`
   - If found, skip the send. Log to `sms_logs` with status='skipped_opt_out'.

**Diagnose checklist:**
1. Query: `SELECT * FROM sms_opt_outs WHERE phone = '+1...'`. Is the opt-out recorded?
2. If yes, grep the sender code for opt-out check. Must be present in every send path.
3. If no, the inbound webhook didn't process — check webhook signature, check Twilio console for delivery.

---

## Duplicate Reminder SMS

**Symptom:**
- Customer gets 2 or 3 of the same 24h booking reminder
- Sent from the same phone number, same content

**Root causes (three possibilities):**
1. `bookings.reminder_sent` flag updated BEFORE the SMS actually sent — race condition
2. `bookings.reminder_sent` updated AFTER SMS send, but the next cron cycle fired before the UPDATE committed
3. SMS send failed silently (e.g., Twilio timeout), code retried without flag check

**Correct pattern:**
```typescript
// 1. Query bookings with reminder_sent = false, scheduled_date in 24h window
// 2. For each booking:
//    a. Send SMS via Twilio
//    b. If response is success: UPDATE bookings SET reminder_sent = true WHERE id = ...
//    c. If response is error: log but do NOT update flag
// 3. Next cron cycle won't re-send because the flag is set
```

**The subtle failure mode:** if two cron runs overlap (Vercel may spin up a second run before the first completes), both may see `reminder_sent = false` and both send. Mitigation: SELECT FOR UPDATE with row locking, or a distributed lock.

**Diagnose:**
1. Query `sms_logs WHERE recipient_phone = '+1...' AND trigger_type = 'reminder_24h' AND created_at BETWEEN ...`. How many sent?
2. Check `bookings.reminder_sent` for the booking — is it true now?
3. Cross-reference timestamps. Were they sent seconds apart (concurrent crons) or hours apart (flag update failure)?

---

## Twilio Webhook Signature Failure

**Symptom:**
- Inbound SMS doesn't register opt-outs
- Status webhooks don't update `sms_logs.status`
- Twilio dashboard shows webhook calls succeeding (200 OK) but app doesn't react

**Root cause:**
Signature verification is returning true incorrectly (accepting all requests without checking), OR the webhook is returning 200 before parsing.

**Correct pattern:**
1. Read `X-Twilio-Signature` header.
2. Construct the expected signature from `TWILIO_AUTH_TOKEN` + full URL + form-encoded body.
3. Compare with timing-safe equality.
4. If mismatch → 403. Otherwise proceed.

**Diagnose:**
1. Read `src/app/api/webhooks/twilio/inbound/route.ts` and `status/route.ts`.
2. Verify the signature check function is called AND its result gates the rest of the handler.
3. If signature passes but processing fails, the bug is downstream — check parsing + DB inserts.

---

## Status Webhook Out-of-Order Updates

**Symptom:**
- `sms_logs.status` shows 'sent' even though Twilio says it was 'delivered'
- A later 'failed' status overwrote an earlier 'delivered'

**Root cause:**
Status updates arrive out-of-order (queued → sent → delivered is the typical chain, but Twilio retries can reorder). Without ordering logic, a stale status can overwrite a fresh one.

**Correct pattern:**
- Define status precedence: `queued < sent < delivered` and `queued < sent < failed < undelivered`.
- Only update `sms_logs.status` if the new status is a forward transition.
- Alternatively: track all status changes in a history table and expose the latest in a view.

**Diagnose:**
1. Query `sms_logs WHERE twilio_sid = 'SM...'`. Current status?
2. If current is 'sent' but you expected 'delivered', check Twilio console for the message's actual final status.
3. Read `src/app/api/webhooks/twilio/status/route.ts` — does it unconditionally UPDATE, or does it check precedence?

---

## Owner Alert Duplicates

**Symptom:**
- Owner receives the same "Low rating alert" multiple times for one feedback submission
- Owner dashboard shows 3 copies of the alert

**Root cause:**
Trigger fires on every UPDATE of the source row, not just the initial rating submission.

**Correct pattern:**
- `owner_alerts` unique constraint on `(type, related_id)` prevents dupes.
- OR: the trigger logic should only fire when `rating < threshold AND previous rating was NULL`.

**Diagnose:**
1. Query `owner_alerts WHERE related_id = '...'`. How many rows?
2. Check `owner_alerts` table constraints.
3. Read the trigger definition if one exists.

---

## Cron Not Running (Vercel)

**Symptom:**
- Reminders stop firing suddenly
- Logs show last execution was days ago

**Root causes:**
1. `vercel.json` cron entry removed or typo'd
2. `CRON_SECRET` changed in Vercel env but old code still checks old value
3. Cron route returning 500 silently, Vercel marked it as failing
4. Vercel Hobby plan: only 2 daily crons free — check tier

**Diagnose:**
1. Read `vercel.json` — is the cron entry present with correct path?
2. Check Vercel dashboard → Cron tab for recent invocations.
3. Read the cron route — does it return 200 on a no-op path? (so Vercel doesn't mark as failing).

---

## Antigravity Automation Not Firing

**Symptom:**
- New booking completes, Antigravity automation (e.g., CRM sync) doesn't run
- Expected SMS/email never arrives

**Root cause (likely):**
- Antigravity workflow paused, mis-triggered, or not subscribed to the event.
- This is NOT a code issue in most cases — investigate in Antigravity console.

**Diagnose:**
1. Confirm the booking event fired in-app (DB row exists, expected status).
2. Check Antigravity console for the workflow's recent execution history.
3. If no execution, the trigger subscription is broken in Antigravity (external to this codebase).

**This skill can't fix Antigravity workflows** — just identify whether the problem is upstream (app) or downstream (Antigravity).

---

## Quick Match Table

| Symptom | Likely incident | First file to read |
|---|---|---|
| STOP reply ignored | inbound webhook signature or insert failed | `src/app/api/webhooks/twilio/inbound/route.ts` |
| Duplicate reminder SMS | flag update race condition | `src/app/api/bookings/reminders/route.ts` |
| Status webhook not reflecting | signature failure or out-of-order | `src/app/api/webhooks/twilio/status/route.ts` |
| Owner alert duplicates | missing unique constraint / trigger logic | `owner_alerts` + trigger defs |
| Cron stopped running | Vercel config or secret mismatch | `vercel.json` + cron route |
| Automation didn't fire | Antigravity workflow issue | Antigravity console (external) |
