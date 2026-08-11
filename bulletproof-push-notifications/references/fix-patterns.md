# Push Notifications — Fix Patterns

Paste-ready diffs for every gap category. When the audit flags a failure, point to the pattern number here and the user gets a concrete change to apply. These patterns are canonical — if you deviate, document why.

All patterns assume:
- `createAdminClient` imported from `@/lib/supabase/admin`
- Push helpers imported from `@/lib/push/server` (`sendPushNotification`, `BookingPush`, `QueuePush`, `BarberPush`)
- Fire-and-forget `.catch(() => {})` on every push send so it never blocks the parent response

---

## Fix-mode preflight checklist (universal — applies to every pattern)

Fix mode in `SKILL.md` runs this sequence for EVERY pattern before the Edit. Do all steps, in order. Skip none.

1. **Preflight** — Read the target file. Match the pattern's "before" block against current code exactly (imports, function names, variable names, surrounding context — NOT just line numbers, which drift). If ANY of these don't match → STOP. Report what differs. Do NOT apply a stale pattern.
2. **Classify** — Run Query 15 from `audit-queries.sql`. Report live (eligible > 0) vs latent (eligible = 0). User decides urgency from this.
3. **Confirm diff** — Show exact `old_string` / `new_string`. Wait for explicit `yes`.
4. **Apply** — Single `Edit` call. One pattern per invocation.
5. **Verify** — Run the pattern's post-fix verification (grep + tsc, plus SQL if live). Every check must pass.
6. **Mirror** — If the pattern says mirror matters, invoke `mirror-check` before handoff.
7. **Handoff** — Stop at `bulletproof-ship`. Do not commit.

If any step fails, stop and report. Do not proceed to the next step.

---

## Pattern 1 — Admin client for push SELECT/DELETE in cron/webhook context

**When:** Any handler gated by `CRON_SECRET`, Stripe webhook signature, Resend webhook signature, HMAC, etc. that reads `push_subscriptions` OR any prerequisite table (clients by phone, users by id) to look up recipients.

**Symptom:** `push_sent: 0` every tick even when subscribers exist. No error. Query 15 confirms eligible subscribers > 0.

**Root cause:** RLS. The user client (`createClient()` from `@/lib/supabase/server`) has no Supabase session under CRON_SECRET auth → resolves to anon. `auth.uid()` is NULL. Policy `auth.uid() = user_id` returns zero rows.

**Fix:**
```ts
// BEFORE (broken under cron)
const supabase = await createClient()
const { data: client } = await supabase
  .from('clients')
  .select('profile_id')
  .eq('phone', clientPhone)
  .single()

const { data: subs } = await (supabase as any)
  .from('push_subscriptions')
  .select('endpoint, p256dh, auth')
  .eq('user_id', client.profile_id)

// ... later ...
if (result.error === 'subscription_expired') {
  await somePushAdmin.from('push_subscriptions').delete().eq('endpoint', sub.endpoint)
}

// AFTER (correct — admin client throughout)
const admin = createAdminClient()

const { data: client } = await admin
  .from('clients')
  .select('profile_id')
  .eq('phone', clientPhone)
  .single()

const { data: subs } = await (admin as any)
  .from('push_subscriptions')
  .select('endpoint, p256dh, auth')
  .eq('user_id', client.profile_id)

// ... later ...
if (result.error === 'subscription_expired') {
  await admin.from('push_subscriptions').delete().eq('endpoint', sub.endpoint)
}
```

**Scope limit:** Only swap the push-send chain. If the route also reads/writes other tables (e.g., `bookings.reminder_sent`) under a working user client, leave those alone. Out-of-scope refactors break unrelated things.

---

## Pattern 2 — Push to customer on booking creation

**When:** A booking is successfully created. Customer currently gets SMS but no push at create time (only at 24h/1h reminders).

