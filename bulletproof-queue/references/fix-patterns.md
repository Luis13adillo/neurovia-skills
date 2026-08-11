# Walk-In Queue — Fix Patterns

Paste-ready diffs for every known queue failure mode. When the audit or diagnose mode flags a failure, point to the pattern number here and the user gets a concrete, scoped change to apply. Each pattern is derived from a real incident documented in `references/incidents.md` and enforces an invariant from `references/invariants.md`.

These patterns are canonical — if you deviate, the HARD RULES in `debugging-protocol.md` Sections 7 and 8 apply (full revert on unauthorized work, full revert on any broken existing behavior).

All patterns assume:
- Read-only verification via `mcp__supabase-mt__execute_sql` only (NEVER `mcp__supabase__`)
- Supabase clients imported from `@/lib/supabase/admin`, `@/lib/supabase/server`, or `@/lib/supabase/client`
- Fixes happen on a `fix/<description>` branch, NEVER on `main` (see `.claude/rules/branch-workflow.md`)

---

## Fix-mode preflight checklist (universal — applies to every pattern)

Fix mode runs this sequence for EVERY pattern before the Edit. Do all steps, in order. Skip none.

1. **Preflight** — Read the target file. Match the pattern's "before" block against current code exactly (imports, function names, variable names, surrounding context — NOT just line numbers, which drift). If ANY of these don't match → STOP. Report what differs. Do NOT apply a stale pattern.
2. **Scope audit** — Confirm the fix touches ONLY files named in the pattern's "Before" / "After" blocks. If a fix would require touching auth, bookings, commission, or any unrelated system → STOP. Ask for approval before expanding.
3. **Confirm diff** — Show exact `old_string` / `new_string`. Wait for explicit `yes`.
4. **Apply** — Single `Edit` call. One pattern per invocation.
5. **Mirror check** — If the pattern touches `/barber/walk-ins/page.tsx` OR `/dashboard/my-chair/page.tsx`, the mirror file MUST receive the identical change in the same session. Invoke `mirror-check` before handoff. Cross-Dashboard Code Mirroring is a HARD RULE (`context-awareness.md`).
6. **Verify** — Run the pattern's post-fix verification (grep + `npx tsc --noEmit`, plus SQL invariant check). Every check must pass.
7. **Handoff** — Stop at `bulletproof-ship`. Do not commit, do not push.

If any step fails, stop and report. Do not proceed to the next step. Do not "just try one more thing" — see Two-Strike Rule (`debugging-protocol.md` Section 5).

---

## Pattern 1 — Restore `calledClientIdRef` guard (auto-start gate)

**When:** Audit C2 fails, or incidents.md "`calledClientIdRef` Guard Incident" symptom reported (auto-start fires for a client the barber never called). The guard was removed, replaced with a boolean, or a reset-`useEffect` was added.

**Before (any of these = broken):**
```tsx
// BROKEN — boolean flag racing with Supabase realtime
const autoStartFiredRef = useRef(false)

useEffect(() => {
  autoStartFiredRef.current = false // reset on client change
}, [currentClient?.id])

// BROKEN — reset effect wiping the ref before timer fires
useEffect(() => {
  calledClientIdRef.current = null
}, [currentClient?.id])
```

**After (the only correct pattern — per 2026-04-11 incident):**
```tsx
// src/app/(dashboard)/barber/walk-ins/page.tsx
// AND src/app/(dashboard)/dashboard/my-chair/page.tsx (identical)

const calledClientIdRef = useRef<string | null>(null)

const handleCallNext = async () => {
  // ... existing logic that PATCHes queue_entries → status='called' ...
  const response = await fetch(`/api/queue/entry/${entryId}`, { method: 'PATCH', ... })
  if (response.ok) {
    calledClientIdRef.current = entryId // set ONLY on API success
  }
}

// Auto-start: fires 60s after THIS BARBER calls a client via handleCallNext.
// Uses calledClientIdRef (the exact client ID they called) — not a boolean flag.
useEffect(() => {
  if (!currentClient || currentClient.status !== 'called') return
  const timer = setTimeout(() => {
    if (calledClientIdRef.current !== currentClient?.id) return // ID mismatch → abort
    calledClientIdRef.current = null
    // proceed with auto-start → PATCH to in_chair
  }, 60_000)
  return () => clearTimeout(timer)
}, [currentClient?.id, currentClient?.status])
```

