# Schedules — Fix Patterns

Paste-ready diffs for every schedules gap category. When the audit flags a failure, point to the pattern number here and the user gets a concrete change to apply. These patterns are canonical — if you deviate, document why.

All patterns assume:
- `createAdminClient` imported from `@/lib/supabase/admin` when writes need to bypass RLS (admin page approvals, cron jobs).
- `createClient` from `@/lib/supabase/server` for user-authed routes.
- Eastern Time is the canonical business timezone — never trust `getDay()` / `getHours()` on Vercel.
- `d03b8ef` per-day location preservation logic in `src/app/api/barber/schedule/route.ts` is LOCKED. Do not rewrite it — only restore it if it drifts.

---

## Fix-mode preflight checklist (universal — applies to every pattern)

Fix mode in `SKILL.md` runs this sequence for EVERY pattern before the Edit. Do all steps, in order. Skip none.

1. **Preflight** — Read the target file. Match the pattern's "Before" block against current code exactly (imports, function names, variable names, surrounding context — NOT just line numbers, which drift). If ANY of these don't match → STOP. Report what differs. Do NOT apply a stale pattern.
2. **Classify** — Run the relevant invariants query from `invariants.md` (or an audit query from `audit-queries.sql`). Report live impact (affected barbers > 0) vs latent (0). User decides urgency from this.
3. **Confirm diff** — Show exact `old_string` / `new_string`. Wait for explicit `yes`.
4. **Apply** — Single `Edit` call. One pattern per invocation.
5. **Verify** — Run the pattern's post-fix verification (grep + `npx tsc --noEmit`, plus SQL if live). Every check must pass.
6. **Mirror** — If the pattern lives in `/barber/schedule/page.tsx` or `/dashboard/my-chair/schedule/page.tsx`, invoke `mirror-check` before handoff. Cross-Dashboard Mirroring Rule is non-negotiable.
7. **Handoff** — Stop at `bulletproof-ship`. Do not commit.

If any step fails, stop and report. Do not proceed to the next step.

---

## Pattern 1 — Restore per-day `location_id` preservation (d03b8ef regression)

**When:** Audit invariant C1 fails. `src/app/api/barber/schedule/route.ts` writes a single `preferred_location_id` to every inserted row instead of reading existing rows first. See `incidents.md` → "Per-Day Location Overwrite."

**Symptom:** Barber changes Friday location → Monday/Wednesday silently flip to the same location on next save.

**Before (broken — pre-d03b8ef pattern):**
```ts
const { data: barber } = await admin
  .from('barbers')
  .select('preferred_location_id')
  .eq('id', barberId)
  .single()
const resolvedLocationId = barber?.preferred_location_id ?? fallbackLocationId

await admin.from('barber_schedules').delete().eq('barber_id', barberId)

const rows = payload.days.map((d) => ({
  barber_id: barberId,
  day_of_week: d.day_of_week,
  start_time: d.start_time,
  end_time: d.end_time,
  location_id: resolvedLocationId,  // WRONG — flattens per-day choices
  is_active: true,
}))
await admin.from('barber_schedules').insert(rows)
```

**After (correct — read existing first, preserve per day):**
```ts
// 1. Read existing rows FIRST — capture each day's location_id.
const { data: existing } = await admin
  .from('barber_schedules')
  .select('day_of_week, location_id')
  .eq('barber_id', barberId)

const existingLocationByDay: Record<number, string> = {}
for (const row of existing ?? []) {
  if (row.location_id) existingLocationByDay[row.day_of_week] = row.location_id
}

// 2. Resolve fallback ONLY for brand-new days (preferred → staff_status).
const { data: barber } = await admin
  .from('barbers')
  .select('preferred_location_id')
  .eq('id', barberId)
  .single()
const { data: staff } = await admin
  .from('staff_status')
  .select('location_id')
  .eq('barber_id', barberId)
  .maybeSingle()
const fallbackLocationId =
  (barber as any)?.preferred_location_id ?? staff?.location_id ?? null

// 3. Delete, then re-insert with each day's prior location preserved.
await admin.from('barber_schedules').delete().eq('barber_id', barberId)

const rows = payload.days.map((d) => {
  const locationId = existingLocationByDay[d.day_of_week] ?? fallbackLocationId
  if (!locationId) {
    throw new Error(
      `No location available for day ${d.day_of_week}. Set preferred_location_id or clock in first.`
    )
  }
  return {
    barber_id: barberId,
    day_of_week: d.day_of_week,
    start_time: d.start_time,
    end_time: d.end_time,
    location_id: locationId,
    is_active: true,
  }
})
await admin.from('barber_schedules').insert(rows)
```

