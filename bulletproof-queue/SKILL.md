---
name: bulletproof-queue
description: Audit, diagnose, or scale-check the MT Barbershop walk-in queue system. Use when the user reports a queue bug, asks to verify queue health, or is preparing to add a new location. Runs read-only SQL via mcp__supabase-mt__execute_sql and read-only codebase greps. Never writes to the production DB. Never modifies application code without explicit user approval.
---

# Bulletproof Queue

## HARD RULE — Unified Walk-In Eligibility (locked 2026-04-25)

**Every route that assigns a walk-in to a barber, OR transitions a walk-in to `called`/`in_chair`, MUST call `isBarberAvailableForWalkIn` from `src/lib/queue/booking-conflicts.ts`.**

The 7 conflict sources that the helper consults are the canonical set:
1. `staff_status.status` — must be `clocked_in` (excludes `on_break`, `with_client`, `clocked_out`, missing row)
2. Active `queue_entries` — `waiting`/`called`/`in_chair` for this barber (use `excludeQueueEntryId` opt for reassign)
3. Native `bookings` — `called`/`in_progress` now, OR `confirmed` whose start time falls within `now..now+duration+buffer`
4. `external_calendar_events` source='booksy' status='confirmed' — overlap window
5. `academy_sessions` — instructor_id match, overlap window
6. `barber_time_blocks` — block_date today, overlap window
7. Google Calendar — best-effort, 3s timeout, fail-open

**Routes covered by this rule (all five MUST call the helper):**
- `src/lib/queue/auto-assign.ts` — `autoAssignNextAnyBarberClient`
- `src/app/api/queue/override-assign/route.ts` — owner force-assign POST
- `src/app/api/queue/entry/[id]/route.ts` — PATCH `→called` (any branch: preference, FIFO, owner override) AND backfill block on completion
- `src/app/api/queue/rotation-preview/route.ts` — uses `batchIsBarberAvailableForWalkIn`
- `src/app/api/queue/route.ts` — POST check-in (preference path)

**Why this rule exists:** Owner reassigned a walk-in to Gustavo on 2026-04-25 while Gustavo was mid-Booksy with Christian Alvarez (10–11 AM). `override-assign` only checked `bookings` `called`/`in_progress` and ignored `external_calendar_events` entirely. Five routes implementing eligibility differently = guaranteed drift. The helper exists to make drift impossible.

**Adding a new conflict source:** extend the helper, never inline. New code that adds an inline conflict check is a violation — push it into `booking-conflicts.ts` so all 5 routes pick it up.

**Coupling violation:** an audit PASS on any of the 5 routes without grep-evidence of `isBarberAvailableForWalkIn` (or `batchIsBarberAvailableForWalkIn`) is a coupling violation. Report it in the Gap Self-Report and mark the route NOT-RUN.

**Inverse direction (booking creation respecting active walk-ins):** out of scope for this skill — covered by `bulletproof-bookings`.

---

The walk-in queue is MT Barbershop's highest-traffic system. This skill hardens it against three failure modes: code drift (fixes that got unwound), data-level invariant violations (impossible states in Supabase), and multi-location scale bugs (hardcoded values that break when location #5 arrives).

This skill does NOT replace `CLAUDE.md`, `MEMORY.md`, or the `.claude/rules/*.md` files. It READS them, then runs a structured protocol.

---

## Mandatory Preflight — BEFORE any action in any mode

Read these four files in order. Skip none. These are the source of truth for the queue system and the hard rules that govern how you work on it.

1. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/CLAUDE.md` — "System C: Walk-In Queue" section, "Existing Systems Are Sacred" rule, test account rules, Supabase MCP rule (`mcp__supabase-mt__` only).
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-MT-Barbershop-Systems/memory/MEMORY.md` — all queue-relevant incidents and the `calledClientIdRef` hard rule at the top.
3. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.claude/rules/debugging-protocol.md` — Sections 4 (Targeted Fix), 5 (Two-Strike Rule), 7 (Zero Tolerance), 8 (Existing Systems Are Untouchable), 9 (Zero Production Data Contamination).
4. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.claude/rules/context-awareness.md` — Cross-Dashboard Code Mirroring Rule.

After reading, confirm to the user: "Preflight complete. Running [mode]." Then proceed.

---

## Choose a Mode

If the user didn't specify a mode when invoking the skill, ask:

- **audit** → full read-only health check (run this weekly or before a launch)
- **diagnose** → the user has a specific queue symptom to investigate
- **scale-check** → the user is preparing to add a new location
- **fix** — apply canonical patterns from `references/fix-patterns.md`. EXPLICIT activation only; audit findings do NOT auto-trigger this mode.

Pick exactly one. Never run two modes in the same invocation.

---

## AUDIT RIGOR — read before starting audit mode

This skill enforces the universal Audit Rigor Standard at `~/.claude/skills/_shared/audit-rigor.md` and the domain Surface Inventory at `references/SURFACE_INVENTORY.md`. Read both before you do anything.

