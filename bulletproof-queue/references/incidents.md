# Walk-In Queue Incident Registry

Each incident includes: the symptom a user reports, the root cause, the files that were fixed, and the rule that came out of it. Use this in `diagnose` mode to match a new report against known failures.

---

## Timezone Bug (2026-03-28)

**Symptom (as user sees it):**
- A booking at 8:00 AM EDT shows as 12:00 PM on the calendar or in confirmation SMS
- Appointments appear 4 hours offset (EDT) or 5 hours offset (EST) from what was booked
- A Wednesday booking shows up on Tuesday's column

**Root cause:**
Vercel runs in UTC. Node's default `toISOString().split('T')[0]`, `getDay()`, `getHours()`, `toTimeString().slice()` all return UTC values. When used to compute local date/time without an explicit `timeZone: 'America/New_York'`, you get the UTC value, not the Eastern Time value the user expects.

**Correct patterns (copy these exactly):**
- Date (YYYY-MM-DD Eastern): `date.toLocaleDateString('en-CA', { timeZone: 'America/New_York' })`
- Time (HH:MM Eastern, 24h): `date.toLocaleTimeString('en-GB', { timeZone: 'America/New_York', hour: '2-digit', minute: '2-digit', hour12: false })`
- Day-of-week Eastern: `date.toLocaleDateString('en-US', { timeZone: 'America/New_York', weekday: 'short' })` then map to number
- Display: always pass `{ timeZone: 'America/New_York' }` to `toLocaleDateString` / `toLocaleTimeString`

**Banned patterns:**
- `toISOString().split('T')[0]` — UTC date, not local
- `toTimeString().slice()` — UTC time, not local
- `getDay()` / `getHours()` without timezone conversion

**Files fixed:**
- `src/app/api/bookings/from-external/route.ts`
- `src/app/api/resend/inbound/route.ts` (notifications + `resolveBarberLocation`)
- `src/app/api/bookings/migrate-appointments/route.ts`

**Safe (already correct):**
- `src/lib/booksy/parser.ts` — handles EDT/EST offset detection, stores proper UTC timestamps

**Calendar filter detail:**
`src/lib/hooks/useCalendarEvents.ts` filters Booksy events with `.in('status', ['confirmed'])` — excludes both `cancelled` AND `converted` events.

**Rule:** ALL date/time operations that run on Vercel MUST include `timeZone: 'America/New_York'`. See MEMORY.md "Booksy Timezone Rule — HARD RULE."

**Diagnose checklist when you see this symptom:**
1. Find the code that writes / reads the affected timestamp.
2. Grep for banned patterns in that file and its helpers.
3. Fix with the correct pattern above.
4. Verify: compare what's in Supabase (UTC) to what the UI renders (should be Eastern).

---

## Fetch Cache Bug (2026-03-26)

**Symptom:**
- Queue page, owner dashboard, or barber dashboard shows stale data
- Data updates in Supabase but the UI doesn't reflect it for ~60 seconds or more
- A page refresh doesn't fix it; only a hard refresh or redeploy does
- Realtime subscriptions fire but the refetched data is old

**Root cause:**
Next.js 14 enables the Data Cache by default in production builds. It caches ALL `fetch()` results, including the ones made internally by the Supabase JS client. Result: even a "fresh" query from Supabase can return cached data for minutes.

`export const dynamic = 'force-dynamic'` is NOT enough. It only disables the Full Route Cache, not the Data Cache applied to individual `fetch()` calls.

**The fix:**
All Supabase client factories must wrap `global.fetch` to force `cache: 'no-store'`:

```ts
createClient(url, key, {
  global: {
    fetch: (input: RequestInfo | URL, init: RequestInit = {}) =>
      fetch(input, { ...init, cache: 'no-store' }),
  },
})
```

