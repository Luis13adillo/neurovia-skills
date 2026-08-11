---
name: bulletproof-locations
description: Audit, diagnose, or scale-check the MT Barbershop locations system (locations table, hours_json, slugs, FALLBACK_LOCATIONS, cross-cutting location references). Use when location data drifts (wrong phone, wrong address, closed-Sunday bugs), before adding or removing a location, or to verify the codebase is ready for N locations. Read-only SQL via mcp__supabase-mt__execute_sql and codebase greps only. Never writes to the production DB.
---

# Bulletproof Locations

Location data is sacred per CLAUDE.md. Addresses, phone numbers, and hours are the canonical source of truth — not the fallback constants, not email templates. If they drift, customers get the wrong address, walk to the wrong plaza, and call a disconnected number.

This skill focuses on two failure modes: drift from canonical data, and scale bottlenecks when adding a 4th, 5th, or Nth location.

This skill does NOT replace `CLAUDE.md`, `MEMORY.md`, or the `.claude/rules/*.md` files. It READS them, then runs a structured protocol.

---

## Mandatory Preflight — BEFORE any action

1. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/CLAUDE.md` — "Multi-Location System" section (canonical data).
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-MT-Barbershop-Systems/memory/MEMORY.md` — "Location Data — CANONICAL" entry (updated 2026-03-25) and the banned old phone numbers.
3. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.claude/rules/debugging-protocol.md` — Sections 4, 5, 7, 8, 9.
4. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.claude/rules/context-awareness.md` — Cross-Dashboard Mirroring Rule.

Confirm "Preflight complete. Running [mode]."

---

## Canonical values (verify EXACT match in audit)

Per CLAUDE.md + MEMORY.md as of 2026-04-20:

| Location | Slug | Address | Phone | Plaza | State |
|---|---|---|---|---|---|
| Wilmington (Primary) | `wilmington` | 3616 Kirkwood Hwy, Wilmington, DE 19808 | (302) 983-2621 | Delaware Liberty Center | DE |
| Newark | `newark` | 73 Marrows Rd, Newark, DE 19713 | (302) 294-1909 | Brookside Plaza | DE |
| New Castle | `new-castle` | 101 Penn Mart Shopping Ctr, New Castle, DE 19720 | (302) 983-2621 | Penn Mart Shopping Center | DE |
| Edwardsville | `edwardsville` | 34 Gateway Shopping Center, Edwardsville, PA 18704 | (347) 792-9614 | Gateway Shopping Center | **PA** |

Location UUIDs (for reference in cross-checks):
- Wilmington: `a1b2c3d4-e5f6-7890-abcd-ef1234567890`
- Newark: `b2c3d4e5-f6a7-8901-bcde-f12345678901`
- New Castle: `c3d4e5f6-a7b8-9012-bcde-f12345678902`
- Edwardsville: `d4e5f6a7-b8c9-0123-cdef-f12345678903`

Hours per CLAUDE.md. Newark closed Sundays (`hours_json.sunday` is null). Edwardsville is the only PA location — email templates must use `locationState` from booking data, never hardcode `", DE"` (see MEMORY.md 2026-04-20 cross-state email fix).

**Banned / deprecated (must NOT appear anywhere in code or DB):**
- Old phone `(302) 998-0900`
- Old phone `(302) 369-0900`
- Any `(302) 555-xxxx` placeholder
- "Houston, TX" anywhere (removed 2026-03-25)
- Hardcoded `, DE` in email template footers (use `locationState` prop — 2026-04-20 fix)

---

## Choose a Mode

- **audit**, **diagnose**, **scale-check**, or **fix**. `audit`, `diagnose`, and `scale-check` are READ-ONLY. `fix` is the only mode that edits code, and only under the explicit gate described in its section.

---

## AUDIT RIGOR — read before starting audit mode

This skill enforces the universal Audit Rigor Standard at `~/.claude/skills/_shared/audit-rigor.md` and the domain Surface Inventory at `references/SURFACE_INVENTORY.md`. Read both before you do anything.

