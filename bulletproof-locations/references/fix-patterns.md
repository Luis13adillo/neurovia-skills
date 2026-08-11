# Locations — Fix Patterns

Paste-ready diffs for the most common location-data drift. When the audit flags a failure, point to the pattern number here and the user gets a concrete change to apply. Patterns are canonical — if you deviate, document why.

All patterns assume:
- Canonical values match MEMORY.md "Location Data — CANONICAL" (2026-04-20) and the "Multi-Location System" section of CLAUDE.md.
- `mcp__supabase-mt__execute_sql` is read-only unless the user explicitly approves a write.
- Location data is sacred. A wrong phone change breaks customer calls immediately.

---

## Fix-mode preflight checklist (universal — applies to every pattern)

Fix mode in `SKILL.md` runs this sequence for EVERY pattern before the Edit. Do all steps, in order. Skip none.

1. **Preflight** — Read the target file. Match the pattern's "before" block against current code (imports, function names, surrounding context — NOT line numbers, which drift). If ANY of these don't match → STOP. Report what differs. Do NOT apply a stale pattern.
2. **Classify** — Is this drift live (affecting customers right now) or latent (only bites when DB updates)? Run the audit query in `audit-queries.sql` for the invariant the pattern addresses. User decides urgency from this.
3. **Confirm diff** — Show exact `old_string` / `new_string`. Wait for explicit `yes`. Location data is customer-visible — no silent fixes.
4. **Apply** — Single `Edit` call. One pattern per invocation.
5. **Verify** — Run the pattern's post-fix verification (grep + tsc, plus SQL for data-level fixes). Every check must pass.
6. **Mirror** — Locations data is read by both owner + barber dashboards. If the pattern changes a hook, context, or resolver, invoke `mirror-check` before handoff.
7. **Handoff** — Stop at `bulletproof-ship`. Do not commit.

If any step fails, stop and report. Do not proceed to the next step.

---

## Pattern 1 — Replace deprecated phone number in code

**When:** Grep C2 flags `(302) 998-0900`, `(302) 369-0900`, or `(302) 555-xxxx` anywhere in `src/` or `supabase/`. Per MEMORY.md these numbers were fully replaced 2026-03-25 — any reappearance is a regression.

**Symptom:** Customer SMS / email / page footer shows an old, disconnected number. Calls to the number go to voicemail for a line we no longer own.

**Root cause:** A template, mock-data file, or UI component hardcoded the phone string. The canonical source (`locations.phone` column) was updated, but the hardcoded literal was missed.

**Before:**
```tsx
<a href="tel:3023690900">(302) 369-0900</a>
```

**After:**
```tsx
// Prefer the DB value threaded through props / context:
<a href={`tel:${location.phone.replace(/\D/g, '')}`}>{location.phone}</a>

// If the surface has no location context (e.g., generic footer),
// use the Wilmington primary number as a fallback ONLY if the code
// already imports from `src/lib/utils/locations.ts` FALLBACK_LOCATIONS:
import { FALLBACK_LOCATIONS } from '@/lib/utils/locations'
const primary = FALLBACK_LOCATIONS.find((l) => l.slug === 'wilmington')!
<a href={`tel:${primary.phone.replace(/\D/g, '')}`}>{primary.phone}</a>
```

**Post-fix verification:**
- `grep -rEn "302[- ]?998[- ]?0900|302[- ]?369[- ]?0900|302[- ]?555[- ]?[0-9]{4}" src/ supabase/` → 0 matches (invariant C2, incident 2026-03-25).
- `npx tsc --noEmit` → no new errors.
- Spot-check the changed surface in browser — tapping `tel:` opens the dialer with the new number.

**Scope limit:** Only swap the phone literal. Do NOT refactor the surrounding component to "be safer" — that's the out-of-scope trap from debugging-protocol.md Section 7.

---

## Pattern 2 — Remove hardcoded address from email/SMS template

**When:** Grep C4 flags literal `Kirkwood Hwy`, `Marrows Rd`, `Penn Mart`, or `Gateway Shopping` in `src/lib/email/` or `src/lib/twilio/`. Addresses must come from `locations.address` threaded through the template payload.

**Symptom:** Customer books a Newark appointment but confirmation email shows the Wilmington address. Or all booking emails show the same address regardless of location.

**Root cause:** Template uses a literal string or reads `locations[0].address` instead of the booking's own `location.address`.

**Before:**
```ts
// src/lib/email/templates.ts
const body = `
  Your appointment is confirmed at:
  3616 Kirkwood Hwy, Wilmington, DE 19808