**Files that must have this wrapper:**
- `src/lib/supabase/admin.ts` (service role)
- `src/lib/supabase/server.ts` (server component / SSR auth)
- Any inline `createClient(...)` anywhere in the codebase (examples per MEMORY.md: `src/app/api/barber/schedule/route.ts`, `src/app/api/barber/location-request/route.ts`)

**Rule:** NEVER remove the `cache: 'no-store'` wrapper. If you create a new Supabase client factory anywhere, it MUST include the wrapper.

**Diagnose checklist when you see this symptom:**
1. `grep -n "cache: 'no-store'" src/lib/supabase/*.ts` — both factories must match.
2. `grep -rn "createClient(" src/app/api/` — every inline usage must either import from `@/lib/supabase/*` or include its own `cache: 'no-store'` wrapper.
3. Restart the dev server after the fix (cached builds survive HMR).

---

## `calledClientIdRef` Guard Incident (2026-04-11)

**Symptom:**
- Auto-start fires for a client the barber never called
- Example from incident: Brayan's dashboard auto-started service for Latoya Green without Brayan pressing "Call Next" for her
- The 60-second auto-start timer seems to fire on any `called` state transition, not just the barber's own actions

**Root cause:**
Original code (commit `f34370d`) used a boolean `autoStartFiredRef` that was set whenever `called_time` transitioned to non-null, regardless of who caused the transition. A reset `useEffect([currentClient?.id])` cleared the flag when Supabase realtime delivered the `called` update — which happened BEFORE the 60s timer fired. By the time the timer checked the flag, it had been reset, so auto-start fired for the wrong client.

**The correct implementation:**
`calledClientIdRef = useRef<string | null>(null)` stores the EXACT client ID that was called. It is:
- Set ONLY inside `handleCallNext()` on API success
- Never reset by a `useEffect([currentClient?.id])`
- Checked in the auto-start timer via `calledClientIdRef.current !== currentClient?.id` — if they don't match, do nothing

Why the client-ID pattern works: even if Supabase realtime changes `currentClient.id` before the timer fires, the stored ID doesn't match the new current client → auto-start aborts. No race condition.

**Files (must be identical — Cross-Dashboard Mirroring Rule):**
- `src/app/(dashboard)/barber/walk-ins/page.tsx`
- `src/app/(dashboard)/dashboard/my-chair/page.tsx`

**API-level guard (also required, do not remove):**
`src/app/api/queue/entry/[id]/route.ts` lines ~217-252 blocks the `→in_chair` transition when the barber already has another active `in_chair` entry or an active booking. Belt-and-suspenders with the frontend guard.

**Banned patterns:**
- Boolean flags (`autoStartFiredRef`, `calledBySelfRef`) for this purpose
- A `useEffect` that resets the ref on `[currentClient?.id]`
- Removing the API-side guard "because the frontend already handles it"

**Rule:** NEVER use a boolean flag or reset-effect for auto-start gating. Use the client-ID match pattern. See MEMORY.md "HARD RULE — Auto-Start Service."

**Skip behavior:** When a barber taps "Skip" / passes their turn, `calledClientIdRef` stays null → when the 60s timer eventually runs for whoever is next, the ID check fails → nothing happens. This is correct.

**Diagnose checklist when you see this symptom:**
1. Read both mirrored files. Both must declare `calledClientIdRef` and use the ID-match pattern.
2. Confirm `calledClientIdRef.current = entryId` runs ONLY inside `handleCallNext` after a successful API response.
3. Confirm no `useEffect` resets the ref based on `currentClient?.id`.
4. Confirm the API route still has the `→in_chair` guard.

---

## Any-Barber Deferred Assignment (2026-03-22) — INTENDED BEHAVIOR

**User report that triggers this entry:**
- "Why is the `assigned_barber_id` empty on a queue entry?"
- "Why isn't the barber assigned at check-in time?"

**This is not a bug.** Queue entries with `barber_preference_id = NULL` (any-barber selection) are created with `assigned_barber_id = NULL`. Assignment happens at CALL time, using real-time fair rotation over `staff_status.cuts_today`.