**Five Pillars (all mandatory):** codebase, database, queries, RLS, integrations. Missing any pillar = failed audit.

**Proof-of-Read:** every file claimed PASS in the Coverage Report MUST cite a `file.ts:LINE` from that file. No line = NOT-RUN, not PASS. This is enforced by the universal standard.

**Forcing language — copy this into your mental model:**

> Do NOT stop on first pass. You MUST work through EVERY file in SURFACE_INVENTORY.md (70+ surfaces), EVERY query in audit-queries.sql, EVERY RLS policy, EVERY trigger, and EVERY integration. Stopping after one finding is a half-audit and is explicitly forbidden.
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
| Add a new location (INSERT into `locations`) | `FALLBACK_LOCATIONS` matches new DB state + `LOCATION_SLUGS` constant updated + `LOCATION_INFO` map updated + `hours_json` provides all 7 days + `max_queue_size` set + `slug` uniqueness + `state` column set (DE vs PA) + new `manifest-kiosk-<slug>.json` created + new `NEXT_PUBLIC_GOOGLE_REVIEW_URL_<SLUG>` env var + static `/queue/<slug>/page.tsx` or catch-all update + `/locations/page.tsx` `locationExtras` entry + `middleware.ts` slug resolution still works | Adding a location touches 11+ surfaces. Missing any = 404 / stale UI / wrong phone / missing PWA manifest. |
| DELETE a location | FK CASCADE to `barber_schedules`, `queue_entries`, `bookings`, `staff_status`, `academy_sessions`, `daily_summaries`, `cash_fee_ledger`, `location_change_requests` + FALLBACK_LOCATIONS cleanup + env vars removed + static page removed + kiosk manifest removed | DELETE cascades through 8 FK'd tables — historical data DIES. Rarely the intent. |
| Edit location phone / address / hours | DB `locations` row updated + NO hardcoded phone in `src/lib/email/`, `src/lib/twilio/`, or templates + NO hardcoded address in same locations + `FALLBACK_LOCATIONS` in `src/lib/utils/locations.ts` matches + consumer templates use `booking.location.phone` / `.address` (NOT `locations[0].phone`) + `useLocations` SWR revalidation | Location data drift = customer calls wrong number. |
| Change `hours_json` (any day) | `hours_json` shape preserved (7 days + max_queue_size) + Sunday null = closed handled correctly + availability API respects new hours + queue check-in rejects outside hours + public /locations page renders updated hours | Hours drive availability. Newark closed Sunday bug was a `hours_json` validation miss. |
| Toggle `accepts_walk_ins` | `/api/locations/[id]/pause/route.ts` + queue check-in `/queue` gated + waitlist overflow routing + TV board messaging + homepage queue widget respects flag | Pause must be respected across all queue consumers. |
| Change location `state` (especially Edwardsville DE→PA drift) | All email templates pass `locationState` from booking location (NOT hardcoded `, DE`) — `src/lib/email/templates.ts` + `academy-templates.ts` + booking + reschedule routes propagate `location.state` | MEMORY.md 2026-04-20 incident: Edwardsville (PA) emails had `, DE` in footer. Missing state propagation = legal risk. |
| Change location `slug` | `middleware.ts` slug resolution + `LOCATION_SLUGS` constant + static `/queue/<slug>/page.tsx` path + `manifest-kiosk-<slug>.json` filename + `NEXT_PUBLIC_GOOGLE_REVIEW_URL_<SLUG>` env var + SEO meta tags + all external links (business cards, Google Business) | Slug is public-facing URL — old links 404. |
| `resolveBarberLocation('current')` in `lib/db/location.ts` | Priority chain: `staff_status.location_id` → `preferred_location_id` → today's schedule → most common → `locations[0]` + Eastern TZ + `staff_status` active-status gate | Fallback to `locations[0]` (Wilmington) = classic "barber at wrong location" bug for clocked-out barbers. |
| Any `locations[0]` fallback site (11 known) | Verify context loads real locations from DB FIRST + fallback is safety net only + not a bias to location #1 + still works when adding location #5 | `locations[0]` is safe when DB loads first; unsafe when it's the primary lookup. |
| `useLocations` hook | SWR 30s dedup + revalidateOnFocus + `cache: 'no-store'` on Supabase client + `FALLBACK_LOCATIONS` served on first paint if no data | Hook is the universal read — any stale reads here cascade to every consumer page. |
| `middleware.ts` slug→id resolution | Uses DB or `LOCATION_SLUGS` constant (both must match) + handles all 4 canonical slugs + rejects unknown slug with 404 (NOT silent fallback to `locations[0]`) | Middleware is the gate — silent fallback here masks 404s. |
| Kiosk PWA manifests | `public/manifest-kiosk-<slug>.json` exists for each active slug + manifest references correct start_url per location + scope per location | Missing kiosk manifest = PWA install fails on tablet at that location. |
| Public locations page `locationExtras` | Keyed by slug + has entry for every active `locations.slug` + plaza/parking/mapUrl/barberCount set + Edwardsville entry present | Missing entry = broken card on /locations page. |
| Email/SMS templates reading location | Uses `booking.location.*` fields (stored on booking) NOT `locations[0].*` or hardcoded strings + `locationState` explicitly passed (no hardcoded `, DE`) | Templates with `locations[0]` = every email shows Wilmington. |
| `barbers.preferred_location_id` (location anchor for all active barbers) | NON-NULL for every `is_active = true` barber + writers: create-barber route + owner schedule PUT + `/api/barber/location` PUT (3 writers) + `location-request` PATCH intentionally does NOT touch it | NULL anchor = clocked-out barber falls through to `locations[0]`. |