**Where:** End of `/src/app/api/bookings/quick/route.ts` (primary booking create). Also wherever else new bookings are created that emit SMS: `src/app/api/bookings/route.ts`, admin booking create.

**Fix:**
```ts
// After notifyBarberOfNewBooking(...) and SMS is sent:

// Push to customer if they're a registered client with a subscription
if (booking.client_id) {
  const admin = createAdminClient()
  const { data: clientRow } = await admin
    .from('clients')
    .select('profile_id')
    .eq('id', booking.client_id)
    .single()

  if (clientRow?.profile_id) {
    const { data: subs } = await (admin as any)
      .from('push_subscriptions')
      .select('endpoint, p256dh, auth')
      .eq('user_id', clientRow.profile_id)

    if (subs && subs.length > 0) {
      const payload = {
        title: 'Booking Confirmed ✂️',
        body: `${barberName} • ${dateFormatted} at ${timeFormatted}`,
        tag: `booking-confirmed-${booking.id}`, // replaces prior notification for same booking
        data: { type: 'booking_confirmed', url: '/book/confirmation', bookingId: booking.id },
        actions: [
          { action: 'view', title: 'View' },
          { action: 'reschedule', title: 'Reschedule' },
        ],
      }
      for (const sub of subs) {
        sendPushNotification(
          { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
          payload
        )
          .then(async (result) => {
            if (result.error === 'subscription_expired') {
              await admin.from('push_subscriptions').delete().eq('endpoint', sub.endpoint)
            }
          })
          .catch(() => {})
      }
    }
  }
}
```

**Verify `/public/sw.js` routes action `reschedule`** to `/book` (it does as of this writing).

---

## Pattern 3 — Push to barber on booking cancel / reschedule

**When:** Booking PATCH (reschedule), DELETE (cancel), or status change to `cancelled`. Barber currently gets in-app notification via `barber_notifications` row but may not get push.

**Where:** The route that handles booking cancel/reschedule (search `grep -rn "status.*cancelled\|booking.*cancel" src/app/api/bookings`).

**Fix:** Use the existing `notifyBarber` helper from `@/lib/db/notifications` — it already sends the push if the barber has subs. Just ensure it's called for these lifecycle events:

```ts
// On cancel:
await notifyBarber(
  admin,
  booking.barber_id,
  'booking_cancelled',
  'Booking Cancelled',
  `${booking.client_name} cancelled their ${dateFormatted} ${timeFormatted} appointment`,
  booking.id
)

// On reschedule (before/after times):
await notifyBarber(
  admin,
  booking.barber_id,
  'booking_rescheduled',
  'Booking Rescheduled',
  `${booking.client_name}: ${oldTime} → ${newTime}`,
  booking.id
)
```

`notifyBarber` handles the `barber_notifications` row insert AND fires `sendBarberPush` (which already uses admin client per Pattern 1). No duplicated logic — reuse the helper.

---

## Pattern 4 — Push on queue position change

**When:** `/src/lib/queue/position-notifier.ts` — `notifyPositionChange()`, `sendAlmostUpNotification()`, `sendLeaveNowNotification()`. These send SMS; add push beside them.

**Fix:**
```ts
// Inside notifyPositionChange, after the SMS send:
const { data: queueSub } = await supabase
  .from('push_subscriptions')
  .select('endpoint, p256dh, auth')
  .eq('queue_token', entry.tracking_token)
  .maybeSingle() // .single() would throw on missing; maybeSingle returns null

if (queueSub) {
  QueuePush.sendPositionUpdate(
    { endpoint: queueSub.endpoint, keys: { p256dh: queueSub.p256dh, auth: queueSub.auth } },
    currentPosition,
    estimatedMinutes
  )
    .then(async (result) => {
      if (result.error === 'subscription_expired') {
        // This context has a Supabase session (called from authed API routes), so
        // RLS on anon queue_token rows permits DELETE only for the subscription owner.
        // Use admin client to be safe:
        const admin = createAdminClient()
        await admin.from('push_subscriptions').delete().eq('endpoint', queueSub.endpoint)
      }
    })
    .catch(() => {})
}
```

