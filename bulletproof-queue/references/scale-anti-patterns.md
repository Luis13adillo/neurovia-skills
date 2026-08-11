# Multi-Location Scale Anti-Patterns

The queue is designed for N locations, but several files hardcode assumptions that break when N grows past 3 (currently Wilmington / Newark / New Castle). Before adding location #5, run every check here. Do NOT fix anything in scale-check mode — report only.

---

## 1. Hardcoded location slugs outside expected files

```bash
grep -rEn "'wilmington'|\"wilmington\"|'newark'|\"newark\"|'new-castle'|\"new-castle\"" src/ --include='*.ts' --include='*.tsx'
```

**Expected (safe) matches:**
- `src/app/(public)/queue/wilmington/page.tsx` etc. — static page route files (these are fine; a new location gets a new file or the catch-all handles it)
- `src/lib/constants/locations.ts` or similar — fallback constants used when DB is unavailable
- SEO schema / metadata files — per-location structured data

**Unsafe matches (flag these):**
- Any `switch (slug)` or `if (slug === 'newark')` containing business logic (hours, pricing, service filtering)
- Hardcoded Google Review URLs tied to a specific slug — these should come from env vars
- SMS template strings referencing a single location

For each unsafe match: report file:line, surrounding context, and a one-line suggestion ("move to DB `locations.hours_json`" / "read from env var" / "use `location.slug` from props").

---

## 2. `locations[0]` anti-pattern

```bash
grep -rn "locations\[0\]" src/
```

**Known files from the last mapping** (verify still present — some may have been fixed):
- `src/components/site/MobileHomePage.tsx:92` — homepage hero defaults to first location
- `src/app/page.tsx:214` — desktop homepage default
- `src/app/(dashboard)/dashboard/queue/page.tsx:89, 599, 629` — owner queue page falls back to `locations[0]` when location = 'all'
- `src/components/dashboard/WalkInForm.tsx:35` — walk-in form defaults to first location
- `src/app/(dashboard)/barber/walk-ins/page.tsx:255` — fallback to `locations[0]` when barber schedule has no location_id
- `src/app/(dashboard)/dashboard/my-chair/page.tsx:199` — owner preferred location fallback

**Fix pattern (DO NOT IMPLEMENT in scale-check mode — just recommend):**
- For barber pages → use the barber's current `staff_status.location_id`, or their `barber_schedules[day_of_week].location_id`, or explicitly prompt the user to pick.
- For owner pages → use owner's `preferred_location_id` from profile, or remember last selection in localStorage, or prompt.
- For public homepages → use geolocation or user preference, not `[0]`.

**Impact at scale #5:** Wilmington (location 0) gets disproportionate traffic because every fallback points there. Adding location #5 doesn't balance this; it inherits the bias.

---

## 3. Hours-of-operation logic must come from `hours_json`

```bash
grep -rn "hours_json" src/
```

**Every hours check, open/closed decision, or Sunday-closure handling MUST read `location.hours_json`** — not a switch statement on `slug`.

**Flag these anti-patterns:**
```ts
if (slug === 'newark' && dayOfWeek === 0) return 'Closed'  // WRONG
```
should be
```ts
const todayHours = location.hours_json?.[dayName(dayOfWeek)];
if (!todayHours?.isOpen) return 'Closed';
```

---

## 4. Hardcoded phone numbers

```bash
grep -rEn "\(?302\)?[- ]?[0-9]{3}[- ][0-9]{4}" src/
grep -rEn "302[0-9]{7}" src/
```

**Expected (safe):**
- `src/lib/constants/locations.ts` FALLBACK_LOCATIONS
- Email template fallbacks explicitly scoped as "if location data is missing, fall back to primary Wilmington"
- Legal / footer contact info (single canonical number)

**Unsafe:** Hardcoded numbers inside per-location routing logic (e.g., "if Newark, use this number"). All numbers should come from `locations.phone` in the DB.