**A PASS on the left side without evidence of auditing the right side = COUPLING VIOLATION.** Report it in the Gap Self-Report.

---

## Mode: audit

### Step 0 — Universal Audit Preamble (MANDATORY — run first, always)

Run the 5 discovery queries from `~/.claude/skills/_shared/audit-rigor.md` section "Universal Audit Preamble", filled in with the locations domain values:

```sql
-- 1. Enumerate locations domain tables + all location_id-carrying consumer tables
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN (
    'locations','barber_schedules','queue_entries','bookings','staff_status',
    'academy_sessions','daily_summaries','cash_fee_ledger','location_change_requests'
  )
ORDER BY table_name;
-- Expected: 9 rows. Missing = inventory drift; STOP and ask user.

-- 2. RLS policies on locations
SELECT tablename, policyname, cmd, roles
FROM pg_policies
WHERE schemaname = 'public' AND tablename = 'locations'
ORDER BY policyname;
-- Expected: at least 1 public SELECT policy + owner write.

-- 3. Location-id FK cascade behavior
SELECT conname, pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE contype = 'f'
  AND pg_get_constraintdef(oid) ILIKE '%REFERENCES locations%'
ORDER BY conname;
-- Expected: all ON DELETE CASCADE (per migration 001).

-- 4. Canonical locations present with expected slugs
SELECT slug, name, state, is_active
FROM locations
ORDER BY name;
-- Expected: 4 rows — wilmington(DE), newark(DE), new-castle(DE), edwardsville(PA), all is_active=true.

-- 5. Migration history
SELECT name, executed_at FROM supabase_migrations.schema_migrations
WHERE name ILIKE '%location%' OR name ILIKE '%new_castle%' OR name ILIKE '%slug%'
   OR name ILIKE '%accepts_walk_ins%' OR name ILIKE '%queue_pause%'
ORDER BY executed_at;
-- Expected: at least 4 rows (see SURFACE_INVENTORY.md section 10).

-- 6. preferred_location_id column on barbers (required — routing anchor)
SELECT column_name FROM information_schema.columns
WHERE table_name = 'barbers' AND column_name = 'preferred_location_id';
-- Expected: 1 row.

-- 7. Edwardsville state = 'PA' (cross-state email fix, 2026-04-20)
SELECT slug, state FROM locations WHERE slug = 'edwardsville';
-- Expected: state='PA'.
```

Attach all 7 result sets to the report under "Universal Preamble". Any drift = stop before domain checks.

### Data-level (production DB)

