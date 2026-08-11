# Services — Fix Patterns

Paste-ready diffs for every gap the `bulletproof-services` audit flags. When a failure maps to a pattern here, point the user to it, get explicit approval, apply ONE pattern per invocation, then verify.

All patterns assume:
- `createAdminClient` imported from `@/lib/supabase/admin`
- `createClient` (SSR / browser) imported from `@/lib/supabase/server` or `@/lib/supabase/client`
- `barber_custom_services` reads / writes always cast via `(supabase as any)` — the table is NOT in generated Supabase types (see `incidents.md` "barber_custom_services not in generated Supabase types").
- Changes stay on a `fix/…` branch per `.claude/rules/branch-workflow.md`. Never commit to `main`.

---

## Fix-mode preflight checklist (universal — applies to every pattern)

Fix mode runs this sequence for EVERY pattern before the `Edit`. Do all steps, in order. Skip none.

1. **Preflight** — Read the target file. Match the pattern's "Before" block against current code exactly (imports, function names, variable names, surrounding context — NOT just line numbers, which drift). If ANY of these don't match → STOP. Report what differs. Do NOT apply a stale pattern.
2. **Classify** — Decide whether the failure is data-level (run the invariant's SELECT query via `mcp__supabase-mt__execute_sql`) or code-level (grep). Report live-impact ("N active bookings reference a now-deleted service") vs latent ("FK rule is wrong, but no one has hard-deleted a service yet"). User decides urgency from this.
3. **Confirm diff** — Show the exact `old_string` / `new_string`. Wait for explicit `yes`.
4. **Apply** — Single `Edit` call per file. One pattern per invocation. Multi-file patterns (e.g. cross-dashboard mirror) do each file as a separate fix.
5. **Verify** — Run the pattern's post-fix verification block. Every grep and SQL check must pass. `npx tsc --noEmit` must not add new errors.
6. **Mirror** — Services UI lives on TWO dashboards (owner `/dashboard/my-chair/services` and barber `/barber/settings` Services tab). Any UI/logic change in one MUST be mirrored. Invoke the `mirror-check` skill before handoff.
7. **Handoff** — Stop at `bulletproof-ship`. Do not commit.

If any step fails, STOP and report. Do not proceed to the next step.

---

## Pattern 1 — FK delete rule drift back to CASCADE

**When:** Invariant #1 fails — one of `bookings.service_id`, `bookings.custom_service_id`, `queue_entries.service_id`, `service_transactions.service_id` shows `delete_rule = CASCADE`. This is the regression documented in `incidents.md` "CASCADE on bookings.service_id (pre-2026-04-21, commit fb35208)". Latent until someone hard-deletes a service; then every future booking for that service vanishes.

**Before:** A new migration added the FK without `ON DELETE SET NULL`, or someone ran raw SQL that re-created the constraint with default behavior. Schema diff shows:
```sql
-- pg_constraint inspection
bookings.service_id -> services.id  ON DELETE CASCADE   -- WRONG
```

**After:** All four consumer FKs use `ON DELETE SET NULL`. History stays intact — bookings keep their stored `duration_minutes`, `service_amount`, and (on `service_transactions`) `service_name`. Only the FK link is nulled.

```sql
-- supabase/migrations/<timestamp>_restore_services_fk_set_null.sql
ALTER TABLE bookings DROP CONSTRAINT bookings_service_id_fkey;
ALTER TABLE bookings ADD CONSTRAINT bookings_service_id_fkey
  FOREIGN KEY (service_id) REFERENCES services(id) ON DELETE SET NULL;
-- Repeat for any other column that regressed. Do NOT touch barber_services.service_id
-- (that one is CORRECTLY CASCADE — junction row goes away if the service is deleted).
```

**Scope limit:** Only the four consumer columns listed above. `barber_services.service_id` CASCADE is intentional and correct (per `invariants.md` #1 note). Do not change it.

**Post-fix verification:**
- Re-run invariant #1 query → expected 4 rows, all `delete_rule = SET NULL`.
- `SELECT COUNT(*) FROM bookings WHERE service_id IS NULL AND status IN ('pending','confirmed')` — should be ~0 (no pre-existing damage to repair).
- Migration applied cleanly via `npx supabase db push` (user runs this, NOT the skill).

---

## Pattern 2 — Walk-in queue leaks barber-scoped services

**When:** Invariant C1 fails — `src/app/(public)/queue/page.tsx` Step 4 ("Select Service") is rendering results from `barber_services` or `barber_custom_services`. HARD RULE violation from `CLAUDE.md` System C: walk-in services are BUSINESS SERVICES ONLY, owner-controlled at `/dashboard/services`, uniform across barbers and locations.

**Before:** The queue page is calling `/api/barber/services?barber_id=...` or importing a barber-scoped hook:
```tsx
// src/app/(public)/queue/page.tsx
const { data: services } = useSWR(
  `/api/barber/services?barber_id=${barberId}`,  // WRONG — leaks personal services
  fetcher
)
```

**After:** Queue Step 4 reads ONLY from the global `services` table via `useServices(true)`:
```tsx
// src/app/(public)/queue/page.tsx
import { useServices } from '@/lib/hooks/useServices'

const { services, loading } = useServices(true)  // activeOnly=true → WHERE is_active=true on services
// No barber_id, no custom services, no per-barber pricing. Uniform walk-in menu.
```

**Scope limit:** Touch only the queue wizard Step 4 service picker. Do NOT change barber profile, booking wizard, or `/services` public page — those intentionally use different sources. Do NOT introduce a new hook; `useServices(true)` already exists.

**Post-fix verification:**
- `grep -n "barber_services\|barber_custom_services\|/api/barber/services" src/app/\(public\)/queue/` → 0 matches (queue path is isolated from barber-scoped data).
- `grep -n "useServices(true)" src/app/\(public\)/queue/page.tsx` → ≥1 match.
- `npx tsc --noEmit` → no new errors.
- Manual spot-check: load `/queue`, reach Step 4, confirm the menu matches `/dashboard/services` exactly (same names, same prices, same ordering).

---

## Pattern 3 — Booking wizard POST stores both `service_id` AND `custom_service_id`

**When:** Invariant C3 fails — `src/app/api/bookings/route.ts` POST sometimes writes both columns non-null, OR neither (returns 400 "unknown service"). Indicates the lookup branch is wrong.

**Before:** The handler writes `service_id` from the request body without deciding which column it belongs to:
```ts
// src/app/api/bookings/route.ts — BROKEN
const { service_id } = body
const { data: booking } = await supabase.from('bookings').insert({
  service_id,           // might belong to barber_custom_services
  custom_service_id: null,
  // ...
})
```

**After:** Lookup in `services` first, then `barber_custom_services`. Mutually exclusive assignment. Duration + price copied at write time (frozen snapshot per `invariants.md` C3/C6).
```ts
// src/app/api/bookings/route.ts
const serviceUuid = body.service_id  // wizard sends a UUID, not knowing which table

const { data: globalService } = await supabase
  .from('services')
  .select('id, name, price, duration_minutes')
  .eq('id', serviceUuid)
  .eq('is_active', true)
  .maybeSingle()

let service_id: string | null = null
let custom_service_id: string | null = null
let serviceName: string
let servicePrice: number
let serviceDuration: number

if (globalService) {
  service_id = globalService.id
  serviceName = globalService.name
  servicePrice = globalService.price
  serviceDuration = globalService.duration_minutes
} else {
  // Fall back to barber custom services — (supabase as any) required (see incidents.md).
  const { data: customService } = await (supabase as any)
    .from('barber_custom_services')
    .select('id, name, price, duration_minutes, barber_id')
    .eq('id', serviceUuid)
    .eq('is_active', true)
    .maybeSingle()

  if (!customService || customService.barber_id !== body.barber_id) {
    return NextResponse.json({ error: 'unknown service' }, { status: 400 })
  }
  custom_service_id = customService.id
  serviceName = customService.name
  servicePrice = customService.price
  serviceDuration = customService.duration_minutes
}

// NEVER both non-null. NEVER both null at insert time.
const { data: booking } = await supabase.from('bookings').insert({
  service_id,
  custom_service_id,
  duration_minutes: serviceDuration,  // frozen at creation
  service_amount: servicePrice,        // frozen at creation
  // ...
})
```

**Scope limit:** Only the booking POST handler. Do not touch reschedule (`PATCH`) or cancel — those read the already-stored row.

**Post-fix verification:**
- SQL: `SELECT COUNT(*) FROM bookings WHERE service_id IS NOT NULL AND custom_service_id IS NOT NULL` → 0 rows.
- SQL: `SELECT COUNT(*) FROM bookings WHERE service_id IS NULL AND custom_service_id IS NULL AND deleted_at IS NULL AND status IN ('pending','confirmed','in_progress')` → 0 rows (except rows where the FK was SET NULL after a service hard-delete — check `updated_at` if in doubt).
- Create a test booking via the wizard with a global service → confirm `service_id` set, `custom_service_id` NULL.
- Create a test booking with a barber custom service → confirm `custom_service_id` set, `service_id` NULL.

---

## Pattern 4 — Missing `(supabase as any)` cast on `barber_custom_services`

**When:** Invariant C12 / incident "barber_custom_services not in generated Supabase types". Build fails with `Property 'barber_custom_services' does not exist on type 'SupabaseClient'` after adding a new read or write path.

**Before:**
```ts
// Server component or API route — FAILS TS build
const { data: customServices } = await supabase
  .from('barber_custom_services')
  .select('*')
  .eq('barber_id', barberId)
  .eq('is_active', true)
```

**After:** Cast the client to `any` for the chained call. Do NOT edit `src/lib/types/database.ts` by hand (per `incidents.md` DO NOT list).
```ts
const { data: customServices } = await (supabase as any)
  .from('barber_custom_services')
  .select('*')
  .eq('barber_id', barberId)
  .eq('is_active', true)
```

**Scope limit:** Only the lines that touch `barber_custom_services`. Do not wholesale-cast the Supabase client for the entire file.

**Permanent fix (separate task, user-approved only):**
```bash
npx supabase gen types typescript --project-id axkcbijbwhcydsqbhtpu > src/lib/types/database.ts
# Then remove (supabase as any) casts in the same commit.
```
Do NOT run this silently — it regenerates ALL types and can introduce unrelated diffs.

**Post-fix verification:**
- `npx tsc --noEmit` → no new errors.
- `grep -n "barber_custom_services" <edited-file>` shows every call wrapped in `(supabase as any)`.

---

## Pattern 5 — Service duration / price edit expected to propagate to existing bookings

**When:** Owner edits `services.duration_minutes` or `services.price` and reports "the change didn't save" on an existing booking. Matches `incidents.md` "Duration edit expected to propagate retroactively (UX expectation, not a bug)".

**Before:** No code change needed. This is intentional per `invariants.md` C6 and P1 — durations and amounts are frozen at booking creation so confirmed appointments don't mutate mid-flight.

**After:** Explain the behavior to the user. DO NOT add a trigger, cron, or migration that retroactively updates `bookings.duration_minutes` or `bookings.service_amount`. That would:
- Shift confirmed customer appointments without notice
- Collide with the `bookings_no_time_overlap` exclusion constraint (new duration may overlap adjacent bookings)
- Invalidate `service_transactions` rows where the amount is already reconciled against a Stripe charge

**Scope limit:** None — no code change. Refuse to implement retroactive propagation unless the user explicitly overrides the HARD RULE in writing (and flag the override per global reporting rules).

**Post-fix verification:**
- None. The "fix" is the explanation.
- If user insists on retroactive update for ONE specific booking, edit that booking directly in the calendar UI (CalendarEventDetailModal supports inline duration edits per MEMORY.md "Session 1: Queue + Booking Hardening").

---

## Pattern 6 — Custom service missing from public barber profile

**When:** Barber added a custom service, it shows in `/barber/settings?tab=services`, but it's absent from `/mtbarbers/[slug]`. Matches `invariants.md` C4 / quick match "Custom service missing from profile → `is_active=false` OR RLS select fail".

**Before:** Two likely causes — check both, fix the actual one:
1. Row has `is_active=false` (soft-deleted by the barber):
   ```sql
   SELECT id, name, is_active, created_at FROM barber_custom_services WHERE barber_id = '<id>';
   ```
2. Server component on `/mtbarbers/[slug]/page.tsx` is NOT using a `cache: 'no-store'` Supabase client, so the row was cached before it was inserted (Next.js 14 Data Cache — see MEMORY.md "Common Pitfalls").

**After (case 1):** Reactivate the row via the barber's own UI — owner should NOT patch a barber's data under the skill. Tell the barber to toggle it back on at `/barber/settings?tab=services`.

**After (case 2):** Confirm the page uses the SSR Supabase factory (`@/lib/supabase/server`), which already wraps fetch with `cache: 'no-store'`. If a new inline `createClient()` was added to this file, it MUST include the same wrapper — or switch to the shared factory.

```tsx
// src/app/(public)/mtbarbers/[slug]/page.tsx — AFTER
export const dynamic = 'force-dynamic'  // defeats Full Route Cache — NOT sufficient alone
import { createClient } from '@/lib/supabase/server'  // this factory includes cache: 'no-store'

const supabase = await createClient()
const { data: customServices } = await (supabase as any)
  .from('barber_custom_services')
  .select('*')
  .eq('barber_id', barber.id)
  .eq('is_active', true)
```

**Scope limit:** Only the profile page. Do NOT touch booking or queue paths.

**Post-fix verification:**
- SQL: confirm the row has `is_active = true`.
- Reload `/mtbarbers/[slug]` — custom service appears. Hard refresh (Cmd+Shift+R) to bust any browser cache.
- `grep -n "cache: 'no-store'\|createClient" src/app/\(public\)/mtbarbers/\[slug\]/page.tsx` — confirm the shared factory is used.

---

## Pattern 7 — Missing `description` field on customer-facing surfaces (2026-03-23 addition)

**When:** `description` column exists on both `services` and `barber_custom_services` (per MEMORY.md "Service System — HARD RULE", description added 2026-03-23), but a new customer-facing surface (new service card, upsell widget, Stripe checkout line item) doesn't render it.

**Before:** Component only reads `name`, `price`, `duration_minutes`:
```tsx
<ServiceCard
  name={service.name}
  price={service.price}
  duration={service.duration_minutes}
/>
```

**After:** Render `description` conditionally (some services don't have one — NULL is valid):
```tsx
<ServiceCard
  name={service.name}
  description={service.description}  // NEW — optional
  price={service.price}
  duration={service.duration_minutes}
/>

// Inside ServiceCard:
{description ? (
  <p className="text-[11px] text-zinc-400 mt-1">{description}</p>
) : null}
```

**Scope limit:** Only the surface that's missing the field. All four existing customer surfaces (queue Step 4, booking wizard Step 3, `/mtbarbers/[slug]`, `/services`) already render `description` per the 2026-03-23 rollout. Don't re-plumb those.

**Post-fix verification:**
- `grep -n "description" <edited-component>` → present.
- Manual check: load the surface, confirm description renders when set and is hidden when NULL.
- `npx tsc --noEmit` clean.

---

## Pattern 8 — Availability API returns slots overlapping existing bookings

**When:** Invariant C7 fails — `/api/bookings/availability` returns slots that collide with a `confirmed` / `pending` / `in_progress` booking or an `in_chair` queue entry. Also fails when dates/times use UTC instead of Eastern (Booksy TZ HARD RULE in MEMORY.md).

**Before:** Busy list missing a status, OR using raw `getDay()` / `toISOString().split('T')[0]` that returns UTC on Vercel:
```ts
// src/app/api/bookings/availability/route.ts — BROKEN
const busy = await supabase
  .from('bookings')
  .select('scheduled_time, duration_minutes')
  .in('status', ['confirmed'])  // MISSING 'pending' AND 'in_progress'

const dateStr = new Date(date).toISOString().split('T')[0]  // UTC — WRONG on Vercel
```

**After:** All three pending-to-in-progress statuses included. Dates formatted with `timeZone: 'America/New_York'` per Booksy TZ rule. DB-level safety net (`bookings_no_time_overlap` exclusion constraint) stays intact as a second defense.
```ts
// src/app/api/bookings/availability/route.ts
const busyBookings = await supabase
  .from('bookings')
  .select('scheduled_time, duration_minutes')
  .eq('barber_id', barberId)
  .eq('scheduled_date', dateStr)
  .in('status', ['confirmed', 'pending', 'in_progress'])  // all three
  .is('deleted_at', null)

const busyQueueEntries = await supabase
  .from('queue_entries')
  .select('start_time, duration_minutes')
  .eq('assigned_barber_id', barberId)
  .in('status', ['in_chair'])  // in_chair also occupies the barber

// Eastern-time date formatting (see MEMORY.md "Booksy Timezone Rule")
const easternDate = new Date(date).toLocaleDateString('en-CA', {
  timeZone: 'America/New_York',
})  // → 'YYYY-MM-DD' in Eastern
```

**Scope limit:** Only `availability/route.ts`. Do not modify the overlap constraint, the booking POST flow, or the calendar hook.

**Post-fix verification:**
- `grep -n "'confirmed'" src/app/api/bookings/availability/route.ts` followed by `'pending'` and `'in_progress'` — all three present.
- `grep -n "toISOString\|getDay\|getHours" src/app/api/bookings/availability/route.ts` — 0 matches (all TZ-naive helpers purged).
- SQL: `SELECT conname FROM pg_constraint WHERE conname = 'bookings_no_time_overlap'` — 1 row (safety net intact).
- Live probe: request availability for a barber with an existing 2:00 PM booking, confirm 2:00 / 2:15 / 2:30 do NOT appear as available (for a 30-minute service).

---

## Pattern 9 — Cross-dashboard drift between owner and barber service UIs

**When:** A fix landed on `/barber/settings` Services tab but NOT on `/dashboard/my-chair/services` (or vice versa). Violates the Cross-Dashboard Code Mirroring HARD RULE (`.claude/rules/context-awareness.md`).

**Before:** Barber page has a new validation, error state, or API call; owner my-chair page does not. E.g. barber page added a "Category required" inline error, owner my-chair page still lets the field blank through.

**After:** Apply the SAME change, character-for-character if possible, to the mirror page. Same state variable names. Same error text. Same API endpoint.

Equivalent page map for services UI:
| Barber page | Owner (my-chair) page | Shared API |
|---|---|---|
| `src/app/(dashboard)/barber/settings/page.tsx` (Services tab) | `src/app/(dashboard)/dashboard/my-chair/services/page.tsx` | `/api/barber/services`, `/api/barber/custom-services` |

Both pages consume the exact same two endpoints. Any auth-derived `barber_id` scoping happens server-side — the client code should be identical.

**Scope limit:** Only the mirror page. Do NOT touch the owner walk-in admin at `/dashboard/services` — that's a different tier (global `services` table), not a mirror.

**Post-fix verification:**
- Diff the two files region-to-region. Any service-tab logic present in one and absent from the other = drift.
- Invoke the `mirror-check` skill to confirm parity before ship.
- `npx tsc --noEmit` clean.

---

## Pattern 10 — Orphan `upsell_rules` referencing inactive or deleted services

**When:** Invariant #8 fails — an `upsell_rules` row points at a `trigger_service_id` or `suggested_service_id` that is `is_active=false` or NULL. Silent failure: the rule never fires and nobody notices.

**Before:** No code bug — data drift. An owner deactivated a service without cleaning up its upsell rules.

**After:** Two options, owner decides:
1. Delete the stale rules (if the service is truly retired):
   ```sql
   -- READ-ONLY from the skill's side — the owner runs this manually after approval.
   DELETE FROM upsell_rules
   WHERE trigger_service_id IN (SELECT id FROM services WHERE is_active = false)
      OR suggested_service_id IN (SELECT id FROM services WHERE is_active = false);
   ```
2. Reactivate the referenced services if they were deactivated by mistake (via `/dashboard/services` UI — NOT via raw SQL from the skill).

**Scope limit:** No code change. Data-level cleanup only. The skill is READ-ONLY (per `SKILL.md` HARD RULES). The DELETE above is NOT run from the skill — it's printed for the user to run themselves.

**Post-fix verification:**
- Re-run invariant #8 → 0 rows.
- Walk through an upsell flow at `/barber/walk-ins` to confirm rules still trigger for the remaining active pairs.

---

## Cross-pattern rules

1. **Services system is LOCKED.** Three-tier separation (walk-in / barber booking / owner personal) is documented as a HARD RULE in CLAUDE.md and MEMORY.md. Do not "unify" it to one table, even if it looks redundant.
2. **Duration + price are FROZEN at row creation.** Do not add retroactive propagation (Pattern 5).
3. **READ-ONLY SQL only.** Every invariant query goes through `mcp__supabase-mt__execute_sql` with a SELECT. Any INSERT/UPDATE/DELETE — including cleanup — must be approved by the user and run by the user (`safe-query` skill).
4. **Mirror every UI change.** Services UI lives on two dashboards. Apply every fix to both. Invoke `mirror-check` before ship.
5. **Use `(supabase as any)` on `barber_custom_services`** (Pattern 4). Do not hand-edit `database.ts`.
6. **Never trust UTC date/time on Vercel.** Availability, reminders, calendar — every one uses `timeZone: 'America/New_York'` (Pattern 8).
7. **Feature branch or nothing.** `fix/…` / `feature/…` only. Never commit to `main` (`.claude/rules/branch-workflow.md`).

---

## When adding a NEW service-consuming surface

Checklist before ship:
1. Does it read from the RIGHT tier? (walk-in → `services` only; booking/profile → `/api/barber/services`; In-Service Mode → stored row)
2. Does it use a `cache: 'no-store'` Supabase client if it's a server component? (Pattern 6)
3. Does it render `description` conditionally? (Pattern 7)
4. Does it use stored `duration_minutes` / `service_amount` from the booking/queue row, not a live service re-fetch? (Invariants C6, C9)
5. If it's a dashboard admin surface, is there a mirror on the other dashboard? (Pattern 9)
6. Any date/time math wrapped with `timeZone: 'America/New_York'`? (Pattern 8)
7. Any new `barber_custom_services` read/write has the `(supabase as any)` cast? (Pattern 4)

If any answer is "no," fix before shipping.
