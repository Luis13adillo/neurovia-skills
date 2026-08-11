# Locations Scale Anti-Patterns

Report-only. Run in `scale-check` mode.

---

## 1. `locations[0]` full inventory

```bash
grep -rn "locations\[0\]" src/
```

Known files (verify still present and safe):
- `src/app/page.tsx:214`
- `src/app/(dashboard)/dashboard/my-chair/page.tsx:199`
- `src/components/site/MobileHomePage.tsx:92`
- `src/app/(dashboard)/dashboard/my-chair/queue/page.tsx:100`
- `src/app/(dashboard)/dashboard/my-chair/schedule/page.tsx:427, 600`
- `src/components/dashboard/WalkInForm.tsx:35`
- `src/components/dashboard/academy/SessionScheduler.tsx:74`
- `src/components/dashboard/BarberScheduleModal.tsx:74, 89, 110`
- `src/app/(dashboard)/barber/schedule/page.tsx:372, 397`
- `src/app/(dashboard)/barber/walk-ins/page.tsx:255`
- `src/app/(dashboard)/dashboard/queue/page.tsx:89, 599, 629`

Each is currently a fallback after DB-load. Flag any that would cause incorrect behavior with more locations:
- Homepage hero (biased to location #1) — consider geolocation or user selection
- Dashboard defaults (biased to location #1) — should use `preferred_location_id`

---

## 2. Hardcoded slug branches

```bash
grep -rEn "(switch[[:space:]]*\([^)]*slug\)|if[[:space:]]*\([^)]*slug[[:space:]]*===?)" src/
```

Look for business logic inside slug switches. Safe usages: SEO metadata, static route files, `locationExtras` UI map. Flag business rules.

---

## 3. Static queue pages

Current per-location pages:
- `src/app/(public)/queue/wilmington/page.tsx`
- `src/app/(public)/queue/newark/page.tsx`
- `src/app/(public)/queue/new-castle/page.tsx`

Adding location #5 requires either:
- Create a new static file (copy an existing one), OR
- Refactor all three to use the catch-all `/queue/[...slug]` (zero new files per location).

**Recommend the refactor before scaling.** It makes every future location zero-code.

---

## 4. `locationExtras` UI-only map

- File: `src/app/(public)/locations/page.tsx`
- Hardcoded object keyed by slug, containing plaza name, parking info, map URL, ratings.
- Adding a new location requires adding a new entry.
- Long-term: move to DB columns on `locations` table (`plaza_name`, `parking_info`, `map_url`).

---

## 5. Google Review URL env vars

```bash
grep -rn "GOOGLE_REVIEW_URL_\|NEXT_PUBLIC_GOOGLE_REVIEW_URL_" src/
```

Per-location env var pattern:
- `NEXT_PUBLIC_GOOGLE_REVIEW_URL_WILMINGTON`
- `NEXT_PUBLIC_GOOGLE_REVIEW_URL_NEWARK`
- `NEXT_PUBLIC_GOOGLE_REVIEW_URL_NEW_CASTLE`

New location needs:
- New env var in Vercel + `.env.local.example`
- Code updated to handle the new slug (if there's a switch)

**Long-term:** move to `locations.google_review_url` DB column. Recommend, don't implement.

---

## 6. `FALLBACK_LOCATIONS` scale discipline

- File: `src/lib/utils/locations.ts`
- Array with 3 entries. Adding a new location means adding an entry.

Reminder note for the report: "Don't let FALLBACK_LOCATIONS drift from DB — set it at go-live and update together when canonical values change."

---

## 7. Barber schedule population before go-live

Before turning on a new location (`is_active = true`):
```sql
SELECT b.slug,
       COUNT(bs.id) AS days_scheduled_at_new_location
FROM barbers b
LEFT JOIN barber_schedules bs
       ON bs.barber_id = b.id
      AND bs.location_id = '<new-location-id>'
      AND bs.is_active = true
WHERE b.is_active = true
GROUP BY b.slug
ORDER BY days_scheduled_at_new_location ASC;
```

Barbers with 0 scheduled days at the new location won't appear in booking or fair rotation there. Decide: are they assigned there, or not?

---

## 8. Old phone number / Houston, TX residue

```bash
grep -rEn "302[- ]?998[- ]?0900|302[- ]?369[- ]?0900|302[- ]?555[- ]?" src/ supabase/
grep -rn "Houston, TX" src/ supabase/
```

Expected: zero matches. This rule applies at all times, not just scale. Run the grep to confirm no regression.

---

## 9. Middleware and routing

- File: `src/middleware.ts`
- Must not hardcode location-specific routing. Dynamic slug handling via Next.js `[slug]` patterns is the correct approach.

---

## 10. Cascading deletes awareness

```sql
SELECT conname, confrelid::regclass AS references_table
FROM pg_constraint
WHERE confdeltype = 'c' -- CASCADE delete
  AND confrelid = 'locations'::regclass;
```

All FKs to `locations` cascade on delete. Removing a location deletes:
- `staff_status` rows
- `queue_entries`
- `bookings`
- `academy_sessions`
- `barber_schedules`
- `daily_summaries`

**If the user ever asks to delete a location, warn explicitly:** "This will cascade and delete N bookings, N queue entries, N schedule rows. Back up first. Approve?"

---

## Output verdict template

```
## Locations Scale Readiness — adding location #5

### Ready
- [green items]

### Must fix before go-live
1. [item + reason]

### Recommended cleanup
- [suggestions — e.g., move locationExtras to DB column, refactor static queue pages to catch-all]

### Verdict
[READY / BLOCKED BY N ITEMS]
```