Run queries in `references/audit-queries.sql`. Expected: all canonical values match.

### Code-level

1. **FALLBACK_LOCATIONS matches DB**
   - File: `src/lib/utils/locations.ts`
   - `FALLBACK_LOCATIONS` array is a safety net for SSR edge cases. It should match canonical values. If it drifts from DB, that's a potential future production bug (when the DB query fails, users see stale data).

2. **LOCATION_SLUGS and LOCATION_INFO mappings consistent**
   - Same file. `LOCATION_SLUGS` maps slug→id. `LOCATION_INFO` maps slug→name/address/city/state/zip.
   - These must all reference the same 4 locations or the slug→data lookup will be incomplete.

3. **resolveBarberLocation() priorities correct**
   - File: `src/lib/db/location.ts`
   - Mode `current`: `staff_status.location_id` (if clocked_in/on_break/with_client) → `preferred_location_id` → today's schedule → most common → `locations[0]`
   - Mode `appointment`: appointment day's schedule → `preferred_location_id` → `locations[0]`
   - Always ET-safe via `toLocaleDateString('en-CA', { timeZone: 'America/New_York' })`
   - **CRITICAL:** `staff_status.location_id` is ONLY read when status is active (`clocked_in`/`on_break`/`with_client`). A clocked-out barber relies on `preferred_location_id` → schedule. If both are stale, they fall back to `locations[0]` (Wilmington) — the classic "wrong location" bug.

4. **preferred_location_id must be set on every active barber (durable anchor invariant)**
   - File: `src/app/api/auth/create-barber/route.ts` — barber insert MUST include `preferred_location_id: location_id`. This is the only way to guarantee correct routing when the barber is clocked-out on a day with no schedule row.
   - File: `src/app/api/barbers/[id]/schedule/route.ts` — owner's PUT handler MUST recompute the most-common `location_id` from the new `activeSchedule` and UPDATE `barbers.preferred_location_id` to it. Without this, relocating a barber via the schedule editor leaves a stale anchor.
   - File: `src/app/api/barber/location/route.ts` — barber's manual location switch. This is the 3rd writer.
   - Audit query:
     ```sql
     SELECT b.slug, b.preferred_location_id,
            (SELECT l.slug FROM locations l WHERE l.id = b.preferred_location_id) AS pref_slug,
            (SELECT COUNT(*) FROM barber_schedules bs WHERE bs.barber_id = b.id AND bs.is_active) AS schedule_rows
     FROM barbers b WHERE b.is_active = true AND b.preferred_location_id IS NULL;
     ```
   - Expected: zero rows. Any NULL `preferred_location_id` on an active barber is a latent routing bug. Any `is_active = true` barber with `schedule_rows = 0` is WORSE — they will always resolve to `locations[0]`.
   - By design exception: **location-change-request PATCH** (`src/app/api/barber/location-request/route.ts`) intentionally does NOT touch `preferred_location_id` because it's a per-day routing change, not a primary-location move.

5. **No banned strings anywhere**
   - `grep -rEn "302[- ]?998[- ]?0900|302[- ]?369[- ]?0900|302[- ]?555[- ]?" src/`
   - `grep -rn "Houston, TX" src/ supabase/`
   - `grep -rn "', DE'\|\", DE\"" src/lib/email` — hardcoded state in email footers (should use `locationState`)
   - Expected: zero matches (except fixed strings inside quoted test strings or known comments that reference history).

6. **No hardcoded addresses in templates**
   - `grep -rn "Kirkwood Hwy\|Marrows Rd\|Penn Mart\|Gateway Shopping" src/lib/email src/lib/twilio`
   - Expected: zero matches. Addresses come from `locations.address`.

7. **Public `/locations` page uses DB, not hardcodes**
   - File: `src/app/(public)/locations/page.tsx`
   - Should fetch via `useLocations()` hook.
   - `locationExtras` map (plaza, parking, mapUrl, barberCount) is keyed by slug — this is acceptable (UI-only extras). Verify Edwardsville has an entry.

### Output template — MANDATORY Coverage Report

Every locations audit MUST produce this full block. A report without the Coverage Report section is INCOMPLETE and will be rejected.

