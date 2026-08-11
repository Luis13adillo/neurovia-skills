# Services Invariants

Severities: CRITICAL / HIGH / MEDIUM / LOW. All SQL is SELECT-only.

---

## Data-level

### 1. FK delete rules on service consumers are uniformly SET NULL [CRITICAL]
```sql
SELECT tc.table_name, kcu.column_name, rc.delete_rule
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu ON tc.constraint_name = kcu.constraint_name
JOIN information_schema.referential_constraints rc ON tc.constraint_name = rc.constraint_name
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND tc.table_schema = 'public'
  AND tc.table_name IN ('bookings', 'queue_entries', 'service_transactions')
  AND kcu.column_name IN ('service_id', 'custom_service_id');
-- Expected: 4 rows, delete_rule='SET NULL' for each
-- (bookings.service_id, bookings.custom_service_id, queue_entries.service_id,
--  service_transactions.service_id)
-- See incidents.md "CASCADE on bookings.service_id (pre-2026-04-21)"
```

### 2. No orphan service refs [CRITICAL]
```sql
SELECT id FROM bookings
WHERE service_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM services s WHERE s.id = bookings.service_id)
  AND deleted_at IS NULL;
-- Expected: 0 rows

SELECT id FROM bookings
WHERE custom_service_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM barber_custom_services c WHERE c.id = bookings.custom_service_id)
  AND deleted_at IS NULL;
-- Expected: 0 rows
```

### 3. Active booking duration matches source service duration [HIGH]
Duration is frozen at creation. Active bookings should still match the current service duration unless the service was edited mid-flight (rare but possible). Completed bookings with mismatched duration are expected and fine.
```sql
SELECT b.id FROM bookings b
JOIN services s ON b.service_id = s.id
WHERE b.duration_minutes != s.duration_minutes
  AND b.status IN ('pending','confirmed','in_progress')
  AND b.deleted_at IS NULL;
-- Expected: 0 rows (or very few — flag for investigation)
```

### 4. No null / zero duration on active bookings or queue entries [HIGH]
```sql
SELECT id FROM bookings
WHERE (duration_minutes IS NULL OR duration_minutes = 0)
  AND status IN ('pending','confirmed','in_progress')
  AND deleted_at IS NULL;
-- Expected: 0 rows
```

### 5. Sensible duration range on active services and custom services [MEDIUM]
```sql
SELECT id, name, duration_minutes FROM services
WHERE is_active = true AND (duration_minutes < 10 OR duration_minutes > 180);
-- Expected: 0 rows

SELECT id, name, duration_minutes FROM barber_custom_services
WHERE is_active = true AND (duration_minutes < 10 OR duration_minutes > 180);
-- Expected: 0 rows
```

### 6. Sensible prices (> 0, <= $500) [MEDIUM]
Three places a price can drift: `services.price`, `barber_custom_services.price`, `barber_services.custom_price`. Prices at $0 or above $500 are suspect.

### 7. No duplicate active custom services per barber (by name) [HIGH]
```sql
SELECT barber_id, lower(trim(name)), COUNT(*) FROM barber_custom_services
WHERE is_active = true GROUP BY 1,2 HAVING COUNT(*) > 1;
-- Expected: 0 rows
```

### 8. Upsell rules reference only active services [MEDIUM]
Silent failure: inactive service on an upsell rule means the rule never triggers.
```sql
SELECT ur.id FROM upsell_rules ur
LEFT JOIN services ts ON ts.id = ur.trigger_service_id
LEFT JOIN services ss ON ss.id = ur.suggested_service_id
WHERE ur.is_active = true
  AND (ts.id IS NULL OR ss.id IS NULL OR ts.is_active = false OR ss.is_active = false);
-- Expected: 0 rows
```

### 9. RLS enabled on all three service tables [HIGH]
```sql
SELECT c.relname, c.relrowsecurity FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN ('services','barber_services','barber_custom_services');
-- Expected: rls_enabled = true for all three
```

### 10. Required RLS policies exist [HIGH]
- `services` → `Owner full access to services` (ALL via `is_owner()`)
- `services` → public `SELECT` policy for `is_active=true`
- `barber_custom_services` → barber-scoped INSERT / UPDATE / DELETE via `barbers.profile_id = auth.uid()`
- `barber_custom_services` → public `SELECT` for `is_active=true`
- `barber_services` → public `SELECT` (writes go through admin-key API route only)

### 11. Category values are within the documented enum [LOW]
Documented: `haircuts`, `beard`, `combos`, `grooming`, `linework`, `specialty`, `color`, `treatments`, `addons`, `hair` (legacy alias), `combo` (legacy alias).

### 12. barber_services.custom_price, if set, is in sane range [MEDIUM]
```sql
SELECT * FROM barber_services WHERE custom_price IS NOT NULL
  AND (custom_price <= 0 OR custom_price > 500);
-- Expected: 0 rows
```

---

## Code-level (verify via Read / Grep)

### C1. Walk-in check-in reads ONLY global services [CRITICAL]
- File: `src/app/(public)/queue/page.tsx` → `useServices(true)` from `src/lib/hooks/useServices.ts`.
- Hook filters `is_active = true` and queries only the `services` table.
- Must NOT reference `barber_services` or `barber_custom_services` anywhere in the walk-in path.
- Per CLAUDE.md HARD RULE: walk-in = business services only. Uniform across barbers.

### C2. Booking wizard reads barber-scoped services [CRITICAL]
- File: `src/app/(public)/book/page.tsx` → calls `/api/barber/services?barber_id=...`.
- API: `src/app/api/barber/services/route.ts` GET
  - Joins `barber_services` → `services` with `is_active = true`.
  - Applies `custom_price` override when present.
  - Appends `barber_custom_services` where `is_active = true`.
  - Returns merged array (with a `source` field to distinguish).