**Scope limit:** Only the two mirrored files. Do NOT touch the API route's in-chair guard (that's Pattern 4). Do NOT touch `MobileQueueView.tsx` or `PostServiceFlow.tsx`.

**Post-fix verification:**
- `grep -n "calledClientIdRef\|autoStartFiredRef\|calledBySelfRef" src/app/(dashboard)/barber/walk-ins/page.tsx` → only `calledClientIdRef` references, no boolean variants
- Same grep on `src/app/(dashboard)/dashboard/my-chair/page.tsx` → identical result
- `grep -n "useEffect" src/app/(dashboard)/barber/walk-ins/page.tsx | grep -n "currentClient?.id"` → no reset effect that wipes `calledClientIdRef` on client id change (only the auto-start timer effect is allowed to depend on it)
- `npx tsc --noEmit` → no new errors
- **Mirror invocation: REQUIRED** — `mirror-check` must show both files byte-identical in the guarded section
- **Live probe (deferred):** have Barber A call a client via their own Call Next → 60s passes → service auto-starts for THAT client. Then have the owner manually set another client to `called` on Barber A's queue → 60s passes → nothing auto-starts. Both outcomes required.

---

## Pattern 2 — Restore `cache: 'no-store'` wrapper on Supabase client factories

**When:** Audit C1 fails, or incidents.md "Fetch Cache Bug" symptom reported (stale queue data, realtime fires but refetched rows are old). A developer removed the wrapper or created a new factory without it.

**Before (broken):**
```ts
// src/lib/supabase/admin.ts — missing wrapper
export function createAdminClient() {
  return createClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    { auth: { autoRefreshToken: false, persistSession: false } }
    // no global.fetch override → Next.js 14 Data Cache serves stale rows
  )
}
```

**After (correct — per 2026-03-26 incident):**
```ts
// src/lib/supabase/admin.ts
export function createAdminClient() {
  return createClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    {
      auth: { autoRefreshToken: false, persistSession: false },
      global: {
        fetch: (url, options = {}) =>
          fetch(url, { ...options, cache: 'no-store' }),
      },
    }
  )
}
```

**Apply identical wrapper to:**
- `src/lib/supabase/admin.ts`
- `src/lib/supabase/server.ts`
- `src/app/api/barber/schedule/route.ts` (inline client per MEMORY.md)
- `src/app/api/barber/location-request/route.ts` (inline client per MEMORY.md)
- Any NEW inline `createClient(...)` found via grep

**Scope limit:** Only the `global.fetch` wrapper. Do NOT restructure the factory, rename exports, or "improve" the auth options — that's out of scope (`debugging-protocol.md` Section 8).

**Post-fix verification:**
- `grep -n "cache: 'no-store'" src/lib/supabase/admin.ts src/lib/supabase/server.ts` → ≥1 match per file
- `grep -rn "createClient(" src/app/api/ --include="*.ts"` → every inline usage either imports from `@/lib/supabase/*` OR has its own `cache: 'no-store'` wrapper
- `npx tsc --noEmit` → no new errors
- Restart dev server on port 3010 after the fix — cached builds survive HMR
- **Live probe (deferred):** mutate a `queue_entries` row via SQL editor → the affected dashboard page reflects the change within ~1s (realtime) and a hard refresh does not show older data

---

## Pattern 3 — Remove dead `claim_queue_entry` / `flow_step` / `useIncompleteFlowEntry` references

**When:** Audit C4 fails, or grep flags the 6d4e4ff signature pattern creeping back (see incidents.md "Unauthorized Commit Revert"). The RPC exists as dead code in production Supabase — it is HARMLESS there because nothing calls it. The danger is app code starting to call it again.

**Before (broken — any of these = 6d4e4ff leakage):**
```ts
// BROKEN — calling a dead RPC
const { data } = await supabase.rpc('claim_queue_entry', { p_entry_id: id, p_barber_id: barberId })

// BROKEN — hook that persists flow state across reloads
import { useIncompleteFlowEntry } from '@/lib/hooks/useIncompleteFlowEntry'

// BROKEN — Zod schema with flow_step
const QueueEntrySchema = z.object({
  id: z.string().uuid(),
  flow_step: z.enum(['payment', 'loyalty', 'rebook']).optional(), // ← unauthorized
})
```