```markdown
## Locations Audit Report — [YYYY-MM-DD]

### Universal Preamble
- Tables enumerated: 9/9 PASS | X/9 FAIL
- RLS policies found: X — list any gaps
- FK cascades to locations ON DELETE CASCADE: PASS/FAIL
- Canonical 4 slugs present: wilmington, newark, new-castle, edwardsville — PASS/FAIL
- Edwardsville state='PA': PASS/FAIL
- preferred_location_id column on barbers: PASS/FAIL
- Migrations confirmed: X/4

### Code-level findings
[PASS/FAIL per invariant with file:line anchors]

### Data-level findings
[PASS/FAIL per query]

---

## Coverage Report (MANDATORY)

### Pillar 1 — Codebase (36 files from SURFACE_INVENTORY.md sections 1-6) — PROOF-OF-READ REQUIRED
| # | File | Verdict | Evidence (file:line — what was checked) |
|---|---|---|---|
| 1 | src/app/api/locations/route.ts | PASS/FAIL/NOT-RUN | e.g. "route.ts:42 — is_active filter + public role" |
| 2 | src/app/api/locations/stats/route.ts | | |
| ... | [all 36] | | |

Files audited with proof-of-read: N / 36 (target: 36/36). Any PASS without a file:line citation = treated as NOT-RUN.

### Pillar 2 — Database (9 tables from SURFACE_INVENTORY.md section 7)
| Table | Row count | Distribution | NULL / FK violations | Verdict |
|---|---|---|---|---|
| locations | | state dist (DE:3, PA:1) | is_active=false count | |
| barber_schedules.location_id | | orphan count | | |
| queue_entries.location_id | | orphan count (30 days) | | |
| bookings.location_id | | orphan count | | |
| staff_status.location_id | | orphan count | | |
| academy_sessions.location_id | | orphan count | | |
| daily_summaries.location_id | | orphan count | | |
| cash_fee_ledger.location_id | | orphan count | | |
| location_change_requests.requested_location_id | | orphan count | | |

Tables audited: N / 9

### Pillar 3 — Queries (from references/audit-queries.sql)
| # | Query | Verdict | Rows |
|---|---|---|---|
| 1 | canonical_phones_match | | |
| 2 | no_banned_phones_in_db | | |
| 3 | hours_json_shape_valid | | |
| 4 | preferred_location_id_not_null_on_active | | |
| ... | [all queries] | | |

Queries run: N / N_total. Skipped: [empty — or list with reason].

### Pillar 4 — RLS (1 locations table)
| Table | Policies found | Expected | Verdict |
|---|---|---|---|
| locations | | ≥2 (public select, owner all) | |

RLS tables audited: N / 1 (plus child-table RLS is covered by owning domains)

### Pillar 5 — Integrations (SURFACE_INVENTORY.md sections 11, 12, 13, 14, 15)
| Integration | Verdict | Note |
|---|---|---|
| FALLBACK_LOCATIONS matches DB | | file: src/lib/utils/locations.ts |
| LOCATION_SLUGS + LOCATION_INFO consistent | | |
| resolveBarberLocation priority chain | | file: src/lib/db/location.ts |
| Middleware slug→id resolution | | file: src/middleware.ts |
| Email templates use locationState (no hardcoded `, DE`) | | src/lib/email/templates.ts |
| Academy email templates state-aware | | src/lib/email/academy-templates.ts |
| Kiosk manifest for each active slug exists | | public/manifest-kiosk-*.json |
| Google Review env var per location | | NEXT_PUBLIC_GOOGLE_REVIEW_URL_* |
| No banned phone strings in src/ | | grep (302)998-0900, 369-0900, 555-xxxx |
| No "Houston, TX" anywhere | | |
| No hardcoded addresses in templates | | grep Kirkwood/Marrows/Penn Mart/Gateway |
| Public `/locations` has Edwardsville in locationExtras | | |
| `locations[0]` fallback sites OK | | 11 known sites |

Integrations audited: N / 13

### Coupling Checks (from Cross-Surface Coupling Rules table)
| Coupling | Both sides audited? | Note |
|---|---|---|
| Add location → {FALLBACK_LOCATIONS, LOCATION_SLUGS, LOCATION_INFO, hours_json 7-day, slug unique, state, manifest, env var, static page/catchall, locationExtras, middleware} | YES/NO | |
| DELETE location → {8 FK CASCADE tables, FALLBACK cleanup, env vars, static page, manifest} | YES/NO | |
| Edit phone/address/hours → {DB row, no hardcode in templates, FALLBACK_LOCATIONS sync, consumer uses booking.location.*, SWR revalidate} | YES/NO | |
| hours_json change → {7-day shape preserved, Sunday null handled, availability API, queue check-in, /locations page} | YES/NO | |
| accepts_walk_ins toggle → {pause route, queue gating, waitlist overflow, TV board, homepage widget} | YES/NO | |
| state change (Edwardsville PA coupling) → {email templates use locationState, academy-templates, booking+reschedule routes pass location.state} | YES/NO | |
| slug change → {middleware, LOCATION_SLUGS, static page path, manifest filename, env var, SEO, external links} | YES/NO | |
| resolveBarberLocation('current') priority chain → {staff_status → preferred → today → common → locations[0] + ET + active gate} | YES/NO | |
| All `locations[0]` fallback sites (11 known) → {DB loads first, fallback only, not primary lookup, scale-safe} | YES/NO | |
| useLocations hook → {SWR 30s, revalidateOnFocus, cache no-store, FALLBACK on first paint} | YES/NO | |
| middleware slug→id → {DB or constant (both match), all 4 slugs, 404 on unknown (no silent fallback)} | YES/NO | |
| Kiosk PWA manifests → {manifest per slug, start_url + scope correct} | YES/NO | |
| /locations `locationExtras` → {all 4 canonical slugs including Edwardsville entry} | YES/NO | |
| Email/SMS templates → {booking.location.* used, locationState explicitly passed, no hardcoded strings} | YES/NO | |
| barbers.preferred_location_id → {NON-NULL on active, 3 writers, location-request does NOT touch} | YES/NO | |

Coupling violations: N  **(must be 0 — any NO row is a violation)**

---

## Gap Self-Report (MANDATORY)

| # | Gap | Why it matters | Severity |
|---|---|---|---|
| G1 | [e.g. Did not open public/manifest-kiosk-edwardsville.json] | Missing manifest = kiosk PWA install fails at Edwardsville | Unknown |

Surfaces in SURFACE_INVENTORY.md NOT audited this run: <comma-separated item numbers>.
Questions requiring external verification (Google Business listing, domain DNS, kiosk hardware, etc.): <list>.

If zero gaps: write "No gaps identified. All 70+ surfaces audited with proof-of-read + all coupling checks passed."

---

## Totals

- Surfaces audited with proof-of-read: X / 70+ (XX%)
- FAILs: N
- NOT-RUNs: N  (if > 0, the audit is PARTIAL, not COMPLETE — state this in the header)
- Coupling violations: N (must be 0)

**If NOT-RUNs > 0 OR coupling violations > 0, the report header MUST say "PARTIAL LOCATIONS AUDIT — N surfaces unaudited, M coupling violations" instead of "Locations Audit Report".**
```

