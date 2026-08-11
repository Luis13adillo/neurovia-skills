# Analytics & Reports — Canonical Fix Patterns

Only applied in `fix` mode, one pattern per invocation, after explicit user approval. Each pattern names the exact files, exact diff, exact post-fix verification.

---

## Pattern 1 — Add `dynamic = 'force-dynamic'` to a cached analytics/reports route

**Symptom:** Owner refreshes `/dashboard/analytics` and sees yesterday's numbers until a hard refresh.

**Root cause:** Route is missing the dynamic export. Vercel caches the first response.

**Target files:** any file under `src/app/api/analytics/**/route.ts`, or `/api/reports`, `/api/dashboard/summary`, `/api/activity-feed`, `/api/commission/*`, `/api/barber/analytics`.

**Before (top of route file):**
```ts
import { NextRequest, NextResponse } from 'next/server'
import { createClient } from '@/lib/supabase/server'

export async function GET(request: NextRequest) {
```

**After:**
```ts
import { NextRequest, NextResponse } from 'next/server'
import { createClient } from '@/lib/supabase/server'

export const dynamic = 'force-dynamic'

export async function GET(request: NextRequest) {
```

**Post-fix verification:**
```bash
grep -n "export const dynamic" <file>
# Expected: one line matching "export const dynamic = 'force-dynamic'"
```

**Scope:** 1 file per application. NEVER bundle multiple routes in a single fix invocation — run the pattern once per file and get approval each time.

---

## Pattern 2 — Replace `toISOString().split('T')[0]` with Eastern-TZ date

**Symptom:** Daily buckets on `/dashboard/analytics` are off by one day around midnight. "Today" shows as empty at 1 AM even though there were 2 completions.

**Root cause:** Vercel runs UTC. `.toISOString().split('T')[0]` returns the UTC date, not the Eastern date.

**Target files:** routes under `src/app/api/analytics/**`, `/api/reports`, `/api/dashboard/summary`, `/api/activity-feed`, `/api/commission/**`, `/api/barber/analytics`.

**Before:**
```ts
const today = new Date().toISOString().split('T')[0]
```

**After:**
```ts
const today = new Date().toLocaleDateString('en-CA', { timeZone: 'America/New_York' })
```

**Variants to replace (same file):**
```ts
// Before:
const dow = date.getDay()
// After:
const dow = new Date(date.toLocaleDateString('en-US', { timeZone: 'America/New_York' })).getDay()

// Before:
const hour = date.getHours()
// After:
const hour = parseInt(
  date.toLocaleTimeString('en-GB', { timeZone: 'America/New_York', hour: '2-digit', hour12: false }),
  10
)
```

**Post-fix verification:**
```bash
grep -nE "toISOString\(\)\.split|\.getDay\(\)|\.getHours\(\)" <file>
# Expected: zero hits
```

---

## Pattern 3 — Scope `/api/commission/barber-summary` and `/api/barber/analytics` to auth-resolved barber

**Symptom:** Barber A can read Barber B's earnings by passing `?barber_id=<B>` to the route.

**Root cause:** Route accepts `barber_id` from `searchParams` instead of resolving it from the authenticated user.

**Target files:** `src/app/api/commission/barber-summary/route.ts`, `src/app/api/barber/analytics/route.ts`.

**Before:**
```ts
const barberId = searchParams.get('barber_id')
if (!barberId) return NextResponse.json({ error: 'barber_id required' }, { status: 400 })
```

**After:**
```ts
const { data: { user } } = await supabase.auth.getUser()
if (!user) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })

const { data: barber } = await supabase
  .from('barbers')
  .select('id')
  .eq('profile_id', user.id)
  .single()

if (!barber) return NextResponse.json({ error: 'Forbidden' }, { status: 403 })
const barberId = barber.id
```

**Post-fix verification:**
```bash
grep -n "searchParams.get('barber_id')" <file>
# Expected: zero hits
```

---

## Pattern 4 — Exclude soft-deleted bookings from analytics/reports queries

**Symptom:** Reports include revenue from bookings the owner cancelled and soft-deleted.

**Root cause:** Query against `bookings` doesn't filter `deleted_at IS NULL`.

**Target files:** any analytics/reports route that queries `bookings`.

**Before:**
```ts
const { data } = await supabase
  .from('bookings')
  .select('...')
  .eq('status', 'completed')
  .gte('scheduled_date', startDate)
```

