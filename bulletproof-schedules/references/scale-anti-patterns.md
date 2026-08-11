# Schedules Scale Anti-Patterns

Run in `scale-check` mode. Report-only — never auto-fix.

---

## 1. `locations[0]` fallback in schedule UI

```bash
grep -rn "locations\[0\]" src/app/\(dashboard\)/barber/schedule/ src/app/\(dashboard\)/dashboard/my-chair/schedule/
```

Known safe matches (the API ignores `locationId` in request body, so these don't persist):
- `src/app/(dashboard)/barber/schedule/page.tsx:372, 397`
- `src/app/(dashboard)/dashboard/my-chair/schedule/page.tsx:427, 600`

**Note in report:** "Fallback defaults exist but do NOT persist. Safe. Location edits must go through the location-request workflow, not the schedule route."

If the grep returns unexpected files, flag them.

---

## 2. Hardcoded day-of-week business logic

```bash
grep -rEn "dayOfWeek[[:space:]]*===?[[:space:]]*[0-6]|getDay\(\)[[:space:]]*===?[[:space:]]*[0-6]" src/
```

Expected: utility functions mapping day numbers. Flag anything that encodes business rules (e.g., "if Sunday, closed"). Those belong in `locations.hours_json`.

---

## 3. `preferred_location_id` column

```sql
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'barbers' AND column_name = 'preferred_location_id';
```

If 0 rows: MUST FIX before scale. Code assumes this column exists. Without it, schedule saves break for any barber needing the fallback (new days without a prior row AND no staff_status row).

**Recommend:** creating an explicit migration so fresh environments work. Don't apply without user approval.

---

## 4. Schedule coverage for active barbers

```sql
-- Active barbers with fewer than 3 active days of schedule
SELECT b.id, b.slug, p.first_name, p.last_name, COUNT(bs.id) AS scheduled_days
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
LEFT JOIN barber_schedules bs ON bs.barber_id = b.id AND bs.is_active = true
WHERE b.is_active = true
GROUP BY b.id, b.slug, p.first_name, p.last_name
HAVING COUNT(bs.id) < 3
ORDER BY scheduled_days ASC;
```

Before adding location #5, decide: will existing barbers move days to the new location, or are you hiring new barbers? Either way, verify each barber has schedule coverage that reflects their intended working pattern.

---

## 5. Location change request backlog

```sql
SELECT l.name AS requested_location, COUNT(*) AS pending_requests
FROM location_change_requests lcr
JOIN locations l ON l.id = lcr.requested_location_id
WHERE lcr.status = 'pending'
GROUP BY l.name;
```

If the new location has a backlog of pending requests, process them before go-live so rotation is correct on day one.

---

## 6. Hardcoded slugs in schedule UI

```bash
grep -rEn "'wilmington'|\"wilmington\"|'newark'|\"newark\"|'new-castle'|\"new-castle\"" src/app/\(dashboard\)/barber/schedule/ src/app/\(dashboard\)/dashboard/my-chair/schedule/
```

Expected: zero matches (schedule UI should be slug-agnostic, reading from `locations` table). Any match is suspect.

---

## 7. Availability API location resolution

Check `src/app/api/bookings/availability/route.ts` — when a new location is added, the availability API must resolve the barber's location for the given date via `barber_schedules` (it does). Verify no hardcoded location-by-day logic exists in the file.

---

## Output verdict template

```
## Schedules Scale Readiness — adding location #5

### Safe
- [list green items]

### Must fix before go-live
1. [file:line or missing artifact] — [reason]

### Recommended (not blocking)
- [suggestions]

### Verdict
[READY / BLOCKED BY N ITEMS]
```