Stop only after every row above is filled. "Stop on first fail" is NOT the protocol — complete the full coverage sweep, then report.

---

## Mode: diagnose

1. Ask for symptom. Examples:
   - "Customer called the old number and got voicemail"
   - "Confirmation email shows wrong address"
   - "Sunday queue page for Newark shows 'open' when it should be closed"
   - "Team page shows a barber at Wilmington but they work at Newark Tuesdays"
   - "A barber I just onboarded is showing at the wrong location when they're clocked out"
   - "Edwardsville barber emails have `, DE` in the footer" (should be `, PA`)

2. Match against `references/incidents.md`.

3. Three-file rule. Two-strike rule. Stay in scope.

**Critical:** NEVER update a location's phone / address / hours directly without explicit user approval. Even correct updates touch customer-facing data.

### Diagnose: "A barber shows up at the wrong location when clocked out"

This is the NULL-preferred_location_id class of bug. `resolveBarberLocation()` in `current` mode has a priority chain; the first matching source wins. If a barber is clocked-out, step 1 (staff_status) is skipped. If `preferred_location_id` is NULL AND today has no schedule row, they fall through to `locations[0]` (Wilmington).

**Checklist:**
1. `SELECT preferred_location_id FROM barbers WHERE id = '<barberId>'`. If NULL → that's the smoking gun.
2. `SELECT day_of_week, location_id FROM barber_schedules WHERE barber_id = '<barberId>' AND is_active`. Is there a row for today's day_of_week (ET)? If zero rows total → even the "most common" step fails.
3. `SELECT status, location_id FROM staff_status WHERE barber_id = '<barberId>'`. If status is `clocked_in`/`on_break`/`with_client`, that overrides everything — check that location_id.
4. Fix: owner re-saves the barber's schedule via the schedule editor (this now re-syncs `preferred_location_id`), OR the barber hits the "I'm at location X" switcher which writes `preferred_location_id` directly via `/api/barber/location`.
5. Backfill existing gaps: `UPDATE barbers SET preferred_location_id = (SELECT location_id FROM staff_status WHERE barber_id = barbers.id LIMIT 1) WHERE preferred_location_id IS NULL AND is_active = true;` — only after explicit owner approval since it touches real barber rows.

