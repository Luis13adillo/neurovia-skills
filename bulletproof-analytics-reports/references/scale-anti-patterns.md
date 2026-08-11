# Scale Anti-Patterns — Analytics & Reports

Flag these when running `scale-check` mode. Each is a blocker or a yellow flag before adding a 5th location or scaling past ~10 active barbers.

---

## A1. Hardcoded barber or location IDs in SQL [BLOCKER]

```bash
grep -rEn "b001[0-9a-f]+|b002[0-9a-f]+|b003[0-9a-f]+|b004[0-9a-f]+|a274e1cf-955a-46f1-bc4c-dcd06a0510af" src/app/api/analytics src/app/api/reports src/app/api/dashboard src/app/api/commission src/app/api/barber/analytics
```

Any hit is a scale blocker — analytics will miss new barbers entirely or double-count the hardcoded one.

---

## A2. `locations[0]` or `barbers[0]` fallback [BLOCKER]

```bash
grep -rEn "locations\[0\]|barbers\[0\]" src/app/\(dashboard\)/dashboard/analytics src/app/\(dashboard\)/dashboard/reports src/app/\(dashboard\)/dashboard/my-chair src/app/\(dashboard\)/barber
```

Defaulting to the first location means with 5 locations, 80% of analytics views start on the wrong one. Same for barbers.

---

## A3. Per-barber loop over Supabase [BLOCKER]

```bash
grep -rB 2 -A 5 "for.*const.*of.*barbers" src/app/api/analytics src/app/api/reports src/app/api/dashboard | grep -B 5 "supabase"
```

Any per-barber query inside a loop is O(N) at request time. The `/api/analytics/barber-comparison` and `/api/analytics/workload` routes are highest risk. Replace with a single SQL aggregation grouped by `barber_id`.

---

## A4. Per-location Promise.all fan-out [YELLOW]

```bash
grep -rEn "Promise\.all.*locations\.map" src/app/api/dashboard src/app/api/analytics src/app/api/reports
```

`/api/dashboard/summary` computes per-location summaries. If it fans out via `Promise.all(locations.map(l => supabase.from(...)))`, each location adds ~40ms round-trip. At 5 locations, that's 200ms serial-equivalent on the critical path for the dashboard home. Prefer one `GROUP BY location_id` query.

---

## A5. Missing `service_transactions` index coverage [YELLOW]

```sql
SELECT indexname FROM pg_indexes WHERE tablename = 'service_transactions';
```

Required at scale:
- `(service_completed_at)` — all time-range queries
- `(barber_id, service_completed_at)` — per-barber analytics
- `(location_id, service_completed_at)` — per-location analytics
- `(payment_status, service_completed_at)` WHERE `payment_status = 'paid'` — partial index for reports

Missing any → sequential scan on every analytics query. At 50k+ rows (≈6 months of full volume with 4 locations), queries start to feel slow.

---

## A6. `/api/activity-feed` limit cap at 50 [YELLOW]

Current max is 50. With 4+ locations, an owner catching up after a morning might want 100+. Not a blocker — but flag for UX review. Options: pagination, date scoping (`from=<ts>`), or per-event-type scoped feeds.

---

## A7. `daily_summaries` upsert contention [YELLOW]

`update_daily_summary` is called from every completion path. At 200+ completions/day across 4 locations, concurrent calls on the same `(date, barber_id, location_id)` row can contend. Confirm the function uses an UPSERT (`INSERT ... ON CONFLICT UPDATE`) and not a read-aggregate-write pattern inside a transaction.

```sql
SELECT pg_get_functiondef('update_daily_summary'::regproc);
```

Look for `ON CONFLICT` clause. If missing, risk of lost writes under concurrency.

---

## A8. 1-year Recharts dataset [YELLOW]

`/dashboard/analytics?period=1y` renders ~365 daily buckets. Recharts can handle this, but animations stutter on mid-tier mobile devices. 70%+ of traffic is mobile per CLAUDE.md. Options:
- Downsample server-side (daily → weekly buckets for period ≥1y)
- Memoize chart data with `useMemo`
- Disable animations on period ≥1y

Not a correctness bug — a perceived quality bug at scale.

---

## A9. Inline CSV builders concatenate without escaping [BLOCKER for data fidelity]

```bash
grep -rEn "\.join\(['\"],['\"]\)" src/app/\(dashboard\)/dashboard/analytics src/app/\(dashboard\)/dashboard/reports src/app/\(dashboard\)/barber
```

Every inline CSV builder that doesn't quote values breaks as soon as a client name has a comma. At 4+ locations the probability of hitting this in a given week approaches 1.

Fix via Pattern 5 — route through `exportToCSV`.

---

## A10. Activity feed sub-query limits [YELLOW]

`/api/activity-feed` runs 3 parallel queries (queue, bookings, service_transactions). If each fetches a fixed 5 and the merged result trims to `limit`, a queue-heavy morning starves the feed of booking events. The correct pattern is to fetch `limit` from each sub-query, then merge and trim.

Verify in `src/app/api/activity-feed/route.ts`:
- Sub-query `.limit(limit)` NOT `.limit(5)`

---

## A11. Inconsistent TZ between page and export [BLOCKER for trust]

If `/dashboard/reports` shows today's totals using Eastern TZ on-screen but the CSV export uses UTC dates, rows cross midnight boundaries differently. Invariant C5 covers the API side, but also grep the page files:

```bash
grep -rEn "toISOString\(\)\.split|\.getDay\(\)|\.getHours\(\)" src/app/\(dashboard\)/dashboard/analytics src/app/\(dashboard\)/dashboard/reports src/app/\(dashboard\)/dashboard/my-chair src/app/\(dashboard\)/barber
```

Zero hits expected.

---

## A12. Mirror drift between owner-personal and barber pages [BLOCKER for consistency]

At scale, every barber uses `/barber/reports` and `/barber/analytics`. The owner uses the mirror pair `/dashboard/my-chair/*`. If they drift, a barber sees behavior different from what the owner sees in their own view — bug reports become "why does mine show X but Gustavo's shows Y?"

Always invoke `mirror-check` skill as part of scale-check.

---

## Scale-check output template

```
## Analytics & Reports Scale-Check — [YYYY-MM-DD]
### Context: preparing to add location #5 / barber #N+1

### BLOCKERS (must fix before)
- [list items A1, A2, A3, A9, A11, A12 if failing]

### YELLOW FLAGS (plan before scaling further)
- [A4, A5, A6, A7, A8, A10]

### Verified clean
- [items that passed]

### Recommended sequence
1. Fix blockers
2. Profile /api/dashboard/summary response time with test data at new scale
3. Profile /api/analytics?period=90d and ?period=1y
4. Run mirror-check on reports + analytics pages
5. Confirm D9 (index coverage) still green after new data volume
```