**After:**
```ts
const { data } = await supabase
  .from('bookings')
  .select('...')
  .eq('status', 'completed')
  .is('deleted_at', null)
  .gte('scheduled_date', startDate)
```

**Post-fix verification:**
```bash
grep -nB 1 -A 3 "\.from\(['\"]bookings" <file> | grep -v "deleted_at"
# Expected: zero booking queries without deleted_at filter
```

---

## Pattern 5 — Route CSV export through `exportToCSV` utility

**Symptom:** CSV has malformed rows — client name with comma splits into two columns, quoted text breaks the row.

**Root cause:** Inline CSV builder concatenates raw values without escaping.

**Target files:** `src/app/(dashboard)/dashboard/reports/page.tsx`, `src/app/(dashboard)/dashboard/analytics/queue/page.tsx`, etc.

**Before:**
```ts
const csv = data.map(r => `${r.date},${r.barber},${r.revenue}`).join('\n')
const blob = new Blob([csv], { type: 'text/csv' })
// ... download logic
```

**After:**
```ts
import { exportToCSV } from '@/lib/utils/csvExport'

exportToCSV(data, [
  { key: 'date', label: 'Date' },
  { key: 'barber', label: 'Barber' },
  { key: 'revenue', label: 'Revenue', formatter: CSVFormatters.currency },
], `reports-${today}.csv`)
```

**Post-fix verification:**
- `npx tsc --noEmit` passes
- Manual CSV download test — open in Excel, verify no split rows

---

## Pattern 6 — Add `export const dynamic` + `cache: 'no-store'` wrapper to inline Supabase client

**Symptom:** Changes in the DB don't reflect on a report page until the Vercel build is re-triggered.

**Root cause:** A route creates an inline `createClient()` with a raw URL/key and doesn't wrap fetch with `cache: 'no-store'`. The Next.js Data Cache silently caches Supabase responses.

**Target files:** any route that creates a Supabase client directly from `@supabase/supabase-js` instead of using `@/lib/supabase/server`.

**Before:**
```ts
import { createClient } from '@supabase/supabase-js'
const supabase = createClient(url, key)
```

**After (preferred):**
```ts
import { createClient } from '@/lib/supabase/server'
const supabase = await createClient()
```

**After (if inline is unavoidable):**
```ts
import { createClient } from '@supabase/supabase-js'

const supabase = createClient(url, key, {
  global: {
    fetch: (input, init) => fetch(input, { ...init, cache: 'no-store' }),
  },
})
```

**Post-fix verification:**
- `npx tsc --noEmit` passes
- Hit the route twice in prod with a DB change between hits — second response must reflect the change

---

## Pattern 7 — Mirror a fix across `/dashboard/my-chair/*` and `/barber/*`

**Symptom:** Owner's personal reports page got an error-banner fix; barber's personal reports page didn't.

**Root cause:** Cross-Dashboard Code Mirroring Rule violated.

**Target files:** always in pairs. See `.claude/rules/context-awareness.md` for the full map.

**Workflow:**
1. Apply the fix to the page that triggered the symptom.
2. Read the mirror page. Find the equivalent code section.
3. Apply the SAME fix (same variable names, same logic, same UI pattern). If the mirror page lacks the section entirely, note as follow-up and flag for user.
4. Invoke `mirror-check` skill. Expected output: "no drift detected".

**Post-fix verification:** `mirror-check` passes.

---

## Pattern 8 — Backfill `daily_summaries` for drifted dates

**Symptom:** D1 query (reconcile) reports drift — `daily_summaries` lags `service_transactions` for some (date, barber, location) rows.

**Root cause:** A completion path (queue or booking) didn't call `update_daily_summary`.

**Target fix:** this is a DATA repair, not a code change. Requires `safe-query` skill (writes to prod DB).

**Workflow:**
1. Get approval from user to backfill. State the date range and affected rows.
2. Hand off to `safe-query` with a CALL statement per (date, barber_id, location_id):
   ```sql
   SELECT update_daily_summary(:date, :barber_id, :location_id);
   ```
3. Re-run D1 invariant — expected 0 rows.
4. Find and fix the upstream write path that missed the call. That fix follows Pattern 1 or Pattern 4 depending on where the miss happened.

**NEVER hand-edit `daily_summaries` directly.** The RPC is the only write path.