`
```

**After:**
```ts
// Template accepts location fields as props:
interface BookingConfirmData {
  locationName: string
  locationAddress: string   // from booking.location.address
  locationCity: string      // from booking.location.city
  locationState: string     // from booking.location.state  ← critical for Edwardsville PA
  locationZip: string
  // ...rest of booking fields
}

const body = `
  Your appointment is confirmed at:
  ${data.locationAddress}, ${data.locationCity}, ${data.locationState} ${data.locationZip}
`
```

Then at the API route that calls the template (e.g., `/api/bookings/quick/route.ts`), select the full location row and pass it through:

```ts
const { data: location } = await supabase
  .from('locations')
  .select('name, address, city, state, zip, phone')
  .eq('id', booking.location_id)
  .single()

await sendBookingConfirmation({
  locationName: location.name,
  locationAddress: location.address,
  locationCity: location.city,
  locationState: location.state,  // ← DO NOT default to 'DE'
  locationZip: location.zip,
  // ...
})
```

**Post-fix verification:**
- `grep -rEn "Kirkwood Hwy|Marrows Rd|Penn Mart|Gateway Shopping" src/lib/email src/lib/twilio` → 0 matches (invariant C4).
- Booking flow smoke test: create a Newark booking → email renders `73 Marrows Rd, Newark, DE 19713`, not Wilmington.
- `npx tsc --noEmit` → no new errors.

**Cite:** Incident "Address Shows Wrong in Confirmation Email" in `incidents.md`.

---

## Pattern 3 — Remove `locationState || 'DE'` default (Edwardsville PA bug)

**When:** Grep flags `locationState || 'DE'` or hardcoded `\`, DE\`` inside an email template. Per MEMORY.md (2026-04-20 cross-state email fix), Edwardsville is PA — any template that silently defaults to DE mislabels the location for Edwardsville bookings.

**Symptom:** Edwardsville booking confirmation email footer reads `Edwardsville, DE` instead of `Edwardsville, PA`. Violates the HARD RULE "Email template footers must use `locationState` from booking data — NEVER hardcode `, DE`."

**Root cause:** Template has a soft default (`locationState || 'DE'`) that papers over the bug when the caller forgets to pass `locationState`. Caller neglects to pass it, default kicks in, Edwardsville gets labeled DE.

**Before:** `src/lib/email/templates.ts` lines 64, 168, 230, 583:
```ts
const locationFooter = data.locationName
  ? `${data.locationName}, ${data.locationState || 'DE'}`
  : 'Wilmington, DE'
```

Also line 433 and 640 have worse variants:
```ts
`${data.locationName}, DE`   // hardcoded — no prop at all
```

Line 771 has a literal:
```ts
Wilmington, DE
```

**After:** Require `locationState` as a non-optional prop and delete the fallback:
```ts
// Top of file / type:
interface WrapTemplateData {
  locationName: string
  locationState: string  // required — 'DE' or 'PA'
  // ...
}

// Body:
const locationFooter = `${data.locationName}, ${data.locationState}`
```

Then at every caller (API routes, cron routes, transactional email senders), pass `location.state` from the DB explicitly. Typescript will now force the fix at each call site.

**Post-fix verification:**
- `grep -rn "locationState || 'DE'" src/lib/email/` → 0 matches.
- `grep -rn "', DE'" src/lib/email/` → 0 matches (outside of the single Wilmington-hardcoded constant in `wrapTemplate`, which should also be removed — see below).
- `wrapTemplate` signature no longer has `locationLine: string = 'Wilmington, DE'` — must be a required param.
- Send a test Edwardsville booking email → footer reads `Edwardsville, PA`.
- `npx tsc --noEmit` → passes (all callers were forced to pass `locationState`).

**Cite:** MEMORY.md "Cross-state email fix (2026-04-20)", invariant C4, and the CLAUDE.md HARD RULE "Location Data Is Sacred" / "Edwardsville is PA."

**Scope limit:** This pattern touches `src/lib/email/templates.ts` and every API route that calls its exports. Do ONE template function per fix-mode invocation. Do not bulk-rewrite all 6 templates in one Edit.

---

## Pattern 4 — Replace `locations[0]` fallback with resolved-location lookup

**When:** Audit scale-check finds a `locations[0]` reference in a code path that sends customer communication or renders a customer-facing page without upstream location resolution. Per scale-check list, 12 files have these references (22 total occurrences) — most are safe fallbacks, but any that drive customer-visible surfaces are latent bugs when a new location is added at index 0.