---

## Mode: scale-check

Produce the "adding location #4 or #5" checklist.

1. **All `locations[0]` references** (known list from previous mapping — verify still present):
   - `src/app/page.tsx:214`
   - `src/app/(dashboard)/dashboard/my-chair/page.tsx:199`
   - `src/components/site/MobileHomePage.tsx:92`
   - `src/app/(dashboard)/dashboard/my-chair/queue/page.tsx:100`
   - `src/app/(dashboard)/dashboard/my-chair/schedule/page.tsx:427, 600`
   - `src/components/dashboard/WalkInForm.tsx:35`
   - `src/components/dashboard/academy/SessionScheduler.tsx:74`
   - `src/components/dashboard/BarberScheduleModal.tsx:74, 89, 110`
   - `src/app/(dashboard)/barber/schedule/page.tsx:372, 397`
   - `src/app/(dashboard)/barber/walk-ins/page.tsx:255`
   - `src/app/(dashboard)/dashboard/queue/page.tsx:89, 599, 629`

   Safe: context loads real locations from DB first. These are fallbacks.
   Flag: any that don't have DB loading upstream — that's an actual bias to location #1.

2. **Static queue pages**
   - `src/app/(public)/queue/wilmington/page.tsx`
   - `src/app/(public)/queue/newark/page.tsx`
   - `src/app/(public)/queue/new-castle/page.tsx`
   - `src/app/(public)/queue/edwardsville/page.tsx` (added 2026-04)
   - Each static page references a `manifest-kiosk-<slug>.json` — scale-check: the new location must also have its kiosk manifest under `/public/`.
   - Adding location #5 requires a new static page OR verifying the catch-all `[...slug]` handler handles new slugs. Recommend refactor to catch-all before scaling to 6+.

3. **`locationExtras` UI-only map**
   - `src/app/(public)/locations/page.tsx` has a hardcoded `locationExtras` object keyed by slug (plaza name, parking info, map URL, ratings). Adding a new location needs a new entry.

4. **Google Review URL env vars**
   - `NEXT_PUBLIC_GOOGLE_REVIEW_URL_WILMINGTON`, `_NEWARK`, `_NEW_CASTLE`, `_EDWARDSVILLE`.
   - Each new location needs its own env var + the code reading these to handle the new slug.
   - Better long-term: move to `locations.google_review_url` DB column. Recommend in report; don't implement.

5. **`hours_json` shape** must include all 7 days + `max_queue_size`
   - Example shape (from New Castle):
     ```json
     {
       "monday": {"open":"09:00","close":"20:00"},
       ...
       "sunday": {"open":"10:00","close":"17:00"},
       "max_queue_size": 10
     }
     ```
   - Sunday null = closed.
   - Any new location must provide all 7 keys.

