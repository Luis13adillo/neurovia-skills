# Communications — Fix Patterns

Paste-ready diffs for every gap category flagged by `bulletproof-communications`. When the audit fails an invariant, point to the pattern number here and the user gets a concrete change to apply. These patterns are canonical — if you deviate, document why.

All patterns assume:
- `createAdminClient` imported from `@/lib/supabase/admin` for cron/webhook contexts
- Opt-out checks via `getClientOptOutStatus` from `@/lib/db/communications`
- Twilio signature verification via `validateTwilioWebhook` from `@/lib/twilio/validate-signature`
- SMS senders live in `src/lib/twilio/sms.ts` (`QueueSMS`, `BookingSMS`, `BarberSMS`, `sendSMS`, `sendMarketingSMS`)
- Email templates live in `src/lib/email/templates.ts` (single-file; no per-template directory)

---

## Fix-mode preflight checklist (universal — applies to every pattern)

Fix mode in `SKILL.md` runs this sequence for EVERY pattern before the Edit. Do all steps, in order. Skip none.

1. **Preflight** — Read the target file. Match the pattern's "before" block against current code exactly (imports, function names, variable names, surrounding context — NOT just line numbers, which drift). If ANY of these don't match → STOP. Report what differs. Do NOT apply a stale pattern.
2. **Classify** — Run the matching query from `references/audit-queries.sql` (or the SELECT shown in `invariants.md`). Report live (violating rows > 0) vs latent (violating rows = 0). User decides urgency from this.
3. **Confirm diff** — Show exact `old_string` / `new_string`. Wait for explicit `yes` before touching any file.
4. **Apply** — Single `Edit` call. One pattern per invocation.
5. **Verify** — Run the pattern's post-fix verification (grep + `npx tsc --noEmit`, plus SQL re-run if live). Every check must pass.
6. **Mirror** — If the pattern touches an SMS/email sender that also exists elsewhere (e.g., walk-in queue vs booking), apply the same guard to its twin. Do not rely on memory — grep for the function name.
7. **Handoff** — Stop at `bulletproof-ship`. Do not commit. Never send a test SMS to a real phone during verification (TCPA risk).

If any step fails, stop and report. Do not proceed to the next step.

---

## Pattern 1 — Missing opt-out check before `twilio.messages.create`

**When:** Audit invariant 2 (no send to opted-out phones) or invariant 12 (recent opt-outs not re-messaged) returns rows. Or a new sender function is added that calls the Twilio API directly without routing through `sendSMS` / `sendMarketingSMS`.

**Root cause:** Sender calls `twilioClient.messages.create({...})` (or a wrapper) without first querying `sms_opt_outs`. See incident "TCPA Opt-Out Compliance" — this is a legal-risk failure, not a nice-to-have.

**Before:**
```ts
// Custom sender bypassing sendSMS
const client = getTwilioClient()
await client.messages.create({
  to: formattedPhone,
  from: TWILIO_PHONE_NUMBER,
  body: message,
})
```

**After:**
```ts
import { getClientOptOutStatus } from '@/lib/db/communications'

const isOptedOut = await getClientOptOutStatus(formattedPhone)
if (isOptedOut) {
  await logSMS({
    recipient_phone: formattedPhone,
    trigger_type,
    status: 'skipped_opt_out',
    message_body: message,
  })
  return { success: false, error: 'Recipient opted out' }
}

// Then send via the canonical helper — do not re-implement Twilio dispatch
const result = await sendSMS({ to: formattedPhone, body: message, triggerType: trigger_type })
```

**Scope limit:** Do not "improve" the sender while you're there. Only add the opt-out check + switch to `sendSMS`. If the caller already uses `sendSMS` / `sendMarketingSMS`, the check is already present inside those helpers (invariant C2 — do not duplicate).

**Post-fix verification:**
- `grep -rn "twilio.*messages\.create\|\.messages\.create" src/ | grep -v node_modules | grep -v 'lib/twilio/sms.ts'` → 0 matches (only `sms.ts` may call Twilio directly).
- `grep -n "getClientOptOutStatus" <edited-file>` → ≥1 match.
- `npx tsc --noEmit` → no new errors.
- Re-run invariant 2 and 12 SQL → 0 violating rows.

---

## Pattern 2 — Twilio webhook accepts requests without signature check

**When:** Audit invariant C1 (webhook signature verification) fails. Handler reads `request.formData()` before `validateTwilioWebhook` returns `valid: true`, or ignores the return value.

