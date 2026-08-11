# Push Notifications Invariants

SELECT-only. **Verify schema first** via preflight.

Expected schema for `push_subscriptions`: `id`, `endpoint`, `p256dh`, `auth`, `user_id`, `queue_token`, `created_at`, `updated_at`.

---

## Data-level

### 1. Every subscription has a recipient [CRITICAL]
```sql
SELECT id, endpoint, created_at
FROM push_subscriptions
WHERE user_id IS NULL AND queue_token IS NULL;
-- Expected: 0 rows (orphaned subscriptions can never receive)
```

### 2. Endpoint uniqueness [CRITICAL]
```sql
SELECT endpoint, COUNT(*) AS n, array_agg(id) AS subscription_ids
FROM push_subscriptions
GROUP BY endpoint
HAVING COUNT(*) > 1;
-- Expected: 0 rows (prevents duplicate pushes)
```

### 3. user_id references valid profile [HIGH]
```sql
SELECT ps.id, ps.user_id
FROM push_subscriptions ps
LEFT JOIN profiles p ON p.id = ps.user_id
WHERE ps.user_id IS NOT NULL
  AND p.id IS NULL;
-- Expected: 0 rows
```

### 4. queue_token references a real queue entry (spot-check) [MEDIUM]
Queue entries expire; their tokens don't. A subscription's `queue_token` might reference a completed entry — that's fine. But it should have AT SOME POINT referenced a real entry.
```sql
SELECT ps.id, ps.queue_token, ps.created_at
FROM push_subscriptions ps
LEFT JOIN queue_entries qe ON qe.tracking_token = ps.queue_token
WHERE ps.queue_token IS NOT NULL
  AND qe.id IS NULL
  AND ps.created_at > now() - interval '7 days';
-- Expected: few/none for recent ones (old stale ok)
```

### 5. Cryptographic keys non-empty [HIGH]
```sql
SELECT id, endpoint
FROM push_subscriptions
WHERE p256dh IS NULL OR p256dh = ''
   OR auth IS NULL OR auth = '';
-- Expected: 0 rows (without keys, send will fail)
```

### 6. Endpoint URL format [MEDIUM]
```sql
SELECT id, substring(endpoint, 1, 60) AS endpoint_prefix
FROM push_subscriptions
WHERE endpoint NOT LIKE 'https://%'
LIMIT 20;
-- Expected: 0 rows (push endpoints are always HTTPS)
```

### 7. Barber subscription coverage [HIGH]
Every active barber should have ≥1 subscription (ideally 1-2: phone + station tablet).
```sql
SELECT b.id, b.slug, p.first_name, p.last_name,
       COUNT(ps.id) AS subscription_count
FROM barbers b
JOIN profiles p ON p.id = b.profile_id
LEFT JOIN push_subscriptions ps ON ps.user_id = b.profile_id
WHERE b.is_active = true
GROUP BY b.id, b.slug, p.first_name, p.last_name
HAVING COUNT(ps.id) = 0
ORDER BY b.slug;
-- Expected: 0 rows (every active barber subscribed on at least one device)
```

### 8. Owner subscription coverage [MEDIUM]
```sql
SELECT p.id, p.email, COUNT(ps.id) AS subscription_count
FROM profiles p
LEFT JOIN push_subscriptions ps ON ps.user_id = p.id
WHERE p.role = 'owner'
GROUP BY p.id, p.email
HAVING COUNT(ps.id) = 0;
-- Expected: 0 rows (owners need broadcast / overdue alerts)
```

### 9. Recent subscription activity [MEDIUM]
Endpoints that haven't been updated in 90+ days are candidates for cleanup.
```sql
SELECT COUNT(*) AS stale_90d
FROM push_subscriptions
WHERE updated_at < now() - interval '90 days';
-- Expected: informational. High number = aggressive cleanup needed.
```

### 10. Subscription age distribution [LOW]
```sql
SELECT
  COUNT(*) FILTER (WHERE created_at > now() - interval '7 days')   AS created_7d,
  COUNT(*) FILTER (WHERE created_at > now() - interval '30 days')  AS created_30d,
  COUNT(*) FILTER (WHERE updated_at > now() - interval '7 days')   AS updated_7d,
  COUNT(*) AS total
FROM push_subscriptions;
```

---

## Code-level

### C1. VAPID_PRIVATE_KEY is server-only [CRITICAL]
```bash
grep -rn "VAPID_PRIVATE_KEY" src/
```
Expected: matches only in server files (API routes, /lib/push/server.ts). Zero matches in `'use client'` files.

