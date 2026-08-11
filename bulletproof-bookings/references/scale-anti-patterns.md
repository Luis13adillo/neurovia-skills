# Bookings Scale Anti-Patterns

Report-only. Run in `scale-check` mode before adding a location.

---

## 1. Hardcoded location names in email / SMS templates

```bash
grep -rn "Wilmington\|Newark\|New Castle" src/lib/email/ src/lib/twilio/
```

Expected: zero direct matches. Templates must use `{{location.name}}` / `{{location.address}}` variables that interpolate from booking context.

If any hardcoded name appears, flag with file:line and suggest the variable substitution.

---

## 2. Hardcoded addresses in templates

```bash
grep -rn "Kirkwood Hwy\|Marrows Rd\|Penn Mart" src/lib/email/ src/lib/twilio/ src/app/api/bookings/
```

Expected: zero matches. Addresses come from `locations.address` in the DB.

---

## 3. Old / banned phone numbers in templates

```bash
grep -rEn "\(?302\)?[- ]?998[- ]?0900|\(?302\)?[- ]?369[- ]?0900|302[- ]?555[- ]?" src/
```

Expected: zero matches. Old numbers were scrubbed 2026-03-25.

Also:
```bash
grep -rn "Houston, TX" src/
```
Expected: zero matches.

---

## 4. `locations[0]` in booking API or wizard

```bash
grep -rn "locations\[0\]" src/app/\(public\)/book/ src/app/api/bookings/
```

Expected: zero matches. Commit `7372ca5` refactored to use schedule-aware location routing. Any regression is a bug.

---

## 5. Availability API location resolution

Read `src/app/api/bookings/availability/route.ts`. The location should come from the barber's `barber_schedules[day_of_week].location_id` for the given date, NOT from a hardcoded map or `locations[0]`.

---

## 6. Booksy sync per-barber config

- Column: `barbers.booksy_sync_email`, `barbers.booksy_sync_enabled` (migration 042).
- Adding a new location means deciding: does each barber there also need Booksy sync? If yes, populate `booksy_sync_email` per barber.
- Query current state:
```sql
SELECT id, slug, booksy_sync_email, booksy_sync_enabled
FROM barbers
WHERE is_active = true
ORDER BY slug;
```

---

## 7. Google Review URL coverage

Per CLAUDE.md env vars:
- `GOOGLE_REVIEW_URL_WILMINGTON`
- `GOOGLE_REVIEW_URL_NEWARK`
- `GOOGLE_REVIEW_URL_NEW_CASTLE`

Adding a new location requires a new env var OR migration of these to a `locations.google_review_url` column.

```bash
grep -rn "GOOGLE_REVIEW_URL_" src/
```
Read the consumer code. If it uses a switch over slugs, adding a new slug breaks it.

---

## 8. Reminder cron load

Adding more locations = more bookings = longer reminder cron run. Vercel cron has a default 10s timeout for Hobby plans, 60s for Pro.

Run:
```sql
SELECT COUNT(*) AS pending_reminders
FROM bookings
WHERE scheduled_date >= (now() AT TIME ZONE 'America/New_York')::date
  AND scheduled_date <= (now() AT TIME ZONE 'America/New_York')::date + interval '2 days'
  AND deleted_at IS NULL
  AND status = 'confirmed'
  AND reminder_sent = false;
```

If this gets into the hundreds per run and Twilio latency is ~300ms each, cron may time out. Flag for rate limiting or batched processing.

---

## 9. Public manage endpoint scalability

`/api/bookings/manage/[code]` is PUBLIC. Rate-limited to 30 GET/min and 5 POST/5min per IP.

If traffic grows with more locations, the global rate limiter may need per-location scoping OR the endpoint needs caching on confirmation_code lookups.

---

## 10. Booksy inbound webhook

- Route: `src/app/api/bookings/resend/inbound/route.ts`
- Receives emails from Resend. Parses Booksy emails per-barber.
- Each additional location means more barbers, more emails. Monitor the webhook's processing time.

---

## Output verdict template

```
## Bookings Scale Readiness — adding location #5

### Ready
- [green items]

### Must fix before go-live
1. [file:line] — [reason]

### Recommended cleanup (not blocking)
- [items]

### Verdict
[READY / BLOCKED BY N ITEMS]
```