**Scope limit:** Ignore `locationId` from request body — barbers must use the location-change-request flow to move days. Do NOT add a body field that lets the barber rewrite location directly.

**Post-fix verification:**
- `grep -n "existingLocationByDay" src/app/api/barber/schedule/route.ts` → ≥2 matches (build map + use map).
- `grep -n "preferred_location_id" src/app/api/barber/schedule/route.ts` → used only as fallback, never as sole source.
- `npx tsc --noEmit` → no new errors.
- **Live probe:** As a test barber, change Wednesday location via location-request (approved), then save the schedule form without touching any other day. Verify the Wednesday row kept the new location; all other days kept their prior locations.

---

## Pattern 2 — Add `cache: 'no-store'` wrapper to inline Supabase clients

**When:** Invariant C3 fails. `src/app/api/barber/schedule/route.ts` or `src/app/api/barber/location-request/route.ts` constructs a Supabase client inline without wrapping `global.fetch` with `cache: 'no-store'`. See MEMORY.md Next.js 14 Data Cache rule (2026-03-26 incident).

**Symptom:** Schedule save returns 200, DB row updates, but next page load shows stale data on Vercel. Works locally (dev bypasses the Data Cache).

**Before (broken — raw `createClient`):**
```ts
import { createClient as createSupabaseClient } from '@supabase/supabase-js'

const admin = createSupabaseClient(
  process.env.NEXT_PUBLIC_SUPABASE_URL!,
  process.env.SUPABASE_SERVICE_ROLE_KEY!
)
```

**After (correct — wrap fetch):**
```ts
import { createClient as createSupabaseClient } from '@supabase/supabase-js'

const admin = createSupabaseClient(
  process.env.NEXT_PUBLIC_SUPABASE_URL!,
  process.env.SUPABASE_SERVICE_ROLE_KEY!,
  {
    global: {
      // HARD RULE — MEMORY.md (2026-03-26): Next.js 14 caches fetch by default.
      // Supabase JS uses fetch internally → stale reads in production.
      fetch: (input, init) => fetch(input, { ...init, cache: 'no-store' }),
    },
  }
)
```

**Scope limit:** Do NOT touch the shared `createAdminClient` in `src/lib/supabase/admin.ts` unless the audit specifically flags it — it already wraps fetch. This pattern targets inline clients only.

**Post-fix verification:**
- `grep -n "cache: 'no-store'" src/app/api/barber/schedule/route.ts src/app/api/barber/location-request/route.ts` → ≥1 match per file that has an inline client.
- `npx tsc --noEmit` → no new errors.
- **Live probe:** Save a schedule change, then immediately refetch via the same route from another tab within 2 seconds. New data must appear, not a cached version.

---

## Pattern 3 — Location-request approval must dual-update `staff_status`

**When:** Invariant C4 fails. `src/app/api/barber/location-request/route.ts` PATCH handler updates `barber_schedules` only. See `incidents.md` → "Location Change Request — Dual-Update Missing."

**Symptom:** Owner approves a Friday move to Newark → barber's `/barber/schedule` shows Newark → but if barber is clocked in at Wilmington RIGHT NOW, walk-in queue still routes to Wilmington until they clock out and back in.

**Before (broken — single-table update):**
```ts
// Approve: update barber_schedules only
await admin
  .from('barber_schedules')
  .update({ location_id: request.requested_location_id })
  .eq('barber_id', request.barber_id)
  .eq('day_of_week', request.day_of_week)

await admin
  .from('location_change_requests')
  .update({
    status: 'approved',
    reviewed_by: owner.id,
    reviewed_at: new Date().toISOString(),
  })
  .eq('id', requestId)
```