**Note on RLS:** `queue_token` subs are anon-owned (`user_id IS NULL`). Under an authenticated session, the user can still SELECT them via the `"Anonymous queue push subscriptions select"` policy because it doesn't filter by role — it just requires `user_id IS NULL AND queue_token IS NOT NULL`. Reading works. For DELETE cleanup on expired subs, use admin to avoid edge cases.

---

## Pattern 5 — Push to barber on customer no-show

**When:** `/src/app/api/queue/entry/[id]/route.ts` — status transition to `no_show`. Currently sends SMS to customer (`QueueSMS.sendNoShowNotification`). Barber gets in-app notification but no push.

**Fix:**
```ts
// In the no_show transition block, after SMS:
await notifyBarber(
  admin,
  currentEntry.assigned_barber_id,
  'no_show',
  'Customer No-Show',
  `${currentEntry.client_name} did not show within the 3-minute window. Calling next.`,
  currentEntry.id
)
```

Again, reuse `notifyBarber` — don't duplicate the push-send boilerplate.

---

## Pattern 6 — iOS Safari PWA install gate

**When:** `NotificationPrompt.tsx`, `PushOptIn.tsx`, or any component that renders a "Enable notifications" button for customers or barbers on iOS Safari without the PWA installed.

**Symptom:** iOS users click Enable → permission denied → cannot re-prompt for ~30 days → silent coverage gap.

**Fix:** Add a utility and gate the prompt:

```ts
// Add to src/lib/push/client.ts (exported):
export function isPWAInstalled(): boolean {
  if (typeof window === 'undefined') return false
  // iOS Safari PWA: navigator.standalone is true
  // Android/Chrome PWA: matches (display-mode: standalone)
  return (
    (navigator as any).standalone === true ||
    window.matchMedia('(display-mode: standalone)').matches
  )
}

export function isIOSSafari(): boolean {
  if (typeof navigator === 'undefined') return false
  const ua = navigator.userAgent
  return /iPhone|iPad|iPod/.test(ua) && !/CriOS|OPiOS|FxiOS|EdgiOS/.test(ua)
}

export function canEnablePush(): { allowed: boolean; reason?: string } {
  if (typeof window === 'undefined') return { allowed: false, reason: 'ssr' }
  if (!('serviceWorker' in navigator) || !('PushManager' in window)) {
    return { allowed: false, reason: 'unsupported' }
  }
  if (isIOSSafari() && !isPWAInstalled()) {
    return { allowed: false, reason: 'needs_pwa_install' }
  }
  return { allowed: true }
}
```

Then in `PushOptIn.tsx` / `NotificationPrompt.tsx`:

```tsx
const gate = canEnablePush()
if (!gate.allowed) {
  if (gate.reason === 'needs_pwa_install') {
    return (
      <InstallPWAInstructions />  // Show "Tap Share → Add to Home Screen" with visual
    )
  }
  return null  // unsupported / ssr
}
// ... existing Enable button ...
```

`InstallPWAInstructions` is a small component that shows the share-icon → Add-to-Home-Screen flow with a screenshot. Reuse any existing install-instruction component before creating a new one.

**Cross-reference:** `bulletproof-onboarding` handles the same gate for barbers during `/barber/setup`. Customer side is this skill's responsibility.

---

## Pattern 7 — Race-guard before firing barber push on Call Next

**When:** `/src/app/api/queue/entry/[id]/route.ts` around the Call Next push block (~line 442-492).

**Symptom:** Duplicate `queue_assigned` rows in `barber_notifications` for the same entry within the same second → duplicate phone buzzes.

**Fix:** Re-read the row status immediately before the push send. The DB's atomic UPDATE already prevents double state transitions; the extra read just prevents a push from firing after another request has already fired one for the same transition.

