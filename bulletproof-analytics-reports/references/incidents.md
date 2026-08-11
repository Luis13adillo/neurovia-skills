# Analytics & Reports Incident Registry

---

## Known Gap: Activity feed is polled, not realtime

**Symptom (as user sees it):**
- Owner creates a booking in one tab; `/dashboard` home activity feed in another tab doesn't show it.
- Walk-in client checks in; feed lags until refresh.

**Root cause:**
`src/lib/hooks/useActivityFeed.ts` fetches `/api/activity-feed` once on mount and exposes a `refetch()` method. No Supabase realtime subscription. Every other realtime surface in the app (queue, bookings, barber_schedules) IS publication-backed — activity feed was never wired up.

**Status:** Known gap. Not a bug per se, but a UX expectation mismatch. Hard refresh or navigating away+back works.

**Possible fix (NOT applied — requires user approval):**
Add Supabase realtime subscriptions on `queue_entries`, `bookings`, `service_transactions` (INSERT + UPDATE) inside `useActivityFeed`, filtered to last 24h, merging with the initial fetch. Estimated effort: 1 hook file, ~30 lines. Pattern already used by `useQueueRealtime`.

**If audit raises this:** report as `[KNOWN GAP]`. Do not auto-fix.

---

## Known Gap: Home page parallel fetches can show transient inconsistency

**Symptom:**
- Owner hits `/dashboard`. A booking completed 200ms ago.
- Activity feed shows it. Commission summary card doesn't — still shows the previous total.
- Refresh fixes it.

**Root cause:**
`/dashboard` fires 4+ independent fetches from page mount: `useHomeSummary`, `useActivityFeed`, `fetch('/api/commission/summary')`, `fetch('/api/barber/reconcile')`. Each resolves independently. An event landing in one table before the other is queried creates a 100–500ms window of disagreement.

**Status:** Known timing gap. Low severity — self-corrects on any re-render.

**If audit raises this:** report as `[KNOWN GAP]`. Do not auto-fix. Fixing requires either a single aggregate endpoint (expensive to build) or snapshot-isolation reads (not supported by Supabase REST).

---

## Potential Incident: `daily_summaries` drift from missed `update_daily_summary` call

**Symptom (as user sees it):**
- `/dashboard/reports` shows $1,410 for today.
- `/dashboard` home shows $1,240 for today.
- Owner insists nothing was refunded. Same date, same filter.

**Root cause (if confirmed by D1 invariant):**
A completion handler — queue or booking — updated `service_transactions` but didn't call `update_daily_summary`. Subsequent reports page reads from `daily_summaries` which is stale. Home page reads from a different path that hits `service_transactions` directly.

**Known writer paths:**
- `src/app/api/bookings/[id]/route.ts:558` — calls `update_daily_summary` on booking → `completed`. CONFIRMED.
- Walk-in queue completion (via `complete_queue_service` RPC) — verify whether it calls `update_daily_summary`. Migration 035 defined the RPC.

**Diagnose checklist:**
1. Run D1 invariant. Which date/barber/location rows drift?
2. For each drifted row, check if the corresponding `service_transactions` came from queue or booking.
3. If queue-originated: inspect `complete_queue_service` definition; confirm it calls `update_daily_summary`.
4. If booking-originated: inspect `src/app/api/bookings/[id]/route.ts` for the line near 558; confirm the RPC call is unconditional, not inside an `if (paymentMethod === 'card')` branch.
5. Any edge case missing? Refunds, tip adjustments, status revert.

**Fix:** Pattern 8 — backfill `daily_summaries` for drifted dates via the RPC. Then Pattern 1 or 4 on the upstream missed path.

---

## Potential Incident: CSV export splits client names with commas

**Symptom:**
- Owner exports `/dashboard/reports` → CSV.
- Opens in Excel. A row with "Smith, Jr." as client name has "Jr." in the next column. Every subsequent cell shifted by one.

**Root cause:**
Inline CSV builder `data.map(r => \`${r.date},${r.name},${r.revenue}\`).join('\n')` doesn't escape commas. `/dashboard/analytics/queue` is known to have inline CSV construction.

**Fix:** Pattern 5 — route through `exportToCSV` utility in `src/lib/utils/csvExport.ts`.

---

## Potential Incident: Barber sees another barber's analytics

**Symptom:**
- Barber A opens browser devtools, finds `?barber_id=<A>` in a request URL.
- Edits to Barber B's UUID. Gets Barber B's earnings back.

**Root cause (if confirmed):**
The route reads `barber_id` from `searchParams` instead of resolving it from `auth.uid()` → `profiles` → `barbers.profile_id`.

**Target files:**
- `src/app/api/commission/barber-summary/route.ts`
- `src/app/api/barber/analytics/route.ts`

**Fix:** Pattern 3 — resolve barber from auth, ignore query param.

**Audit step:** C4 invariant grep. Zero hits expected.

---

## Potential Incident: Soft-deleted bookings inflate reports

**Symptom:**
- Owner soft-deletes a cancelled booking (sets `deleted_at`).
- It still shows up in `/dashboard/reports` daily totals.

**Root cause:**
Reports SQL queries `bookings` with only `status='completed'`, not `.is('deleted_at', null)`. Bookings that were completed, then cancelled, then soft-deleted still satisfy the status filter.

**Fix:** Pattern 4 — add `.is('deleted_at', null)` to every analytics/reports query over `bookings`.

---

## Potential Incident: Analytics shows yesterday's data after deploy

**Symptom:**
- Vercel deploy completes at 2 PM.
- Owner opens `/dashboard/analytics` at 2:05 PM. Numbers frozen at 1:30 PM.
- Hard refresh doesn't help. Different browser doesn't help. Only another deploy helps.

**Root cause:**
Route missing `export const dynamic = 'force-dynamic'`. Next.js Full Route Cache served the build-time snapshot.

**Fix:** Pattern 1 — add the export.

**Prevention:** Invariant C1 grep on every PR that touches analytics/reports routes.
