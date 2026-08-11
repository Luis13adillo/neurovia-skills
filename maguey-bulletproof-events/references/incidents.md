# Events — Known Incidents & Fix Patterns

---

## Incident: Event saved but not purchasable
**Symptom:** Event shows on marketing site, but "Buy Tickets" does nothing, or purchase site shows 0 tickets available.
**Root cause options:**
1. `ticket_types` rows not created during save (form submission error silently dropped)
2. `ticket_types.is_active = false` on all rows
3. `events.status = 'draft'` — purchase site filters this out
4. Event date in the past

**Debug:**
```sql
SELECT * FROM ticket_types WHERE event_id = '<id>';
SELECT status, event_date, cancellation_status FROM events WHERE id = '<id>';
```
**Fix:** ensure ticket_types saved during event creation — if missing, add them manually (WRITE, requires approval). Or: flip status to `published`.

---

## Incident: VIP-enabled event has no VIP tables
**Symptom:** Owner set vip_enabled=true, saved event, but VIP floor plan is empty.
**Root cause:** auto-setup logic didn't fire. Possibilities:
1. `vip_table_templates` empty (no default to copy from)
2. Code path skipped if certain fields missing
3. Fresh event created while VIP seed is missing

**Debug:**
```sql
SELECT id, vip_enabled FROM events WHERE id = '<id>';
SELECT * FROM event_vip_tables WHERE event_id = '<id>';
SELECT * FROM vip_table_templates;
```
**Fix:** manually seed tables via admin UI, or insert from template (WRITE, requires approval).

---

## Incident: Event cancellation partial
**Symptom:** Owner clicked "Cancel Event", function timed out, half the customers got refunds.
**Root cause:** `cancel-event-with-refunds` iterates orders serially. Edge Function has a 5-10 second execution limit.
**Recovery:** re-run the function. It uses Stripe idempotency keys so already-refunded orders are skipped.
**Debug:**
```sql
-- Which orders still need refunding?
SELECT o.id, o.purchaser_email, o.status, o.total
FROM orders o WHERE o.event_id = '<event_id>' AND o.status = 'paid';

-- Event status:
SELECT cancellation_status, cancelled_at FROM events WHERE id = '<event_id>';
```
**Proper fix (requires approval):** refactor function to process in batches + add checkpoint table for resume support.

---

## Incident: Flyer scan returned wrong data
**Symptom:** Uploaded flyer, AI autofilled wrong date/name/venue.
**Root cause:** OCR quality on stylized nightclub flyers is tricky (fonts, overlays, background images).
**Fix:** improve the `scan-flyer` Edge Function prompt engineering. Include examples of Maguey flyers in the prompt. Consider manual review always (never auto-save AI output without user confirm).

---

## Incident: AI event description hallucinates
**Symptom:** Generated description claims artists or features that aren't real.
**Root cause:** `generate-event-description` prompt too loose — AI fills gaps creatively.
**Fix:** tighten prompt to only use provided fields (name, date, artist names if given, description bullets). Add: "Do not invent details. If information is missing, write generically."

---

## Incident: Image upload fails silently
**Symptom:** Owner uploads image, UI seems OK, but `events.image_url` is NULL.
**Root cause options:**
1. File > 5MB rejected client-side but UI didn't surface error
2. Bucket upload succeeded but DB UPDATE didn't run
3. Storage RLS blocked the upload (anon role lacks write)

**Debug:** check browser network tab for POST to `/storage/v1/object/event-images/...`. Response code tells story.
**Fix:** ensure error handling path surfaces toast/message. Verify bucket RLS allows authenticated UPLOAD.

---

## Incident: Past events still showing as "upcoming" on marketing
**Symptom:** Event date was last week, but it still appears on the homepage.
**Root cause options:**
1. Marketing's `useEvents` doesn't filter by date
2. Event status still 'published' — no automatic archiving

**Fix:**
- Short-term: add date filter in `useEvents` hook: `.gte('event_date', today)`
- Long-term: cron job to archive events where `event_date < today - N days`. But this is a WRITE — requires user approval.

---

## Incident: Duplicate event created
**Symptom:** Two events with same name and date appear on all sites.
**Root cause:** double-click on save button or API retry without idempotency.
**Fix:**
- Short-term: UI disables save button after first click
- Long-term: add DB-level UNIQUE(name, event_date) OR idempotency key in create payload
- Cleanup: archive the duplicate (WRITE, requires approval)

---

## Incident: Reminders not sending
**Symptom:** Event is in 24 hours, customers haven't received reminder.
**Root cause options:**
1. `send-event-reminders` cron not scheduled
2. Function crashed on deploy (import error)
3. `event_reminder_log` already has rows for this event (unique constraint prevents)

**Debug:**
```sql
-- Job scheduled?
SELECT * FROM cron.job WHERE command ILIKE '%reminder%';
-- Reminder log for this event?
SELECT reminder_type, COUNT(*) FROM event_reminder_log erl
JOIN tickets t ON t.id = erl.ticket_id
WHERE t.event_id = '<event_id>'
GROUP BY reminder_type;
```

---

## Incident: Age-restricted event: someone underage got in
**Symptom:** Scanner let in an underage attendee for a 21+ event.
**Root cause:** scanner flow doesn't check `events.age_restriction` before admitting; it only validates QR.
**Fix:** integrate ID verification step in scanner UI. When event is age-restricted, prompt operator to verify ID before confirming scan.
**Compliance:** this is a legal issue. Flag to ownership.

---

## Incident: Cancelled event still visible on marketing
**Symptom:** Event was cancelled but magueynightclub.com still shows it.
**Root cause:** marketing `useEvents` doesn't filter `cancellation_status != 'cancelled'`. (Known gap in sync skill.)
**Fix:** add filter in `useEvents` subscription handler. Escalate to `maguey-bulletproof-sync` if needed.

---

## Pattern: Seasonal event batch creation
When launching a quarter of events (e.g. 12 events for a season):
1. Use `vip_table_templates` to avoid reconfiguring VIP every time
2. Create via UI one at a time (no bulk import currently)
3. Verify each: ticket_types seeded, VIP tables seeded, image uploaded
4. Publish all only after review (don't rush)
5. Announcement email blast: use `send-event-announcement` Edge Function, not manual

**Gotcha:** if you plan to edit a template, edit BEFORE creating events from it. Template changes don't propagate retroactively.

---

## Pattern: Event cancellation as a last resort
Cancellation is expensive + traumatic. Before:
1. Can the event be rescheduled instead? (Update `event_date` — no refunds needed if customers accept)
2. Is it a full cancel or just VIP? (VIP-only cancellation is a different flow)
3. Communication plan: cancel → email → social post → refund arrives in 5-10 business days

Document the cancellation reason in `events.cancellation_reason` for future analysis.