```ts
// After the atomic UPDATE succeeded and the push is about to go:
const { data: postUpdate } = await admin
  .from('queue_entries')
  .select('status, called_time')
  .eq('id', id)
  .single()

// If the called_time differs by more than 2 seconds from what we expect,
// another request may have just called this entry. Skip the push.
const expectedCalledTime = new Date().getTime()
const actualCalledTime = postUpdate?.called_time
  ? new Date(postUpdate.called_time).getTime()
  : 0
if (Math.abs(expectedCalledTime - actualCalledTime) > 2000) {
  return // another request already handled this; skip push
}

// ... existing push send ...
```

**Alternative (cleaner):** Use a unique notification `tag` in the payload (`tag: 'call-next-' + entryId`). Browsers replace notifications with the same tag — if two requests each call `showNotification` with the same tag, the user sees one, not two. This is the least-invasive fix:

```ts
const payload = {
  title: '...',
  body: '...',
  tag: `call-next-${id}`, // <-- dedupe via browser, no race-guard needed
  data: { ... },
  actions: [...],
}
```

Prefer the tag approach unless the `barber_notifications` row duplication itself is the problem — then race-guard.

---

## Pattern 8 — Payload schema validator + user content truncation

**When:** Adding a new push sender, OR reviewing existing ones. Payloads must be < 4096 bytes and include `title`.

**Fix:** Add a shared builder helper in `src/lib/push/server.ts`:

```ts
const MAX_PAYLOAD_BYTES = 3800 // leave 296-byte headroom for envelope

export function buildPushPayload(input: {
  title: string
  body: string
  url?: string
  type?: string
  tag?: string
  actions?: Array<{ action: string; title: string }>
  data?: Record<string, unknown>
}): object {
  if (!input.title) throw new Error('push payload: title required')
  const truncatedBody = input.body.length > 400
    ? input.body.slice(0, 397) + '...'
    : input.body
  const payload = {
    title: input.title,
    body: truncatedBody,
    icon: '/icon-192.png',
    badge: '/icon-72.png',
    tag: input.tag,
    actions: input.actions || [],
    data: {
      url: input.url || '/',
      type: input.type || 'generic',
      ...(input.data || {}),
    },
  }
  const size = new TextEncoder().encode(JSON.stringify(payload)).byteLength
  if (size > MAX_PAYLOAD_BYTES) {
    // Truncate body more aggressively
    const overflow = size - MAX_PAYLOAD_BYTES
    payload.body = payload.body.slice(0, Math.max(20, payload.body.length - overflow - 20)) + '...'
  }
  return payload
}
```

Then senders use:
```ts
const payload = buildPushPayload({
  title: 'Booking Confirmed ✂️',
  body: notes || `${barberName} at ${timeFormatted}`,
  url: '/book/confirmation',
  type: 'booking_confirmed',
  tag: `booking-confirmed-${bookingId}`,
  actions: [{ action: 'view', title: 'View' }, { action: 'reschedule', title: 'Reschedule' }],
})
```

This enforces C13 (payload schema) with a single code path instead of scattered payload literals.

---

## Cross-pattern rules

1. **Always fire-and-forget.** Push sends must never block the API response. `.catch(() => {})` on every send.
2. **Always handle 410/404.** Every sender must delete expired endpoints — use admin client for the DELETE.
3. **Always use `tag`** on the payload for dedupe. Browsers replace notifications with the same tag.
4. **Never `.single()` on optional subscriptions** — use `.maybeSingle()` so a missing row returns null instead of throwing.
5. **Never log raw `p256dh` or `auth`** — they are cryptographic keys. Redact before logging.
6. **Always set `title` and `data.url` (or action handler coverage).** Missing title → no notification shown. Missing url + no action handler → click lands on `/`.

---

## When adding a NEW sender

