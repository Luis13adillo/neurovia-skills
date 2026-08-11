# Walk-In Queue Invariants

An invariant is a statement that MUST be true at all times. If a query returns a violation, you have a bug. These are the assertions that protect the queue system's correctness.

Each invariant has a severity:
- **CRITICAL** — customer-visible data corruption or revenue loss
- **HIGH** — will cause incorrect behavior but doesn't lose money directly
- **MEDIUM** — inconsistency that may not be user-visible immediately
- **LOW** — hygiene (test data leaks, dead data)

All SQL is SELECT-only. Run via `mcp__supabase-mt__execute_sql`. Never INSERT / UPDATE / DELETE.

---

## Data-level invariants

### 1. Every active queue entry has a valid location [CRITICAL]
Customers without a location can't be routed, notified, or assigned.
```sql
SELECT qe.id, qe.location_id, qe.status
FROM queue_entries qe
LEFT JOIN locations l ON l.id = qe.location_id
WHERE l.id IS NULL
  AND qe.status IN ('waiting', 'called', 'in_chair');
-- Expected: 0 rows
```

### 2. No two entries `in_chair` for the same barber [CRITICAL]
A barber can only serve one client at a time. Violations mean the state machine or the API guard has been bypassed.
```sql
SELECT assigned_barber_id, COUNT(*) AS active_count,
       array_agg(id) AS entry_ids
FROM queue_entries
WHERE status = 'in_chair'
  AND assigned_barber_id IS NOT NULL
GROUP BY assigned_barber_id
HAVING COUNT(*) > 1;
-- Expected: 0 rows
```

### 3. No barber is both `in_chair` in the queue AND has an active booking [CRITICAL]
Same reason as #2, cross-system.
```sql
SELECT qe.assigned_barber_id, qe.id AS queue_entry_id, b.id AS booking_id
FROM queue_entries qe
JOIN bookings b
  ON b.barber_id = qe.assigned_barber_id
 AND b.status IN ('confirmed', 'in_progress')
 AND b.scheduled_date = (now() AT TIME ZONE 'America/New_York')::date
WHERE qe.status = 'in_chair';
-- Expected: 0 rows (a barber is either serving a walk-in OR a booking, not both)
```

### 4. Every `completed` queue entry has a `service_transactions` row [CRITICAL]
Missing rows = missing revenue audit trail. The trigger should auto-create them.
```sql
SELECT qe.id, qe.end_time, qe.service_amount
FROM queue_entries qe
LEFT JOIN service_transactions st ON st.queue_entry_id = qe.id
WHERE qe.status = 'completed'
  AND st.id IS NULL
  AND qe.end_time > now() - interval '30 days';
-- Expected: 0 rows
```

### 5. Position sequence has no gaps per location [HIGH]
`assign_queue_position` uses a FOR UPDATE lock to serialize position assignment. Gaps indicate either the lock failed or manual SQL writes happened.
```sql
WITH active AS (
  SELECT location_id, position,
         ROW_NUMBER() OVER (PARTITION BY location_id ORDER BY position) AS expected_pos
  FROM queue_entries
  WHERE status IN ('waiting', 'called', 'in_chair')
)
SELECT location_id, position, expected_pos
FROM active
WHERE position != expected_pos;
-- Expected: 0 rows
-- NOTE: If this fires, do NOT rewrite positions from app code. Investigate first.
```

### 6. `called_time` is set only when `status = 'called'` [HIGH]
The field is set at the called transition. If it's populated on a waiting entry or cleared on a called entry, the state machine is leaking.
```sql
SELECT id, status, called_time
FROM queue_entries
WHERE (status = 'called' AND called_time IS NULL)
   OR (status = 'waiting' AND called_time IS NOT NULL);
-- Expected: 0 rows
```

### 7. `start_time` is set only for `in_chair` or later [HIGH]
```sql
SELECT id, status, start_time, end_time
FROM queue_entries
WHERE (status IN ('in_chair', 'completed') AND start_time IS NULL)
   OR (status IN ('waiting', 'called') AND start_time IS NOT NULL);
-- Expected: 0 rows
```

### 8. Completed entries have an `end_time` [HIGH]
```sql
SELECT id, status, end_time
FROM queue_entries
WHERE status = 'completed'
  AND end_time IS NULL;
-- Expected: 0 rows
```

### 9. Test barber IDs are `is_active = false` [HIGH]
Test barbers must be hidden from customers. If any are `is_active = true`, they show up on `/team`, booking flow, and public views.
```sql
SELECT id, is_active
FROM barbers
WHERE id IN (
  'a274e1cf-955a-46f1-bc4c-dcd06a0510af',
  'b0020000-0000-0000-0000-000000000002',
  'b0030000-0000-0000-0000-000000000003',
  'b0040000-0000-0000-0000-000000000004'
)
AND is_active = true;
-- Expected: 0 rows
```

### 10. No test client names in recent production data [LOW]
Tests are supposed to clean up after themselves. Lingering `TEST-` or `TEST_` prefixed rows indicate a test leak.
```sql
SELECT id, client_name, created_at
FROM queue_entries
WHERE (client_name ILIKE 'TEST-%' OR client_name ILIKE 'TEST_%')
  AND created_at > now() - interval '24 hours'
ORDER BY created_at DESC;
-- Expected: 0 rows (or explain to user each one individually)
```