**Root cause:** Inbound/status webhook processes the body path-length before verifying `X-Twilio-Signature`. See incident "Twilio Webhook Signature Failure" — this opens the app to forged opt-outs and forged delivery-status overwrites.

**Before:**
```ts
export async function POST(request: NextRequest) {
  const formData = await request.formData()
  const body = formData.get('Body') as string
  // ... process opt-out / status update ...
}
```

**After:**
```ts
import { validateTwilioWebhook } from '@/lib/twilio/validate-signature'

export async function POST(request: NextRequest) {
  const result = await validateTwilioWebhook(request)
  if (!result.valid) {
    return new NextResponse('Forbidden', { status: 403 })
  }
  const params = result.params!  // parsed inside validator
  const body = params.Body
  const fromPhone = params.From
  // ... process opt-out / status update ...
}
```

**Gotcha:** `validate-signature.ts` intentionally skips verification when `TWILIO_AUTH_TOKEN` is unset ("dev mode" branch, line 33-49). In production, `TWILIO_AUTH_TOKEN` must always be set or forged webhooks become accepted. Do NOT remove the dev-mode branch — it is load-bearing for local testing. But if you add a new webhook route, confirm `TWILIO_AUTH_TOKEN` is present in Vercel prod env.

**Post-fix verification:**
- `grep -n "validateTwilioWebhook" src/app/api/webhooks/twilio/inbound/route.ts src/app/api/webhooks/twilio/status/route.ts` → ≥1 match each.
- `grep -n "formData\(\)" src/app/api/webhooks/twilio/` → 0 matches (validator owns parsing).
- `npx tsc --noEmit` → no new errors.
- Live probe (deferred): send a curl POST without `X-Twilio-Signature` → expect 403.

---

## Pattern 3 — Cron route missing `CRON_SECRET` gate

**When:** Invariant C3 fails. A cron route under `src/app/api/cron/**` or `src/app/api/bookings/reminders/route.ts` does not check `Authorization: Bearer ${CRON_SECRET}`. See CLAUDE.md "Production Readiness" — `/api/bookings/reminders` was historically unprotected and had to be hardened.

**Before:**
```ts
export async function GET(request: NextRequest) {
  const admin = createAdminClient()
  // ... fetch and send ...
}
```

**After:**
```ts
export async function GET(request: NextRequest) {
  const authHeader = request.headers.get('authorization')
  if (authHeader !== `Bearer ${process.env.CRON_SECRET}`) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })
  }
  const admin = createAdminClient()
  // ... fetch and send ...
}
```

**Scope limit:** Add the gate. Do not refactor the body of the handler. Do not change cron schedule in `vercel.json` — that's a separate decision.

**Post-fix verification:**
- `grep -n "CRON_SECRET" <edited-file>` → ≥1 match.
- `grep -L "CRON_SECRET" src/app/api/cron/**/route.ts src/app/api/bookings/reminders/route.ts src/app/api/bookings/send-reminder/route.ts` → empty list (every cron gated).
- `npx tsc --noEmit` → no new errors.
- Live probe (deferred): `curl https://mtbarbershop.com/api/cron/<name>` without Authorization → 401.

---

## Pattern 4 — Reminder flag updated before send succeeds (duplicate-send race)

**When:** Invariant 4 (no duplicate reminder SMS) returns rows, or incident "Duplicate Reminder SMS" matches the symptom. The cron updates `bookings.reminder_sent = true` before verifying Twilio returned success, so failures cause silent drops AND overlapping cron runs cause duplicates.

**Root cause:** `UPDATE` fires before or independent of the `sendSMS` result. See `references/incidents.md` "Duplicate Reminder SMS" — subtle failure mode is two overlapping Vercel cron invocations both seeing `reminder_sent = false`.

**Before:**
```ts
for (const booking of bookings) {
  await admin.from('bookings').update({ reminder_sent: true }).eq('id', booking.id)
  await BookingSMS.sendReminder24h(booking)
}
```

**After:**
```ts
for (const booking of bookings) {
  const result = await BookingSMS.sendReminder24h(booking)
  if (!result.success) {
    console.error('[reminders] send failed', booking.id, result.error)
    continue  // do NOT flip the flag on failure
  }
  await admin
    .from('bookings')
    .update({ reminder_sent: true })
    .eq('id', booking.id)
    .eq('reminder_sent', false)  // optimistic concurrency: only flip if still false
}
```