Checklist:
1. Admin client? (Pattern 1 if cron/webhook)
2. Fire-and-forget + 410/404 cleanup?
3. Payload built via `buildPushPayload` (Pattern 8)?
4. Tagged for dedupe (Pattern 7 alternative)?
5. Trigger added to the coverage matrix in SKILL.md C10?
6. SMS parity checked (does the same trigger also send SMS)?
7. Service worker `/public/sw.js` routes the payload's action/url correctly?

If any of these is "no," stop and fix before shipping.

---

# Per-pattern fix-mode specifics

Fix mode reads this section when applying a pattern. Each entry has three blocks: **preflight** (confirm code hasn't drifted), **blast radius** (what's actually touched), and **post-fix verification** (flip fail→pass). If preflight fails or post-fix verification fails, STOP.

---

## Pattern 1 — Admin client in bookings reminders cron

**Preflight check**
- Read [src/app/api/bookings/reminders/route.ts](src/app/api/bookings/reminders/route.ts) lines ~40-85.
- Confirm the `sendBookingPushReminder` helper still uses `supabase` (the SSR user client) for both `.from('clients').select('profile_id')` AND `(supabase as any).from('push_subscriptions').select(...)`.
- Confirm `createAdminClient` is imported at top but only used for the DELETE in the 410/404 cleanup block.
- If the helper already uses `admin` for the SELECTs → STOP, already fixed.
- If the function signature changed or the SELECTs moved → STOP, re-plan.

**Blast radius**
- File: [src/app/api/bookings/reminders/route.ts](src/app/api/bookings/reminders/route.ts)
- Function: `sendBookingPushReminder` (local helper inside GET handler)
- Mirror pages: none (cron-only route)
- Upstream callers: both the 24h and 1h reminder loops inside the same GET handler
- Other crons with same pattern: `/api/cron/service-reminder/route.ts` (already admin-clean, skip) and `/api/cron/feedback-requests/route.ts` (check before concluding — if it touches push_subscriptions under cron auth, same fix)

**Post-fix verification**
- `grep -n "supabase\.from('push_subscriptions')" src/app/api/bookings/reminders/route.ts` → 0 matches (only admin client should touch it)
- `grep -n "admin\.from('push_subscriptions')" src/app/api/bookings/reminders/route.ts` → ≥1 match
- `grep -n "supabase\.from('clients')\.select('profile_id')" src/app/api/bookings/reminders/route.ts` → 0 matches inside `sendBookingPushReminder` scope (admin should own that lookup too)
- `npx tsc --noEmit` → no new errors
- **Live probe (deferred):** `curl -H "Authorization: Bearer $CRON_SECRET" https://mtbarbershop.com/api/bookings/reminders` → inspect JSON `push_sent`; should be > 0 when eligible subscribers exist

---

## Pattern 2 — Push to customer on booking creation

**Preflight check**
- Read [src/app/api/bookings/quick/route.ts](src/app/api/bookings/quick/route.ts) around the section after `notifyBarberOfNewBooking(...)` (near end of POST handler, ~line 250-310).
- Confirm: SMS (`BookingSMS.send...`) fires at creation, but no `sendPushNotification` / `BookingPush` / `QueuePush` call targets the customer.
- Confirm `createAdminClient` is importable (already used elsewhere in the file) and `sendPushNotification` is importable from `@/lib/push/server`.
- If a customer-side push call already exists → STOP, already wired. Check why audit still flags the gap.
- If `/src/app/api/bookings/route.ts` also creates bookings, apply the same addition there (multi-file change — STILL one pattern per fix-mode invocation; do the second file as a separate fix invocation).

**Blast radius**
- File: [src/app/api/bookings/quick/route.ts](src/app/api/bookings/quick/route.ts) (primary)
- Secondary: [src/app/api/bookings/route.ts](src/app/api/bookings/route.ts) (same pattern, separate invocation)
- Functions touched: POST handler, near the end
- Mirror pages: none (API route)
- Service worker impact: confirm `/public/sw.js` handles `actions: [{action:'view'}, {action:'reschedule'}]` (it does as of 2026-04-20; the `reschedule` handler routes to `/book`)

