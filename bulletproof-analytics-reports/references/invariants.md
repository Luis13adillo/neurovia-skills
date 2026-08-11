# Analytics & Reports Invariants

Severities: CRITICAL / HIGH / MEDIUM / LOW. All SQL is SELECT-only. Run via `mcp__supabase-mt__execute_sql`.

---

## Code-level

### C1. `export const dynamic = 'force-dynamic'` on every analytics/reports API route [CRITICAL]
```bash
for f in src/app/api/analytics/**/route.ts src/app/api/reports/route.ts src/app/api/dashboard/summary/route.ts src/app/api/activity-feed/route.ts src/app/api/commission/summary/route.ts src/app/api/commission/barber-summary/route.ts src/app/api/barber/analytics/route.ts; do
  grep -L "export const dynamic" "$f"
done
# Expected: empty output
```

### C2. No inline Supabase clients without `cache: 'no-store'` wrapper [CRITICAL]
```bash
grep -rEn "createClient\(['\"]https" src/app/api/analytics src/app/api/reports src/app/api/dashboard src/app/api/activity-feed src/app/api/commission src/app/api/barber/analytics
# Expected: zero hits, OR hits that also wrap global.fetch with cache: 'no-store'
```

### C3. Owner role check on owner-scoped routes [CRITICAL]
```bash
for f in src/app/api/analytics/**/route.ts src/app/api/reports/route.ts src/app/api/dashboard/summary/route.ts src/app/api/activity-feed/route.ts src/app/api/commission/summary/route.ts; do
  grep -L "role.*owner" "$f"
done
# Expected: empty output
```

### C4. Barber scope resolved from auth, not from query param [CRITICAL]
```bash
grep -rEn "searchParams.get\(['\"]barber_id" src/app/api/commission/barber-summary src/app/api/barber/analytics
# Expected: zero hits — barber_id must be resolved from auth.uid() via profiles → barbers.profile_id
```

### C5. Eastern TZ on date aggregation [CRITICAL]
```bash
grep -rEn "toISOString\(\)\.split|\.getDay\(\)|\.getHours\(\)|toTimeString\(\)" src/app/api/analytics src/app/api/reports src/app/api/dashboard src/app/api/activity-feed src/app/api/commission src/app/api/barber/analytics
# Expected: zero hits — all should use timeZone: 'America/New_York'
```

### C6. Soft-deleted bookings excluded [HIGH]
```bash
grep -rEn "\.from\(['\"]bookings['\"]\)" src/app/api/analytics src/app/api/reports src/app/api/dashboard src/app/api/activity-feed | grep -v "deleted_at"
# Expected: every booking query on this surface includes .is('deleted_at', null)
```

### C7. Cross-dashboard mirror parity [HIGH]
Compare file structure, state variables, computed values, and CSV column definitions between each pair:
- `src/app/(dashboard)/dashboard/my-chair/reports/page.tsx` ↔ `src/app/(dashboard)/barber/reports/page.tsx`
- `src/app/(dashboard)/dashboard/my-chair/analytics/page.tsx` ↔ `src/app/(dashboard)/barber/analytics/page.tsx`
- `src/app/(dashboard)/dashboard/my-chair/page.tsx` (home section) ↔ `src/app/(dashboard)/barber/page.tsx`

Use `mirror-check` skill for the structural diff. Differences must be acknowledged as intentional (owner-only feature) or fixed.

### C8. CSV strings escaped [HIGH]
```bash
grep -rEn "\.join\(['\"],['\"]\)" src/app/\(dashboard\)/dashboard/analytics src/app/\(dashboard\)/dashboard/reports
# Expected: inline CSV builders must use the utility OR escape commas/quotes/newlines in values
```
All analytics/reports pages SHOULD use `src/lib/utils/csvExport.ts::exportToCSV`. Flag any inline builders.