6. **Barber schedules for the new location**
   - Before go-live, every barber assigned to the new location needs `barber_schedules` rows for their working days. Without them, they're invisible to booking + fair rotation.

7. **Cascading FK dependencies**
   - `staff_status.location_id`, `queue_entries.location_id`, `bookings.location_id`, `academy_sessions.location_id`, `daily_summaries.location_id`, `barber_schedules.location_id`, `cash_fee_ledger.location_id` (optional).
   - Deleting a location cascades (ON DELETE CASCADE per migration 001). Adding is free (no dependencies to break).

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

Location data (address, phone, hours) flows to nearly every page. A wrong value becomes a customer-visible bug within minutes.

### Consumers (every surface that reads location data)

| Consumer | File / URL | What it reads |
|---|---|---|
| Homepage | `src/app/page.tsx` + `src/components/site/MobileHomePage.tsx` | location cards, phone, address |
| Public locations | `src/app/(public)/locations/page.tsx` | full list with hours + map |
| Queue check-in pages | `/queue/wilmington`, `/newark`, `/new-castle` (static) + `/queue/[...slug]` (catch-all) | location-specific queue UI |
| TV board | `src/app/(public)/tv/[location]/page.tsx` | location name, branding |
| Team page | `src/app/(public)/team/page.tsx` | filters barbers by location per day |
| Public profile | `src/app/(public)/mtbarbers/[slug]/page.tsx` | barber's working location per day |
| Booking wizard step 1 | `/book` | location selector |
| Email templates | `src/lib/email/templates/*` | confirmation, reminder, cancellation |
| SMS templates | `src/lib/twilio/templates/*` | reminder, queue, feedback |
| Middleware slug resolution | `src/middleware.ts` | slug → id for route scoping |
| FALLBACK_LOCATIONS | `src/lib/utils/locations.ts` | SSR edge case safety net (must match DB) |

### Propagation invariants

1. **FALLBACK_LOCATIONS matches DB** — otherwise first-paint shows stale data.
2. **`useLocations` hook uses SWR with 30s dedup + revalidateOnFocus.** Changes propagate to every page within 30s naturally; or immediately on focus.
3. **No hardcoded addresses / phones in templates.** Templates read from `booking.location.address`, `booking.location.phone`, etc.
4. **Middleware resolves slug to id from DB, not from a static map** (except the `LOCATION_SLUGS` constant which must match DB).
5. **`hours_json` keys (monday..sunday + max_queue_size) always present.**
6. **`barbers.preferred_location_id` is NON-NULL for every `is_active = true` barber.** This is the durable anchor for clocked-out barber routing. Writers: create-barber route, owner schedule PUT, and `/api/barber/location` PUT. Location-change-request PATCH intentionally does NOT touch it (per-day routing by design).
7. **Email templates receive `locationState` explicitly** — no hardcoded `, DE` or `, PA`. Edwardsville is PA, all others are DE. Booking + reschedule routes must pass `location.state` from the DB through to every template call.

### Diagnose: "I updated Wilmington's phone number in the owner dashboard, but emails still send the old number"

1. DB update happened? `SELECT phone FROM locations WHERE slug = 'wilmington'`. Is it the new number?
2. Email template hardcoded? Grep `src/lib/email/templates/` for `302`. Flag any literal.
3. FALLBACK_LOCATIONS stale? Read `src/lib/utils/locations.ts` — still has the old number?
4. `useLocations` cache stale? The hook caches for 5 minutes in the locations helper; SWR has 30s dedup. User may need to refresh.
5. If all green → a template is using `locations[0].phone` instead of `booking.location.phone`. Find and flag.

---

## HARD RULES

- NEVER write to production DB (location data included — a wrong phone change breaks customer calls).
- NEVER modify canonical values (phone, address, hours) without explicit approval — even "fixing a typo."
- Location Data Is Sacred per CLAUDE.md.
- ALWAYS use `mcp__supabase-mt__`.
- Branch workflow. Stay in scope.