**Post-fix verification**
- `grep -n "sendPushNotification\|BookingPush" src/app/api/bookings/quick/route.ts` → ≥1 match after the fix
- `grep -n "booking_confirmed" src/app/api/bookings/quick/route.ts` → 1 match (the push payload's `data.type`)
- `npx tsc --noEmit` → no new errors
- **Live probe (deferred):** Create a test booking with a registered client that has a push subscription; confirm the client's device receives the push within ~3 seconds

---

## Pattern 3 — Push to barber on booking cancel / reschedule

**Preflight check**
- Read the route that handles booking cancel: `grep -rn "status.*cancelled\|soft.*delete.*booking\|deleted_at.*new Date" src/app/api/bookings` → find the handler.
- Likely locations: `/src/app/api/bookings/[id]/route.ts` (DELETE or PATCH) or `/src/app/api/bookings/cancel/route.ts` if it exists.
- Confirm `notifyBarber` from `@/lib/db/notifications` is importable and that the handler currently does NOT call it for `booking_cancelled` or `booking_rescheduled` types.
- If the handler is missing entirely (no cancel route) → different problem, not a fix-pattern application. Escalate.

**Blast radius**
- Files: depends on what grep finds. Likely `src/app/api/bookings/[id]/route.ts`
- Function touched: DELETE or PATCH handler where status transitions to `cancelled` or scheduled_date changes
- Mirror pages: both `/dashboard/bookings` and `/barber/calendar` consume barber_notifications via the realtime hook — the notification row itself is the mirror, so no separate UI change needed
- Reuses: `notifyBarber(supabase, barberId, type, title, message, relatedId)` in `src/lib/db/notifications.ts`

**Post-fix verification**
- `grep -n "booking_cancelled\|booking_rescheduled" src/app/api/bookings` → ≥2 matches after fix (one per lifecycle)
- `grep -n "notifyBarber" <the-edited-file>` → ≥1 match
- `npx tsc --noEmit` → no new errors
- **Live probe (deferred):** cancel a test booking; confirm a `barber_notifications` row is inserted with type `booking_cancelled` and the barber's subscribed device receives the push

---

## Pattern 4 — Push on queue position change

**Preflight check**
- Read [src/lib/queue/position-notifier.ts](src/lib/queue/position-notifier.ts).
- Confirm `notifyPositionChange`, `sendAlmostUpNotification`, `sendLeaveNowNotification` all currently send **only SMS** (no `QueuePush` call).
- Confirm `QueuePush` is importable from `@/lib/push/server` and exports `sendPositionUpdate`.
- If any function already calls `QueuePush` → STOP, partial fix may have been applied already.

**Blast radius**
- File: [src/lib/queue/position-notifier.ts](src/lib/queue/position-notifier.ts)
- Functions touched: `notifyPositionChange` (primary), `sendAlmostUpNotification`, `sendLeaveNowNotification`
- Mirror pages: `/queue/[token]` customer tracker page reads the push on the client side via SW; no dashboard mirror
- **Mirror-check invocation: NOT required** — this is a library, not a dashboard page. But if a related UI change lands in `/barber/walk-ins` (position-change UI), then yes.

**Post-fix verification**
- `grep -n "QueuePush\.sendPositionUpdate" src/lib/queue/position-notifier.ts` → ≥1 match (the fix)
- `grep -n "queue_token" src/lib/queue/position-notifier.ts` → ≥1 match (SELECT by queue_token)
- `npx tsc --noEmit` → no new errors
- **Live probe (deferred):** join queue as test customer with notifications enabled, then have another customer complete service ahead of you; confirm push arrives on position change

---

## Pattern 5 — Push to barber on customer no-show

**Preflight check**
- Read [src/app/api/queue/entry/[id]/route.ts](src/app/api/queue/entry/[id]/route.ts) around the `no_show` transition (grep for `'no_show'` inside the PATCH handler).
- Confirm SMS (`QueueSMS.sendNoShowNotification`) fires but `notifyBarber` for type `no_show` does NOT.
- Confirm `notifyBarber` helper is already imported in this file (it is — used for `queue_assigned`).
- If `notifyBarber(... 'no_show' ...)` already exists → STOP, already fixed.

**Blast radius**
- File: [src/app/api/queue/entry/[id]/route.ts](src/app/api/queue/entry/[id]/route.ts)
- Function: PATCH handler, `no_show` transition block
- Mirror pages: barber/owner dashboards consume `barber_notifications` table via realtime — no UI code change needed
- **Mirror-check invocation: NOT required** — API route only, the UI mirror is data-driven

**Post-fix verification**
- `grep -n "notifyBarber.*no_show" src/app/api/queue/entry/[id]/route.ts` → ≥1 match
- `npx tsc --noEmit` → no new errors
- **Live probe (deferred):** call a test customer, wait past the 3-minute no-show window, confirm `barber_notifications` row is inserted with type `no_show` and subscribed barber receives push

---

## Pattern 6 — iOS Safari PWA install gate

**Preflight check**
- Read [src/lib/push/client.ts](src/lib/push/client.ts); confirm `isPWAInstalled`, `isIOSSafari`, `canEnablePush` helpers do NOT already exist.
- Read [src/components/profile/PushOptIn.tsx](src/components/profile/PushOptIn.tsx); confirm it calls `subscribe()` directly without any iOS install gate.
- Read [src/components/queue/NotificationPrompt.tsx](src/components/queue/NotificationPrompt.tsx); same check.
- If any helper already exists in `client.ts` → STOP, partial work was already done; read first before overwriting.

**Blast radius**
- Files:
  - [src/lib/push/client.ts](src/lib/push/client.ts) (add 3 exports)
  - [src/components/profile/PushOptIn.tsx](src/components/profile/PushOptIn.tsx) (wrap render with gate)
  - [src/components/queue/NotificationPrompt.tsx](src/components/queue/NotificationPrompt.tsx) (same)
  - Potentially add `<InstallPWAInstructions />` component if not already present — search first: `grep -rn "Add to Home Screen\|InstallPWA" src/components`
- Mirror pages: **YES** — `PushOptIn` renders on `/profile` (customer); `NotificationPrompt` renders on `/queue/[token]`. Both are customer-facing. Barber-side equivalent (PWA install during `/barber/setup`) is handled by `bulletproof-onboarding` skill — coordinate, don't duplicate.
- **Mirror-check invocation: CONDITIONAL** — if the fix also needs a mirror in `/barber/setup`, hand that off to `bulletproof-onboarding`. Do not touch barber setup code from this skill.
- UI impact: visible to customers on iOS Safari. MUST be UI-reviewed before shipping.

**Post-fix verification**
- `grep -n "isPWAInstalled\|isIOSSafari\|canEnablePush" src/lib/push/client.ts` → 3 matches (exports)
- `grep -n "canEnablePush\|isPWAInstalled" src/components/profile/PushOptIn.tsx` → ≥1 match
- `grep -n "canEnablePush\|isPWAInstalled" src/components/queue/NotificationPrompt.tsx` → ≥1 match
- `npx tsc --noEmit` → no new errors
- **Explicit user instruction (mandatory):** before handoff to bulletproof-ship, tell the user: "Test on iOS Safari — (1) not installed → should see install instructions, not a broken permission prompt. (2) installed (PWA from Home Screen) → normal enable flow."

---

## Pattern 7 — Race-guard / tag-based dedupe

**Preflight check**
- Read [src/app/api/queue/entry/[id]/route.ts](src/app/api/queue/entry/[id]/route.ts) around the `BarberPush.sendQueueAssigned` call.
- Inspect the payload that's built for the push. Look for `tag:` field.
- **If `tag` is already present AND formatted as `<type>-<entity_id>` (e.g. `call-next-${entryId}`) → STOP, already deduped via browser.**
- If `tag` missing OR generic → apply the tag-based fix (preferred over server-side race-guard).
- Separately: run the dedupe SQL (Query 16 from audit-queries.sql) to confirm the race is actually happening before applying.

**Blast radius**
- File: [src/app/api/queue/entry/[id]/route.ts](src/app/api/queue/entry/[id]/route.ts)
- Function: PATCH handler, Call Next branch
- Also audit other senders for `tag:` field — `BookingPush.sendReminder`, `BarberPush.send*`, etc. Missing tags there mean the same dedupe bug can happen elsewhere. But fix ONE pattern per invocation.
- Mirror pages: none

**Post-fix verification**
- `grep -n "tag: .call-next-\${" src/app/api/queue/entry/[id]/route.ts` → ≥1 match (or equivalent template)
- Re-run Query 16 after 24 hours: duplicate `barber_notifications` within 10s window should drop to 0
- `npx tsc --noEmit` → no new errors
- **Live probe (deferred):** simulate two concurrent PATCHes on the same queue entry via curl; confirm barber receives only ONE notification on their device (browser dedupes by tag)

---

## Pattern 8 — Payload schema builder (`buildPushPayload`)

**Preflight check**
- Read [src/lib/push/server.ts](src/lib/push/server.ts); confirm `buildPushPayload` does NOT already exist.
- Inventory current push senders via grep:
  ```
  grep -rn "sendPushNotification\|sendPushToMany" src/ | grep -v node_modules
  ```
- Each sender currently constructs a payload as an object literal. Count them — this is the N files that need to switch to `buildPushPayload` in follow-up fix invocations.
- If `buildPushPayload` exists → STOP, it's already centralized. Audit why the skill flagged it.

**Blast radius**
- Primary file: [src/lib/push/server.ts](src/lib/push/server.ts) (add the helper + export)
- Follow-up files (each a separate fix invocation — ONE pattern per invocation):
  - [src/app/api/queue/entry/[id]/route.ts](src/app/api/queue/entry/[id]/route.ts) (2 payloads: barber + customer)
  - [src/app/api/bookings/reminders/route.ts](src/app/api/bookings/reminders/route.ts) (2 payloads)
  - [src/lib/db/notifications.ts](src/lib/db/notifications.ts) (1 payload)
  - [src/app/api/cron/service-reminder/route.ts](src/app/api/cron/service-reminder/route.ts) (1 payload)
  - [src/app/api/communications/send-blast/route.ts](src/app/api/communications/send-blast/route.ts) (1 payload)
- Mirror pages: none (library change)

**Post-fix verification**
- `grep -n "export function buildPushPayload" src/lib/push/server.ts` → 1 match
- `grep -n "MAX_PAYLOAD_BYTES" src/lib/push/server.ts` → ≥1 match
- `npx tsc --noEmit` → no new errors
- (Only after follow-up invocations) `grep -rn "title:\s*'" src/app/api/queue src/app/api/bookings src/lib/db` → 0 hand-built payload literals; all should route through `buildPushPayload`

---

## Skipping gap #8 (low barber push coverage)

If the user says "fix gap 8" in fix mode, the skill MUST refuse and redirect:

> Gap 8 is an onboarding problem, not a code bug. 20+ active barbers have no push subscription because they haven't installed the PWA or enabled notifications during setup. The fix is in the `/barber/setup` wizard flow.
>
> Handoff to the `bulletproof-onboarding` skill — it owns the `/barber/setup` wizard including PWA-install + push-enrollment steps.

Do NOT attempt to patch user data or subscribe on behalf of barbers.