- Must NOT return another barber's services.

### C3. Booking POST routes to correct column [CRITICAL]
- File: `src/app/api/bookings/route.ts`
- When creating a booking:
  1. Look up service_id in `services`. If found, set `service_id`, leave `custom_service_id=NULL`.
  2. Else look up in `barber_custom_services`. If found, set `custom_service_id`, leave `service_id=NULL`.
  3. Else 400. Never store both columns non-null.
- `duration_minutes` and `service_amount` copied from the matched source at write time (frozen snapshot).

### C4. Public profile merges both sources [HIGH]
- File: `src/app/(public)/mtbarbers/[slug]/page.tsx`
- Must use a Supabase client that wraps fetch with `cache: 'no-store'` (Next.js 14 Data Cache rule — see MEMORY.md).
- Merges `barber_services` (with `custom_price` applied) + `barber_custom_services`.

### C5. Three separate service management UIs write to three scopes [CRITICAL]
- Owner walk-in: `src/app/(dashboard)/dashboard/services/page.tsx` → `useServices` hook writes to `services` ONLY.
- Barber personal: `src/app/(dashboard)/barber/settings/page.tsx` Services tab → POST `/api/barber/services` writes to `barber_services` ONLY. Custom via `/api/barber/custom-services`.
- Owner personal: `src/app/(dashboard)/dashboard/my-chair/services/page.tsx` → same APIs, scoped to owner's barber_id.
- Any UI that writes across tiers is a CRITICAL bug.

### C6. Duration is frozen at row creation [HIGH]
- `bookings.duration_minutes` and `queue_entries.duration_minutes` are set at POST / check-in.
- No trigger or cron should retroactively update these.
- Grep for any UPDATE to these columns with `duration_minutes` — flag if found.
```bash
grep -rn "duration_minutes" src/app/api/ | grep -iE "update|set duration"
```

### C7. Availability API respects duration and Eastern TZ [CRITICAL]
- File: `src/app/api/bookings/availability/route.ts`
- Reads `duration` query param (default 30). Uses it for slot size.
- Busy list includes: `confirmed`, `pending`, `in_progress` bookings + `in_chair` queue entries.
- Every date/time operation uses `timeZone: 'America/New_York'` (see MEMORY.md Booksy TZ Rule).
- Grep for raw `toISOString().split('T')[0]`, `getDay()`, `getHours()`, `toTimeString()` without `toLocaleXxx('…', { timeZone: 'America/New_York' })` upstream.

### C8. Exclusion constraint `bookings_no_time_overlap` exists [HIGH]
- DB-level safety net (migration `20260401000000_booking_overbooking_constraint.sql`).
- Verify:
```sql
SELECT conname FROM pg_constraint WHERE conname = 'bookings_no_time_overlap';
-- Expected: 1 row
```

### C9. In-Service Mode uses stored duration [HIGH]
- File: `src/components/dashboard/InServiceMode.tsx` (shared).
- Timer math uses the queue entry's / booking's `duration_minutes`.
- Not a live service lookup (would drift if the owner edited the service mid-service).

### C10. Cross-dashboard services UI mirror intact [HIGH]
- `src/app/(dashboard)/dashboard/my-chair/services/page.tsx`
- `src/app/(dashboard)/barber/settings/page.tsx` Services tab
- Same features, same API endpoints, same category accordions (per Cross-Dashboard Mirroring Rule).

### C11. Supabase client factories include `cache: 'no-store'` [HIGH]
- `src/lib/supabase/admin.ts`
- `src/lib/supabase/server.ts`
- Any inline `createClient()` in API routes that read services must match.
- Critical because Next.js 14's Data Cache will serve stale service rows without this.

### C12. `barber_custom_services` writes use `(supabase as any)` type assertion [LOW]
- The table is not in generated Supabase types (per MEMORY.md).
- Any server-side write must cast to `any`. This is a known annoyance, not a bug.

---

## Propagation-level

### P1. Service edit on admin UI updates future-only behavior [HIGH]
- Walk-in / booking / profile consumers must see the change on next page load.
- Existing `queue_entries` / `bookings` must NOT change — that would mutate in-flight work.

### P2. Service soft-delete (is_active=false) hides from consumers [HIGH]
- `useServices(true)` and all public queries filter `is_active=true`.
- Active bookings that reference a deactivated service remain valid (duration / name / price already stored).

### P3. Service hard-delete nulls the FK [CRITICAL]
- Post-2026-04-21: all four consumer FKs are SET NULL.
- Booking keeps its duration / amount — the only thing lost is the link to the (now-deleted) service.
- If someone ever re-introduces CASCADE on `bookings.service_id`, future bookings vanish on service delete.

### P4. SWR cache invalidated on admin mutation [MEDIUM]
- `useServices` calls `mutate()` after insert / update / delete.
- If a screen stays stale, the culprit is usually a missing `mutate()` call in a newer CRUD path.

---

## Security

### S1. Owner-only writes to global services [CRITICAL]
- RLS policy `Owner full access to services` uses `is_owner()` function.
- Any authenticated user without owner role cannot write.

### S2. Barber can only write their own custom services [CRITICAL]
- RLS policies scope INSERT/UPDATE/DELETE via `barber_id IN (SELECT id FROM barbers WHERE profile_id = auth.uid())`.
- Cross-barber write attempts silently fail.

### S3. `barber_services` writes go only through authenticated API route [HIGH]
- Table has no INSERT/UPDATE/DELETE RLS policies.
- All writes via `/api/barber/services` POST, which derives `barber_id` server-side from `user.id`.
- A barber cannot pass a different barber's ID in the request body — the route ignores it.