### 11. Walk-in services are `is_active = true` globals [HIGH]
Walk-in queue check-in reads ONLY from `services` where `is_active = true`. The UI pulls this list. No per-barber customization for walk-ins.
```sql
-- Walk-in-reachable services today (sample query)
SELECT id, name, price, is_active
FROM services
WHERE is_active = true
ORDER BY name;
-- Expected: list matches what /queue check-in shows. If they differ, caching or a filter bug.
```

### 12. Newark is closed Sundays in `hours_json` [MEDIUM]
Documented in CLAUDE.md "Multi-Location System." Must be reflected in data.
```sql
SELECT id, name, slug, hours_json
FROM locations
WHERE slug = 'newark';
-- Expected: hours_json.sunday is null, 'Closed', or has is_open=false (inspect the shape you store)
```

### 13. Every active barber has at least one row in `barber_schedules` [MEDIUM]
Otherwise the availability API + fair rotation can silently exclude them.
```sql
SELECT b.id, b.is_active, p.first_name, p.last_name
FROM barbers b
JOIN profiles p ON p.id = b.profile_id
LEFT JOIN barber_schedules bs ON bs.barber_id = b.id AND bs.is_active = true
WHERE b.is_active = true
GROUP BY b.id, p.first_name, p.last_name
HAVING COUNT(bs.id) = 0;
-- Expected: 0 rows
```

### 14. Every barber in `staff_status` is a real, active barber [MEDIUM]
```sql
SELECT ss.barber_id, ss.status
FROM staff_status ss
LEFT JOIN barbers b ON b.id = ss.barber_id
WHERE b.id IS NULL
   OR b.is_active = false;
-- Expected: 0 rows for test_active=true filter; test barbers may appear but are is_active=false
```

### 15. `current_queue_entry_id` on `staff_status` points at real `in_chair` entry [HIGH]
When `staff_status.status = 'with_client'`, the linked queue entry must exist and be `in_chair`.
```sql
SELECT ss.barber_id, ss.status, ss.current_queue_entry_id, qe.status AS qe_status
FROM staff_status ss
LEFT JOIN queue_entries qe ON qe.id = ss.current_queue_entry_id
WHERE ss.status = 'with_client'
  AND (qe.id IS NULL OR qe.status != 'in_chair');
-- Expected: 0 rows
```

### 16. Customer loyalty `visit_count` matches completed entries within a reasonable bound [LOW]
Soft check — not an exact equality (bookings also contribute), but a huge mismatch indicates loyalty accounting drift.

NOTE: schema uses `current_punches` / `total_punches_earned`. CLAUDE.md has doc drift documenting these as `punches_count` / `rewards_earned` — out of scope for this skill.

```sql
-- Eyeball: clients with many queue completions but zero loyalty rows
SELECT c.id, c.phone, c.visit_count, cl.current_punches
FROM clients c
LEFT JOIN customer_loyalty cl ON cl.client_phone = c.phone
WHERE c.visit_count >= 10
  AND (cl.id IS NULL OR cl.current_punches = 0)
LIMIT 20;
-- Expected: none or very few. Investigate if many.
```

### 17. `upsert_client_from_service` consolidates by phone (no duplicates) [MEDIUM]
```sql
SELECT phone, COUNT(*) AS n
FROM clients
WHERE phone IS NOT NULL AND phone != ''
GROUP BY phone
HAVING COUNT(*) > 1;
-- Expected: 0 rows (migration 045 added UNIQUE constraint on phone)
```

---

## Code-level invariants (verify via Read / Grep, not SQL)

### C1. `cache: 'no-store'` wrapper present [CRITICAL]
Files: `src/lib/supabase/admin.ts`, `src/lib/supabase/server.ts`.
Must wrap `global.fetch` with `{ cache: 'no-store' }`. See incidents.md "Fetch Cache Bug."

### C2. `calledClientIdRef` pattern intact [CRITICAL]
Files: `src/app/(dashboard)/barber/walk-ins/page.tsx`, `src/app/(dashboard)/dashboard/my-chair/page.tsx`.
Must use `useRef<string | null>(null)` and set only in `handleCallNext` on API success. No boolean flags, no reset effects. See incidents.md "`calledClientIdRef` Guard Incident."

### C3. In-chair API guard [CRITICAL]
File: `src/app/api/queue/entry/[id]/route.ts` around lines 217-252.
Must block `→in_chair` when another active `in_chair` entry exists for the barber, or an active booking overlaps.

### C4. No dead RPC calls in app code [HIGH]
Grep: `grep -rn "claim_queue_entry\|useIncompleteFlowEntry\|flow_step" src/`.
Expected: zero matches. Any match is 6d4e4ff leakage — see incidents.md "Unauthorized Commit Revert."

### C5. MCP client is `supabase-mt` only [HIGH]
Grep: `grep -rn "mcp__supabase__" .claude/ ~/.claude/`.
Expected: zero matches in THIS project. `mcp__supabase__` is a different (nightclub) project.

### C6. No hardcoded real barber IDs in test files [HIGH]
Run: `npm run test:check-ids` (if present) in the repo. Must exit 0.

### C7. Cross-dashboard code mirroring [HIGH]
When one mirrored file changes (e.g., `barber/walk-ins/page.tsx`), the equivalent file (`dashboard/my-chair/page.tsx`) must receive the same change. Full pair list is in `context-awareness.md`.

### C8. Realtime-enabled tables match expected list [MEDIUM]
Realtime hooks must subscribe to tables that have realtime enabled: `queue_entries`, `staff_status`, `bookings`, `barber_notifications`, `waitlist`. If a new hook subscribes to a table not in this list, realtime won't fire.