**Note on overlapping crons:** The `.eq('reminder_sent', false)` filter is a light-weight row-level guard. If a second cron invocation already flipped the flag, this UPDATE is a no-op — but the SMS has already been sent by the first invocation. That is the underlying race; true elimination requires a distributed lock or a unique index on `(booking_id, trigger_type, created_at::date)` in `sms_logs`. Flag for discussion; do not implement without user approval.

**Post-fix verification:**
- `grep -B2 -A2 "reminder_sent.*true" src/app/api/bookings/reminders/route.ts` → UPDATE is AFTER `sendReminder24h` call in every branch.
- Re-run invariant 4 SQL (24h after deploy) → 0 duplicates per booking.
- Re-run invariant 3 SQL → every `reminder_sent=true` has matching `sms_logs` row.

---

## Pattern 5 — Status webhook unconditionally overwrites `sms_logs.status`

**When:** Invariant C4 fails (no precedence). `sms_logs.status = 'sent'` when Twilio later delivered, or a stale `failed` overwrites a fresh `delivered`. See incident "Status Webhook Out-of-Order Updates".

**Root cause:** `src/app/api/webhooks/twilio/status/route.ts` does a blind UPDATE keyed on `twilio_sid` without checking whether the new status is a forward transition.

**Before:**
```ts
await admin
  .from('sms_logs')
  .update({ status: newStatus })
  .eq('twilio_sid', messageSid)
```

**After:**
```ts
const STATUS_RANK: Record<string, number> = {
  queued: 1,
  sent: 2,
  delivered: 3,
  failed: 3,      // terminal, same rank as delivered
  undelivered: 3, // terminal
}

const { data: existing } = await admin
  .from('sms_logs')
  .select('status')
  .eq('twilio_sid', messageSid)
  .single()

const currentRank = STATUS_RANK[existing?.status ?? 'queued'] ?? 0
const newRank = STATUS_RANK[newStatus] ?? 0

if (newRank < currentRank) {
  return NextResponse.json({ ok: true, skipped: 'stale status' })
}

await admin
  .from('sms_logs')
  .update({ status: newStatus })
  .eq('twilio_sid', messageSid)
```

**Post-fix verification:**
- `grep -n "STATUS_RANK\|status.*rank" src/app/api/webhooks/twilio/status/route.ts` → ≥1 match.
- `npx tsc --noEmit` → no new errors.
- Live probe (deferred): send the same `twilio_sid` a `failed` status AFTER `delivered` — confirm the row stays `delivered`.

---

## Pattern 6 — Hardcoded location state in email template footer

**When:** Any new email template in `src/lib/email/templates.ts` hardcodes `, DE` in the footer, OR a booking/reminder route fails to pass `location.state` through to the template. See the HARD RULE in MEMORY.md: **"Edwardsville is PA, not DE"**. Cross-state customers have already received wrong-state footers — incident documented 2026-04-20.

**Root cause:** Template function signature missing `locationState`, OR caller doesn't forward `location.state` from the DB row.

**Before:**
```ts
// In templates.ts
interface BookingEmailData {
  customerName: string
  locationName?: string
  // ... no locationState ...
}
const locationFooter = data.locationName ? `${data.locationName}, DE` : 'Wilmington, DE'
```

**After:**
```ts
interface BookingEmailData {
  customerName: string
  locationName?: string
  locationState?: string  // <-- required for PA vs DE
}
const locationFooter = data.locationName
  ? `${data.locationName}, ${data.locationState || 'DE'}`
  : 'Wilmington, DE'
```

And at every caller that loads a booking:
```ts
const { data: location } = await admin.from('locations').select('name, state').eq('id', booking.location_id).single()
await sendBookingConfirmationEmail({
  // ...
  locationName: location?.name,
  locationState: location?.state,  // <-- must be present
})
```

**Scope limit:** Apply to EVERY template function that renders a footer. Grep first:
```
grep -n "locationFooter\|, DE'\|wrapTemplate" src/lib/email/templates.ts
```
Then check all four templates (booking confirmation, reminder, feedback, win-back). MEMORY.md confirms the fix was already applied — but new templates added after 2026-04-20 may regress.

**Post-fix verification:**
- `grep -n "', DE'" src/lib/email/templates.ts` → only the single fallback literal `'Wilmington, DE'` should remain; no interpolated `\`${name}, DE\`` strings.
- `grep -n "locationState" src/lib/email/templates.ts` → one match per template function.
- `grep -rn "sendBookingConfirmationEmail\|sendReminderEmail" src/app/api/` → every call site passes `locationState: location?.state`.
- `npx tsc --noEmit` → no new errors.