**After:** Delete the calls/imports/fields entirely. Do NOT replace them with a new abstraction — the inline FIFO + rotation validation in `src/app/api/queue/entry/[id]/route.ts` is the correct implementation and does not need a helper.

**Scope limit:** Remove the dead reference ONLY. Do NOT drop the `claim_queue_entry` RPC from the database (it's harmless there, and a DROP is a destructive action that needs explicit approval per `debugging-protocol.md` Section 9).

**Post-fix verification:**
- `grep -rn "claim_queue_entry\|useIncompleteFlowEntry\|flow_step" src/` → 0 matches
- `grep -rn "claim_queue_entry\|flow_step" supabase/migrations/` → only matches in the original 6d4e4ff migration file (dead RPC is allowed to persist in DB)
- `npx tsc --noEmit` → no new errors (confirms no orphan imports)
- **Escalate to user:** report which files had the leakage and when they were added (via `git log -S "claim_queue_entry"` on the affected paths). This is a signal that the Zero Tolerance rule was bypassed.

---

## Pattern 4 — Restore in-chair API guard

**When:** Audit C3 fails, or invariants.md Invariant #2 (no two `in_chair` per barber) or #3 (no barber both `in_chair` + active booking) returns >0 rows. The guard block at `src/app/api/queue/entry/[id]/route.ts` was removed, weakened, or replaced with an RPC call.

**Before (broken — guard missing or replaced with dead RPC):**
```ts
// BROKEN — direct UPDATE with no concurrency check
if (body.status === 'in_chair') {
  await supabase
    .from('queue_entries')
    .update({ status: 'in_chair', start_time: new Date().toISOString() })
    .eq('id', id)
}

// BROKEN — routed through dead RPC
await supabase.rpc('claim_queue_entry', { p_entry_id: id })
```

**After (correct — per incidents.md "`calledClientIdRef` Guard Incident", "API-level guard" section):**
```ts
// src/app/api/queue/entry/[id]/route.ts around lines 217-252

if (body.status === 'in_chair') {
  // Block if the barber already has another active in_chair entry
  const { data: existingInChair } = await admin
    .from('queue_entries')
    .select('id')
    .eq('assigned_barber_id', currentEntry.assigned_barber_id)
    .eq('status', 'in_chair')
    .neq('id', id)
    .limit(1)

  if (existingInChair && existingInChair.length > 0) {
    return NextResponse.json(
      { error: 'Barber already has another client in chair' },
      { status: 409 }
    )
  }

  // Block if the barber has an active booking right now
  const nowEastern = new Date().toLocaleDateString('en-CA', { timeZone: 'America/New_York' })
  const { data: activeBooking } = await admin
    .from('bookings')
    .select('id')
    .eq('barber_id', currentEntry.assigned_barber_id)
    .in('status', ['confirmed', 'in_progress'])
    .eq('scheduled_date', nowEastern)
    .limit(1)

  if (activeBooking && activeBooking.length > 0) {
    return NextResponse.json(
      { error: 'Barber has an active booking; cannot start walk-in' },
      { status: 409 }
    )
  }
  // ... proceed with UPDATE to in_chair
}
```

**Scope limit:** Only the `→in_chair` branch. Do NOT touch the `→called`, `→completed`, `→no_show`, or `→cancelled` branches. Do NOT replace with an RPC (see Pattern 3 — `claim_queue_entry` is dead).

**Post-fix verification:**
- `grep -n "already has another\|active booking" src/app/api/queue/entry/[id]/route.ts` → ≥2 matches (the two guard clauses)
- Run invariants.md Invariant #2 query → 0 rows
- Run invariants.md Invariant #3 query → 0 rows
- `npx tsc --noEmit` → no new errors
- **Live probe (deferred):** with Barber A already `in_chair` on entry X, attempt PATCH to `in_chair` on entry Y for the same barber → must return 409. Same test with an active booking for the barber today → 409.

---

## Pattern 5 — Mirror any queue fix to `/barber/walk-ins` ↔ `/dashboard/my-chair`

**When:** A fix was applied to one of the mirrored pages but not the other. Cross-Dashboard Code Mirroring HARD RULE violation (`context-awareness.md`). This is the most common queue drift — new state, new error banner, new computed value lands on barber page but not owner my-chair.

**Mirror pairs (queue-relevant):**
| Barber page | Owner page |
|---|---|
| `src/app/(dashboard)/barber/walk-ins/page.tsx` | `src/app/(dashboard)/dashboard/my-chair/page.tsx` |
| `src/app/(dashboard)/barber/page.tsx` (home) | `src/app/(dashboard)/dashboard/my-chair/page.tsx` |

**Before (drift):** one file has `const [clockError, setClockError] = useState<string | null>(null)` + error banner UI + `isSoloBarber` computed; the other file is missing them.

**After:** both files have byte-identical queue logic. Only `role`-specific sections (owner-only overrides, owner analytics widgets) may differ, and those are already isolated behind role checks.

**Scope limit:** Only mirror queue-specific logic (call/skip/complete, error banners, soft/hard clock-in states, `calledClientIdRef`, queue-entry fetching, post-service flow). Do NOT mirror owner-only UI into the barber page — the barber is NOT an owner superset.

**Apply via `mirror-check` skill:**
```
# Inside fix-mode, after applying a fix to one page:
mirror-check --files src/app/(dashboard)/barber/walk-ins/page.tsx src/app/(dashboard)/dashboard/my-chair/page.tsx --section "queue handlers"
```

**Post-fix verification:**
- `mirror-check` returns zero drift for the edited section
- `diff` of the queue-handler blocks shows only the documented owner-only differences (e.g., owner queue-override buttons, owner analytics)
- `grep -n "<variable or function name>" <both files>` → identical line count for the mirrored logic
- `npx tsc --noEmit` → no new errors

---

## Pattern 6 — Replace `locations[0]` fallback with real location context

**When:** Scale-check mode flags a `locations[0]` usage outside safe fallbacks (see SKILL.md scale-check section). At 3 locations it works by accident; at 5+ it ships walk-ins to the wrong shop.

**Before (broken):**
```tsx
// src/app/(dashboard)/dashboard/my-chair/page.tsx ~ line 199
const locationId = locations[0]?.id // ← wrong at 5 locations

// src/components/dashboard/WalkInForm.tsx:35
const defaultLocation = locations[0]
```

**After (correct):**
```tsx
// Prefer, in this order:
// 1. The barber's current staff_status.location_id (where they're clocked in)
// 2. The barber's primary assigned location from barber_schedules for today
// 3. An explicit user selection via a location picker
// Never the array's first element.

const locationId =
  staffStatus?.location_id ??
  todaysSchedule?.location_id ??
  userSelectedLocationId ??
  null

if (!locationId) {
  return <LocationPicker locations={locations} onSelect={setUserSelectedLocationId} />
}
```

**Scope limit:** One file per fix invocation. Do NOT cascade fixes across the 6 known files in the SKILL.md scale-check list in a single pass — each file has different context and different correct fallback. Review file-by-file.

**Post-fix verification:**
- `grep -n "locations\[0\]" <the-edited-file>` → 0 matches
- Manual inspection: the new fallback chain handles the case when `staff_status` is absent (barber not clocked in) AND no today schedule (barber not scheduled)
- `npx tsc --noEmit` → no new errors
- **Mirror invocation:** if the edited file is `/barber/walk-ins/page.tsx` or `/dashboard/my-chair/page.tsx`, invoke `mirror-check`

---

## Pattern 7 — Fix timezone-unsafe date math in queue code

**When:** Diagnose reports incidents.md "Timezone Bug" symptom (wait time off by 4-5 hours, check-in on wrong day). Grep finds banned patterns in queue paths.

**Before (broken):**
```ts
const today = new Date().toISOString().split('T')[0] // UTC date, not Eastern
const dayOfWeek = new Date().getDay()                 // UTC day, not Eastern
const hhmm = new Date().toTimeString().slice(0, 5)    // UTC time, not Eastern
```

**After (correct — per incidents.md "Timezone Bug"):**
```ts
const today = new Date().toLocaleDateString('en-CA', { timeZone: 'America/New_York' })
// → "YYYY-MM-DD" Eastern

const dayOfWeekShort = new Date().toLocaleDateString('en-US', {
  timeZone: 'America/New_York',
  weekday: 'short',
})
// then map "Sun"..."Sat" → 0..6 for barber_schedules lookups

const hhmm = new Date().toLocaleTimeString('en-GB', {
  timeZone: 'America/New_York',
  hour: '2-digit',
  minute: '2-digit',
  hour12: false,
})
// → "HH:MM" Eastern
```

**Scope limit:** Only queue-related files. Bookings are owned by `bulletproof-bookings`; communications by `bulletproof-communications`. If the grep result pulls in a non-queue file, hand off — do NOT fix out-of-scope.

**Post-fix verification:**
- `grep -n "toISOString().split('T')\|toTimeString().slice\|getDay()\|getHours()" <the-edited-file>` → 0 matches for the replaced lines
- Also run `tz-audit` skill on the edited file
- `npx tsc --noEmit` → no new errors
- **Live probe (deferred):** check in a client at 9:00 PM Eastern on a Sunday → `queue_entries.check_in_time` stored correctly in UTC → UI displays "9:00 PM Sunday" in Eastern, not "1:00 AM Monday"

---

## Pattern 8 — Restore realtime subscription on a consumer hook

**When:** User reports "queue change in Supabase took >1s to appear on screen" or audit finds a consumer page that re-fetches on a timer instead of subscribing to realtime. Invariant C8 (realtime-enabled tables match expected) flags a gap.

**Before (broken — polling instead of subscribing):**
```tsx
useEffect(() => {
  const interval = setInterval(() => {
    fetchQueueEntries() // ← polling every N seconds
  }, 5000)
  return () => clearInterval(interval)
}, [])
```

**After (correct — realtime subscription):**
```tsx
useEffect(() => {
  const supabase = createClient()
  const channel = supabase
    .channel(`queue-entries-${locationId}`)
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'queue_entries', filter: `location_id=eq.${locationId}` },
      (payload) => {
        // refetch or patch local state from payload
        refetchQueueEntries()
      }
    )
    .subscribe()
  return () => {
    supabase.removeChannel(channel)
  }
}, [locationId])
```

**Scope limit:** Only the hook/component the user reported as slow. Do NOT convert all pollers to subscriptions in one pass.

**Post-fix verification:**
- Query `SELECT tablename FROM pg_publication_tables WHERE pubname = 'supabase_realtime' ORDER BY tablename;` via `mcp__supabase-mt__execute_sql` → includes `queue_entries`, `staff_status`, `barber_notifications`
- `grep -n "setInterval\|setTimeout" <the-edited-file>` → no polling loops targeting queue data
- `grep -n "removeChannel" <the-edited-file>` → cleanup present
- `npx tsc --noEmit` → no new errors
- **Live probe (deferred):** mutate a `queue_entries` row via SQL editor → UI reflects the change within ~1s (not 5s)

---

## Cross-pattern rules

1. **Never write to production Supabase during a fix.** Not to verify, not to reproduce, not "temporarily." All verification is SELECT-only via `mcp__supabase-mt__execute_sql`. If a fix genuinely requires a write, escalate with explicit scope (`debugging-protocol.md` Section 9).
2. **Never replace a working atomic RPC with inline SQL.** `assign_queue_position`, `complete_queue_service`, `transition_staff_status`, `upsert_client_from_service`, `increment_barber_cuts` are all locked. They prevent race conditions. Replacing them inline is an unauthorized system change (`debugging-protocol.md` Section 7-8).
3. **Never add a "claim" mechanic to fair rotation.** The rotation is 100% fairness-based by documented design. Any code that lets a barber pre-claim or bypass rotation directly contradicts the `CLAUDE.md` System C design. Suggest only; do not implement.
4. **Always mirror queue UI fixes.** `/barber/walk-ins` and `/dashboard/my-chair` share the same queue code. A fix on one without the other creates drift — see Pattern 5.
5. **Always verify the API guard survives alongside the frontend guard.** `calledClientIdRef` (frontend) and the in-chair guard (API) are belt-and-suspenders. Neither replaces the other.
6. **Never use `mcp__supabase__`.** It points at the nightclub project. MT Barbershop is `mcp__supabase-mt__` only. Mixing them is a silent data-source bug.
7. **Two-strike rule in fix mode.** If the first attempt fails, the second must use a DIFFERENT approach. Third attempt = STOP and report "I don't know" (`debugging-protocol.md` Section 5).

---

## When adding a NEW queue feature (not a fix)

This skill is for audit / diagnose / fix only. For new features, stop and hand off:
- Use `plan-feature` skill to draft a `.planning/` spec
- Get explicit user approval on the spec
- Then implement on a `feature/<description>` branch

Do NOT propose a new feature from within a fix-mode invocation. The Zero Tolerance rule (`debugging-protocol.md` Section 7) treats any unsolicited new file, RPC, hook, or route as unauthorized work subject to full revert.
