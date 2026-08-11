---
name: bulletproof-schedules
description: Audit, diagnose, or scale-check the MT Barbershop barber schedules system (barber_schedules table, availability API, location change requests). HARD RULE — one barber, one location, all 7 days, forever; non-uniform location_id across a barber's schedule rows is a bug, never a feature. Use when schedules show stale data, barbers appear at wrong locations, availability returns wrong slots, or before adding a new location. Read-only SQL via mcp__supabase-mt__execute_sql and codebase greps only. Never writes to the production DB. Never modifies application code without explicit user approval.
---

# Bulletproof Schedules

## HARD RULE — One Barber, One Location, Forever (locked 2026-04-25)

**Every barber works at exactly ONE physical location, on every day they work. There is NO operational case — past, present, or future — where a barber works at Location A on some days and Location B on other days within the same week, month, or ever.**

Owner stated this explicitly on 2026-04-25 after Juan Prado's Saturday `barber_schedules` row drifted to New Castle while Mon-Fri were Newark, hiding him from the Newark walk-in queue.

**Implications for this skill — read before doing ANYTHING:**
- All 7 `barber_schedules` rows for a single barber MUST share the same `location_id`. Any drift across rows is a **bug**, not a feature.
- The phrase "per-day location routing" appearing elsewhere in this skill describes the **mechanical implementation** (the table is keyed by `day_of_week`), NOT a real operational pattern. Treat any non-uniform `location_id` across a barber's 7 rows as data corruption that needs repair.
- `barbers.preferred_location_id` is the canonical "this barber's location" anchor. All 7 schedule rows MUST match it.
- Do NOT propose features, UI, or code paths that support split-location weeks (e.g. "Tuesday at Wilmington, Thursday at Newark"). Do NOT audit for them. Do NOT write fix patterns that preserve them.
- `audit` mode MUST flag any barber whose `barber_schedules.location_id` values are non-uniform across rows as a finding. `fix` mode (with explicit approval) collapses all rows to the barber's `preferred_location_id`.
- `location_change_requests` is for **permanent moves** of a barber from one location to another, NOT per-day rotations. Approving a request flips ALL 7 schedule rows + `preferred_location_id` together.
- `resolveBarberLocation` priority chain still works as documented, but the per-day branch should always return the same value as `preferred_location_id`. If they diverge, the schedule is corrupt.
- `barber/clock/route.ts` reading today's schedule for clock-in is harmless **only because all 7 rows agree**. If they don't agree, clock-in silently moves the barber on the wrong day. Treat this as a bug surface in audits.

**Enforcement:** This rule overrides any conflicting language anywhere else in this skill, in `references/`, or in audit-queries. If you find advice that assumes per-day location variation is legitimate, treat it as stale and flag it.

---

## HARD RULE — Schedule + staff_status Feed Walk-In Eligibility (locked 2026-04-25)

`barber_schedules` (location for the day) and `staff_status` (clock state: `clocked_in` / `on_break` / `with_client` / `clocked_out`) are both consumed by the unified walk-in eligibility helper `isBarberAvailableForWalkIn` in `src/lib/queue/booking-conflicts.ts`.

**What this means for this skill:**
- Anything that breaks `staff_status` invariants — stale `clocked_in` rows, mismatched `location_id`, missing rows for new barbers — directly breaks walk-in assignment. Audit `staff_status` integrity as part of any schedule audit.
- The `clocked_in` status is the ONLY value that lets a barber receive a walk-in. `with_client`, `on_break`, `clocked_out`, or a missing row = unavailable.
- Schedule changes that affect today's `location_id` are immediately visible to walk-in routing because clock-in resolves location from `barber_schedules`. The one-location rule above keeps this drift-free.