### C2. NEXT_PUBLIC_VAPID_PUBLIC_KEY accessible client-side [HIGH]
```bash
grep -rn "NEXT_PUBLIC_VAPID_PUBLIC_KEY" src/
```
Expected: accessed in `src/lib/push/client.ts` and/or `src/lib/push/server.ts` `getVapidPublicKey()`.

### C3. Service worker exists and registers at boot [CRITICAL]
- File: `/public/sw.js` (must exist).
- File: `src/lib/push/client.ts` → `registerServiceWorker()` must call `navigator.serviceWorker.register('/sw.js')`.
- Grep: `grep -rn "navigator.serviceWorker.register" src/`

### C4. Service worker handles 'push' event [CRITICAL]
- Read `/public/sw.js`.
- Must have `self.addEventListener('push', ...)` that calls `self.registration.showNotification(title, options)`.

### C5. Service worker handles 'notificationclick' [HIGH]
- Same file.
- Must have `self.addEventListener('notificationclick', ...)`.
- Routing: barber actions ('call', 'skip', 'complete') → `/barber/walk-ins`; customer actions → `data.trackingUrl || '/queue'`.

### C6. `sendPushNotification` handles 410/404 [CRITICAL]
- File: `src/lib/push/server.ts`.
- Must catch HTTP 410 and 404; return expired-marker; do NOT throw.

### C7. Subscription cleanup on 410 [CRITICAL]
- Callers of `sendPushToMany` collect expired endpoints and DELETE them.
- Example: `src/app/api/communications/send-blast/route.ts` (per gap-scan).
- Grep: `grep -rn "subscription_expired\|DELETE.*push_subscriptions" src/`

### C8. POST /api/push/subscribe upserts, doesn't insert blindly [HIGH]
- File: `src/app/api/push/subscribe/route.ts`.
- Must check for existing endpoint and UPDATE, else INSERT.

### C9. POST handler requires either user_id context or queue_token [HIGH]
- Same file. Reject (400) if neither is available.