### C9. Activity feed source-table limit handling [MEDIUM]
`src/app/api/activity-feed/route.ts` merges 3 parallel queries (queue, bookings, payments). Each sub-query must use the `limit` param proportionally — e.g., for `limit=15`, each sub-query fetches ~15 (then merge+sort+slice to 15). Fetching 5 from each and merging is wrong: a queue-heavy hour would starve bookings from the feed.

### C10. Home-page parallel fetch acknowledgment [LOW]
`/dashboard` home fires independent fetches. Short-lived inconsistency (booking shows in activity feed before appearing in commission summary) is a KNOWN TIMING GAP, not a bug. Document in the audit report as `[KNOWN GAP]` — do not attempt to fix without explicit user approval.

---

## Data-level

### D1. `daily_summaries.total_revenue` reconciles with `service_transactions` [CRITICAL]
```sql
WITH st_agg AS (
  SELECT
    (service_completed_at AT TIME ZONE 'America/New_York')::date AS d,
    barber_id,
    location_id,
    SUM(service_amount) AS st_revenue,
    SUM(tip_amount) AS st_tips,
    COUNT(*) AS st_cuts
  FROM service_transactions
  WHERE payment_status = 'paid'
    AND service_completed_at >= NOW() - INTERVAL '30 days'
  GROUP BY 1, 2, 3
)
SELECT
  ds.date,
  ds.barber_id,
  ds.location_id,
  ds.total_revenue AS ds_revenue,
  st.st_revenue,
  ds.total_tips AS ds_tips,
  st.st_tips,
  ds.total_cuts AS ds_cuts,
  st.st_cuts
FROM daily_summaries ds
JOIN st_agg st ON st.d = ds.date AND st.barber_id = ds.barber_id AND st.location_id = ds.location_id
WHERE (ds.total_revenue <> st.st_revenue
    OR ds.total_tips <> st.st_tips
    OR ds.total_cuts <> st.st_cuts);
-- Expected: 0 rows. Any row is `daily_summaries` drift.
```

### D2. Every completed queue_entry has a `service_transactions` row [CRITICAL]
```sql
SELECT qe.id, qe.client_name, qe.assigned_barber_id, qe.end_time
FROM queue_entries qe
LEFT JOIN service_transactions st ON st.queue_entry_id = qe.id
WHERE qe.status = 'completed'
  AND qe.end_time >= NOW() - INTERVAL '30 days'
  AND st.id IS NULL;
-- Expected: 0 rows. Orphans mean the completion handler didn't INSERT the audit row.
```

### D3. Every completed booking has a `service_transactions` row [CRITICAL]
```sql
SELECT b.id, b.client_name, b.barber_id, b.scheduled_date, b.scheduled_time
FROM bookings b
LEFT JOIN service_transactions st ON st.booking_id = b.id
WHERE b.status = 'completed'
  AND b.deleted_at IS NULL
  AND b.scheduled_date >= CURRENT_DATE - INTERVAL '30 days'
  AND st.id IS NULL;
-- Expected: 0 rows.
```

### D4. No orphan service_transactions rows [HIGH]
```sql
SELECT st.id, st.barber_id, st.location_id, st.service_completed_at
FROM service_transactions st
LEFT JOIN barbers b ON b.id = st.barber_id
LEFT JOIN locations l ON l.id = st.location_id
WHERE b.id IS NULL OR l.id IS NULL;
-- Expected: 0 rows.
```

### D5. `daily_summaries` doesn't reference deleted barbers/locations [HIGH]
```sql
SELECT ds.id, ds.date, ds.barber_id, ds.location_id
FROM daily_summaries ds
LEFT JOIN barbers b ON b.id = ds.barber_id
LEFT JOIN locations l ON l.id = ds.location_id
WHERE b.id IS NULL OR l.id IS NULL;
-- Expected: 0 rows.
```

