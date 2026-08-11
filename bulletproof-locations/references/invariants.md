# Locations Invariants

All SQL is SELECT-only. Run via `mcp__supabase-mt__execute_sql`.

---

## Data-level

### 1. Exactly 3 active locations with canonical slugs [CRITICAL]
```sql
SELECT slug, is_active
FROM locations
WHERE is_active = true
ORDER BY slug;
-- Expected: exactly 3 rows with slugs: new-castle, newark, wilmington
```

### 2. Wilmington canonical data [CRITICAL]
```sql
SELECT slug, name, address, city, state, zip, phone
FROM locations
WHERE slug = 'wilmington';
-- Expected:
--   name: Wilmington
--   address: 3616 Kirkwood Hwy
--   city: Wilmington
--   state: DE
--   zip: 19808
--   phone: (302) 983-2621 (or 3029832621 / 302-983-2621 depending on format)
```

### 3. Newark canonical data [CRITICAL]
```sql
SELECT slug, name, address, city, state, zip, phone, hours_json->>'sunday' AS sunday_hours
FROM locations
WHERE slug = 'newark';
-- Expected:
--   name: Newark
--   address: 73 Marrows Rd
--   city: Newark
--   state: DE
--   zip: 19713
--   phone: (302) 294-1909
--   sunday_hours: null (closed)
```

### 4. New Castle canonical data [CRITICAL]
```sql
SELECT slug, name, address, city, state, zip, phone
FROM locations
WHERE slug = 'new-castle';
-- Expected:
--   name: New Castle
--   address: 101 Penn Mart Shopping Ctr
--   city: New Castle
--   state: DE
--   zip: 19720
--   phone: (302) 983-2621
```

### 5. No deprecated phone numbers in DB [HIGH]
```sql
SELECT id, slug, phone
FROM locations
WHERE phone SIMILAR TO '%(998[- ]?0900|369[- ]?0900|555[- ]?[0-9]{4})%';
-- Expected: 0 rows
```

### 6. hours_json has all 7 days (keys present) [HIGH]
```sql
SELECT slug,
       hours_json ? 'monday'    AS has_monday,
       hours_json ? 'tuesday'   AS has_tuesday,
       hours_json ? 'wednesday' AS has_wednesday,
       hours_json ? 'thursday'  AS has_thursday,
       hours_json ? 'friday'    AS has_friday,
       hours_json ? 'saturday'  AS has_saturday,
       hours_json ? 'sunday'    AS has_sunday,
       hours_json ? 'max_queue_size' AS has_max_queue_size
FROM locations
WHERE is_active = true;
-- Expected: all columns true for every row
```

### 7. Slugs are unique [CRITICAL]
```sql
SELECT slug, COUNT(*) AS n
FROM locations
GROUP BY slug
HAVING COUNT(*) > 1;
-- Expected: 0 rows
```

### 8. accepts_walk_ins set for all active locations [MEDIUM]
```sql
SELECT id, slug, accepts_walk_ins
FROM locations
WHERE is_active = true
  AND accepts_walk_ins IS NULL;
-- Expected: 0 rows (null means no explicit decision; true/false must be set)
```

### 9. State is "DE" for all MT locations [MEDIUM]
```sql
SELECT id, slug, state
FROM locations
WHERE is_active = true
  AND state != 'DE';
-- Expected: 0 rows (MT operates only in Delaware)
```

### 10. No "Houston, TX" in locations table [HIGH]
```sql
SELECT id, name, city, state, address
FROM locations
WHERE city ILIKE '%houston%'
   OR state = 'TX'
   OR address ILIKE '%houston%';
-- Expected: 0 rows
```

---

## Code-level (verify via Read / Grep)

### C1. FALLBACK_LOCATIONS matches DB [HIGH]
- File: `src/lib/utils/locations.ts`
- The `FALLBACK_LOCATIONS` array is a safety net. Should match canonical values to avoid stale first-paint.
- Manual comparison: read file → compare to query result from invariants 2-4.

### C2. No banned phone numbers in source code [CRITICAL]
```bash
grep -rEn "302[- ]?998[- ]?0900|302[- ]?369[- ]?0900|302[- ]?555[- ]?[0-9]{4}" src/
```
Expected: zero matches.

### C3. No "Houston, TX" in source code [HIGH]
```bash
grep -rn "Houston, TX\|Houston,TX" src/
```
Expected: zero matches.

### C4. No hardcoded addresses in email/SMS templates [HIGH]
```bash
grep -rn "Kirkwood Hwy\|Marrows Rd\|Penn Mart" src/lib/email src/lib/twilio
```
Expected: zero matches. Addresses come from `locations.address` via template variables.

### C5. `resolveBarberLocation()` intact [HIGH]
- File: `src/lib/db/location.ts`
- Modes `current` and `appointment` with documented priority chains.
- Always uses `timeZone: 'America/New_York'` for date resolution.

### C6. Public `/locations` page reads from DB [MEDIUM]
- File: `src/app/(public)/locations/page.tsx`
- Uses `useLocations()` hook. Not hardcoded.
- `locationExtras` object keyed by slug is acceptable (UI-only extras like plaza name, map URL).

### C7. Middleware does NOT hardcode location slugs in routing [HIGH]
- File: `src/middleware.ts`
- Should not contain `if (slug === 'newark') ...` patterns.

### C8. Canonical values match MEMORY.md + CLAUDE.md [HIGH]
- Compare DB query results to the "Location Data — CANONICAL" entry in MEMORY.md and the "Multi-Location System" section of CLAUDE.md.
- Flag any drift.