**After (correct — conditional dual-update for today's schedule):**
```ts
// 1. Update barber_schedules for the target day.
await admin
  .from('barber_schedules')
  .update({ location_id: request.requested_location_id })
  .eq('barber_id', request.barber_id)
  .eq('day_of_week', request.day_of_week)

// 2. If the approval applies to TODAY (ET) and barber is actively on the floor,
//    update staff_status.location_id so queue routing flips immediately.
const todayDow = Number(
  new Date().toLocaleDateString('en-US', {
    timeZone: 'America/New_York',
    weekday: 'short',
  }) // 'Mon' etc. — map to number
    .replace(/Sun|Mon|Tue|Wed|Thu|Fri|Sat/, (d) =>
      String(['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].indexOf(d))
    )
)

if (request.day_of_week === todayDow) {
  await admin
    .from('staff_status')
    .update({ location_id: request.requested_location_id })
    .eq('barber_id', request.barber_id)
    .in('status', ['clocked_in', 'on_break', 'with_client'])
}

// 3. Mark request approved.
await admin
  .from('location_change_requests')
  .update({
    status: 'approved',
    reviewed_by: owner.id,
    reviewed_at: new Date().toISOString(),
  })
  .eq('id', requestId)
```

**Scope limit:** Do NOT change the queue code to look at `barber_schedules` instead of `staff_status`. That is a separate, much bigger refactor. Stay in scope: dual-update at approval time only.

**Post-fix verification:**
- `grep -n "staff_status" src/app/api/barber/location-request/route.ts` → ≥1 match inside the PATCH handler.
- `grep -n "America/New_York" src/app/api/barber/location-request/route.ts` → ≥1 match (day-of-week conversion).
- `npx tsc --noEmit` → no new errors.
- **Live probe (test barber clocked in at Wilmington):** owner approves a same-day move to Newark → inspect `SELECT location_id FROM staff_status WHERE barber_id = '<test>'` → must now be Newark. Walk-in check-in at Newark should immediately be able to assign this barber.

---

## Pattern 4 — Replace UTC `getDay()` with Eastern TZ day-of-week lookup

**When:** Invariant C2 fails or `tz-audit` skill flags `getDay()` inside schedule/availability code. HARD RULE — Booksy Timezone (MEMORY.md 2026-03-28). Vercel runs UTC, so `new Date().getDay()` returns the UTC day, not Eastern.

**Symptom (happens on Vercel, not locally):** A booking at 11 PM Eastern on Friday is stored with Saturday's `day_of_week` because UTC rolled over. Availability filter then reads Saturday's schedule → wrong location, wrong hours, wrong bookable slots.

**Before (broken — UTC day-of-week):**
```ts
const dayOfWeek = new Date(scheduledDate).getDay() // 0-6, UTC on Vercel
const { data: schedule } = await supabase
  .from('barber_schedules')
  .select('*')
  .eq('barber_id', barberId)
  .eq('day_of_week', dayOfWeek)
  .maybeSingle()
```

**After (correct — Eastern short-name → number):**
```ts
// Canonical Eastern-TZ day-of-week conversion.
const dowShort = new Date(scheduledDate).toLocaleDateString('en-US', {
  timeZone: 'America/New_York',
  weekday: 'short',
}) // 'Sun' | 'Mon' | ... | 'Sat'
const dayOfWeek = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].indexOf(dowShort)

const { data: schedule } = await supabase
  .from('barber_schedules')
  .select('*')
  .eq('barber_id', barberId)
  .eq('day_of_week', dayOfWeek)
  .maybeSingle()
```

**Scope limit:** ONLY touch the day-of-week calculation. Do NOT refactor unrelated date formatting in the same file — those are separate patterns (use `tz-audit` + pattern in `bulletproof-bookings` fix-patterns if they surface).

**Files most likely to need this:**
- `src/app/api/bookings/availability/route.ts` (already ET-safe as of the d03b8ef audit; verify before assuming it needs a fix).
- Any new API route that filters `barber_schedules` by `day_of_week`.

**Post-fix verification:**
- `grep -nE "\.getDay\(\)" src/app/api/barber/ src/app/api/bookings/availability/` → 0 matches (or each match is accompanied by an ET-localized source Date).
- `grep -n "America/New_York" <edited file>` → ≥1 match.
- `npx tsc --noEmit` → no new errors.
- **Live probe:** On Vercel, request availability at 11:30 PM Eastern on a Friday. Confirm the response uses Friday's schedule, not Saturday's.

---

## Pattern 5 — Subscribe to `barber_schedules` realtime on mirrored schedule pages

**When:** Schedule toggles don't propagate live. The user saves on one device/tab, other devices show stale data until a manual refresh. Realtime publication covers `barber_schedules` as of commit `c7c5b12` (2026-04-21).

**Symptom:** Owner flips a day off in `/dashboard/location-requests` → barber's `/barber/schedule` still shows the old state for minutes until they reload.

**Verify publication is live first:**
```sql
SELECT tablename FROM pg_publication_tables
WHERE pubname = 'supabase_realtime'
  AND tablename IN ('barber_schedules', 'location_change_requests');
-- Expected: 2 rows. If fewer, publication isn't set — different fix (add via migration, user approval required).
```

**Before (no realtime subscription on schedule pages):**
```tsx
useEffect(() => {
  void loadSchedule()
}, [barberId])
```

**After (subscribe + refetch on change):**
```tsx
useEffect(() => {
  void loadSchedule()

  const supabase = createClient()
  const channel = supabase
    .channel(`barber_schedules:${barberId}`)
    .on(
      'postgres_changes',
      {
        event: '*',
        schema: 'public',
        table: 'barber_schedules',
        filter: `barber_id=eq.${barberId}`,
      },
      () => {
        void loadSchedule()
      }
    )
    .subscribe()

  return () => {
    void supabase.removeChannel(channel)
  }
}, [barberId])
```

**Scope limit:** Apply to BOTH:
- `src/app/(dashboard)/barber/schedule/page.tsx`
- `src/app/(dashboard)/dashboard/my-chair/schedule/page.tsx`

This is a Cross-Dashboard Mirroring Rule change. The two files must land with identical subscription logic in the same commit. Invoke `mirror-check` after the Edit and before handoff.

**Post-fix verification:**
- `grep -n "barber_schedules:" src/app/(dashboard)/barber/schedule/page.tsx src/app/(dashboard)/dashboard/my-chair/schedule/page.tsx` → ≥1 match per file.
- `grep -n "removeChannel" <both files>` → ≥1 match per file (cleanup prevents leaked channels).
- `npx tsc --noEmit` → no new errors.
- **Live probe:** Open `/barber/schedule` in two tabs (one logged in as the owner on `/dashboard/my-chair/schedule`). Save a toggle in one tab → the other tab must reflect the change within 2 seconds with no manual refresh.

---

## Pattern 6 — Add missing `preferred_location_id` migration (column drift)

**When:** Invariant `incidents.md` → "`preferred_location_id` Column Drift Risk" fails. Column exists in production Supabase (manually added) but no migration file. Fresh dev or staging DB breaks on schedule save.

**Symptom:** `column barbers.preferred_location_id does not exist` from the schedule save endpoint. Only reproducible on a fresh DB clone — never on prod.

**Resolution:** This is NOT a code fix. It is a missing migration. Apply in two steps with explicit user approval at each.

**Step 1 — confirm drift:**
```sql
SELECT column_name
FROM information_schema.columns
WHERE table_name = 'barbers' AND column_name = 'preferred_location_id';
-- Expected: 1 row (prod has it). If 0 rows on prod: different emergency — the schedule save endpoint is currently broken on prod too.
```

**Step 2 — propose migration (DO NOT apply without user `yes`):**
```sql
-- supabase/migrations/<timestamp>_add_barbers_preferred_location_id.sql
ALTER TABLE barbers
  ADD COLUMN IF NOT EXISTS preferred_location_id UUID REFERENCES locations(id);

-- Backfill: pick the location they most recently clocked in at.
UPDATE barbers b
SET preferred_location_id = ss.location_id
FROM staff_status ss
WHERE ss.barber_id = b.id
  AND b.preferred_location_id IS NULL
  AND ss.location_id IS NOT NULL;
```

**Scope limit:** Do NOT chain other "while we're here" schema changes into this migration (e.g., a new index, a rename, a cleanup). One migration, one concern.

**Post-fix verification:**
- Migration file exists in `supabase/migrations/` with `IF NOT EXISTS` (idempotent against prod which already has the column).
- `mcp__supabase-mt__list_migrations` shows the migration registered.
- On fresh dev DB: `npx supabase db reset && npx supabase db push` completes without error; the schedule save endpoint returns 200 for a barber with no existing schedule rows.

---

## Pattern 7 — Mirror schedule UI changes across both dashboard pages

**When:** You edit `src/app/(dashboard)/barber/schedule/page.tsx` and the equivalent feature / state / validation does not exist in `src/app/(dashboard)/dashboard/my-chair/schedule/page.tsx` (or vice-versa). HARD RULE — Cross-Dashboard Code Mirroring (`context-awareness.md`).

**Symptom:** Barber gets a new error banner on save failures; owner's `/dashboard/my-chair/schedule` still shows a silent swallow. Or: owner gets a new "Request location change" button; barber still sees the old three-dot menu.

**Process (not a code diff — a workflow):**
1. Edit the first file.
2. **Immediately** invoke the `mirror-check` skill with the edited path. It reports drift.
3. For every flagged drift item, apply the same change to the mirror page — same state variables, same computed values, same UI feedback, same validation.
4. Re-run `mirror-check` → clean.
5. Both files land in the same commit.

**Scope limit:**
- If `mirror-check` flags a drift that's orthogonal to your change (pre-existing drift), note it as a follow-up task in the handoff — do NOT fix it in the same commit unless the user explicitly approves expanding scope.
- Shared components (`RequestLocationChangeModal`, `MyLocationRequests`) already mirror by construction — do NOT duplicate them per dashboard. Only page-level state/UI needs mirroring.

**Post-fix verification:**
- `mirror-check` returns clean for the two schedule pages.
- `git diff --stat HEAD src/app/(dashboard)/barber/schedule/page.tsx src/app/(dashboard)/dashboard/my-chair/schedule/page.tsx` → both files show changes (or both show zero — never one-sided).
- `npx tsc --noEmit` → no new errors.

---

## Cross-pattern rules

1. **Read-only by default.** No INSERT/UPDATE/DELETE on production without explicit user approval for that specific query. HARD RULE — Zero Production Data Contamination.
2. **`mcp__supabase-mt__` only.** Never `mcp__supabase__` — that's a different project. See MEMORY.md.
3. **Eastern Time is the business timezone.** Every new date/time op in a scheduling code path MUST pass `timeZone: 'America/New_York'`. No exceptions.
4. **`cache: 'no-store'` on every inline Supabase client.** If you add a new one in a schedule/location-request route, add the fetch wrapper in the same commit.
5. **Per-day preservation is LOCKED.** `d03b8ef` logic in `src/app/api/barber/schedule/route.ts` is untouchable. Only restore if it regresses — never "simplify."
6. **Location changes go through the request flow.** The schedule PATCH endpoint ignores `locationId` from the body. If a feature tempts you to let the barber set location directly on `/barber/schedule`, escalate — that's a policy change, not a code change.
7. **Mirror pages land together.** `/barber/schedule` + `/dashboard/my-chair/schedule` edits ship in the same commit. Invoke `mirror-check` before every handoff.
8. **Every fix = single pattern.** One invocation fixes one pattern. Do not chain patterns inside a single Edit — auditability dies.

---

## When adding a NEW schedule-touching route or hook

Checklist before committing:
1. `cache: 'no-store'` wrapper on any inline Supabase client? (Pattern 2)
2. Eastern TZ on every `getDay()` / `getHours()` / date-string op? (Pattern 4, or defer to `tz-audit` skill)
3. Writes respect `d03b8ef` per-day preservation? (Pattern 1 — don't touch `barber_schedules` bulk-writes without preserving prior `location_id`)
4. If writing from a cron/webhook (no auth session): `createAdminClient` from `@/lib/supabase/admin`, not an inline SSR client.
5. If the new route mutates location routing (like approvals): dual-update pattern? (Pattern 3)
6. Realtime publication covers new table if it's surface-facing? Verify with the SQL in Pattern 5.
7. Mirror page updated if the new feature surfaces on `/barber/schedule` OR `/dashboard/my-chair/schedule`? (Pattern 7)
8. Invariants in `invariants.md` updated if the new code creates a new failure mode worth auditing?

If any of these is "no," stop and fix before shipping.