**Symptom:** After adding a new location to the DB, a page or notification starts referencing the wrong location because `locations[0]` now returns the new one instead of Wilmington.

**Root cause:** `locations[0]` assumes deterministic order and that index 0 is always Wilmington. Neither is guaranteed — the order depends on the query's `ORDER BY`, and adding a new location can shuffle the array.

**Before:**
```ts
// src/components/dashboard/WalkInForm.tsx
const defaultLocationId = locations[0]?.id
```

**After — Option A (if there's a logged-in barber context):**
```ts
import { resolveBarberLocation } from '@/lib/db/location'

const resolvedId = await resolveBarberLocation(barberId, { mode: 'current' })
const defaultLocationId = resolvedId ?? locations[0]?.id  // locations[0] as safety net only
```

**After — Option B (explicit slug lookup for global surfaces):**
```ts
const primary = locations.find((l) => l.slug === 'wilmington')
const defaultLocationId = primary?.id ?? locations[0]?.id
```

**After — Option C (if the surface is truly location-agnostic):**
Leave `locations[0]` but add a comment explaining why this is not a bias bug:
```ts
// locations[0] is a last-resort fallback; upstream <LocationSelector>
// guarantees location_id is set before this component mounts.
const fallbackId = locations[0]?.id
```

**Post-fix verification:**
- `grep -n "locations\[0\]" <edited-file>` → 0 matches (Option A/B) OR 1 match with an explaining comment (Option C).
- If the file is listed in `SKILL.md` scale-check as having `locations[0]` references, update that list in the skill if all references are resolved.
- `npx tsc --noEmit` → no new errors.
- **Mirror-check required:** any change to `my-chair/*` or `barber/*` MUST be mirrored to the paired dashboard per the Cross-Dashboard Code Mirroring Rule.

**Cite:** SKILL.md scale-check list; CLAUDE.md "Cross-Dashboard Consistency"; context-awareness.md mirror map.

---

## Pattern 5 — Newark Sunday still appears open

**When:** Customer reports `/queue/newark` accepts check-in on Sunday, or the public locations page shows Newark as open Sunday. Per CLAUDE.md / MEMORY.md, Newark is closed Sundays.

**Symptom:** Sunday customers can submit to the Newark queue. Or the homepage card for Newark says "Open now."

**Root cause (ordered by likelihood):**
1. The code uses `new Date().getDay()` (UTC on Vercel) instead of ET-safe `toLocaleDateString(..., { timeZone: 'America/New_York', weekday: 'short' })`. Late Saturday UTC evening = Sunday ET late-night = wrong day branch.
2. `hours_json->>'sunday'` in the DB is not null for Newark. Should be null (closed).
3. The open/closed check reads a hardcoded schedule instead of `hours_json`.

**Before:**
```ts
const dayOfWeek = new Date().getDay()  // UTC — wrong on Vercel
const todaysHours = hours_json[['sunday','monday',...][dayOfWeek]]
```

**After:**
```ts
// ET-safe day-of-week resolution:
const etWeekday = new Date().toLocaleDateString('en-US', {
  timeZone: 'America/New_York',
  weekday: 'long',
}).toLowerCase()  // 'sunday' | 'monday' | ...

const todaysHours = hours_json[etWeekday]
const isClosed = todaysHours === null || todaysHours === undefined
```

**Post-fix verification:**
- Query `SELECT hours_json->>'sunday' FROM locations WHERE slug = 'newark'` → `null` (invariant #3).
- `grep -n "getDay()\|getUTCDay()" <file>` → 0 matches (MEMORY.md Booksy Timezone Rule).
- Visit `/queue/newark` on Sunday (or mock the date in dev) → "Closed" state renders, check-in disabled.
- `npx tsc --noEmit` → no new errors.

**Cite:** Incident "Newark Sunday Still Appears Open" in `incidents.md`; MEMORY.md "Booksy Timezone Rule".

---

## Pattern 6 — FALLBACK_LOCATIONS drift from DB

**When:** Audit invariant C1 flags a mismatch between `FALLBACK_LOCATIONS` in `src/lib/utils/locations.ts` and the DB `locations` table (phone, address, or state).

**Symptom:** Public page shows one address on first paint, then "corrects" to a different one after hydration. The stale first-paint value matches `FALLBACK_LOCATIONS`.

**Root cause:** The DB was updated (phone change, typo fix) but the fallback array was not re-synced. `FALLBACK_LOCATIONS` is used for SSR when the DB call fails or hasn't completed.

**Before:**
```ts
// src/lib/utils/locations.ts — stale Edwardsville entry
export const FALLBACK_LOCATIONS: LocationRow[] = [
  // ...wilmington, newark, new-castle...
  {
    id: 'd4e5f6a7-b8c9-0123-cdef-f12345678903',
    slug: 'edwardsville',
    name: 'Edwardsville',
    address: '34 Gateway Shopping Center',
    city: 'Edwardsville',
    state: 'DE',           // ← WRONG; should be PA
    zip: '18704',
    phone: '(347) 792-9614',
  },
]
```

**After:**
```ts
  {
    id: 'd4e5f6a7-b8c9-0123-cdef-f12345678903',
    slug: 'edwardsville',
    name: 'Edwardsville',
    address: '34 Gateway Shopping Center',
    city: 'Edwardsville',
    state: 'PA',           // ← matches DB + MEMORY.md canonical
    zip: '18704',
    phone: '(347) 792-9614',
  },
```

**Post-fix verification:**
- Run data-level queries #2, #3, #4 (per-location canonical) AND compare each field to the `FALLBACK_LOCATIONS` entry. Every field must match.
- `grep -n "state: 'DE'" src/lib/utils/locations.ts` → should NOT return the Edwardsville entry.
- `grep -n "LOCATION_SLUGS\|LOCATION_INFO" src/lib/utils/locations.ts` → verify the slug→id map and slug→info map are consistent with the array (same 4 entries).
- `npx tsc --noEmit` → passes.

**Scope limit:** Only fix the drifting fields. Do NOT re-order, re-type, or "modernize" the array.

**Cite:** Invariant C1; incident "Drift Between FALLBACK_LOCATIONS and DB" in `incidents.md`.

---

## Pattern 7 — Adding a new location: the 7-point checklist

**When:** User says "we're opening a 5th location" or "add Dover". This is not a single Edit — it's a coordinated checklist. Fix mode must walk through each point and confirm each is done before ship.

**Required artifacts (skip any at your peril):**

1. **DB row** — `INSERT INTO locations (...) VALUES (...)` with ALL fields: `id, name, slug, address, city, state, zip, phone, hours_json (all 7 days + max_queue_size), is_active=true, accepts_walk_ins`. Requires explicit user approval — this is a production write.
2. **`FALLBACK_LOCATIONS`** — Add a matching entry in `src/lib/utils/locations.ts`. Also add the slug→id pair to `LOCATION_SLUGS` and the slug→info object to `LOCATION_INFO`.
3. **Static queue page** — Add `src/app/(public)/queue/<slug>/page.tsx` (copy from `edwardsville/page.tsx`). Also add a corresponding `public/manifest-kiosk-<slug>.json`.
4. **`locationExtras` map** — Add a slug entry to `src/app/(public)/locations/page.tsx` (plaza name, parking, mapUrl, barberCount).
5. **Google Review env var** — Set `NEXT_PUBLIC_GOOGLE_REVIEW_URL_<SLUG>` in Vercel. Update code that reads these to handle the new slug.
6. **Barber schedules** — For every barber who will work at the new location, INSERT `barber_schedules` rows (`day_of_week`, `location_id`, `start_time`, `end_time`). Without schedule rows, barbers are invisible to booking + fair rotation.
7. **Static page refactor decision** — If this is location #5, consider migrating the static per-location queue pages to the `[...slug]` catch-all. Recommend in report; do NOT implement without approval.

**Before (incomplete):**
```ts
// DB row inserted, FALLBACK_LOCATIONS updated, but:
// - no static queue page → /queue/<slug> 404s
// - no Google Review env var → feedback CTA links to nothing
// - no barber_schedules rows → no barbers show on /team for any day
```

**After:**
All 7 artifacts present. Audit mode re-run → all invariants pass for the new location.

**Post-fix verification:**
- Data-level invariant #1: query returns `N` active rows (where `N` = old count + 1).
- Data-level invariant #6: new location's `hours_json` has all 7 days + `max_queue_size` keys.
- `SELECT COUNT(*) FROM barber_schedules WHERE location_id = '<new-id>'` → ≥ 1 per expected barber.
- Visit `/queue/<slug>` → renders without 404.
- Visit `/locations` → new card renders with plaza, parking, map.
- `grep -n "<SLUG>" .env.local` → env var present.
- `npx tsc --noEmit` → passes.

**Cite:** SKILL.md scale-check section; incident "Adding a New Location — Common Mistakes" in `incidents.md`.

---

## Pattern 8 — Backfill NULL `preferred_location_id` on active barbers

**When:** Data-level audit returns rows where `is_active = true` AND `preferred_location_id IS NULL`. Per SKILL.md section 4, this is the "wrong location when clocked out" root cause.

**Symptom:** A barber who's clocked out appears at Wilmington (index 0) on public profile, team page, or booking flow — even though they work at Newark.

**Root cause:** `resolveBarberLocation('current')` priority chain: staff_status (only while active) → `preferred_location_id` → today's schedule → most-common schedule → `locations[0]`. If the barber is clocked out AND `preferred_location_id` is NULL AND today has no schedule row, they fall through to `locations[0]`.

**Before (verification query, READ-ONLY):**
```sql
SELECT b.slug, b.preferred_location_id,
       (SELECT COUNT(*) FROM barber_schedules bs
        WHERE bs.barber_id = b.id AND bs.is_active) AS schedule_rows
FROM barbers b
WHERE b.is_active = true
  AND b.preferred_location_id IS NULL;
```

**After (REQUIRES EXPLICIT USER APPROVAL — this is a production write):**
```sql
-- Preferred: derive from staff_status if any row exists
UPDATE barbers b
SET preferred_location_id = s.location_id
FROM staff_status s
WHERE s.barber_id = b.id
  AND b.preferred_location_id IS NULL
  AND b.is_active = true;

-- Fallback: derive from most-common active schedule location
UPDATE barbers b
SET preferred_location_id = (
  SELECT bs.location_id
  FROM barber_schedules bs
  WHERE bs.barber_id = b.id AND bs.is_active
  GROUP BY bs.location_id
  ORDER BY COUNT(*) DESC
  LIMIT 1
)
WHERE b.preferred_location_id IS NULL
  AND b.is_active = true;
```

Also patch the 3 writer routes so the invariant holds going forward — any time a barber is created or their schedule changes, `preferred_location_id` must be set or updated:
- `src/app/api/auth/create-barber/route.ts` — on INSERT, set `preferred_location_id: location_id`.
- `src/app/api/barbers/[id]/schedule/route.ts` — after PUT, recompute most-common `location_id` from the new schedule and UPDATE `barbers.preferred_location_id`.
- `src/app/api/barber/location/route.ts` — already correct (manual location switch).

Do NOT touch `src/app/api/barber/location-request/route.ts` — by design this is per-day routing, not a primary-location move (per SKILL.md).

**Post-fix verification:**
- Re-run the verification query → 0 rows.
- `npx tsc --noEmit` → passes.
- Smoke test: find a test barber, clock them out, visit their public profile → shows their correct location, not Wilmington.
- Mirror-check: schedule writer changes touch both owner + barber views — invoke `mirror-check`.

**Scope limit:** DO NOT backfill any barber that is `is_active = false` (including test barbers) — that's out of scope and pollutes reports.

**Cite:** SKILL.md section 4 ("preferred_location_id must be set on every active barber"); diagnose section "A barber shows up at the wrong location when clocked out".

---

## Cross-pattern rules

1. **Canonical data is owned by MEMORY.md + CLAUDE.md.** Code drifts from canonical. DB drifts from canonical. Both require approval to change. Templates and fallbacks drift silently — those are the fix-pattern targets.
2. **Edwardsville is PA.** Every template, prop, and fallback must carry `state` explicitly. No `|| 'DE'` defaults. No hardcoded `, DE`.
3. **ET-safe day-of-week everywhere.** `getDay()` is UTC on Vercel. Always `toLocaleDateString('en-US', { timeZone: 'America/New_York', weekday: 'long' })`.
4. **`locations[0]` is a last-resort fallback, never a primary reference.** Prefer slug lookup or `resolveBarberLocation()`.
5. **`FALLBACK_LOCATIONS` must match DB.** Any mismatch = latent first-paint bug.
6. **Never write to production DB without explicit user approval.** Location data is sacred; `preferred_location_id` backfill, phone changes, and address edits all require a `yes` before the Edit.
7. **Every fix must preserve the 4-location model until #5 is greenlit.** Don't anticipate expansion — scale-check flags it; implement only on request.

---

## When adding a NEW location-reading surface

Checklist:
1. Does it accept `location` as a prop (not `locations[0]`)?
2. Does it pass `locationState` explicitly to any template call?
3. Does it use ET-safe date/time for hours logic?
4. If it's in `my-chair/*` or `barber/*`, is the mirror page updated per the Cross-Dashboard Code Mirroring rule?
5. Does it degrade gracefully if the DB fetch fails (FALLBACK_LOCATIONS only)?

If any of these is "no," stop and fix before shipping.