**Coupling rule:** if you audit `barber/clock/route.ts` (which writes `staff_status.location_id` from today's schedule), you MUST also verify the unified eligibility helper consumers — see `bulletproof-queue` HARD RULE.

---

Schedules drive booking availability, fair-rotation eligibility, and location routing. When they drift, the booking flow silently shows the wrong barber or the wrong location — the kind of bug that leaks real revenue and confuses real customers.

This skill does NOT replace `CLAUDE.md`, `MEMORY.md`, or the `.claude/rules/*.md` files. It READS them, then runs a structured protocol.

---

## Mandatory Preflight — BEFORE any action

Read in order:
1. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/CLAUDE.md` — "System B: Booking Flow" section, "Multi-Location System" section, "Existing Systems Are Sacred" rule.
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-MT-Barbershop-Systems/memory/MEMORY.md` — the Booksy Timezone Rule and the commit `d03b8ef` fix note.
3. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.claude/rules/debugging-protocol.md` — Sections 4, 5, 7, 8, 9.
4. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.claude/rules/context-awareness.md` — Cross-Dashboard Code Mirroring Rule.

After reading, confirm "Preflight complete. Running [mode]."

---

## Choose a Mode

- **audit** → read-only health check
- **diagnose** → specific symptom to investigate
- **scale-check** → prep for adding a location
- **fix** — apply canonical patterns from `references/fix-patterns.md`. EXPLICIT activation only; audit findings do NOT auto-trigger this mode.

---

## AUDIT RIGOR — read before starting audit mode

This skill enforces the universal Audit Rigor Standard at `~/.claude/skills/_shared/audit-rigor.md` and the domain Surface Inventory at `references/SURFACE_INVENTORY.md`. Read both before you do anything.

**Five Pillars (all mandatory):** codebase, database, queries, RLS, integrations. Missing any pillar = failed audit.

**Proof-of-Read:** every file claimed PASS in the Coverage Report MUST cite a `file.ts:LINE` from that file. No line = NOT-RUN, not PASS. This is enforced by the universal standard.

**Forcing language — copy this into your mental model:**

> Do NOT stop on first pass. You MUST work through EVERY file in SURFACE_INVENTORY.md (45+ surfaces), EVERY query in audit-queries.sql, EVERY RLS policy, EVERY trigger, and EVERY integration. Stopping after one finding is a half-audit and is explicitly forbidden.
>
> Silence ≠ Pass. Self-declaration ≠ Proof. Every PASS needs a file:line citation.
>
> Obey the Cross-Surface Coupling Rules below. Skipping a coupled surface while passing its partner = coupling violation.
>
> The Coverage Report + Gap Self-Report are MANDATORY. A report missing either is rejected. If NOT-RUN > 0, the header must say "PARTIAL AUDIT".

---

## Cross-Surface Coupling Rules — MUST be followed

When you audit a surface on the left, you MUST also audit all surfaces on the right in the same session. These rules catch the systemic gaps where one file's behavior depends on another that looks unrelated.

| If you audit... | You MUST also audit... | Why |
|---|---|---|
| `barber/schedule/route.ts` PATCH (barber self-service) | d03b8ef per-day `location_id` preservation intact + `trg_barber_schedule_audit` stamps `updated_by` + realtime `barber_schedules` publication + availability API recompute for touched days + public profile refetch + team page refetch + `useBarbers` hook refetch + Booksy sync not broken for this barber | Schedule PATCH is the entry point — missing the per-day preservation drops Friday's location on save. 7 downstream surfaces read the result. |
| `barbers/[id]/schedule/route.ts` PUT (owner-managed) | Same as above PLUS `preferred_location_id` recompute on `barbers` row (most-common location from new `activeSchedule`) + audit log entry | Owner PUT must re-anchor the barber's default location. Missing = stale routing for clocked-out barbers. |
| `barber/location/route.ts` PUT (manual primary-location switch) | `barbers.preferred_location_id` write + immediate rotation eligibility update + does NOT touch schedule rows (this writes anchor only) + auth event logged | Manual switch is the 3rd writer to `preferred_location_id`. |
| `barber/location-request/route.ts` PATCH (owner approval) | Dual-update: `barber_schedules.location_id` for that day AND `staff_status.location_id` if barber currently clocked in + notification to barber + intentionally does NOT touch `preferred_location_id` | Per-day move must propagate to BOTH tables or queue routes to old location. By-design exception to anchor rule. |
| Any change to `barber_schedules` | Realtime publication `barber_schedules` fires + `useCalendarEvents` recomputes hours + `useBarbers` hook refetches + public profile "Works Mon, Wed, Fri" updates + team page location-per-day filter updates + availability API picks up new hours | Schedule is read by 6 consumers; missing realtime = stale "Works..." display. |
| `auth/create-barber/route.ts` (new barber invite) | `preferred_location_id` set at INSERT (durable anchor) + initial `barber_schedules` rows OR scheduled onboarding prompts + default `is_active` correct + onboarding-step coupling | New barber without `preferred_location_id` = always routed to `locations[0]`. |
| `resolveBarberLocation('current')` in `lib/db/location.ts` | Priority chain: `staff_status.location_id` (only when active) → `preferred_location_id` → today's schedule → most common → `locations[0]` + Eastern TZ via `toLocaleDateString('en-CA', { timeZone: 'America/New_York' })` + `staff_status` status check gates step 1 | 5-step fallback chain. Skipping any step = wrong location. |
| `resolveBarberLocation('appointment')` mode | Appointment day's schedule → `preferred_location_id` → `locations[0]` + Eastern TZ | Appointment mode is used by booking confirmation emails. Wrong location in email = customer drives to wrong plaza. |
| `bookings/availability/route.ts` | Reads `barber_schedules` for requested date's `day_of_week` + uses Eastern TZ for today/now conversion + respects `is_active = true` + gates slots by `start_time`/`end_time`/`break_start`/`break_end` | Availability's bounds come from schedule — stale schedule = customer books outside barber's working hours. |
| `queue/rotation-preview/route.ts` | Fair rotation filters by today's `barber_schedules` match + `staff_status` active + only barbers with a row for today's ET day_of_week | Rotation without schedule filter = assigns walk-in to barber at wrong location. |
| `barber/clock/route.ts` clock-in | `resolveBarberLocation('current')` + writes `staff_status.location_id` from resolved value + rotation eligibility immediate | Clock-in = anchor moment for today's routing. |
| `useBarberSchedule` / `useLocationRequests` hooks | Subscribe to realtime channel on their respective tables + SWR revalidate on mutation + cache: no-store downstream | Hooks are the client-side bridge — missing subscription = barber sees stale schedule. |
| Inline Supabase clients in `barber/schedule/route.ts` + `barber/location-request/route.ts` | Both MUST wrap `global.fetch` with `cache: 'no-store'` (MEMORY.md 2026-03-26 rule) | Missing = stale schedule reads on Vercel. |
| Cross-dashboard schedule UI mirror | `/barber/schedule/page.tsx` matches `/dashboard/my-chair/schedule/page.tsx` — same features, same validation, same location-per-day UX | Drift = Cross-Dashboard Mirroring Rule violation. |
| Delete/deactivate a barber | `barber_schedules.is_active` cascades OR schedule rows removed + `location_change_requests` cleanup + `preferred_location_id` nulled + active staff_status cleanup | Deactivated barber must disappear from availability + team + profile consumers. |

**A PASS on the left side without evidence of auditing the right side = COUPLING VIOLATION.** Report it in the Gap Self-Report.

---

## Mode: audit

### Step 0 — Universal Audit Preamble (MANDATORY — run first, always)

Run the 5 discovery queries from `~/.claude/skills/_shared/audit-rigor.md` section "Universal Audit Preamble", filled in with the schedules domain values:

```sql
-- 1. Enumerate schedules domain tables
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('barber_schedules','location_change_requests','barbers','locations','staff_status')
ORDER BY table_name;
-- Expected: 5 rows. Missing = inventory drift; STOP and ask user.

-- 2. RLS policies on schedule tables
SELECT tablename, policyname, cmd, roles
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('barber_schedules','location_change_requests')
ORDER BY tablename, policyname;
-- Expected: multiple per table (public SELECT on barber_schedules; barber/owner writes).

-- 3. Triggers
SELECT event_object_table, trigger_name, action_timing, event_manipulation
FROM information_schema.triggers
WHERE event_object_schema = 'public'
  AND event_object_table IN ('barber_schedules','location_change_requests')
ORDER BY event_object_table, trigger_name;
-- Expected: trg_barber_schedule_audit on barber_schedules.

-- 4. RPC functions
SELECT routine_name, routine_definition IS NOT NULL AS has_body
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name IN ('set_schedule_updated_by');
-- Expected: 1 row, has_body=true.

-- 5. Migration history
SELECT name, executed_at FROM supabase_migrations.schema_migrations
WHERE name ILIKE '%barber_schedule%' OR name ILIKE '%location_change%'
   OR name ILIKE '%schedule_break%' OR name ILIKE '%schedules_realtime%'
ORDER BY executed_at;
-- Expected: at least 5 rows (see SURFACE_INVENTORY.md section 11).

-- 6. preferred_location_id column on barbers + realtime publication
SELECT column_name FROM information_schema.columns
WHERE table_name = 'barbers' AND column_name = 'preferred_location_id';
-- Expected: 1 row. If missing = CRITICAL; fallback routing broken for clocked-out barbers.

SELECT tablename FROM pg_publication_tables
WHERE pubname = 'supabase_realtime' AND tablename = 'barber_schedules';
-- Expected: 1 row.
```

Attach all 6 result sets to the report under "Universal Preamble". Any drift = stop before domain checks.

### Code-level invariants

1. **Schedule API preserves per-day location_id** (commit `d03b8ef` fix)
   - File: `src/app/api/barber/schedule/route.ts` lines ~129-193
   - Must: read existing rows FIRST, build `existingLocationByDay` map, then delete, then re-insert keeping each day's prior `location_id`. Fallback to `barbers.preferred_location_id` or `staff_status.location_id` ONLY for brand-new days.
   - Must NOT: resolve a single `preferred_location_id` and write it to all inserted rows (that was the bug).

2. **Availability API uses `timeZone: 'America/New_York'`**
   - File: `src/app/api/bookings/availability/route.ts`
   - Must use Eastern TZ for: today check, now-time conversion, Booksy event conversion, queue entry start_time conversion.
   - Banned: `toISOString().split('T')[0]`, `getDay()`, `getHours()`, `toTimeString().slice()` without Eastern TZ.

3. **No inline Supabase clients without `cache: 'no-store'`**
   - Check `src/app/api/barber/schedule/route.ts` and `src/app/api/barber/location-request/route.ts` — inline clients must wrap fetch.

4. **Location request approval dual-update**
   - File: `src/app/api/barber/location-request/route.ts` PATCH handler
   - When approved, must update BOTH `barber_schedules` (location_id for the day) AND `staff_status.location_id` if barber is currently clocked in — so queue routing takes effect immediately.

5. **Cross-dashboard mirror intact**
   - Files: `src/app/(dashboard)/barber/schedule/page.tsx` and `src/app/(dashboard)/dashboard/my-chair/schedule/page.tsx`
   - Schedule editing UI must exist on both. If one adds a feature the other lacks, Cross-Dashboard Mirroring Rule is broken.

### Data-level invariants

Run queries in `references/audit-queries.sql` via `mcp__supabase-mt__execute_sql`. All SELECT-only. Expected result is 0 rows unless noted.

### Output template — MANDATORY Coverage Report

Every schedules audit MUST produce this full block. A report without the Coverage Report section is INCOMPLETE and will be rejected.

```markdown
## Schedules Audit Report — [YYYY-MM-DD]

### Universal Preamble
- Tables enumerated: 5/5 PASS | X/5 FAIL
- RLS policies found: X — list any gaps
- Triggers found: X/1
- RPCs found: X/1
- Migrations confirmed: X/6
- preferred_location_id column exists: PASS/FAIL
- barber_schedules realtime publication: PASS/FAIL

### Code-level findings
[PASS/FAIL per invariant with file:line anchors]

### Data-level findings
[PASS/FAIL per query with row counts]

---

## Coverage Report (MANDATORY)

### Pillar 1 — Codebase (22 files from SURFACE_INVENTORY.md sections 1-6) — PROOF-OF-READ REQUIRED
| # | File | Verdict | Evidence (file:line — what was checked) |
|---|---|---|---|
| 1 | src/app/api/barber/schedule/route.ts | PASS/FAIL/NOT-RUN | e.g. "route.ts:142 — existingLocationByDay map built before delete" |
| 2 | src/app/api/barbers/[id]/schedule/route.ts | | e.g. "preferred_location_id resync at line X" |
| ... | [all 22] | | |

Files audited with proof-of-read: N / 22 (target: 22/22). Any PASS without a file:line citation = treated as NOT-RUN.

### Pillar 2 — Database (3 schedule tables + 2 parent, from SURFACE_INVENTORY.md section 7)
| Table | Row count | Distribution | Violations | Verdict |
|---|---|---|---|---|
| barber_schedules | | is_active dist; per barber day coverage | invalid day_of_week / reversed times | |
| location_change_requests | | status dist (pending/approved/rejected) | | |
| barbers.preferred_location_id | | NULL count on is_active=true | orphan preferred_location_id | |

Tables audited: N / 3

### Pillar 3 — Queries (from references/audit-queries.sql)
| # | Query | Verdict | Rows |
|---|---|---|---|
| 1 | active_barbers_without_schedule | | |
| ... | [all queries] | | |

Queries run: N / N_total. Skipped: [empty — or list with reason].

### Pillar 4 — RLS (3 tables)
| Table | Policies found | Expected | Verdict |
|---|---|---|---|
| barber_schedules | | ≥3 (public select, barber write own, owner all) | |
| location_change_requests | | ≥2 (barber own, owner all) | |
| barbers (preferred_location_id column RLS) | | inherited via barbers RLS | |

RLS tables audited: N / 3

### Pillar 5 — Integrations (SURFACE_INVENTORY.md sections 9, 12, 13)
| Integration | Verdict | Note |
|---|---|---|
| Trigger: trg_barber_schedule_audit | | updated_by stamped |
| Realtime: barber_schedules | | |
| Invariant: d03b8ef per-day preservation | | |
| Invariant: owner PUT recomputes preferred_location_id | | |
| Invariant: create-barber sets preferred_location_id | | |
| Invariant: location-request PATCH dual-updates schedules + staff_status | | |
| Invariant: resolveBarberLocation priority chain correct | | |
| Invariant: availability API uses Eastern TZ | | |
| Invariant: inline Supabase clients wrap `cache: 'no-store'` | | |
| Mirror: barber/schedule vs my-chair/schedule | | |

Integrations audited: N / 10

### Coupling Checks (from Cross-Surface Coupling Rules table)
| Coupling | Both sides audited? | Note |
|---|---|---|
| barber/schedule PATCH → {d03b8ef preservation, audit trigger, realtime, availability, profile, team, useBarbers, Booksy} | YES/NO | |
| barbers/[id]/schedule PUT → {same as above + preferred_location_id recompute} | YES/NO | |
| barber/location PUT → {preferred_location_id, rotation eligibility, no schedule rows touched, auth event} | YES/NO | |
| location-request PATCH → {dual-update barber_schedules + staff_status, notification, preferred_location_id NOT touched} | YES/NO | |
| Any barber_schedules change → {realtime, useCalendarEvents, useBarbers, profile, team, availability} | YES/NO | |
| create-barber → {preferred_location_id INSERT, initial schedule rows, is_active, onboarding-step} | YES/NO | |
| resolveBarberLocation('current') priority chain → {staff_status active → preferred → today → most common → locations[0] + ET} | YES/NO | |
| resolveBarberLocation('appointment') chain + ET | YES/NO | |
| availability API → {reads schedule day_of_week + ET + is_active + times/breaks} | YES/NO | |
| rotation-preview → {filters by today's schedule + staff_status active} | YES/NO | |
| barber/clock → {resolveBarberLocation + writes staff_status.location_id} | YES/NO | |
| useBarberSchedule / useLocationRequests hooks → {realtime + SWR + cache no-store} | YES/NO | |
| Inline Supabase clients cache: no-store | YES/NO | |
| Cross-dashboard schedule UI mirror (barber vs my-chair) | YES/NO | |
| Barber deactivation → {schedule is_active, location_change_requests cleanup, preferred_location_id nulled, staff_status cleanup} | YES/NO | |

Coupling violations: N  **(must be 0 — any NO row is a violation)**

---

## Gap Self-Report (MANDATORY)

| # | Gap | Why it matters | Severity |
|---|---|---|---|
| G1 | [e.g. Did not open src/app/api/barber/location/route.ts] | 3rd writer to preferred_location_id — skip = stale anchor | Unknown |

Surfaces in SURFACE_INVENTORY.md NOT audited this run: <comma-separated item numbers>.
Questions requiring external verification (Booksy parser behavior, Supabase realtime delivery, etc.): <list>.

If zero gaps: write "No gaps identified. All 45+ surfaces audited with proof-of-read + all coupling checks passed."

---

## Totals

- Surfaces audited with proof-of-read: X / 45+ (XX%)
- FAILs: N
- NOT-RUNs: N  (if > 0, the audit is PARTIAL, not COMPLETE — state this in the header)
- Coupling violations: N (must be 0)

**If NOT-RUNs > 0 OR coupling violations > 0, the report header MUST say "PARTIAL SCHEDULES AUDIT — N surfaces unaudited, M coupling violations" instead of "Schedules Audit Report".**
```

Stop only after every row above is filled. "Stop on first fail" is NOT the protocol — complete the full coverage sweep, then report.

---

## Mode: diagnose

1. **Ask for symptom.** Examples:
   - "Barber is showing up at wrong location on their dashboard"
   - "Booking availability says no slots but barber is clearly free"
   - "Schedule save blanked out my Friday location"
   - "Changed location on Wed and Fri but only Wed saved"

2. **Match against `references/incidents.md`.**
   - Per-day location overwrite symptom → d03b8ef fix — verify the code didn't regress
   - Wrong-day-of-week or 4-hour-off time symptoms → Booksy Timezone Rule
   - Location change request approved but queue still routes old → dual-update missing in PATCH handler

3. **Three-file rule.** Read max 3 files. If no match after 3, STOP and ask for direction.

4. **Two-strike rule.** Second fix must differ in approach from the first.

5. **Stay in scope.** Do not wander into auth, commission, or queue code.

---

## Mode: scale-check

Produce a "must-fix-before-location-#5" checklist.

1. **`locations[0]` in schedule UI** (known files — verify still present):
   - `src/app/(dashboard)/barber/schedule/page.tsx:372,397`
   - `src/app/(dashboard)/dashboard/my-chair/schedule/page.tsx:427,600`
   - These are fallback defaults; the API ignores `locationId` in request body, so they don't persist. Safe. But note on report.

2. **Hardcoded day-of-week logic**
   - `grep -rEn "dayOfWeek[[:space:]]*===?[[:space:]]*[0-6]|getDay\(\)[[:space:]]*===?[[:space:]]*[0-6]" src/`
   - Flag anything with location-aware business logic inside.

3. **`preferred_location_id` column**
   - Used by `src/app/api/barber/schedule/route.ts` and `src/app/api/barber/location/route.ts`.
   - Verify the column exists in production: `SELECT column_name FROM information_schema.columns WHERE table_name='barbers' AND column_name='preferred_location_id'`.
   - If missing: schedule saves for brand-new days will fail for any barber without an existing staff_status row. Flag as MUST FIX before scale.

4. **Each barber has schedule for all working days**
   - Run audit query checking all active barbers have day_of_week coverage matching their staff_status/location expectations.

5. **Location-change-request coverage**
   - If adding a new location, barbers may want to move days to it. Verify `/api/barber/location-request` is reachable by all barbers and the owner approval UI exists at `/dashboard` (check for `location_change_requests` table reads).

## Mode: fix

The only mode that writes code. Closes the loop between "audit/diagnose found X" and "X is fixed + verified." Does NOT commit, does NOT push, does NOT touch the production DB. See `references/fix-patterns.md` for the canonical patterns.

### Activation is EXPLICIT

Fix mode fires ONLY when the user types one of:
- `apply pattern N` — N is a pattern number from `references/fix-patterns.md`
- `fix <symptom-phrase>` — natural-language form; the skill maps to a pattern and CONFIRMS before doing anything
- `enter fix mode` followed by a scope

Any other phrasing → audit/diagnose instead. An audit finding NEVER auto-triggers a fix.

### Workflow (strict — every step, no shortcuts)

1. **Scope declaration.** Restate in 1–2 sentences which pattern (number + name), which file(s) will change, any mirror-page impact.
2. **Preflight.** Read the target file. Confirm the "before" block from `fix-patterns.md → Pattern N` still matches current code — imports, function signatures, surrounding context, NOT line numbers (which drift). If drift → STOP and report what differs. Do NOT apply a stale pattern.
3. **Scope audit.** Confirm the fix touches ONLY files named in the pattern's Before/After blocks. If a fix would require touching an unrelated system → STOP and ask for approval before expanding.
4. **Diff proposal.** Show the exact `old_string` / `new_string` the skill will pass to `Edit`. Wait for the user to type `yes` / `apply` / `proceed`. No implicit approval.
5. **Apply.** Single `Edit` call. ONE pattern per fix-mode invocation. Never bundled.
6. **Post-fix verification.** `npx tsc --noEmit` passes. Re-run the pattern's post-fix grep and/or SQL check — must pass. For UI patterns, explicitly tell the user "you must test this in the browser before shipping — I can't verify UI."
7. **Mirror check.** If the fix touches any page in the Cross-Dashboard Code Mirroring map (`.claude/rules/context-awareness.md`), invoke the `mirror-check` skill before handoff.
8. **Handoff to `bulletproof-ship`.** Fix mode DOES NOT commit, stage, or push. Propose a branch name (`fix/<domain>-<pattern-slug>`) and a commit message in MT's conventional format, then tell the user to invoke `bulletproof-ship`.

### Integration with other skills

| Skill | Role |
|---|---|
| `bulletproof-ship` | Final step. Commit + push + deploy safety. Mandatory. |
| `mirror-check` | Cross-dashboard enforcement for any dashboard-touching fix. |
| `safe-query` | If a pattern requires DB writes (rare), route through safe-query. |

---

## Downstream Consumers & Propagation

When a barber toggles a day ON/OFF, the change MUST reflect immediately everywhere the schedule flows — profile, team, booking wizard, calendar hours, TV board. The skill traces every link.

### Consumers (every surface that reads schedule data)

| Consumer | File / URL | What it reads |
|---|---|---|
| Availability API | `src/app/api/bookings/availability/route.ts` | schedule for given date → bookable slots |
| Public barber profile | `src/app/(public)/mtbarbers/[slug]/page.tsx` | "Works: Mon, Wed, Fri" display + location per day |
| Team page | `src/app/(public)/team/page.tsx` | which barbers work which locations today |
| Booking wizard step 2 | `src/app/(public)/book/page.tsx` | barber filtering by selected location + date |
| Calendar bounds | `src/lib/hooks/useCalendarEvents.ts` | working hours for calendar display |
| TV board | `src/app/(public)/tv/[location]/page.tsx` | expected barbers today |
| Queue routing | indirect via `staff_status.location_id` (clock-in resolves today's schedule location) |

### Propagation invariants

1. **`cache: 'no-store'` on inline Supabase clients** (the `src/app/api/barber/schedule/route.ts` and `src/app/api/barber/location-request/route.ts` inline clients must wrap fetch).
2. **Schedule UI re-fetches after mutation.** PATCH response updates SWR/React Query cache; OR Supabase realtime publication on `barber_schedules` triggers refetch.
3. **Realtime enabled on `barber_schedules`** (if the skill finds it's NOT published, every consumer is on a polling fallback — flag as scale concern).
   ```sql
   SELECT tablename FROM pg_publication_tables
   WHERE pubname = 'supabase_realtime' AND tablename = 'barber_schedules';
   ```
4. **Location change requests propagate to TWO places atomically.** PATCH approval must update BOTH `barber_schedules` AND `staff_status.location_id` (when barber currently clocked in) — otherwise queue routing stays on old location.
5. **`d03b8ef` per-day preservation intact.** The schedule write path must read existing rows FIRST, preserve each day's `location_id`, only fall back for brand-new days.

### Diagnose: "Lily turned on Monday + Wednesday, UI saved, but profile / booking / team page don't show them"

1. DB write happened? `SELECT * FROM barber_schedules WHERE barber_id = (lookup by slug) AND day_of_week IN (1, 3)` — expect 2 active rows.
2. Availability API reads `is_active = true`? Read the file.
3. Profile page re-fetches after a mutation? Or just reads on page load (stale until refresh)?
4. Supabase factories wrap fetch with `cache: 'no-store'`? Read both.
5. If all green but UI still stale → Next.js Data Cache is defeating the read. Verify `export const dynamic = 'force-dynamic'` on the consuming route.
6. If write never persisted → `d03b8ef` regression. Read `src/app/api/barber/schedule/route.ts` to confirm per-day preservation.

---

## HARD RULES

- NEVER write to production DB. READ-ONLY via `mcp__supabase-mt__execute_sql`.
- NEVER modify a working system without explicit user approval.
- NEVER expand scope. Schedule bug = schedule fix. No "while I'm here" touch-ups.
- ALWAYS use `mcp__supabase-mt__`, never `mcp__supabase__`.
- NEVER test on real barbers (use test accounts only).
- If a fix breaks any existing behavior, FULL REVERT.
- Branch workflow: any code change on a `fix/…` branch, not `main`.
- User reports override queries.