---

## Pattern 7 — Inbound opt-out keyword not recognized

**When:** A customer reply like `UNSUBSCRIBE` or `END` is logged but never inserted into `sms_opt_outs`. Invariant 1 spot-check shows the keyword isn't handled. Incident: "TCPA Opt-Out Compliance".

**Root cause:** `src/app/api/webhooks/twilio/inbound/route.ts` only recognizes a subset (e.g., just `STOP`) and drops the rest.

**Before:**
```ts
if (body.trim().toUpperCase() === 'STOP') {
  await admin.from('sms_opt_outs').insert({ phone: fromPhone, keyword: 'STOP', direction: 'in' })
}
```

**After:**
```ts
const OPT_OUT_KEYWORDS = ['STOP', 'STOPALL', 'UNSUBSCRIBE', 'CANCEL', 'END', 'QUIT']
const normalized = body.trim().toUpperCase()

if (OPT_OUT_KEYWORDS.includes(normalized)) {
  // Idempotent: unique constraint on (phone) — if it exists, skip
  const { data: existing } = await admin
    .from('sms_opt_outs')
    .select('id')
    .eq('phone', fromPhone)
    .maybeSingle()

  if (!existing) {
    await admin.from('sms_opt_outs').insert({
      phone: fromPhone,
      keyword: normalized,
      direction: 'in',
    })
  }
  // Twilio auto-replies to STOP keywords with a confirmation SMS — do NOT send another
  return new NextResponse('<Response></Response>', {
    headers: { 'Content-Type': 'text/xml' },
  })
}
```

**Scope limit:** Do not add a confirmation SMS from app code. Twilio auto-confirms STOP on the number level. Sending a second "you've been unsubscribed" message compounds the TCPA issue.

**Post-fix verification:**
- `grep -n "OPT_OUT_KEYWORDS" src/app/api/webhooks/twilio/inbound/route.ts` → 1 match.
- Re-run invariant 1 SQL after a test opt-out → row with `direction='in'` appears.
- Live probe (deferred): reply `END` from a test phone → confirm row inserted AND no outbound SMS logged.

---

## Pattern 8 — Winback cron re-sends within the same interval

**When:** Invariant 10 (winback_sent uniqueness) returns rows, or customers report "same win-back twice in one month". The cron logic in `src/app/api/cron/winback/route.ts` doesn't check `winback_sent` before dispatching.

**Root cause:** Missing pre-flight query against `winback_sent(client_id, interval_weeks)` before calling `sendMarketingSMS`. The unique constraint catches it on INSERT but the SMS has already gone out.

**Before:**
```ts
for (const client of eligibleClients) {
  await sendMarketingSMS({ to: client.phone, body: message, triggerType: 'winback_6wk' })
  await admin.from('winback_sent').insert({ client_id: client.id, interval_weeks: 6 })
}
```

**After:**
```ts
for (const client of eligibleClients) {
  const { data: alreadySent } = await admin
    .from('winback_sent')
    .select('id')
    .eq('client_id', client.id)
    .eq('interval_weeks', 6)
    .maybeSingle()

  if (alreadySent) continue

  const result = await sendMarketingSMS({
    to: client.phone,
    body: message,
    triggerType: 'winback_6wk',
  })
  if (!result.success) continue  // do NOT record if send failed

  await admin
    .from('winback_sent')
    .insert({ client_id: client.id, interval_weeks: 6 })
    // swallow 23505 uniqueness violations — race with another run
    .then(null, (err) => { if (err?.code !== '23505') throw err })
}
```

**Post-fix verification:**
- `grep -n "winback_sent" src/app/api/cron/winback/route.ts` → SELECT precedes INSERT.
- Re-run invariant 10 SQL → 0 duplicate `(client_id, interval_weeks)` rows.
- `npx tsc --noEmit` → no new errors.

---

## Pattern 9 — Owner alert duplicates on low rating

**When:** Invariant spot-check on `owner_alerts` shows 2+ rows with the same `type='low_rating'` and same `related_id`. See incident "Owner Alert Duplicates".

**Root cause:** Feedback submission triggers alert insert without checking for existing, OR trigger logic fires on UPDATE not just INSERT.

**Before:**
```ts
if (rating < 3) {
  await admin.from('owner_alerts').insert({
    type: 'low_rating',
    title: 'Low rating received',
    message: `${clientName} rated ${rating}/5`,
    related_id: feedbackId,
  })
}
```