### D6. Commission totals reconcile [CRITICAL]
```sql
SELECT
  DATE_TRUNC('day', st.service_completed_at AT TIME ZONE 'America/New_York')::date AS d,
  SUM(st.owner_fee_amount) AS st_fees,
  SUM(ds.total_owner_fees) AS ds_fees
FROM service_transactions st
LEFT JOIN daily_summaries ds
  ON ds.date = (st.service_completed_at AT TIME ZONE 'America/New_York')::date
  AND ds.barber_id = st.barber_id
  AND ds.location_id = st.location_id
WHERE st.service_completed_at >= NOW() - INTERVAL '30 days'
  AND st.payment_status = 'paid'
GROUP BY 1
HAVING SUM(st.owner_fee_amount) <> SUM(ds.total_owner_fees);
-- Expected: 0 rows.
```

### D7. No duplicate `service_transactions` per queue_entry/booking [CRITICAL]
```sql
SELECT queue_entry_id, COUNT(*) AS n
FROM service_transactions
WHERE queue_entry_id IS NOT NULL
GROUP BY queue_entry_id
HAVING COUNT(*) > 1
UNION ALL
SELECT booking_id AS id, COUNT(*)
FROM service_transactions
WHERE booking_id IS NOT NULL
GROUP BY booking_id
HAVING COUNT(*) > 1;
-- Expected: 0 rows. Duplicates double-count revenue.
```

### D8. `service_transactions.service_completed_at` is non-null [HIGH]
```sql
SELECT id, barber_id, payment_status, service_amount
FROM service_transactions
WHERE service_completed_at IS NULL;
-- Expected: 0 rows. NULL completion timestamp means the row never flows into daily buckets.
```

### D9. Service transactions indexed for analytics scale [MEDIUM]
```sql
SELECT indexname, indexdef
FROM pg_indexes
WHERE tablename = 'service_transactions';
-- Expected: indexes on (service_completed_at), (barber_id, service_completed_at),
-- (location_id, service_completed_at). Missing any of these → sequential scan at scale.
```

### D10. `daily_summaries` UNIQUE(date, barber_id, location_id) [HIGH]
```sql
SELECT date, barber_id, location_id, COUNT(*) AS n
FROM daily_summaries
GROUP BY date, barber_id, location_id
HAVING COUNT(*) > 1;
-- Expected: 0 rows. Duplicate summary rows = double-counted revenue in reports.
```

### D11. Home-summary revenue matches reports revenue (single-day spot check) [HIGH]
Run the same date through both code paths:
```sql
-- Reports path: service_transactions sum for a given date
SELECT
  SUM(service_amount) AS reports_revenue,
  SUM(tip_amount) AS reports_tips,
  COUNT(*) AS reports_cuts
FROM service_transactions
WHERE (service_completed_at AT TIME ZONE 'America/New_York')::date = CURRENT_DATE
  AND payment_status = 'paid';

-- Home path: daily_summaries sum for the same date
SELECT
  SUM(total_revenue) AS home_revenue,
  SUM(total_tips) AS home_tips,
  SUM(total_cuts) AS home_cuts
FROM daily_summaries
WHERE date = CURRENT_DATE;
-- Expected: identical numbers. Drift = update_daily_summary missed a write.
```

### D12. Activity feed source tables have indexed timestamps [MEDIUM]
```sql
SELECT tablename, indexname, indexdef
FROM pg_indexes
WHERE tablename IN ('queue_entries', 'bookings', 'service_transactions')
  AND indexdef ~* '(check_in_time|end_time|scheduled_date|service_completed_at)';
-- Expected: indexes present. Without them, the 3 merged queries scan full tables.
```

---

## Severity summary

| Sev | Count | If failing |
|---|---|---|
| CRITICAL | 7 (C1, C2, C3, C4, C5, D1, D2, D3, D6, D7) | STOP. Owner-visible wrong numbers or revenue loss risk. Fix before next use. |
| HIGH | 7 (C6, C7, C8, D4, D5, D8, D10, D11) | STOP. Drift risk. Fix this sprint. |
| MEDIUM | 3 (C9, D9, D12) | FLAG. Scale risk. Plan a fix before next location. |
| LOW | 1 (C10) | DOCUMENT. Known timing gap, not a bug. |