**Five Pillars (all mandatory):** codebase, database, queries, RLS, integrations. Missing any pillar = failed audit.

**Proof-of-Read:** every file claimed PASS in the Coverage Report MUST cite a `file.ts:LINE` from that file. No line = NOT-RUN, not PASS. This is enforced by the universal standard.

**Forcing language — copy this into your mental model:**

> Do NOT stop on first pass. You MUST work through EVERY file in SURFACE_INVENTORY.md (100+ surfaces), EVERY query in audit-queries.sql, EVERY RLS policy, EVERY trigger, and EVERY integration. Stopping after one finding is a half-audit and is explicitly forbidden.
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
| `queue/entry/[id]/route.ts` completion (`→completed`) | `service_transactions` creation trigger + `cash_fee_ledger` INSERT + `staff_status` transition (with_client → clocked_in) + `daily_summaries` upsert + `increment_barber_cuts` RPC call + `upsert_client_from_service` RPC + `customer_loyalty` punch + next-client smart-routing UI | Completion has 6+ downstream writes. Any silent catch block or RPC omission = drift in commission, rotation fairness, CRM, or loyalty. |
| `queue/entry/[id]/route.ts` call-to-chair (`→in_chair`) | In-chair guard lines 217-252 + `booking-conflicts.ts` overlap check + `staff_status` → `with_client` transition + `current_queue_entry_id` write + `calledClientIdRef` auto-start guard in both mirrored walk-ins pages | Call-to-chair must be gated. Guard bypass = two clients in one chair. |
| `queue/entry/[id]/route.ts` no-show (`→no_show`) | Position shift for remaining `waiting` entries + `position_notifier.ts` SMS suppression + feedback SMS suppression + no auto-bill to cash_fee_ledger | No-show must NOT trigger payment/feedback SMS or create a ledger row. |
| `queue/skip-turn/route.ts` | `calledClientIdRef` reset behavior (must stay null on skip) + re-assignment via `auto-assign.ts` + notification to next barber + original client's tracking_token URL still valid | Skip ≠ no-show. The entry goes back to queue, not to cancel. |
| `queue/override-assign/route.ts` | `isBarberAvailableForWalkIn` call (with `excludeQueueEntryId`) covering all 7 sources + fair rotation bypass logging + `cuts_today` still increments on completion + paused-mode block + location-match guard on `staff_status` | Owner override must NOT bypass eligibility. Skipping any of the 7 sources = HARD RULE violation. Owner override must NOT corrupt fairness metrics retroactively. |
| `queue/entry/[id]/void/route.ts` | `decrement_barber_cuts` RPC + `cash_fee_ledger` row delete/waive + `service_transactions` status update + `daily_summaries` rollback + `customer_loyalty` punch reversal + referral event reversal | Void reverses 5+ downstream writes. One missed rollback = permanent drift. |
| `queue/entry/[id]/reassign-completed/route.ts` | Old barber's `cuts_today` decrement + new barber's `cuts_today` increment + `cash_fee_ledger` recompute for both + `service_transactions.barber_id` update + `daily_summaries` for both barbers | Completed reassign touches TWO barbers' fairness + commission ledgers. |
| `queue/entry/[id]/service/route.ts` (change service on active entry) | `duration_minutes` recompute + `service_amount` recompute + overlapping-slot check + In-Service Mode timer reset | Mid-service service change can break timer + payment amount. |
| `queue/entry/[id]/delay/route.ts` (notified-position delay) | `position_notifier.ts` SMS cancellation + `estimated_arrival_time` recompute + rotation preview update | Delay must NOT fire the "You're next" SMS or mark barber with_client. |
| `barber/clock/route.ts` (clock-in/out) | `transition_staff_status` RPC atomicity + `staff_status.cuts_today` reset on new day + `preferred_location_id` fallback if schedule-less + rotation eligibility recompute | Clock-in resolves today's location via `resolveBarberLocation('current')` — schedule drift = wrong-location routing. |
| `barber/break/route.ts` | `staff_status` → `on_break` + `break_started_at` stamp + rotation-preview removal + any active `current_queue_entry_id` handling (shouldn't be on break with a client) | Break must remove barber from rotation immediately. |
| `barber/[id]/force-status/route.ts` (owner override) | `transition_staff_status` RPC still called (not bypassed) + `auth_events` log + owner role check | Owner force-status must still go through the atomic RPC, not raw UPDATE. |
| `barber/[id]/queue-control/route.ts` (auto/manual/paused) | `queue_control_mode` column + `auto-assign.ts` eligibility filter + realtime publication on `barbers` | Changing to paused must remove barber from next-assignment pool within <1s. |
| `locations/[id]/pause/route.ts` | `accepts_walk_ins` flag + check-in wizard gating + waitlist overflow routing + TV board messaging | Paused location must reject new check-ins AND show paused banner on TV. |
| Any write to `queue_entries.status` | Realtime publication includes `queue_entries` + `useQueue`/`useQueueRealtime` hook subscription + `cache: 'no-store'` on server reads + tracking_token stability (customer URL never 404s mid-lifecycle) | Status update must propagate to customer tracker, TV, dashboards within 1s. |
| `auto-assign.ts` winner pick | `staff_status` active-only filter + `is_active=true` on barber + `queue_control_mode='auto'` + no active `in_chair` entry + no overlapping booking + fairness tiebreak (`cuts_today ASC, last_cut_completed_at ASC`) | Fair rotation has 6 eligibility inputs. Any skipped check = unfair assignment. |

**A PASS on the left side without evidence of auditing the right side = COUPLING VIOLATION.** Report it in the Gap Self-Report.

---

## Mode: audit

### Step 0 — Universal Audit Preamble (MANDATORY — run first, always)

Run the 5 discovery queries from `~/.claude/skills/_shared/audit-rigor.md` section "Universal Audit Preamble", filled in with the queue domain values:

```sql
-- 1. Enumerate queue domain tables
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('queue_entries','staff_status','barber_notifications','waitlist','locations')
ORDER BY table_name;
-- Expected: 5 rows. Missing = inventory drift; STOP and ask user.

-- 2. RLS policies on every queue table
SELECT tablename, policyname, cmd, roles
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('queue_entries','staff_status','barber_notifications','waitlist')
ORDER BY tablename, policyname;
-- Expected: at least 1 policy per role per table (see SURFACE_INVENTORY.md section 10).
-- Any missing policy or extra-permissive policy = RLS gap; FLAG in coverage report.

-- 3. Triggers on queue-touched tables
SELECT event_object_table, trigger_name, action_timing, event_manipulation
FROM information_schema.triggers
WHERE event_object_schema = 'public'
  AND event_object_table IN ('queue_entries','staff_status')
ORDER BY event_object_table, trigger_name;
-- Expected: create_service_transaction_from_queue, trg_queue_entries_daily_summary.

-- 4. RPC functions
SELECT routine_name, routine_definition IS NOT NULL AS has_body
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name IN (
    'assign_queue_position','complete_queue_service','upsert_client_from_service',
    'transition_staff_status','increment_barber_cuts','decrement_barber_cuts'
  );
-- Expected: 6 rows, all has_body=true.

-- 5. Migration history
SELECT name, executed_at FROM supabase_migrations.schema_migrations
WHERE name ILIKE '%queue%' OR name ILIKE '%concurrency%' OR name ILIKE '%virtual_queue%'
   OR name ILIKE '%barber_notifications%' OR name ILIKE '%staff_status%'
   OR name ILIKE '%barber_cuts%' OR name ILIKE '%void_service%'
   OR name ILIKE '%queue_control%' OR name ILIKE '%barber_schedules%realtime%'
   OR name ILIKE '%security_hardening%'
ORDER BY executed_at;
-- Expected: at least 11 rows (see SURFACE_INVENTORY.md section 11).

-- 6. Realtime publications
SELECT tablename FROM pg_publication_tables
WHERE pubname = 'supabase_realtime'
  AND tablename IN ('queue_entries','staff_status','barber_notifications','waitlist')
ORDER BY tablename;
-- Expected: at least queue_entries, staff_status, barber_notifications present.
```

Attach all 6 result sets to the report under "Universal Preamble". Any drift = stop before domain checks.

### Code-level invariants

Run these greps / file checks. Each has an expected result — if the actual differs, it's a FAIL.

1. **`cache: 'no-store'` wrapper on Supabase factories**
   - File: `src/lib/supabase/admin.ts` — must contain a custom `global.fetch` that forces `cache: 'no-store'`
   - File: `src/lib/supabase/server.ts` — same requirement
   - Also check: `src/app/api/barber/schedule/route.ts` and `src/app/api/barber/location-request/route.ts` (inline clients per MEMORY.md note)
   - Why: Next.js 14 Data Cache caches `fetch()` by default. Removing this wrapper causes stale queue reads (MEMORY.md: 2026-03-26 bug).
   - Check: `grep -n "cache: 'no-store'" src/lib/supabase/admin.ts src/lib/supabase/server.ts`

2. **`calledClientIdRef` guard intact in both mirrored files**
   - File: `src/app/(dashboard)/barber/walk-ins/page.tsx`
   - File: `src/app/(dashboard)/dashboard/my-chair/page.tsx`
   - Must contain: `calledClientIdRef = useRef<string | null>(null)`, set ONLY inside `handleCallNext` on API success, checked via `calledClientIdRef.current !== currentClient?.id`.
   - Must NOT contain: a boolean `autoStartFiredRef` / `calledBySelfRef`, a `useEffect` that resets the ref on `[currentClient?.id]`.
   - Why: 2026-04-11 incident — boolean flag + reset-effect race allowed auto-start to fire for the wrong client. Client-ID-match pattern is the only correct implementation.
   - Check: `grep -n "calledClientIdRef\|autoStartFiredRef\|calledBySelfRef" <both files>`

3. **No duplicate "Start Service" button in MobileQueueView**
   - File: `src/components/queue/MobileQueueView.tsx` (or the component actually rendered in `/barber/walk-ins`)
   - Why: 2026-03-20 unauthorized commit added a duplicate. Was reverted.

4. **No `flow_step` persistence in Zod schemas**
   - Grep: `grep -rn "flow_step" src/lib/validations/ src/app/api/queue/`
   - Expected: zero matches. Any match indicates the reverted 6d4e4ff code is creeping back.

5. **In-chair guard at `src/app/api/queue/entry/[id]/route.ts` lines ~217-252**
   - Must block `→in_chair` when the barber already has another active `in_chair` queue entry or an active booking.
   - Read the file. Verify the guard block exists and wasn't replaced with an RPC call like `claim_queue_entry` (that RPC is dead code in the DB — must not be called from app code).

### Data-level invariants

Run the queries in `references/audit-queries.sql` via `mcp__supabase-mt__execute_sql`. One SELECT at a time. NEVER run INSERT, UPDATE, or DELETE.

The expected result for every query is 0 rows unless the query comment says otherwise. Report each as pass/fail with the query and row count.

### Output template — MANDATORY Coverage Report

Every queue audit MUST produce this full block. A report without the Coverage Report section is INCOMPLETE and will be rejected.

```markdown
## Queue Audit Report — [YYYY-MM-DD]

### Universal Preamble
- Tables enumerated: 5/5 PASS | X/5 FAIL (list missing)
- RLS policies found: X (expected ≥4 tables covered) — list any gaps
- Triggers found: X/2 on queue_entries
- RPCs found: X/6
- Migrations confirmed: X/11
- Realtime publications: queue_entries/staff_status/barber_notifications PASS/FAIL

### Code-level findings
[PASS/FAIL per invariant with file:line anchors]

### Data-level findings
[PASS/FAIL per query with row counts]

---

## Coverage Report (MANDATORY)

### Pillar 1 — Codebase (57 files from SURFACE_INVENTORY.md sections 1-6) — PROOF-OF-READ REQUIRED
| # | File | Verdict | Evidence (file:line — what was checked) |
|---|---|---|---|
| 1 | src/app/api/queue/route.ts | PASS/FAIL/NOT-RUN | e.g. "route.ts:142 — Zod rejects missing location_id" |
| 2 | src/app/api/queue/[token]/route.ts | | |
| ... | [all 57] | | |

Files audited with proof-of-read: N / 57 (target: 57/57). Any PASS without a file:line citation = treated as NOT-RUN.

### Pillar 2 — Database (5 tables from SURFACE_INVENTORY.md section 7)
| Table | Row count | Status dist | NULL violations | Verdict |
|---|---|---|---|---|
| queue_entries | | waiting:X, called:X, in_chair:X, completed:X, no_show:X, cancelled:X | | |
| staff_status | | clocked_in:X, on_break:X, clocked_out:X, with_client:X | | |
| barber_notifications | | is_read:X vs unread:X | | |
| waitlist | | waiting:X, notified:X, converted:X, expired:X | | |
| locations | | accepts_walk_ins counts | | |

Tables audited: N / 5

### Pillar 3 — Queries (from references/audit-queries.sql)
| # | Query | Verdict | Rows |
|---|---|---|---|
| 1 | no_two_in_chair_per_barber | | |
| ... | [all queries] | | |

Queries run: N / N_total. Skipped: [empty — or list with reason].

### Pillar 4 — RLS (4 queue tables)
| Table | Policies found | Expected | Verdict |
|---|---|---|---|
| queue_entries | | ≥3 (public insert, owner all, barber select) | |
| staff_status | | ≥3 (public select, owner all, barber update) | |
| barber_notifications | | ≥2 (owner, barber) | |
| waitlist | | ≥2 | |

RLS tables audited: N / 4

### Pillar 5 — Integrations (SURFACE_INVENTORY.md sections 9, 12, 13, 14)
| Integration | Verdict | Note |
|---|---|---|
| Trigger: create_service_transaction_from_queue | | |
| Trigger: trg_queue_entries_daily_summary | | |
| Realtime: queue_entries | | |
| Realtime: staff_status | | |
| Realtime: barber_notifications | | |
| Cron: queue-cleanup | | |
| Cron: queue-eta | | |
| Cron: service-reminder | | |
| Cron: auto-clockout | | |
| Push notifications (web-push) | | |
| Twilio SMS (queue events) | | |

Integrations audited: N / 11

### Coupling Checks (from Cross-Surface Coupling Rules table)
| Coupling | Both sides audited? | Note |
|---|---|---|
| Completion → {ST trigger, cash_fee_ledger INSERT, staff_status, daily_summaries, increment_barber_cuts, client upsert, loyalty punch, smart-routing} | YES/NO | |
| Call-to-chair → {in-chair guard 217-252, booking-conflicts, staff_status with_client, current_queue_entry_id, calledClientIdRef} | YES/NO | |
| No-show → {position shift, SMS suppression, feedback suppression, no ledger row} | YES/NO | |
| Skip-turn → {calledClientIdRef null, re-assign via auto-assign, next barber notify, tracking_token stable} | YES/NO | |
| Override-assign → {fairness logging, cuts_today still counts, active check not skipped} | YES/NO | |
| Void → {decrement_barber_cuts, ledger delete/waive, ST update, daily_summaries rollback, loyalty reversal, referral reversal} | YES/NO | |
| Reassign-completed → {old barber cuts--, new barber cuts++, ledger both, ST update, daily_summaries both} | YES/NO | |
| Change-service → {duration recompute, amount recompute, overlap check, In-Service timer reset} | YES/NO | |
| Delay → {SMS cancel, estimated_arrival recompute, rotation preview update} | YES/NO | |
| Clock-in/out → {transition_staff_status atomic, cuts_today reset, preferred_location_id fallback, rotation eligibility} | YES/NO | |
| Break → {staff_status on_break, break_started_at, rotation removal} | YES/NO | |
| Force-status → {RPC still used, auth_events, owner role} | YES/NO | |
| Queue-control mode change → {queue_control_mode, auto-assign filter, realtime barbers} | YES/NO | |
| Location pause → {accepts_walk_ins, check-in gating, waitlist overflow, TV banner} | YES/NO | |
| Status write → {realtime publication, consumer hook subscription, cache no-store, tracking_token stable} | YES/NO | |
| auto-assign → {staff_status active, is_active, queue_control_mode, no in_chair, no overlap booking, fairness tiebreak} | YES/NO | |

Coupling violations: N  **(must be 0 — any NO row is a violation)**

---

## Gap Self-Report (MANDATORY)

| # | Gap | Why it matters | Severity |
|---|---|---|---|
| G1 | [e.g. Did not open src/app/api/queue/entry/[id]/delay/route.ts] | Touches estimated_arrival_time + SMS suppression — could double-notify | Unknown |

Surfaces in SURFACE_INVENTORY.md NOT audited this run: <comma-separated item numbers>.
Questions requiring external verification (Twilio console, Supabase dashboard, push subscription health, etc.): <list>.

If zero gaps: write "No gaps identified. All 100+ surfaces audited with proof-of-read + all coupling checks passed."

---

## Totals

- Surfaces audited with proof-of-read: X / 100+ (XX%)
- FAILs: N
- NOT-RUNs: N  (if > 0, the audit is PARTIAL, not COMPLETE — state this in the header)
- Coupling violations: N (must be 0)

**If NOT-RUNs > 0 OR coupling violations > 0, the report header MUST say "PARTIAL QUEUE AUDIT — N surfaces unaudited, M coupling violations" instead of "Queue Audit Report".**
```

Stop only after every row above is filled. "Stop on first fail" is NOT the protocol — complete the full coverage sweep, then report.

---

## Mode: diagnose

Follow this protocol exactly. It mirrors `debugging-protocol.md` Section 1.

### Step 1: Ask, don't assume
Ask the user:
- What do you see? (screenshot preferred)
- What's the exact error message or unexpected behavior?
- Which role/location/barber?
- When did it start? (to correlate with recent commits via `git log --oneline -20`)

Do NOT read any file until you have the symptom.

### Step 2: Simple fixes first (< 2 min)
Tell the user to try — in order:
1. Hard refresh the page (Cmd+Shift+R)
2. Restart the dev server on port 3010 if the bug is local
3. Check if dev server has TypeScript errors in the terminal

If the problem goes away, STOP. You're done.

### Step 3: Match against known incidents
Open `references/incidents.md`. Scan for a symptom match. Known entries:

- **Stale queue data** (waits >60s to update despite realtime subscription) → Fetch Cache Bug, 2026-03-26 → check `cache: 'no-store'` wrappers.
- **Auto-start fires for wrong client** → `calledClientIdRef` Guard incident, 2026-04-11 → verify ref pattern in both mirrored files.
- **Time shown as 4 hours later than booked** → Timezone Bug, 2026-03-28 → grep for `toISOString().split('T')` and `toTimeString().slice` in queue/booking/calendar paths.
- **Two clients assigned to same barber `in_chair`** → in-chair guard bypass → read `src/app/api/queue/entry/[id]/route.ts` lines 217-252.
- **Random new files or RPCs you don't recognize** (e.g., `claim_queue_entry`, `useIncompleteFlowEntry`, `flow_step`) → 6d4e4ff pattern leaking back → STOP and alert user.
- **UI shows a state that your SQL query can't find** → "User Reports Override Queries" rule → the UI may query a different table. Trace the code path the UI uses, not the first related table that comes to mind.

If the symptom matches, apply the fix pattern in `references/incidents.md` for that entry. Do NOT wander beyond the files it names.

### Step 4: 3-file rule (if no match)
If no known incident matches:
1. Read AT MOST 3 files based on the error message location (e.g., the API route named in a 500, the hook named in a console error, the page file named in a screenshot).
2. Find the bug.
3. If you haven't found it after 3 files, STOP. Report what you know to the user. Ask for direction. Do NOT read a 4th file.

### Step 5: Two-strike rule
If your first fix doesn't work, your second attempt MUST use a different approach — not a variation of the first. If the second also fails, STOP. Tell the user what you tried and what you think is actually going on.

### Step 6: Stay in scope
The fix touches ONLY the broken feature. If a fix would require changing something outside the queue (auth, bookings, commission), explain WHY and ask for approval before proceeding.

---

## Mode: scale-check

Run every check. Produce a "must-fix-before-adding-location-#5" checklist.

### 1. Hardcoded location slugs
```bash
grep -rn "'wilmington'\|\"wilmington\"\|'newark'\|\"newark\"\|'new-castle'\|\"new-castle\"" src/
```
Expected matches (safe): SEO schema, static page route files at `src/app/(public)/queue/{wilmington,newark,new-castle}/page.tsx`, `FALLBACK_LOCATIONS` constant, test fixtures.
Flag everything else. Especially any `switch (slug)` or `if (slug === 'newark')` with business logic inside.

### 2. `locations[0]` anti-pattern
```bash
grep -rn "locations\[0\]" src/
```
Known files from last audit (verify still present — they may have been fixed since):
- `src/components/site/MobileHomePage.tsx:92`
- `src/app/page.tsx:214`
- `src/app/(dashboard)/dashboard/queue/page.tsx:89, 599, 629`
- `src/components/dashboard/WalkInForm.tsx:35`
- `src/app/(dashboard)/barber/walk-ins/page.tsx:255`
- `src/app/(dashboard)/dashboard/my-chair/page.tsx:199`

For each match, report: file path, line number, surrounding context, whether the fallback makes sense with 5+ locations.

### 3. Hours-of-operation logic
```bash
grep -rn "hours_json" src/
```
Must be the single source of truth for day closures. Any `if (slug === 'newark' && dayOfWeek === 0)` pattern is a bug — that logic belongs in `locations.hours_json`.

### 4. Hardcoded phone numbers / addresses
```bash
grep -rEn "\(?302\)?[- ]?[0-9]{3}[- ][0-9]{4}" src/
grep -rn "Kirkwood Hwy\|Marrows Rd\|Penn Mart" src/
```
Expected: matches only in `FALLBACK_LOCATIONS`, email template fallbacks, and metadata/SEO. Anything else is suspect.

### 5. Static queue check-in pages
List: `src/app/(public)/queue/wilmington/page.tsx`, `src/app/(public)/queue/newark/page.tsx`, `src/app/(public)/queue/new-castle/page.tsx`.
Report: "To add location #5, you must either create a new static page here OR verify the `/queue/[...slug]` catch-all handles the new slug."

### 6. Day-of-week hardcoding
```bash
grep -rEn "dayOfWeek[[:space:]]*===?[[:space:]]*[0-6]|getDay\(\)[[:space:]]*===?" src/
```
Expected: utility functions that map day numbers. Flag any business rule like "if Sunday, close early."

### 7. TV board routes
Check: `src/app/(public)/tv/[location]/page.tsx`. Must be dynamic on `[location]`, not a switch over the 3 known slugs.

### Scale-check output template

```
## Scale Readiness Report — adding location #5

### Hardcoded slugs (safe vs unsafe)
[list safe matches briefly, then list unsafe matches with file:line and a one-line fix suggestion]

### locations[0] anti-pattern
[file:line list, each with "fallback OK" or "MUST FIX: should be user.preferred_location_id or staff_status.location_id"]

### Hours & day-of-week
[any hardcoded day logic found]

### Phones & addresses
[any hardcoded values outside expected files]

### Static pages to add/update
[explicit file list]

### Verdict
[READY / NOT READY — with a numbered must-fix list if NOT READY]
```

Do NOT make any fixes in scale-check mode. Report only.

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

Queue state changes must reflect everywhere that shows it — immediately. The skill traces every link in the chain.

### Consumers (every surface that reads queue data)

| Consumer | File / URL | What it reads |
|---|---|---|
| Customer tracker | `/queue/[token]` | own entry's position, barber, status |
| TV board | `src/app/(public)/tv/[location]/page.tsx` | all waiting + in_chair at location |
| Barber My Chair | `src/app/(dashboard)/barber/walk-ins/page.tsx` | entries assigned to this barber |
| Owner My Chair | `src/app/(dashboard)/dashboard/my-chair/page.tsx` | mirror of barber page + owner overrides |
| Owner all-queue | `src/app/(dashboard)/dashboard/queue/page.tsx` | all entries across all locations |
| Homepage widget | `src/components/site/MobileHomePage.tsx` | aggregate counts per location |
| Notification crons | `/api/cron/queue-eta`, `/api/cron/service-reminder` | entries needing ETA / reminder |

### Propagation invariants (verify during audit)

1. **Realtime publication includes the tables:**
   ```sql
   SELECT tablename FROM pg_publication_tables WHERE pubname = 'supabase_realtime' ORDER BY tablename;
   -- Must include: queue_entries, staff_status, barber_notifications
   ```
2. **Every consumer hook subscribes or re-fetches on mutation:** `useQueue`, `useQueueRealtime`, `useBarberClock`, any hook fed by queue data. State update within 1s of DB change.
3. **No server-side cache between write and read:** `cache: 'no-store'` on `admin.ts` + `server.ts`. Any inline client too.
4. **Push + SMS triggers fire on each state transition:**
   - `waiting → called` → SMS + push via `/api/push/**`
   - `called → in_chair` → staff_status = 'with_client'
   - `in_chair → completed` → cash ledger + loyalty punch + client upsert (atomic via `complete_queue_service` RPC)
5. **`tracking_token` stable across all lifecycle transitions** — customer URL never breaks.

### Diagnose: "my queue change didn't propagate"

1. DB write happened? Query the entry by ID, verify status.
2. Realtime publication has the table? Query `pg_publication_tables`.
3. Consumer hook subscribed to the channel? Read the hook.
4. Supabase client wrapped with `cache: 'no-store'`? Read factory.
5. If all green → the write didn't happen. Re-check the write endpoint (state machine validation rejecting it silently).

---

## Critical Operational Flows — Barber & Owner Journeys

These are multi-step flows where a break at ANY step causes the symptom. The skill traces each step and reports which link is broken. Run this as part of `diagnose` mode when the user describes a journey-level bug.

### FLOW A: Walk-In Assignment → Call Next / Skip / No-Show

**Trigger:** Client checks in as "Any Barber" → system assigns → barber sees notification → barber decides.

**Steps and verifications (run in order):**

1. **Check-in created**
   - DB: `queue_entries` row with `status='waiting'`, `barber_preference_id IS NULL`, `assigned_barber_id IS NULL`, valid `location_id`.
   - Verify: `SELECT id, status, assigned_barber_id, barber_preference_id, location_id FROM queue_entries WHERE client_phone = '...' ORDER BY check_in_time DESC LIMIT 1;`

2. **Auto-assign eligibility — barber is actually available**
   - Barber clocked in at this location: `staff_status.status IN ('clocked_in')` (NOT `'on_break'`, `'clocked_out'`, `'with_client'`)
   - Barber mode is `auto` (not `manual` or `paused`): check `barbers.queue_control_mode`
   - Barber is `is_active = true`
   - Barber has no active `queue_entries` with `status='in_chair'`
   - Barber has no overlapping `bookings` with `status IN ('confirmed','in_progress')` for now
   - Barber has no conflicting academy session / Google Calendar event / Booksy event
   - Verify with the rotation-preview query in `audit-queries.sql` query #19.

3. **Assignment executed**
   - PATCH via `/api/queue/entry/[id]` → `status='called'`, `assigned_barber_id=X`, `called_time=now()`.
   - FIFO check: the assigned entry was first in waiting list (position ASC) OR it was an explicit barber preference.
   - Fairness check: `cuts_today ASC, last_cut_completed_at ASC` winner.

4. **Notification chain fires**
   - `barber_notifications` row INSERTed (type='queue_assigned' or similar).
   - Realtime publication emits on `queue_entries` + `barber_notifications`.
   - In-app: `WalkInAlertModal` (or equivalent) displays on barber's open page.
   - Push: if barber not in app, push via `/api/push/**` → their phone → service worker displays OS notification.
   - SMS: customer gets "You've been called" SMS.

5. **Barber decision window (3 min)**
   - Customer-side no-show timer starts at `called_time + 3 min`.
   - Barber UI shows "Call to Chair" and "Skip" buttons.
   - Auto-start: 60s after `handleCallNext` set `calledClientIdRef.current = entryId`. If ref matches currentClient.id at 60s, auto-transition to `in_chair`. If barber skips or ref doesn't match → no auto-start.

6. **Call to Chair**
   - PATCH → `status='in_chair'`, `start_time=now()`.
   - API guard at `src/app/api/queue/entry/[id]/route.ts` lines 217-252 blocks if barber already has another active in_chair OR active booking.
   - `staff_status` updates: `status='with_client'`, `current_queue_entry_id=entryId`.
   - UI transitions to In-Service Mode (full-screen takeover).

7. **Skip (barber passes)**
   - Entry becomes available for re-assignment to another eligible barber.
   - `calledClientIdRef` stays null (this barber passed — no auto-start).
   - Next rotation winner gets assigned.

8. **No-show path (3 min expires with no action)**
   - Barber manually marks as no_show (automatic cron was removed 2026-03-22 per MEMORY.md).
   - PATCH → `status='no_show'`, `end_time=now()`.
   - Next client gets called.

### Diagnose breakpoint quick reference

| Symptom | Likely broken step | First check |
|---|---|---|
| Client assigned to barber who's on break | Step 2 — eligibility check | `staff_status.status` for that barber |
| Client assigned to barber with active in-chair | Step 2 — active check | query queue_entries for that barber |
| Barber doesn't see the assignment modal | Step 4 — realtime not firing | `pg_publication_tables` + hook subscription |
| Barber's phone doesn't buzz | Step 4 — push failed | `push_subscriptions` for barber + `bulletproof-push-notifications` |
| Customer doesn't get SMS | Step 4 — SMS path broken | `bulletproof-communications` |
| Auto-start fired for wrong client | Step 5 — `calledClientIdRef` pattern | see MEMORY.md HARD RULE + incidents.md |
| Call to Chair rejected with "active booking" | Step 6 — guard correctly blocks | check the API guard + bookings for that barber |

### FLOW B: Clock-In → Availability → Eligible for Assignment

1. Barber taps "Clock In" at a location.
2. `staff_status` row updated: `status='clocked_in'`, `location_id=X`, `clocked_in_at=now()`, `cuts_today=0` (on new day).
3. If `staff_status` row didn't exist, one is INSERTed.
4. Barber now eligible for auto-assignment at this location.
5. On break → `transition_staff_status` RPC → `status='on_break'`, eligible check fails.
6. On clock-out → `status='clocked_out'`, removed from rotation.

Verify with atomic RPC: `transition_staff_status(p_barber_id, p_expected_status, p_new_status, ...)`.

### FLOW C: Post-Service Flow (after Complete Service)

1. Barber taps "Complete Service" from In-Service Mode.
2. `complete_queue_service` RPC called atomically: UPDATE queue_entries status='completed', UPDATE staff_status cuts_today++, UPSERT clients row.
3. `service_transactions` trigger fires → inserts audit row.
4. Commission: cash → `cash_fee_ledger` row INSERTed. Card/link → fees auto-split or pending.
5. Loyalty punch via `add_loyalty_punch(phone)` RPC.
6. Smart routing UI: next booking in 15 min? queue has waiting? nothing pending?

---

## HARD RULES (non-negotiable, from `debugging-protocol.md`)

- **NEVER write to the production DB.** Not even with test barber IDs. Not "temporarily." READ-ONLY via `mcp__supabase-mt__execute_sql`. If a fix requires writes, tell the user and get explicit approval.
- **NEVER modify a working system without explicit user approval.** Fair rotation, state machine, atomic RPCs, `calledClientIdRef` guard, in-chair guard — all locked. Can suggest. Cannot implement.
- **NEVER expand scope.** If the user reports a symptom in the queue, fix THAT symptom. Do not "also improve" surrounding code.
- **ALWAYS use `mcp__supabase-mt__`**, never `mcp__supabase__` (different project, unrelated).
- **NEVER test on real barbers.** Only use test accounts: `b0020000-0000-0000-0000-000000000002`, `b0030000-0000-0000-0000-000000000003`, `b0040000-0000-0000-0000-000000000004`, dev owner `a274e1cf-955a-46f1-bc4c-dcd06a0510af`.
- **If a fix breaks any existing behavior, FULL REVERT.** Not a partial fix. Not a cherry-pick.
- **Branch workflow:** any code change goes on a `fix/…` or `feature/…` branch, never directly to `main`. Merge only with explicit user approval.
- **User reports override queries.** If the user says "I see X on the screen" and your SQL says otherwise, the user is right. Find the code path the UI uses.

---

## When Firecrawl Is Useful (and When It Isn't)

Useful:
- Verifying current Next.js 14 Data Cache behavior if docs changed
- Checking Stripe webhook idempotency patterns
- Confirming Supabase RLS syntax if unsure
- Reading recent release notes after an upgrade

Not useful:
- "How do other barbershops handle walk-in queues?" — you see their UI, not their schema
- "Best practices for multi-location SaaS" — too generic, doesn't know our tables

Invoke firecrawl ONLY at diagnosis time when a specific external question comes up. Do not pre-scrape anything into this skill.

---

## What to Return to the User

End every invocation with either:
- A completed report (audit / scale-check)
- A reproduction case + proposed fix in one file (diagnose)
- Or an explicit "I don't know — here's what I found, need direction"

Never silently retry. Never keep reading files hoping for clarity.