**Never allowed (old numbers — if you see these, they're stale):**
- `(302) 998-0900` — replaced 2026-03-25
- `(302) 369-0900` — replaced 2026-03-25
- Any `(302) 555-xxxx` — placeholder, never production

---

## 5. Hardcoded addresses

```bash
grep -rn "Kirkwood Hwy\|Marrows Rd\|Penn Mart" src/
```

**Expected:** FALLBACK_LOCATIONS, SEO schemas, occasional email-template explicit addresses.
**Unsafe:** Anywhere the address is used as a decision key or rendered from a non-DB source.

**Also check for banned values:**
- "Houston, TX" — removed from all templates 2026-03-25. Any match = bug.

---

## 6. Static queue check-in pages

**Current files:**
- `src/app/(public)/queue/wilmington/page.tsx`
- `src/app/(public)/queue/newark/page.tsx`
- `src/app/(public)/queue/new-castle/page.tsx`

**Adding location #5 requires either:**
- (a) Creating `src/app/(public)/queue/<new-slug>/page.tsx` with identical structure, OR
- (b) Verifying `src/app/(public)/queue/[...slug]/page.tsx` catch-all handles the new slug AND removes the need for static per-location files.

Ideally, refactor to option (b) before adding location #5 so every future location is zero-code. Recommend this to the user but do not implement in scale-check mode.

---

## 7. TV display routes

**File:** `src/app/(public)/tv/[location]/page.tsx`
Must be dynamic on `[location]` (it is). Verify no `switch (location)` with business logic inside.

---

## 8. Day-of-week hardcoded logic

```bash
grep -rEn "dayOfWeek[[:space:]]*===?[[:space:]]*[0-6]|getDay\(\)[[:space:]]*===?[[:space:]]*[0-6]" src/
```

**Expected:** Utility functions mapping day numbers to names.
**Flag:** Business rules like `if (dayOfWeek === 0) closed` — those belong in `hours_json`, not code.

Also — per MEMORY.md "Booksy Timezone Rule" — any `getDay()` call on Vercel without `timeZone: 'America/New_York'` is WRONG. Check:
```bash
grep -rn "\.getDay()\|\.getHours()" src/app/api/ src/lib/
```
Every match should be inside a function that also uses `toLocaleDateString` with the Eastern timezone, OR on an already-localized date.

---

## 9. Fair rotation scope — all barbers at a location

The fair rotation algorithm picks lowest `cuts_today` among eligible barbers at a location. If a new location is added but `barber_schedules` isn't populated, barbers won't appear in rotation there.

**Pre-launch check for a new location:**
```sql
-- Run after adding location + assigning barbers
SELECT l.name AS location, b.id AS barber_id, bs.day_of_week, bs.is_active
FROM locations l
LEFT JOIN barber_schedules bs ON bs.location_id = l.id AND bs.is_active = true
LEFT JOIN barbers b ON b.id = bs.barber_id AND b.is_active = true
WHERE l.slug = '<new-slug>'
ORDER BY b.id, bs.day_of_week;
-- Expected: a row for each active barber × each day they work
```

---

## 10. SMS / email templates with location names

```bash
grep -rn "Wilmington\|Newark\|New Castle" src/lib/email/ src/lib/twilio/
```

**Expected:** zero direct references. Templates should read `{{location.name}}` from a variable bag.
**Flag:** any hardcoded location name inside a template — it won't substitute correctly for location #5.

---

## 11. Google Review URLs

Per CLAUDE.md env vars:
- `GOOGLE_REVIEW_URL_WILMINGTON`
- `GOOGLE_REVIEW_URL_NEWARK`
- `GOOGLE_REVIEW_URL_NEW_CASTLE`

**Adding location #5 requires:** a new env var, plus the code that reads these to handle the new slug. Grep for how these are consumed:
```bash
grep -rn "GOOGLE_REVIEW_URL_" src/
```

**Refactor recommendation:** Store review URLs in `locations.google_review_url` column instead of env vars. Do not implement in scale-check mode — recommend only.

---

## Output: scale-readiness verdict

After running all checks, produce this summary:

```
## Scale Readiness — adding location #5

### Ready
- [green items: dynamic routing, DB-driven hours, no hardcoded phones in business logic]

### Must fix before adding location #5
1. [file:line] — [what to fix] — [why it breaks]
2. ...

### Recommended cleanup (not blocking)
- [refactor suggestions, e.g., move review URLs to DB column]

### Verdict
[READY / BLOCKED BY N MUST-FIX ITEMS]
```

Never make fixes in scale-check mode. The user decides which to tackle and when.
