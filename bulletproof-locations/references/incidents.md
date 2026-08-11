# Locations Incident Registry

---

## Phone Number Update + Houston Cleanup (2026-03-25)

**What happened:**
- Deprecated phone numbers `(302) 998-0900` and `(302) 369-0900` were replaced across templates.
- "Houston, TX" was removed from all email templates and fallbacks.
- Canonical values established (see MEMORY.md "Location Data — CANONICAL").

**Banned values that should never reappear:**
- `(302) 998-0900` — old, pre-2026-03-25
- `(302) 369-0900` — old, pre-2026-03-25
- Any `(302) 555-xxxx` — placeholder, never production
- "Houston, TX" — wrong state, was a scaffold default

**Diagnose checklist:**
1. `grep -rEn "302[- ]?998[- ]?0900|302[- ]?369[- ]?0900|302[- ]?555[- ]?" src/ supabase/`
2. `grep -rn "Houston, TX" src/ supabase/`
3. Any match requires a fix (with approval).

---

## Location Data Is Sacred (HARD RULE)

**From CLAUDE.md:**
> All addresses, phone numbers, and hours are the canonical source of truth. NEVER hardcode addresses from other states. NEVER use placeholder phone numbers. If location data is needed anywhere in the code, it MUST match these values or come from the `locations` table in the database.

**What this means in practice:**
- A bug report like "phone number on email is wrong" → the CODE may be correct (reading from DB); the DB may have been updated incorrectly. Check DB first.
- A bug report like "address shows wrong on team page" → likely the code path reads from a hardcoded source or `FALLBACK_LOCATIONS`. Find the code path.
- NEVER silently "fix" by updating a hardcoded string if the canonical source is the DB. Update the DB instead, with approval.

---

## Drift Between FALLBACK_LOCATIONS and DB

**Symptom:**
- Public page briefly shows one address
- Reload shows a different address
- The "stale" value matches `FALLBACK_LOCATIONS` in `src/lib/utils/locations.ts`

**Root cause:**
`FALLBACK_LOCATIONS` is used for SSR edge cases when the DB call fails or hasn't completed. If it drifts from the DB (e.g., DB updated, fallback not updated), users see the stale version on first paint.

**Diagnose:**
1. Read `src/lib/utils/locations.ts` `FALLBACK_LOCATIONS` array.
2. Compare values to current DB state via: `SELECT id, name, slug, address, city, state, zip, phone FROM locations`.
3. For any mismatch, flag. Fix requires approval (changes customer-facing data).

**Why not auto-fix:**
- The fallback may be intentionally stale (e.g., if DB was just updated and fallback hasn't shipped).
- Decide with the user what's current and update both sources together.

---

## Newark Sunday Still Appears Open

**Symptom:**
- Customer visits `/queue/newark` on Sunday
- Page shows "open" or accepts check-in
- But Newark is closed Sundays (per CLAUDE.md and MEMORY.md)

**Root cause:**
- `hours_json.sunday` value is not null for Newark in the DB
- Or code path doesn't read `hours_json` and uses hardcoded fallback
- Or TZ handling bug treats Saturday UTC late-night as Sunday (unlikely but possible)

**Diagnose:**
1. Query: `SELECT slug, hours_json FROM locations WHERE slug = 'newark'`
2. Verify `hours_json->>'sunday'` is null or a closed indicator.
3. Read the queue/locations page code path for Sunday handling.
4. Check that the code uses `toLocaleDateString('en-US', { timeZone: 'America/New_York', weekday: 'short' })` for day-of-week determination.

---

## Old Phone Number In Customer SMS

**Symptom:**
- Customer receives SMS with an old/disconnected phone number
- Or SMS from a location we no longer operate

**Root cause:**
- SMS template has a hardcoded phone string (violates Location Data Is Sacred)
- Or template uses the wrong variable (e.g., `{{locations[0].phone}}` when it should be `{{booking.location.phone}}`)

**Diagnose:**
1. `grep -rn "302-" src/lib/twilio/`
2. `grep -rn "phone" src/lib/twilio/templates/` — check every template references the booking's location, not a global.
3. Look for any literal phone in templates.

---

## Address Shows Wrong in Confirmation Email

**Symptom:**
- Customer books a Newark appointment
- Email confirmation shows Wilmington address

**Possible root causes:**
1. Email template hardcodes Wilmington as default
2. `booking.location_id` is correct but template accesses `locations[0]`
3. `locations` data didn't load before template ran (SSR edge case — fallback used)

**Diagnose:**
1. Read `src/lib/email/templates/bookingConfirmation.ts` (or wherever the booking confirm template lives).
2. Confirm it accesses `booking.location.address`, not `locations[0].address` or a hardcoded string.
3. Check the booking row: is `location_id` correctly set?

---

## Adding a New Location — Common Mistakes

**User intent:** Add Dover or Middletown as location #4.

**Common oversights (DON'T skip):**
- Forgot to populate `barber_schedules` for the new location → barbers invisible to booking/rotation there
- Forgot to add static `src/app/(public)/queue/<slug>/page.tsx` OR verify catch-all handles it
- Forgot to add `NEXT_PUBLIC_GOOGLE_REVIEW_URL_<SLUG>` env var
- Forgot to add entry to `locationExtras` in `src/app/(public)/locations/page.tsx`
- Forgot to update `FALLBACK_LOCATIONS` in `src/lib/utils/locations.ts`
- Didn't set `hours_json` with all 7 days + `max_queue_size`

**Diagnose checklist after a "new location not working" report:**
1. Does it appear in `SELECT * FROM locations WHERE is_active = true`?
2. Do barbers have schedule rows pointing at it?
3. Does `/queue/<slug>` render? (static vs. catch-all)
4. Does the `locationExtras` map have the slug?
5. Is the env var set in Vercel?

---

## Quick Match Table

| Symptom | Likely incident | First file to read |
|---|---|---|
| Old phone number anywhere | 2026-03-25 cleanup regression | template file containing phone |
| "Houston, TX" anywhere | cleanup regression | grep + fix |
| Wrong address in email | template accessing locations[0] | template file |
| Newark Sunday shows open | hours_json or day-of-week bug | `SELECT hours_json FROM locations WHERE slug='newark'` |
| New location not appearing | incomplete setup | run setup checklist |
| Fallback drift | FALLBACK_LOCATIONS out of sync with DB | `src/lib/utils/locations.ts` |
