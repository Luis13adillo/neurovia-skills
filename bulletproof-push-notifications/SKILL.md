---
name: bulletproof-push-notifications
description: Audit, diagnose, or scale-check the MT Barbershop PWA push notification infrastructure (push_subscriptions table, /api/push/**, /src/lib/push/**, /public/sw.js service worker, VAPID keys, web-push delivery, subscription lifecycle). Use when barbers don't get walk-in alerts on their phone, customers don't get queue notifications, subscriptions go stale, or before onboarding more devices. Read-only SQL via mcp__supabase-mt__execute_sql only. Never writes to production DB.
---

# Bulletproof Push Notifications

40 barbers across 4 locations = ~160+ device subscriptions to keep alive. A dead subscription means a barber misses a walk-in alert on their phone. A broken service worker means notification clicks go nowhere. A VAPID key rotation without coordinated subscription refresh means ALL notifications silently stop.

This skill audits the push infrastructure layer. It complements `bulletproof-queue` (which covers the upstream "when should a push fire" logic) and `bulletproof-communications` (which covers SMS as the redundancy channel).

This skill does NOT replace `CLAUDE.md`, `MEMORY.md`, or the `.claude/rules/*.md` files. It READS them, then runs a structured protocol.

---

## Mandatory Preflight — BEFORE any action

1. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/CLAUDE.md` — PWA section, push notification env vars.
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-MT-Barbershop-Systems/memory/MEMORY.md`.
3. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.claude/rules/debugging-protocol.md` — Sections 4, 5, 7, 8, 9.

**Verify schema first:**

```sql
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'push_subscriptions'
ORDER BY ordinal_position;
```

Expected columns: `id`, `endpoint`, `p256dh`, `auth`, `user_id`, `queue_token`, `created_at`, `updated_at`.

**Verify env:**

```bash
# Check these are set in production:
# - NEXT_PUBLIC_VAPID_PUBLIC_KEY (public, browser-readable)
# - VAPID_PRIVATE_KEY (server-only, never NEXT_PUBLIC_*)
# - VAPID_SUBJECT (optional, defaults to mailto:support@mtbarbershop.com)
```

---

## Two-plane audit: DATA plane vs. CODE plane

**What this skill CAN verify:** data-plane health (subscriptions valid, delivery attempts logged, no orphan rows) and code-plane structure (service worker registered, 410/404 handled).

**What this skill CANNOT verify:** actual device delivery. iOS/Android notification centers are black boxes. Real testing requires a real device with the app's PWA installed.

Be clear about this limit in every report.

---

## Choose a Mode

- **audit**, **diagnose**, **scale-check**, or **fix**.

`audit`, `diagnose`, and `scale-check` are READ-ONLY. `fix` is the only mode that makes code edits, and only under the strict gate described in its section.

---

## AUDIT RIGOR — read before starting audit mode

This skill enforces the universal Audit Rigor Standard at `~/.claude/skills/_shared/audit-rigor.md` and the domain Surface Inventory at `references/SURFACE_INVENTORY.md`. Read both before you do anything.

**Five Pillars (all mandatory):** codebase, database, queries, RLS, integrations. Missing any pillar = failed audit.

**Proof-of-Read:** every file claimed PASS in the Coverage Report MUST cite a `file.ts:LINE` from that file. No line = NOT-RUN, not PASS. This is enforced by the universal standard.

**Forcing language — copy this into your mental model:**

> Do NOT stop on first pass. You MUST work through EVERY file in SURFACE_INVENTORY.md (~52 surfaces), EVERY query in audit-queries.sql (18 queries), EVERY RLS policy, EVERY push trigger path, and EVERY integration (web-push, FCM, APNs). Stopping after one finding is a half-audit and is explicitly forbidden.
>
> Silence ≠ Pass. Self-declaration ≠ Proof. Every PASS needs a file:line citation.
>
> Obey the Cross-Surface Coupling Rules below. Skipping a coupled surface while passing its partner = coupling violation.
>
> The Coverage Report + Gap Self-Report are MANDATORY. A report missing either is rejected. If NOT-RUN > 0, the header must say "PARTIAL AUDIT".
>
> **Remember the two-plane rule:** this skill verifies DATA plane + CODE plane. It does NOT verify actual device delivery. Never mark an audit PASS on the basis of "no DB anomalies" alone — code-plane + RLS must be swept too.

---

## Cross-Surface Coupling Rules — MUST be followed

When you audit a surface on the left, you MUST also audit all surfaces on the right in the same session. These rules catch the systemic gaps where one surface's behavior depends on another that looks unrelated. A PASS on the left without evidence of auditing the right = COUPLING VIOLATION.

| If you audit... | You MUST also audit... | Why |
|---|---|---|
| `src/app/api/push/subscribe/route.ts` (POST subscribe) | (a) UPSERT by endpoint (no duplicate rows), (b) `user_id` XOR `queue_token` set (not both null), (c) RLS policy matches anon queue-token insert path, (d) `/public/sw.js` `pushsubscriptionchange` handler exists for renewal, (e) `VAPID_PRIVATE_KEY` never leaks to client bundle | Missing upsert = duplicate subscriptions = duplicate pushes. Missing queue_token path = anon customers can't subscribe. |
| `src/lib/push/server.ts` → `sendPushNotification()` | (a) 410/404 Gone → DELETE from `push_subscriptions` by endpoint, (b) payload size ≤ 4096 bytes (truncation for user-generated content), (c) `{ title, body }` always present or notification never displays, (d) `data.url` OR action handler in sw.js for every action key, (e) web-push library receives VAPID keys from env (not hardcoded) | Missing 410 cleanup = dead subscriptions accumulate forever. Missing title = silent non-display. Payload >4096 = send fails silently. |
| Queue Call-Next in `src/app/api/queue/entry/[id]/route.ts` (line ~442-485) | (a) barber `push_subscriptions` SELECT by `user_id = barber.profile_id`, (b) customer subscription by `queue_token = queue_entries.tracking_token`, (c) race-guard: re-read `queue_entries.status` before push (avoid duplicate push on concurrent PATCH), (d) `barber_notifications` INSERT (in-app bell), (e) SMS parity (same trigger fires SMS via bulletproof-communications) | Race = duplicate barber push. Missing bell row = barber misses in-app indicator. Missing SMS parity = push-only users lose visibility. |
| `src/app/api/bookings/reminders/route.ts` (cron 24h + 1h) | (a) MUST use `createAdminClient()` — SSR user client + CRON_SECRET = silent 0-row RLS failure (Gap #1), (b) `bookings.reminder_sent` / `one_hour_reminder_sent` flag UPDATE AFTER push success, (c) `push_subscriptions` SELECT via `clients.profile_id` bridge, (d) 410/404 cleanup on stale endpoints, (e) `CRON_SECRET` bearer auth | Anon RLS context returns 0 rows = silent miss. Wrong client factory = every reminder tick sends 0 pushes. |
| `src/app/api/cron/service-reminder/route.ts` (L1/L2/L3 escalation) | (a) L1 → barber push only, L2 → barber push + owner push, L3 → owner push + owner_alerts, (b) admin client (same RLS pattern as bookings/reminders), (c) `barber_notifications` per tier, (d) SMS parity with bulletproof-communications, (e) `CRON_SECRET` auth | Tier drift = owner paged at L1 before barber knows. Missing push parity = cross-channel gap. |
| `src/lib/db/notifications.ts` → `notifyBarberOfNewBooking` | (a) `barber_notifications` INSERT with `type='new_booking'`, (b) push via `BarberPush`, (c) bookings consumer must call this exactly once per booking create, (d) `related_id` FK on notification row | Double-call = duplicate push. Missing call = barber unaware of new booking. |
| `webhooks/resend/inbound/route.ts` (Booksy parsed → push) | (a) push to barber on `new appointment` type only (NOT reschedule/cancel), (b) admin client (signed webhook, no auth session), (c) ≤ 4096-byte payload including client name, (d) coupled to bulletproof-booksy-parser's event insert | Push on every parse event (including reschedule) = noise. Missing push = barber misses new Booksy appt. |
| `communications/send-blast/route.ts` (mass push broadcast) | (a) audience filter: only send to rows where `push_subscriptions` exists AND endpoint not 410-expired, (b) per-delivery 410 cleanup (blasts are prime time for dead endpoints), (c) payload truncation for blast body, (d) parity with SMS blast filter (opt-out excluded) | Stale blast to dead endpoints = slow cron. Opt-out not excluded = TCPA-adjacent via push. |
| `/public/sw.js` `push` event handler | (a) `self.registration.showNotification(title, options)` called with validated payload, (b) `notificationclick` handler routes every action key (`call`/`skip`/`complete`/`reschedule`/`view`) + default `data.url`, (c) reads fields the senders write (payload schema parity), (d) stays in sync when new action keys are introduced by senders | Missing action handler = click lands on `/`. Schema drift between sender + sw.js = silent data loss. |
| Subscription lifecycle (create → use → 410 → delete) | (a) POST `/api/push/subscribe` creates, (b) 410/404 → DELETE by endpoint in `sendPushNotification`, (c) stale cleanup not done by cron (natural 410-flow only), (d) UNIQUE index on `endpoint` prevents duplicates, (e) `pushsubscriptionchange` handler re-POSTs to subscribe on browser-triggered renewal | Broken any link = accumulation of dead rows OR missing renewal. |
| VAPID key management | (a) `NEXT_PUBLIC_VAPID_PUBLIC_KEY` matches `VAPID_PRIVATE_KEY` pair (mismatched = every send fails), (b) `VAPID_PRIVATE_KEY` absent from client bundle (grep for leaks), (c) `VAPID_SUBJECT` defaults to mailto: format, (d) key rotation procedure documented — rotation invalidates ALL subscriptions | Mismatched pair = silent universal failure. Key leak = anyone can send pushes as MT. |
| iOS PWA install gate (`NotificationPrompt.tsx`, `PushOptIn.tsx`) | (a) `navigator.standalone === true` OR non-iOS check before prompting, (b) fallback UI when install required ("add to home screen first"), (c) coupled to `/barber/setup` onboarding flow (bulletproof-onboarding) for barbers, (d) customer-side on queue tracker page | Prompting iOS Safari users without PWA install = ~30-day denial = silent coverage gap. |
| `barber_notifications` INSERT (any sender) | (a) `type` in enum (`new_booking`/`booking_cancelled`/`queue_assigned`/`owner_broadcast`/`new_review`), (b) `is_read` defaults false, (c) `related_id` set so bell UI deep-links, (d) push fires AFTER bell INSERT (bell is source of truth) | Bell row missing = no in-app indicator. Unknown type = renderer fallback. |
| Customer queue tracker push (`QueueTrackerContent.tsx`) | (a) subscribes with `queue_token` (anon path), (b) RLS policy allows anon INSERT with `user_id IS NULL AND queue_token IS NOT NULL`, (c) position-change trigger in `src/lib/queue/position-notifier.ts` fires push (currently Gap #4 — SMS-only), (d) Called-Next consumer path uses same queue_token | Gap #4 means customer queue push never fires. Even if subscription works, there's no sender. |
| Trigger parity matrix (C10) | Every row in the matrix must have BOTH SMS and push senders. When auditing any single row, check BOTH channels. Cross-skill: bulletproof-communications owns SMS side, this skill owns push side | Gap detection requires both halves of the matrix. |

**A PASS on the left side without evidence of auditing the right side = COUPLING VIOLATION.** Report it in the Gap Self-Report.

---

## Mode: audit

### Step 0 — Universal Audit Preamble (MANDATORY — run first, always)

Run the 5 discovery queries from `~/.claude/skills/_shared/audit-rigor.md` section "Universal Audit Preamble", filled in with the push domain values:

```sql
-- 1. Enumerate push domain tables
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN (
    'push_subscriptions','barber_notifications',
    'profiles','clients','queue_entries','barbers'
  )
ORDER BY table_name;
-- Expected: 6 rows. Missing = inventory drift; STOP and ask user.

-- 2. RLS policies on push-owned tables
SELECT tablename, policyname, cmd, roles, qual, with_check
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('push_subscriptions','barber_notifications')
ORDER BY tablename, policyname;
-- Expected: push_subscriptions → auth.uid() = user_id policy + anon queue_token policy +
--           owner-all + service-role-write. barber_notifications → barber-select-own + service-role-write.
-- RLS drift is the #1 failure mode for push (silent anon reads returning 0 rows under cron).

-- 3. Triggers on push-related tables (expected: 0 push-owned)
SELECT event_object_table, trigger_name, action_timing, event_manipulation
FROM information_schema.triggers
WHERE event_object_schema = 'public'
  AND event_object_table IN ('push_subscriptions','barber_notifications')
ORDER BY event_object_table, trigger_name;
-- Expected: 0 domain-owned triggers. Extras get flagged.

-- 4. RPC functions (0 push-owned)
SELECT routine_name
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name ILIKE ANY (ARRAY['%push%','%subscription%','%notify%','%notif%']);
-- Expected: 0 rows for push-owned. Any returned = surface drift.

-- 5. Migration history — push_subscriptions is NOT in migrations
SELECT name, executed_at FROM supabase_migrations.schema_migrations
WHERE name ILIKE '%push%' OR name ILIKE '%notification%' OR name ILIKE '%030%barber_notifications%';
-- Expected: at least 030_barber_notifications.sql. push_subscriptions is manual — flag if absent
-- from production DB (verified via preamble Query 1).
```

Attach all 5 result sets to the report under "Universal Preamble". Any drift = stop before domain checks.

### Code-level invariants

1. **VAPID keys never exposed client-side**
   - `NEXT_PUBLIC_VAPID_PUBLIC_KEY` is OK in browser (it's called "public" for a reason).
   - `VAPID_PRIVATE_KEY` must be server-only. Grep: `grep -rn "VAPID_PRIVATE_KEY" src/` — matches must be in server files only.

2. **Service worker file exists and handles push events**
   - File: `/public/sw.js`
   - Must listen on `'push'` event and call `self.registration.showNotification(title, options)`.
   - Must listen on `'notificationclick'` and route via `event.notification.data.url` or action-specific paths.
   - Per gap-scan: MT's `sw.js` routes actions `'call'`, `'skip'`, `'complete'` to `/barber/walk-ins` — verify these are still present.

3. **Service worker registered at app boot**
   - `src/lib/push/client.ts` → `registerServiceWorker()` registers `/sw.js`.
   - Grep: `grep -rn "navigator.serviceWorker.register" src/` — should be called once per session.

4. **410 Gone / 404 handling cleans dead endpoints**
   - `src/lib/push/server.ts` → `sendPushNotification()` catches 410/404 and returns `{ error: 'subscription_expired' }`.
   - Caller must DELETE from `push_subscriptions` where endpoint matches.
   - Without this: dead subscriptions accumulate indefinitely.

5. **Subscription upsert by endpoint**
   - `/src/app/api/push/subscribe/route.ts` POST must UPSERT (check existing by endpoint, UPDATE if found, INSERT if new).
   - Without this: duplicate subscriptions per endpoint.

6. **`user_id` OR `queue_token` set — not both null**
   - Each subscription must identify a recipient: authenticated user (barber/owner) OR anonymous queue customer.
   - Rows with both null are orphaned.

7. **Push trigger points call `sendPushNotification` or wrapper**
   - Main trigger paths (per gap-scan):
     - `src/app/api/queue/entry/[id]/route.ts` lines ~442-485 (Call Next → QueuePush + BarberPush)
     - `src/app/api/bookings/reminders/route.ts` (24h, 1h customer reminders)
     - `src/app/api/cron/service-reminder/route.ts` (overdue barber alerts, 3-tier escalation)
     - `src/app/api/communications/send-blast/route.ts` (owner broadcasts)
     - `src/lib/queue/position-notifier.ts` (position updates)
     - `src/lib/db/notifications.ts` → `notifyBarberOfNewBooking`

8. **Actions on notifications route correctly**
   - Barber's "Call" action → `/barber/walk-ins`
   - "Skip" action → `/barber/walk-ins` (same page, different state)
   - Customer's "Reschedule" → `/book`
   - Verified in `public/sw.js` `notificationclick` handler.

9. **Push-related SELECTs from cron / webhook / unauthenticated contexts use the admin client** [CRITICAL]
   - RLS on `push_subscriptions`: `auth.uid() = user_id` (authenticated, own rows only) OR `user_id IS NULL AND queue_token IS NOT NULL` (anon queue tracker only). Nothing else matches.
   - Cron routes authenticated via `CRON_SECRET` header have NO Supabase session → resolve to anon. The SSR user client (`createClient()` from `@/lib/supabase/server`) filtering by `user_id = <uuid>` returns **zero rows silently**.
   - The same applies to `clients` SELECT when it's a prerequisite to the push send (e.g., `clients.profile_id` lookup by phone in cron context).
   - Fix pattern: use `createAdminClient()` from `@/lib/supabase/admin` for the entire push-send chain (prerequisite lookups + push_subscriptions SELECT + 410/404 DELETE) in any cron / webhook / unauthenticated-but-authorized context.
   - **Grep signal:** any file that imports from `'@/lib/supabase/server'` AND queries `push_subscriptions` AND is gated by `CRON_SECRET` / webhook signature (not `supabase.auth.getUser()`). Verify it uses admin client for the push path.
   - **Failure mode is silent** — no error, just `push_sent: 0` forever. Will not surface in Sentry. Only visible via DB-plane eligibility queries (see Query 15).
   - **Canonical fix diff:** see `references/fix-patterns.md` → Pattern 1.

10. **Trigger/channel parity** — every user-facing SMS has a push counterpart (and vice versa) unless explicitly opted out [HIGH]
    - SMS and push are redundancy channels. If a state change fires SMS but not push, mobile users with the PWA installed get slower notice than phone-only users. Worse, if push fires but SMS doesn't, users without the PWA get nothing.
    - **Known trigger coverage matrix (as of 2026-04-20):**

| Trigger | SMS | Push | Status |
|---|---|---|---|
| Queue: Call Next → barber | ✓ | ✓ | OK |
| Queue: Call Next → customer | ✓ | ✓ | OK |
| Queue: Position change → customer | ✓ | ✗ | **GAP — push missing** |
| Queue: You're next (almost up) | ✓ | ✗ (folded into position) | **GAP** |
| Queue: Leave-now | ✓ | ✗ | **GAP** |
| Queue: No-show → barber | ✓ | ✗ | **GAP** |
| Booking: Created → barber | ✓ | ✓ (via `notifyBarberOfNewBooking`) | OK |
| Booking: Created → customer | ✓ | ✗ | **GAP** |
| Booking: Cancelled → barber | partial | ✗ | **GAP** |
| Booking: Rescheduled → barber | partial | ✗ | **GAP** |
| Booking: 24h reminder → customer | ✓ | ✓ (but see C9 bug) | Latent |
| Booking: 1h reminder → customer | ✓ | ✓ (but see C9 bug) | Latent |
| Service: Overdue → barber (L1/L2/L3) | ✓ | ✓ | OK |
| Service: Stuck 60min → owner | ✓ | ✓ | OK |
| Mass blast → all users | ✓ | ✓ | OK |

    - **Detect:** grep for each row — `grep -rn "SMS.send\|Push.send\|BookingPush\|QueuePush\|BarberPush" src/app/api`. Compare against SMS calls in the same handler. Rows marked GAP are known today; the skill's job is to keep this table current, not just use it stale.
    - **Fix pattern:** see `references/fix-patterns.md` → Patterns 2–5 (booking confirmation push, queue position push, cancel/reschedule/no-show push).

11. **iOS Safari PWA install gate before enabling push** [HIGH]
    - iOS 16.4+ supports web push **only** for apps added to Home Screen. A user who denies permission on iOS Safari without the PWA installed cannot be re-prompted for ~30 days.
    - `NotificationPrompt.tsx` and `PushOptIn.tsx` must check `navigator.standalone === true` (PWA installed) OR not-iOS before rendering the enable button on iOS Safari.
    - Without the gate: iOS users will deny → silent coverage gap.
    - **Detect:** `grep -rn "standalone\|homeScreen\|/iPhone\|iPad/\|webkit" src/components/queue src/components/profile src/lib/push --include="*.ts*"`. Expected: PWA-install detection wrapping the prompt on iOS.
    - **Fix pattern:** see `references/fix-patterns.md` → Pattern 6.
    - **Cross-reference:** `bulletproof-onboarding` skill covers the barber side of this (install as part of `/barber/setup`). Customer side belongs here.

12. **Race-guard before firing a push send** [MEDIUM]
    - Two concurrent "Call Next" PATCHes on the same queue entry both pass the initial validation, one wins the atomic UPDATE (409 for the other), but both can still fire the push if the push send runs BEFORE the UPDATE. Result: duplicate push to the barber.
    - **Fix:** read the row's current status immediately before push send; skip if the status no longer matches the push's premise (e.g., entry is no longer `called`).
    - **Detect:** `SELECT related_id, COUNT(*) FROM barber_notifications WHERE type = 'queue_assigned' AND created_at > now() - interval '1 day' GROUP BY related_id HAVING COUNT(*) > 1;` — if > 0, races are happening.
    - **Fix pattern:** see `references/fix-patterns.md` → Pattern 7.

13. **Payload schema consistency between senders and service worker** [MEDIUM]
    - `/public/sw.js` reads specific fields from `event.notification.data`: `data.url`, `data.type`, action-specific routing (`'call'`, `'skip'`, `'complete'`, `'reschedule'`, `'view'`).
    - Every sender MUST include `{ title, body }` (required for display) AND the `data.url` field (or an action whose handler routes correctly). Missing `title` → notification never shows. Missing `data.url` + no action handler → click lands on `/` by default.
    - Payload size hard limit: **4096 bytes**. Any sender that includes user-generated content (booking notes, blast message body) MUST truncate before building the payload.
    - **Detect:** read every `{ title:, body:, ...}` literal in the push senders listed in C7. Verify `title` is always set and `data.url` is present OR an action handler covers all actions.
    - **Fix pattern:** see `references/fix-patterns.md` → Pattern 8 (truncation + schema validator).

### Data-level invariants

Run queries in `references/audit-queries.sql`. SELECT-only.

### Output template — MANDATORY Coverage Report

Every push notifications audit MUST produce this full block. A report without the Coverage Report section is INCOMPLETE and will be rejected.

```markdown
## Push Notifications Audit Report — [YYYY-MM-DD]

### Universal Preamble
- Tables enumerated: X/6 PASS | FAIL (list missing)
- RLS policies found: X (expected ≥2 per table across 2 tables)
- Triggers found: X (expected 0 push-owned)
- RPCs found: X (expected 0)
- Migrations confirmed: 030_barber_notifications + push_subscriptions manual table

### Trigger parity (invariant C10)
Reproduce the full matrix from C10 with current state. Flag any row where SMS fires but push does not (or vice versa).

### Latent vs live classification
Every code-plane failure MUST be classified:
- **Live (blocking)** — real subscribers exist and are being dropped RIGHT NOW. Fix with urgency.
- **Latent (prospective)** — code is wrong but no subscriber currently exercises the path.
Use Query 15 (eligible subscribers) to tell them apart.

### Device-level limit
"This audit verifies DATA + CODE + RLS + integrations. It does NOT confirm individual devices actually receive notifications. Verify by having one barber test 'Call Next' on their phone with the app closed."

---

## Coverage Report (MANDATORY)

### Pillar 1 — Codebase (29 files from SURFACE_INVENTORY.md sections 1-5) — PROOF-OF-READ REQUIRED
| # | File | Verdict | Evidence (file:line — what was checked) |
|---|---|---|---|
| 1 | src/app/api/push/subscribe/route.ts | PASS/FAIL/NOT-RUN | e.g. "subscribe/route.ts:42 — upsert by endpoint with onConflict" |
| 2 | src/app/api/queue/route.ts (push trigger) | | |
| ... | [all 29 from §§1-5] | | |
| 21 | public/sw.js (SW handlers) | | e.g. "sw.js:87 — notificationclick handles 'call'/'skip'/'complete'" |

Files audited with proof-of-read: N / 29 (target: 29/29). Any PASS without a file:line citation = treated as NOT-RUN.

### Pillar 2 — Database (6 tables from SURFACE_INVENTORY.md section 6)
| Table | Row count | Provider dist | NULL violations | Verdict |
|---|---|---|---|---|
| push_subscriptions | | FCM/APNs/Firefox/WNS (Query 13) | orphan rows (Query 1) | |
| barber_notifications | | | | |
| profiles (user_id ref check) | — | — | — | |
| clients (profile_id bridge) | — | — | — | |
| queue_entries (tracking_token) | — | — | — | |
| barbers (profile_id bridge) | — | — | — | |

Tables audited: N / 6

### Pillar 3 — Queries (18 queries from references/audit-queries.sql)
| # | Query | Verdict | Rows |
|---|---|---|---|
| 0 | schema_verification | | |
| 1 | orphaned_subscriptions | | |
| 2 | endpoint_uniqueness | | |
| ... | [all 18] | | |
| 15 | eligible_subscribers (live/latent classifier) | | |
| 16 | race_dup_barber_notifications | | |
| 17 | active_barbers_no_subs | | |
| 18 | ios_vs_fcm_distribution | | |

Queries run: N / 18. Skipped: [empty — or list with reason].

### Pillar 4 — RLS (2 push tables)
| Table | Policies found | Expected | Verdict |
|---|---|---|---|
| push_subscriptions | | 4 (auth-own, anon-queue-token, owner-all, service-role) | |
| barber_notifications | | 2 (barber-own, service-role) | |

**RLS-specific check:** verify cron/webhook callers (C9 invariant) use admin client, not SSR user client. Any route that queries push_subscriptions with `CRON_SECRET` gating but imports `@/lib/supabase/server` = FAIL.

RLS tables audited: N / 2

### Pillar 5 — Integrations (SURFACE_INVENTORY.md sections 11, 12)
| Integration | Verdict | Note |
|---|---|---|
| web-push npm package (VAPID signing) | | |
| FCM (Chrome/Android) endpoints | | |
| APNs (Safari/iOS PWA) endpoints | | |
| 410/404 dead subscription cleanup | | |
| Service worker /public/sw.js registration | | |
| Cron: bookings/reminders (hourly) | | |
| Cron: cron/service-reminder | | |
| VAPID key env vars (public vs private separation) | | |
| Trigger parity matrix (C10) | | |

Integrations audited: N / 9

### Coupling Checks (from Cross-Surface Coupling Rules table)
| Coupling | Both sides audited? | Note |
|---|---|---|
| push/subscribe → {UPSERT by endpoint, user_id XOR queue_token, RLS anon path, pushsubscriptionchange, VAPID private not in client} | YES/NO | |
| sendPushNotification → {410/404 DELETE, ≤4096 payload, title+body present, data.url or action, VAPID from env} | YES/NO | |
| Queue Call-Next → {barber sub SELECT, customer sub by queue_token, race-guard status re-read, barber_notifications INSERT, SMS parity} | YES/NO | |
| bookings/reminders cron → {admin client (Gap #1), reminder_sent after send, clients.profile_id bridge, 410 cleanup, CRON_SECRET} | YES/NO | |
| cron/service-reminder → {L1/L2/L3 escalation, admin client, barber_notifications per tier, SMS parity, CRON_SECRET} | YES/NO | |
| notifyBarberOfNewBooking → {barber_notifications INSERT, BarberPush call, exactly-once per booking, related_id FK} | YES/NO | |
| Booksy inbound → push → {new-appt only (not reschedule/cancel), admin client, ≤4096 payload, coupled to bulletproof-booksy-parser} | YES/NO | |
| send-blast push → {subs filter, per-delivery 410 cleanup, payload truncation, opt-out parity with SMS} | YES/NO | |
| sw.js push handler → {showNotification call, notificationclick routes all actions, schema parity with senders} | YES/NO | |
| Subscription lifecycle → {subscribe creates, 410 deletes, UNIQUE endpoint index, pushsubscriptionchange renewal} | YES/NO | |
| VAPID management → {public/private pair match, no private leak, VAPID_SUBJECT mailto:, rotation procedure} | YES/NO | |
| iOS PWA gate → {navigator.standalone check, fallback UI, coupled to /barber/setup onboarding, queue-tracker customer gate} | YES/NO | |
| barber_notifications INSERT → {type enum, is_read default, related_id, push AFTER bell} | YES/NO | |
| Customer queue tracker push → {queue_token sub, anon RLS policy, position-notifier.ts sender (Gap #4), called-next consumer} | YES/NO | |
| Trigger parity matrix (C10) → {every row has both SMS + push; gaps from matrix enumerated} | YES/NO | |

Coupling violations: N  **(must be 0 — any NO row is a violation)**

---

## Gap Self-Report (MANDATORY)

| # | Gap | Why it matters | Severity |
|---|---|---|---|
| G1 | [e.g. Did not open src/lib/queue/position-notifier.ts] | Gap #4 lives here — customer queue push never fires | Unknown |

Surfaces in SURFACE_INVENTORY.md NOT audited this run: <comma-separated item numbers>.
Questions requiring external verification (real device delivery test, FCM/APNs console, iOS Safari behavior): <list>.

If zero gaps: write "No gaps identified. All 52 surfaces audited with proof-of-read + all coupling checks passed. (Note: device-level delivery remains unverifiable by this skill — see two-plane rule.)"

---

## Totals

- Surfaces audited with proof-of-read: X / 52 (XX%)
- FAILs: N
- NOT-RUNs: N
- Coupling violations: N (must be 0)

**If NOT-RUNs > 0 OR coupling violations > 0, the report header MUST say "PARTIAL PUSH NOTIFICATIONS AUDIT — N surfaces unaudited, M coupling violations" instead of "Push Notifications Audit Report".**
```

Stop only after every row above is filled. "Stop on first fail" is NOT the protocol — complete the full coverage sweep, then report.

---

## Known feature gaps (as of 2026-04-20, re-verify every audit)

These are gaps the skill has already discovered and cataloged. When doing an audit, check whether each is still present. If a gap is closed, remove it from this list in a skill-update commit.

| # | Gap | Severity | Fix pattern |
|---|---|---|---|
| 1 | `bookings/reminders/route.ts:51-62` — cron uses SSR user client to SELECT `push_subscriptions` → silent 0-row under anon RLS | Latent (no client subscribers) | Pattern 1 |
| 2 | No push to customer at booking creation (SMS only). `/src/app/api/bookings/quick/route.ts` | Latent | Pattern 2 |
| 3 | No push to barber on booking cancel/reschedule. Wherever DELETE/PATCH on bookings lives | Latent | Pattern 3 |
| 4 | No push to customer on queue position change. `/src/lib/queue/position-notifier.ts` sends SMS only | Live if customer subs exist | Pattern 4 |
| 5 | No push to barber on customer no-show. `/src/app/api/queue/entry/[id]/route.ts` | Latent | Pattern 5 |
| 6 | No iOS PWA-install gate before permission prompt → permission denials on Safari | Live | Pattern 6 |
| 7 | No race-guard before firing barber push on Call Next → duplicate pushes on concurrent PATCH | Live (rare) | Pattern 7 |
| 8 | Active-barber push coverage is ~17% (4 of ~24 as of 2026-04-20) → many barbers silently missing walk-in alerts | Live, onboarding issue | Defer to `bulletproof-onboarding` |

---

## Mode: diagnose

Symptoms this skill handles:

1. **"Barber didn't get a walk-in alert on their phone"**
   - Walk the Call Next flow (Flow A in `bulletproof-queue`).
   - At step 4 (notification chain), this skill's job:
     - Does the barber have a `push_subscriptions` row with non-NULL `user_id = barber's profile_id`?
     - Is the endpoint still valid? (check recent delivery success in logs if tracked)
     - Is the service worker registered? (ask user to open DevTools → Application → Service Workers on their device)
     - Has the endpoint been cleaned up by a 410 handler? (query recent deletes)

2. **"Customer queue tracker doesn't buzz when they're called"**
   - Does the customer have a subscription with `queue_token = queue_entries.tracking_token`?
   - Did the Call Next handler query by `queue_token` and send?

3. **"Every barber's notifications stopped working overnight"**
   - VAPID key rotation? Check when `VAPID_PRIVATE_KEY` env var last changed.
   - After rotation, all subscriptions need to be re-created (old signatures invalid).
   - Or: `web-push` library upgraded with breaking changes.

4. **"Subscription count is way lower than expected"**
   - 410/404 cleanup might be aggressive OR endpoints expire naturally (iOS refreshes periodically).
   - Check growth pattern: new subs/day vs. deletes/day.

5. **"Click on notification opens wrong page"**
   - Bug in `/public/sw.js` `notificationclick` handler OR in the push payload's `data.url`.
   - Trace: open DevTools on device → check what payload the push delivered.

6. **"Subscription rows exist but no user_id / no queue_token"**
   - Orphaned rows from a partial subscription flow. Harmless but add up over time.

7. **"Push sends report `push_sent: 0` every tick even though subscriptions exist"**
   - Classic silent-RLS failure. The SELECT that feeds the sender is running under anon (cron / webhook auth with no Supabase session) and RLS hides every row.
   - Check: does the sender import from `@/lib/supabase/server` (user client) or `@/lib/supabase/admin` (admin client)?
   - In cron / webhook / CRON_SECRET / HMAC contexts → MUST be admin client. See invariant #9.
   - Distinguish from the "no subscribers exist" case with Query 15 (eligible subscribers for that audience) before investigating code.

### Diagnose protocol

1. Ask user for the specific symptom + affected barber/customer identifier.
2. Query `push_subscriptions` for that user.
3. If subscription exists, attempt to correlate with recent `queue_entries` or `barber_notifications` events.
4. Three-file rule. Two-strike rule.

---

## Mode: scale-check (40 barbers, 4 locations, growing)

1. **Subscription coverage per active barber**
```sql
SELECT b.id, b.slug, p.first_name, p.last_name,
       COUNT(ps.id) AS subscription_count
FROM barbers b
JOIN profiles p ON p.id = b.profile_id
LEFT JOIN push_subscriptions ps ON ps.user_id = b.profile_id
WHERE b.is_active = true
GROUP BY b.id, b.slug, p.first_name, p.last_name
ORDER BY subscription_count ASC, b.slug;
```

Target: every active barber has ≥1 subscription (ideally 1-2 devices: phone + tablet at station).

Barbers with 0 → they won't get "Call Next" pushes. Possible causes:
- Never enabled notifications (onboarding gap)
- Disabled in browser settings
- Endpoint expired and never re-subscribed

2. **Stale subscription age**
```sql
SELECT
  COUNT(*) FILTER (WHERE updated_at > now() - interval '7 days')  AS active_7d,
  COUNT(*) FILTER (WHERE updated_at <= now() - interval '30 days') AS stale_30d,
  COUNT(*) FILTER (WHERE updated_at <= now() - interval '90 days') AS very_stale_90d,
  COUNT(*) AS total
FROM push_subscriptions;
```

iOS Safari expires subscriptions periodically. High stale count = need proactive refresh prompt.

3. **Subscription growth rate**
```sql
SELECT DATE_TRUNC('week', created_at) AS week, COUNT(*) AS new_subs
FROM push_subscriptions
WHERE created_at > now() - interval '8 weeks'
GROUP BY week
ORDER BY week DESC;
```

Growth should correlate with new barber onboarding + customer traffic.

4. **Cleanup activity (410 handlers firing)**
   - Not directly queryable without a separate log table. Flag: if subscriptions never get cleaned up, they accumulate forever (not a scale problem at 160, but at 10k it is).

5. **iOS Safari limits**
   - iOS 16.4+ supports web push, but ONLY for apps added to Home Screen (PWA installed).
   - Barbers on iOS must: open MT in Safari → Share → Add to Home Screen → open from Home Screen → enable notifications.
   - Flag this onboarding friction in the scale report.

6. **VAPID key rotation readiness**
   - If `VAPID_PRIVATE_KEY` is rotated, ALL existing subscriptions become invalid.
   - Need a coordinated migration: generate new pair → deploy → users re-subscribe.
   - Recommend having a documented procedure before operating at scale.

---

## Mode: fix

The only mode that writes code. Closes the loop between "audit found X" and "X is fixed + verified + ready to ship." Does NOT commit, does NOT push, does NOT touch production DB.

### Activation is EXPLICIT-ONLY
Fix mode fires ONLY when the user types one of:
- `apply pattern N` — N ∈ 1–8 from `references/fix-patterns.md`
- `fix gap N` — N ∈ "Known feature gaps" table (invariant #10)
- `fix the [rls bug | position push | booking confirmation push | no-show push | cancel push | reschedule push | ios gate | race guard | payload schema]` — natural-language form; the skill maps to a pattern and CONFIRMS with the user before doing anything
- `enter fix mode` followed by a scope

Any other phrasing → skill runs audit/diagnose instead. An audit finding NEVER auto-triggers a fix.

### Workflow (strict — every step, no shortcuts)

**Step 1 — Scope declaration.** Restate in 1–2 sentences:
- Which pattern (number + name)
- Which file(s) will change
- Which audience (barber / customer / owner)
- Any mirror page impact

**Step 2 — Preflight verification.** Read the target file. Confirm the "before" code block from `fix-patterns.md → Pattern N → preflight check` still matches current code. Imports, function signatures, surrounding lines. **If drift is detected → STOP.** Report what changed, do NOT apply a stale pattern.

**Step 3 — Live vs latent classification.** Run Query 15. Report whether the gap has real subscribers today:
- `eligible > 0` → **LIVE** (urgent)
- `eligible = 0` → **LATENT** (prospective fix — user may defer)

**Step 4 — Diff proposal.** Show the exact `old_string` / `new_string` the skill will pass to `Edit`. Wait for the user to type `yes`, `apply`, `proceed`, or equivalent. **No implicit approval.** No "I'll just go ahead."

**Step 5 — Apply.** Single `Edit` call. **ONE pattern per fix-mode invocation.** Never bundled.

**Step 6 — Post-fix verification (mandatory).**
- `npx tsc --noEmit` → no new TypeScript errors in the changed file
- Re-run the pattern's grep and/or SQL check from `fix-patterns.md → Pattern N → post-fix verification` → must now pass
- For LIVE fixes: re-run Query 15 / relevant data-plane query → eligible subscribers are now reachable
- For Pattern 6 (iOS gate) and other UI patterns: explicitly tell the user "you must test this on iOS Safari before shipping — I can't verify UI"

**Step 7 — Mirror check.** If the fix touches dashboard code (Patterns 4, 5, or any future barber-dashboard pattern), invoke `mirror-check` skill to enforce the Cross-Dashboard Code Mirroring HARD RULE. Report result before proceeding.

**Step 8 — Handoff to `bulletproof-ship`.** The skill DOES NOT commit, stage, or push. It formulates:
- Suggested branch name: `fix/push-<pattern-slug>` (e.g. `fix/push-bookings-reminders-admin-client`)
- Suggested commit message in MT's conventional format (e.g. `fix(push): use admin client for booking reminder subscribers`)

Then it explicitly tells the user to invoke `bulletproof-ship`. Bulletproof-ship enforces branch-workflow, pre-commit hooks, and push gates.

### Integration with other skills

| Skill | Role |
|---|---|
| `bulletproof-ship` | Final step. Commit + push + deploy safety. Mandatory. |
| `mirror-check` | Cross-dashboard enforcement for Patterns 4, 5, and any dashboard-touching fix. |
| `safe-query` | If a future pattern requires DB writes (none today do), route through safe-query. |
| `bulletproof-onboarding` | Gap #8 (low barber push coverage) is an onboarding issue, not a code bug. Fix mode refuses and redirects. |

### Example turn

```
User: fix pattern 1

Skill:
  [Scope] Pattern 1 — Admin client for push SELECT/DELETE in bookings reminder cron.
          File: src/app/api/bookings/reminders/route.ts.
          Audience: customer. No mirror page.

  [Preflight] Reading target file... lines 49-78 match pattern "before" block.
              No drift detected.

  [Classification] Query 15 → clients_with_profile_subs = 0 → LATENT.
                   (No real subscribers today. Fix is prospective.)

  [Diff] Proposing Edit:
    old_string:
      const { data: client } = await supabase
        .from('clients')
        ...
    new_string:
      const admin = createAdminClient()
      const { data: client } = await admin
        .from('clients')
        ...

  Proceed? (yes / no)

User: yes

Skill:
  [Apply] Edit succeeded.
  [Verify] npx tsc --noEmit → 0 new errors.
           grep "supabase.from('push_subscriptions')" bookings/reminders/route.ts → 0 matches.
           grep "admin.from('push_subscriptions')" bookings/reminders/route.ts → 2 matches.
           ✓ Pattern applied correctly.
  [Mirror] N/A — cron route, no dashboard.
  [Handoff] Ready for bulletproof-ship.
            Suggested branch: fix/push-bookings-reminders-admin-client
            Suggested commit: "fix(push): use admin client for booking reminder subscribers"

            Invoke /bulletproof-ship (or tell me to invoke it) to commit + push.
```

---

## HARD RULES

### Always (all modes)
- NEVER write to production DB.
- NEVER modify VAPID keys in production without a subscription-refresh plan.
- NEVER log raw `p256dh` or `auth` values (they're cryptographic keys).
- NEVER commit VAPID_PRIVATE_KEY to git.
- Push delivery cannot be fully verified without real devices.
- ALWAYS use `mcp__supabase-mt__`.
- Branch workflow. Stay in scope.

### Fix-mode specific (only active in Mode: fix)
- **Explicit activation only.** Never enters fix mode from an audit finding. Must see `apply pattern N`, `fix gap N`, `fix the X`, or `enter fix mode`.
- **One pattern per invocation.** Never bundles multiple patterns in one Edit, one commit, or one PR.
- **File scope is bounded.** Only touches files in: `src/app/api/**`, `src/lib/push/**`, `src/lib/db/notifications.ts`, `src/lib/queue/position-notifier.ts`, `src/components/queue/**`, `src/components/profile/**`, `src/components/barber/**`, `/public/sw.js`. Anything outside = STOP and re-scope.
- **Preflight is mandatory.** Never applies a pattern whose preflight check fails (code drift). Report drift, do not apply a stale pattern.
- **User confirmation is mandatory.** Must show the exact `old_string` / `new_string` and wait for `yes` / `apply` / `proceed`. No implicit approval.
- **Post-fix verification is mandatory.** Never skips `npx tsc --noEmit` and the pattern-specific grep/SQL check.
- **Mirror check is mandatory for dashboard fixes.** Patterns 4, 5, and any future barber-dashboard pattern MUST invoke `mirror-check` before handoff.
- **Never auto-ships.** Hands off to `bulletproof-ship` with a suggested branch + commit. User must invoke `bulletproof-ship` explicitly.
- **Never commits to main.** Per `.claude/rules/branch-workflow.md`, all fixes go through a feature branch.
- **Never skips hooks or force-pushes.** `bulletproof-ship` enforces this; fix mode does not bypass.
- **Onboarding gaps redirect.** If a "fix" request is actually an onboarding gap (e.g. gap #8 — barbers without subs), refuse and point to `bulletproof-onboarding`.