**After:**
```ts
if (rating < 3) {
  // Idempotent insert: do nothing if an alert already exists for this feedback
  const { data: existing } = await admin
    .from('owner_alerts')
    .select('id')
    .eq('type', 'low_rating')
    .eq('related_id', feedbackId)
    .maybeSingle()

  if (!existing) {
    await admin.from('owner_alerts').insert({
      type: 'low_rating',
      title: 'Low rating received',
      message: `${clientName} rated ${rating}/5`,
      related_id: feedbackId,
    })
  }
}
```

**Long-term fix (needs user approval):** Add a DB unique constraint `UNIQUE (type, related_id) WHERE related_id IS NOT NULL` on `owner_alerts`. Do NOT apply a migration from this pattern without explicit migration approval — see debugging-protocol.md Section 7.

**Post-fix verification:**
- Re-run: `SELECT type, related_id, COUNT(*) FROM owner_alerts GROUP BY type, related_id HAVING COUNT(*) > 1` → 0 rows.
- `grep -n "owner_alerts" <edited-file>` → SELECT precedes INSERT.

---

## Pattern 10 — Blast `sent_count + failed_count` drift from `recipient_count`

**When:** Invariant 9 returns rows — a completed blast has mismatched counters. Usually caused by early-exit in the sender loop (e.g., a thrown error skips the counter update).

**Root cause:** Blast sender increments counters inside a try block that re-throws before the UPDATE commits, OR the loop breaks on first failure.

**Before:**
```ts
for (const recipient of recipients) {
  const result = await sendMarketingSMS({ to: recipient.phone, body, triggerType: 'blast' })
  if (result.success) sentCount++
  else failedCount++
}
await admin.from('sms_blasts').update({ sent_count: sentCount, failed_count: failedCount, status: 'completed' }).eq('id', blastId)
```

**After:**
```ts
let sentCount = 0
let failedCount = 0

try {
  for (const recipient of recipients) {
    try {
      const result = await sendMarketingSMS({ to: recipient.phone, body, triggerType: 'blast' })
      if (result.success) sentCount++
      else failedCount++
    } catch (err) {
      // Per-recipient failure is a counted failure, not a loop exit
      failedCount++
      console.error('[blast] per-recipient error', recipient.phone, err)
    }
  }
} finally {
  // Counters updated even if the outer block throws
  await admin.from('sms_blasts').update({
    sent_count: sentCount,
    failed_count: failedCount,
    status: 'completed',
  }).eq('id', blastId)
}
```

**Post-fix verification:**
- Re-run invariant 9 SQL after next blast → 0 mismatched rows.
- `grep -n "finally" src/app/api/communications/send-blast/route.ts` → ≥1 match.

---

## Cross-pattern rules

1. **Never write to production DB during verification.** All verification is SELECT-only. No test SMS to real phones. TCPA fines are real.
2. **Always use `mcp__supabase-mt__`** — not `mcp__supabase__` (that's the Maguey project).
3. **Never remove the dev-mode branch in `validate-signature.ts`** (lines 33-49). Local dev needs it. Production safety is enforced by `TWILIO_AUTH_TOKEN` being set.
4. **Never reference n8n** in user-facing text or new code. MT moved to Antigravity; historical env-var names may remain but must not be re-wired.
5. **Always forward `location.state`** on any new email-sending code path. Edwardsville is PA.
6. **Fire-and-forget is not safe here.** Unlike push, SMS failures must be logged — a silently-dropped reminder is a no-show risk and a trust risk. Every sender writes to `sms_logs` with the final status.

---

## When adding a NEW SMS sender or cron

Checklist before opening a PR:
1. Opt-out check via `getClientOptOutStatus` before dispatch? (Pattern 1)
2. Routes through `sendSMS` / `sendMarketingSMS` rather than calling Twilio directly? (Pattern 1)
3. Logged to `sms_logs` on both success and failure paths, including `skipped_opt_out`?
4. If cron: gated by `CRON_SECRET`? (Pattern 3)
5. If cron: sends flag updated AFTER send success, not before? (Pattern 4)
6. If webhook: `validateTwilioWebhook` runs first and gates everything? (Pattern 2)
7. If new email template: `locationState` field in interface + passed by every caller? (Pattern 6)
8. Antigravity reviewed — is this new automation a better fit for an Antigravity workflow than inline code? (Per MEMORY.md, prefer Antigravity for new automations.)

If any answer is "no," stop and fix before shipping. Handoff to `bulletproof-ship` only when all boxes tick.