**Why:** Assigning at check-in would use a stale snapshot of `cuts_today`. By the time the client gets called, the fair-rotation winner may be different.

**Flow:**
1. Client checks in, picks "Any Barber" → entry: `barber_preference_id = NULL`, `assigned_barber_id = NULL`, `status = 'waiting'`
2. Auto-assign engine (or a barber's "Call Next") picks lowest `cuts_today` barber who is clocked in, not on break, not with a client, no conflicts
3. PATCH the entry: `status = 'called'`, `assigned_barber_id = [picked barber]`, `called_time = now()`

**If the user is confused, explain this is the design.** If someone proposes reverting to check-in-time assignment, that is a system change — requires explicit approval and affects fair rotation correctness. Do not implement.

---

## Unauthorized Commit Revert (2026-03-20) — Pattern to Watch For

**Symptom:**
You (or a previous session) notice unfamiliar files or patterns in the queue code:
- A `claim_queue_entry` RPC being called from app code
- A hook called `useIncompleteFlowEntry`
- Cron routes like `/api/cron/stale-cleanup` or `/api/cron/queue-cleanup`
- A duplicate "Start Service" button in `MobileQueueView` or `PostServiceFlow`
- Zod schemas with `flow_step` fields
- New database migrations creating `claim_queue_entry` or similar

**Root cause:**
Commit `6d4e4ff` turned a verification task into a 40-file rewrite. It was reverted via `git revert` → commit `ad99107`. The `claim_queue_entry` RPC still exists in production Supabase as dead code (harmless because nothing calls it).

**What's correct:**
- Inline FIFO + rotation validation lives in `src/app/api/queue/entry/[id]/route.ts`
- `MobileQueueView` has ONE Start button (on the active client card)
- `PostServiceFlow` does NOT persist `flow_step`
- Zod schemas for queue entry do not include `flow_step`

**Rule:** If you see the patterns above reappear in a diff or a file read, STOP. Flag them to the user immediately. They are the signature of unauthorized work creeping back in. See `debugging-protocol.md` Section 7.

**Diagnose checklist:**
1. `grep -rn "claim_queue_entry\|useIncompleteFlowEntry\|flow_step" src/ supabase/migrations/`
2. Any match (except the DB migration for the dead RPC) = investigate and likely revert.

---

## User Reports Override Queries — Meta-Rule

**Symptom:**
- User says: "I see Gustavo's name on the queue screen for Newark"
- You query `barber_schedules` for `day_of_week = today` at Newark and don't find Gustavo
- You tell the user they're mistaken

**Don't.** The UI may query a DIFFERENT table than you checked. Example: `/queue` filters barbers by `staff_status.location_id` (who's clocked in RIGHT NOW), not `barber_schedules.location_id` (who is scheduled).

**Rule:**
1. User reports a fact from the screen → that fact is ground truth.
2. Find the exact code path the UI uses to get that data.
3. Check THAT table. Fix THAT data source.
4. Never argue with a screenshot.

---

## Quick Match Table

| Symptom | Likely incident | First file to read |
|---|---|---|
| Stale data, slow to update | Fetch Cache Bug | `src/lib/supabase/admin.ts` / `server.ts` |
| Auto-start fires for wrong client | `calledClientIdRef` Guard | `barber/walk-ins/page.tsx` + `my-chair/page.tsx` |
| Times off by 4-5 hours | Timezone Bug | the file that renders or writes the timestamp |
| Two clients `in_chair` per barber | API guard bypass | `src/app/api/queue/entry/[id]/route.ts` |
| `flow_step`, `claim_queue_entry`, or mystery cron appearing | 6d4e4ff leakage | grep and revert |
| UI shows X, query says Y | User-Reports-Override | trace the code path, not the first-guess table |
| "Any Barber" has no assigned_barber_id | Deferred Assignment | this is correct — not a bug |