### C10. Push send is fire-and-forget (non-blocking) [MEDIUM]
- Push sends should not block API responses (Twilio/Stripe flows can't wait on push).
- Pattern: `sendPushToMany(...).catch(() => {})` after the primary response is formed.

### C11. Payload structure matches SW handler [HIGH]
- Senders provide `{ title, body, icon?, badge?, tag?, data?, actions? }`.
- Service worker reads these. Missing `title` = notification won't display.

### C12. Trigger paths aligned with Flow A (Call Next) [HIGH]
- `src/app/api/queue/entry/[id]/route.ts` lines ~442-485 must fire `BarberPush.sendQueueAssigned` to the assigned barber AND `QueuePush.sendCalledNotification` to the customer on status transition to `'called'`.

### C13. (Renumbered — see C9 in SKILL.md) Push SELECTs from cron / webhook / anon contexts use admin client [CRITICAL]
RLS policies on `push_subscriptions`:
```
"Users manage own"          → ALL,    auth.uid() = user_id
"Anonymous queue sub INSERT"→ INSERT, user_id IS NULL AND queue_token IS NOT NULL
"Anonymous queue sub SELECT"→ SELECT, user_id IS NULL AND queue_token IS NOT NULL
```
Cron routes authenticated via `CRON_SECRET`, and webhook routes authenticated via signature verification, have NO Supabase session → Supabase client resolves to **anon role**. A user-client SELECT on `push_subscriptions` filtered by `user_id = <uuid>` matches **no** anon policy and silently returns `[]`. No error. No log. Just `push_sent: 0` forever.

The same trap applies to any prerequisite lookup in the same chain (e.g., `clients.profile_id` by phone) that sits behind RLS.

**Grep detection:**
```bash
# Files that touch push_subscriptions AND import the SSR user client
grep -l "push_subscriptions" src/app/api/**/*.ts | \
  xargs grep -l "'@/lib/supabase/server'" 2>/dev/null

# For each match, check if the route is gated by CRON_SECRET or webhook signature
# (not supabase.auth.getUser()). If yes → likely broken.
grep -l "CRON_SECRET\|STRIPE_WEBHOOK_SECRET\|RESEND_WEBHOOK_SECRET" <match>
```

Expected: ZERO files that combine `push_subscriptions` + SSR user client + cron/webhook auth. Those MUST use `createAdminClient()` from `@/lib/supabase/admin` instead.

**Known safe patterns:**
- `src/app/api/communications/send-blast/route.ts` — owner-auth'd (not anon), but uses admin client anyway. OK.
- `src/lib/db/notifications.ts` — called from within authenticated API routes where the admin client is already in scope. OK.
- `src/app/api/cron/service-reminder/route.ts` — cron-auth'd, uses admin client. OK.
- `src/app/api/queue/entry/[id]/route.ts` — mixed auth; uses admin client for the push paths. OK.
- `src/app/api/bookings/reminders/route.ts` — cron-auth'd, customer-push path. Must use admin client throughout the helper.

**Corollary — latent vs live:**
A fail here can be latent (code is wrong but there are no eligible subscribers yet) or live (subscribers exist and are dropped every tick). Always pair this check with Query 15 (eligible subscribers for that audience) to classify severity.

**Fix:** see `fix-patterns.md` → Pattern 1.

### C14. Trigger/channel parity — SMS and push fire for the same lifecycle event [HIGH]

For each user-facing state change (queue join, call-next, position change, booking create/cancel/reschedule, reminder, no-show, service overdue), both SMS and push should fire unless the recipient has explicitly opted out.

**Current known-gap table** — see SKILL.md invariant #10 (C10). Keep that table synchronized with this file. When running an audit, reproduce the full table with current state.

**Detect:**
```bash
# For each trigger, check both channels fire in the same handler
grep -rn "QueueSMS\|BookingSMS" src/app/api src/lib | awk -F: '{print $1}' | sort -u > /tmp/sms_senders.txt
grep -rn "QueuePush\|BookingPush\|BarberPush\|sendPushNotification" src/app/api src/lib | awk -F: '{print $1}' | sort -u > /tmp/push_senders.txt
diff /tmp/sms_senders.txt /tmp/push_senders.txt
```
Files in `sms_senders.txt` but not `push_senders.txt` = triggers that fire SMS without push.

**Fix:** see `fix-patterns.md` → Patterns 2 (booking confirmation), 3 (booking cancel/reschedule), 4 (queue position), 5 (no-show).

### C15. iOS Safari PWA install gate [HIGH]

Any component that prompts a user to enable push on iOS Safari MUST first verify the PWA is installed (`navigator.standalone === true`). iOS 16.4+ denies the permission prompt entirely unless the app is launched from Home Screen.

**Detect:**
```bash
# Expected: PWA/standalone detection in these files
grep -rn "standalone\|PushManager\|navigator.serviceWorker" src/components/queue src/components/profile src/lib/push --include="*.ts*"
grep -rn "iPhone\|iPad\|iOS Safari" src/components src/lib/push --include="*.ts*"
```
Expected: at least one file gates the prompt with a `standalone` check on iOS.

**Failure signature (data plane):** Low iOS subscription count relative to overall iOS traffic share (not directly queryable without analytics; correlate `endpoint LIKE '%.push.apple.com/%'` count with total subs and compare to expected iOS share).

**Fix:** see `fix-patterns.md` → Pattern 6. Cross-reference `bulletproof-onboarding` skill for barber-side gating during `/barber/setup`.

### C16. Race-guard or tag-based dedupe on concurrent pushes [MEDIUM]

Two concurrent "Call Next" PATCHes on the same queue entry can each pass initial validation, one wins the atomic UPDATE (409 for the other), but both may still fire the push send. Result: duplicate push to the barber's phone.

**Preferred fix:** notification `tag` (browsers dedupe by tag). Every payload MUST include `tag: '<type>-<entity_id>'`. No server-side race-guard needed.

**Fallback fix:** re-read the row's status/called_time immediately before the push send; skip if it diverged from what we expected.

**Detect:**
```sql
-- Duplicate queue_assigned notifications for same entry within 10s
SELECT related_id, COUNT(*) AS dupes, MIN(created_at) AS first, MAX(created_at) AS last
FROM barber_notifications
WHERE type = 'queue_assigned' AND created_at > now() - interval '7 days'
GROUP BY related_id
HAVING COUNT(*) > 1 AND (MAX(created_at) - MIN(created_at)) < interval '10 seconds';
```
Expected: 0 rows. Any row indicates a race.

**Fix:** see `fix-patterns.md` → Pattern 7.

### C17. Payload schema + 4096-byte size limit [MEDIUM]

Every push payload MUST include a `title` (required for display) AND either `data.url` or action-handler coverage (for click routing). Payloads exceeding 4096 bytes are rejected by every major push service.

**Detect:**
```bash
# Find push payload literals missing `title`
grep -rn "sendPushNotification\|sendPushToMany" src/ | head -30
# Manually read each sender and confirm payload has `title`. Flag any that's dynamic/optional.

# For size, look for payloads that include user content without truncation
grep -rn "body:\s*notes\|body:\s*message\|body:\s*\`\${.*note" src/
```

**Fix:** centralize via `buildPushPayload()` helper — see `fix-patterns.md` → Pattern 8. Once adopted, any payload that deviates fails at the builder, not at the push service.
