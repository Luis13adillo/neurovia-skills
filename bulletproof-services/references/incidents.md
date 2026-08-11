# Services Incident Registry

---

## CASCADE on bookings.service_id (commit `fb35208`, 2026-04-21)

**Symptom (latent — never triggered in production):**
- Owner deletes a walk-in service from `/dashboard/services` expecting the service to just go away
- Instead, every future `bookings` row that referenced that service is silently wiped out (cascade delete)
- No audit log entry, no confirmation — bookings disappear
- Customers show up for appointments that no longer exist in the system

**Why it was latent:**
The `useServices.deleteService()` hook uses a SOFT-delete (`UPDATE services SET is_active=false`) — it never issued a hard DELETE, so the cascade never fired. But the FK was a loaded gun: a future admin tool, a manual SQL cleanup, or a seed-script re-run could have pulled the trigger.

**Root cause:**
Original `bookings_service_id_fkey` was created with `ON DELETE CASCADE` while the three sibling FKs (`bookings.custom_service_id`, `queue_entries.service_id`, `service_transactions.service_id`) all used `ON DELETE SET NULL`. Inconsistent delete semantics across similar columns.

**Fix:**
Migration `supabase/migrations/20260421030000_fix_bookings_service_id_cascade.sql` drops the old FK and recreates it with `ON DELETE SET NULL`. Now, when a service is hard-deleted, the booking row keeps its stored `duration_minutes`, `service_amount`, and `service_name` (on `service_transactions`) — only the FK link is nulled.

**Diagnose query:**
```sql
SELECT tc.table_name, kcu.column_name, rc.delete_rule
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu ON tc.constraint_name = kcu.constraint_name
JOIN information_schema.referential_constraints rc ON tc.constraint_name = rc.constraint_name
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND tc.table_schema = 'public'
  AND tc.table_name IN ('bookings','queue_entries','service_transactions')
  AND kcu.column_name IN ('service_id','custom_service_id');
-- Expected: 4 rows, delete_rule='SET NULL' for each.
-- If ANY row shows CASCADE, regression — re-apply the migration.
```

---

## "Delete-then-insert" race in `/api/barber/services` POST

**Symptom:**
- Barber saves their service selections on `/barber/settings?tab=services`
- Save returns success
- Opening the page again shows zero services (the screen went blank)
- SMS / booking availability shows "no services offered" for that barber

**Root cause:**
`src/app/api/barber/services/route.ts` POST handler:
1. DELETEs all `barber_services` rows for the barber.
2. INSERTs new rows for the submitted selections.

If the request payload arrives empty (UI bug, race, edge case) OR the INSERT fails transiently between step 1 and step 2, the barber ends up with zero services. No transaction wraps the two operations.

**Mitigation (not yet implemented):**
Wrap the delete + insert in a Supabase transaction (RPC function), OR diff the submitted set against current rows and only apply the diff.

**Diagnose:**
```sql
SELECT bs.barber_id, b.slug, COUNT(bs.service_id) AS global_links,
       (SELECT COUNT(*) FROM barber_custom_services c WHERE c.barber_id = bs.barber_id AND c.is_active = true) AS custom_count
FROM barber_services bs
LEFT JOIN barbers b ON b.id = bs.barber_id
GROUP BY bs.barber_id, b.slug
HAVING COUNT(bs.service_id) = 0;
-- Active barbers with 0 global service links — check if that's intentional.
```

If a barber reports "all my services disappeared," read the audit log in `/dashboard/auth-log` (service edits are logged there) and re-save.

---

## `barber_custom_services` not in generated Supabase types (2026-03-06)

**Symptom:**
- TypeScript build fails with `Property 'barber_custom_services' does not exist on type 'SupabaseClient'`
- Developer added `import type { Database } from '@/lib/types/database'` and the table is missing

**Root cause:**
The Supabase types generator did not pick up the table from migration `20260306223406_create_barber_custom_services.sql`. Per MEMORY.md, the workaround is `(supabase as any)` type assertion on every server-side read/write.

**Resolution (not yet done):**
Re-run `npx supabase gen types typescript --local > src/lib/types/database.ts` against the production DB, commit, and remove the `as any` casts.

**Do NOT:**
- Manually edit `database.ts` to add the table.
- Silently add `as any` without noting it.

---

## Service name collision between walk-in and barber custom (2026-03-12 unified customization)

**Symptom (not a bug — intentional):**
- A customer books "Men's Haircut" on the owner's profile and pays $80.
- A walk-in customer at the same location pays $40 for "Men's Haircut."
- Customers compare notes, confusion ensues.

**Root cause:**
- Walk-in services are uniform across barbers/locations at owner-set prices.
- Owner's personal booking services (`barber_custom_services`) can have any price the owner picks.
- If both are named "Men's Haircut," the customer has no clue the price difference is tier-based, not location-based.

**Mitigation:**
Encourage the owner to rename his personal booking services distinctively (e.g., "Men's Regular Haircut" — as he already does per the audit of 2026-04-21). Skill `audit` query #20 flags name collisions as a warning.

---

## Duration edit expected to propagate retroactively (UX expectation, not a bug)

**Symptom:**
- Owner edits "Men's Haircut" duration from 45 min → 60 min.
- Existing booking scheduled for tomorrow still shows 45 min on the calendar.
- Owner reports "the duration didn't save."

**Root cause:**
This is intentional. `bookings.duration_minutes` is frozen at creation. Retroactive update would mutate confirmed customer appointments mid-flight, overlap with adjacent bookings, and surprise both the customer and the barber.

**Resolution:**
Explain to the owner: edits apply to NEW bookings only. If they want to change an existing booking's duration, they must edit the booking directly in the calendar.

**DO NOT:**
- "Fix" this by adding a cron or trigger that syncs duration retroactively.
- Recommend the owner delete-and-recreate future bookings.

---

## Quick Match Table

| Symptom | Likely incident | First file to read |
|---|---|---|
| Owner deleted service and bookings disappeared | CASCADE regression (pre-fb35208) | FK rules query above |
| Barber saved services, now all empty | delete-then-insert race | `src/app/api/barber/services/route.ts` POST |
| TS error on barber_custom_services | types not regenerated | `src/lib/types/database.ts` |
| Customer confused by different prices for same service name | intentional name collision | audit query #20 |
| Duration edit didn't update existing booking | frozen-at-creation (intentional) | explain, don't fix |
| Custom service missing from profile | `is_active=false` OR RLS select fail | `barber_custom_services` SELECT policy |
| Availability slots overlap existing bookings | `in_progress` missing from busy list OR TZ bug | `src/app/api/bookings/availability/route.ts` |
| Walk-in shows barber's custom price | wrong hook in queue page | `src/app/(public)/queue/page.tsx` |
| Booking POST returned 400 "unknown service" | service_id not in services AND not in barber_custom_services | lookup logic in `src/app/api/bookings/route.ts` |
