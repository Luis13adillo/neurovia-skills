# Auth — Fix Patterns

Paste-ready diffs for each documented incident or invariant violation. When audit/diagnose flags a failure, point to the pattern number here and apply the diff. Every pattern below is traceable to `incidents.md` or `invariants.md` — do not add patterns without real source material.

All patterns assume:
- `createClient` imported from `@/lib/supabase/server` (user client — RLS-aware)
- `createAdminClient` imported from `@/lib/supabase/admin` (service role — bypasses RLS)
- Supabase SQL run via `mcp__supabase-mt__execute_sql` only (never `mcp__supabase__`)
- Test writes forbidden — audit via SELECT only unless the user explicitly authorizes writes

---

## Fix-mode preflight checklist (universal — applies to every pattern)

Run this sequence for every pattern before the Edit. Do all steps, in order. Skip none.

1. **Preflight** — Read the target file. Match the pattern's "Before" block against the current code exactly (imports, function names, variable names, surrounding context — NOT just line numbers, which drift). If anything does not match → STOP. Report what differs. Do NOT apply a stale pattern.
2. **Classify** — Query the relevant data-level invariant from `invariants.md` (e.g. Invariant 7 for duplicate emails, Invariant 10 for concurrent sessions). Report whether the bug is LIVE (rows affected > 0) or LATENT (pattern is wrong but no data is currently broken). User decides urgency from this.
3. **Confirm diff** — Show exact `old_string` / `new_string`. Wait for explicit `yes`.
4. **Apply** — Single `Edit` call. One pattern per invocation.
5. **Verify** — Run the pattern's post-fix verification (grep + `npx tsc --noEmit`, plus SQL if live). Every check must pass.
6. **Mirror** — Auth changes rarely need dashboard mirroring, but if the change touches `useAuth` consumers on a barber/owner page, invoke `mirror-check` before handoff.
7. **Handoff** — Stop at `bulletproof-ship`. Do not commit.

If any step fails, stop and report. Do not proceed to the next step.

---

## Pattern 1 — Admin client used for user fetches (session pollution)

**When:** `createAdminClient()` is used to call `auth.getUser()` or any user-scoped query. Per `incidents.md` → "Admin Client Session Pollution (2026-03-06)" [CRITICAL] and `invariants.md` C6.

**Symptom:** Intermittent test failures. `auth.getUser()` returns stale or wrong user under concurrency because the service role client has no per-request session state.

**Before**
```ts
// /src/app/api/some-route/route.ts
import { createAdminClient } from '@/lib/supabase/admin'

export async function GET(request: NextRequest) {
  const admin = createAdminClient()
  const { data: { user } } = await admin.auth.getUser() // WRONG — service role has no session
  if (!user) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })

  const { data: profile } = await admin
    .from('profiles')
    .select('role')
    .eq('id', user.id)
    .single()
  // ... rest
}
```

**After**
```ts
import { createClient } from '@/lib/supabase/server'
import { createAdminClient } from '@/lib/supabase/admin'

export async function GET(request: NextRequest) {
  const supabase = await createClient() // user client — reads cookie-bound session
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })

  // Use user client for user-scoped reads (RLS applies)
  const { data: profile } = await supabase
    .from('profiles')
    .select('role')
    .eq('id', user.id)
    .single()

  // Only swap to admin client for operations that MUST bypass RLS
  // (e.g. owner writing to another user's row, cron cleanup, etc.)
  if (profile?.role === 'owner') {
    const admin = createAdminClient()
    // ... explicit admin op here
  }
}
```

**Post-fix verification**
```bash
grep -rn "createAdminClient" src/app/api/
# Each hit must be justified (bypassing RLS for a specific admin op, cron, or webhook).
# Any hit that calls `.auth.getUser()` on the admin client is a regression.

grep -rn "admin\.auth\.getUser\|adminClient\.auth\.getUser" src/
# Expected: 0 matches.
```

---

## Pattern 2 — Cookie cache cross-user pollution (missing user-ID prefix)

**When:** `src/middleware.ts` `getUserRole()` trusts `mt-user-role` cookie without validating it belongs to the current `user.id`. Per `incidents.md` → "Cookie Cache Cross-User Pollution" and `invariants.md` C1 [CRITICAL].

**Symptom:** User A logs out, User B logs in on same device → briefly routed to A's dashboard before middleware corrects.

**Before**
```ts
// src/middleware.ts — getUserRole()
const cachedValue = request.cookies.get('mt-user-role')?.value
if (cachedValue) {
  return cachedValue as UserRole // WRONG — no user-ID check
}

// ... later, on fresh read:
response.cookies.set('mt-user-role', role, { ... }) // WRONG — no user-ID prefix
```

**After**
```ts
// src/middleware.ts — getUserRole()
const cachedValue = request.cookies.get('mt-user-role')?.value
if (cachedValue) {
  const [cachedUserId, cachedRole] = cachedValue.split(':')
  if (cachedUserId === user.id && cachedRole) {
    return cachedRole as UserRole
  }
  // Cached value belongs to a different user — ignore it, fall through to JWT/DB.
}

// ... later, on fresh read:
response.cookies.set('mt-user-role', `${user.id}:${role}`, {
  httpOnly: true,
  secure: true,
  sameSite: 'lax',
  maxAge: 60 * 60, // 1 hour
})
```

**Post-fix verification**
```bash
grep -n "mt-user-role" src/middleware.ts
# Expected: cookie value is `${user.id}:${role}` on SET, and SPLIT on `:` + compared to user.id on READ.

grep -n "cachedUserId === user.id" src/middleware.ts
# Expected: ≥1 match (the guard).
```

---

## Pattern 3 — Lockout check runs AFTER password attempt

**When:** `src/app/api/auth/login/route.ts` calls `signInWithPassword` before checking `auth_lockouts`. Per `incidents.md` → "Lockout Misfires" and `invariants.md` C4 [HIGH].

**Symptom:** User with correct password gets "account locked" because a prior failed attempt ran up the counter AFTER their successful login attempt was processed.

**Before**
```ts
// src/app/api/auth/login/route.ts
export async function POST(request: NextRequest) {
  const { email, password } = await request.json()
  const supabase = await createClient()

  const { data, error } = await supabase.auth.signInWithPassword({ email, password })

  if (error) {
    await incrementFailedAttempts(email) // WRONG — runs before lockout check
    return NextResponse.json({ error: error.message }, { status: 401 })
  }
  // ... success path
}
```

**After**
```ts
import { checkLockout, incrementFailedAttempts, resetLockout } from '@/lib/auth/lockout'
import { invalidateOldSessions } from '@/lib/auth/session-tracker'

export async function POST(request: NextRequest) {
  const { email, password } = await request.json()

  // 1. Lockout check FIRST — locked accounts do not get to attempt password
  const lockout = await checkLockout(email)
  if (lockout.locked) {
    return NextResponse.json(
      { error: 'Account temporarily locked. Try again later.' },
      { status: 429 }
    )
  }

  // 2. Attempt password
  const supabase = await createClient()
  const { data, error } = await supabase.auth.signInWithPassword({ email, password })

  if (error) {
    await incrementFailedAttempts(email)
    return NextResponse.json({ error: 'Invalid credentials' }, { status: 401 })
  }

  // 3. Success → reset lockout + invalidate old sessions
  await resetLockout(data.user.id)
  await invalidateOldSessions(data.user.id, data.session.access_token)

  return NextResponse.json({ user: data.user })
}
```

**Post-fix verification**
```bash
grep -n "checkLockout\|signInWithPassword\|resetLockout\|invalidateOldSessions" src/app/api/auth/login/route.ts
# Expected order in output: checkLockout → signInWithPassword → resetLockout + invalidateOldSessions
```

```sql
-- invariants.md #8 — locked-until hygiene
SELECT id, profile_id, failed_attempts, locked_until
FROM auth_lockouts
WHERE locked_until < now() - interval '1 hour';
-- After fix + cleanup cron, should trend to 0.
```

---

## Pattern 4 — Concurrent login invalidation missing

**When:** Successful login does not call `invalidateOldSessions`. Per `incidents.md` → "Concurrent Login Modal Keeps Popping" and `invariants.md` C8 + data invariant 10 [HIGH].

**Symptom:** Multiple `active_sessions` rows per profile; modal loops; every new login kicks prior device (expected) but prior rows never cleaned.

**Before**
```ts
// src/app/api/auth/login/route.ts — after signInWithPassword success
await resetLockout(data.user.id)
await logAuthEvent('login_success', data.user.id)
// Missing: invalidateOldSessions
```

**After**
```ts
await resetLockout(data.user.id)
await invalidateOldSessions(data.user.id, data.session.access_token)
await logAuthEvent('login_success', data.user.id)
```

**Post-fix verification**
```bash
grep -n "invalidateOldSessions" src/app/api/auth/login/route.ts
# Expected: ≥1 match directly after the signInWithPassword success branch.
```

```sql
-- invariants.md #10 — single active session per profile
SELECT profile_id, COUNT(*) AS active_count
FROM active_sessions
WHERE expires_at > now()
GROUP BY profile_id
HAVING COUNT(*) > 1;
-- Expected: 0 rows after a cycle of logins post-fix.
```

---

## Pattern 5 — Supabase client missing `cache: 'no-store'` wrapper

**When:** A Supabase client factory does not wrap `global.fetch` with `cache: 'no-store'`. Per `invariants.md` C7 [CRITICAL]. Shared rule with `bulletproof-queue`.

**Symptom:** Stale auth data between middleware check and API route DB query. Next.js 14 Data Cache caches `fetch()` by default, and the Supabase JS client uses `fetch()` internally.

**Before**
```ts
// src/lib/supabase/admin.ts
import { createClient } from '@supabase/supabase-js'

export function createAdminClient() {
  return createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    {
      auth: { persistSession: false, autoRefreshToken: false },
    }
  )
}
```

**After**
```ts
import { createClient } from '@supabase/supabase-js'

export function createAdminClient() {
  return createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    {
      auth: { persistSession: false, autoRefreshToken: false },
      global: {
        fetch: (url, options) =>
          fetch(url, { ...options, cache: 'no-store' }),
      },
    }
  )
}
```

**Post-fix verification**
```bash
grep -n "cache: 'no-store'" src/lib/supabase/admin.ts src/lib/supabase/server.ts
# Expected: ≥1 match in each file.

grep -rn "createClient(" src/app/api/ | grep -v "from '@/lib/supabase"
# Any inline Supabase client created in an API route MUST also include the cache wrapper.
# Flag every hit for review.
```

---

## Pattern 6 — Dev mock / bypass regression in auth

**When:** A `NODE_ENV === 'development'` branch in auth code bypasses password, role check, or lockout. Per `incidents.md` → "Dev Mock / Bypass Removal (2026-03-05)" and `invariants.md` C3 [CRITICAL].

**Symptom:** Auth behaves differently in dev vs prod. Real passwords accepted without checking Supabase, or role returned without DB lookup.

**Before**
```ts
// src/app/api/auth/login/route.ts (regression example)
if (process.env.NODE_ENV === 'development' && email === 'dev@mtbarbershop.com') {
  return NextResponse.json({ user: MOCK_DEV_USER }) // REMOVED 2026-03-05 — never reintroduce
}
```

**After**
```ts
// No branch. Dev owner uses the real account (dev@mtbarbershop.com / MTBarbershop2026)
// with real Supabase auth. See CLAUDE.md Test Accounts section.
```

**Post-fix verification**
```bash
grep -rEn "NODE_ENV.*development.*(bypass|mock|skip.*auth)" src/app/api/auth/ src/middleware.ts src/lib/auth/
# Expected: 0 matches.

grep -rn "MOCK_USER\|MOCK_DEV_USER\|mockAuth\|devBypass" src/
# Expected: 0 matches in production auth paths.
```

---

## Pattern 7 — Missing `is_active = true` filter leaks test barbers to public

**When:** A public-facing query (team page, booking flow, public profile, walk-in queue) fetches barbers without filtering `is_active`. Per `incidents.md` → "Test Barber Leaks Into Production Views" and `invariants.md` data invariant 6 [HIGH].

**Symptom:** Test barbers (`b0020000…`, `b0030000…`, `b0040000…`) appear on `/team`, `/book`, or `/queue`.

**Before**
```ts
// Example: public team page query
const { data: barbers } = await supabase
  .from('barbers')
  .select('id, slug, profile:profiles(first_name, last_name, avatar_url)')
  .order('chair_number')
// WRONG — no is_active filter; test barbers leak
```

**After**
```ts
const { data: barbers } = await supabase
  .from('barbers')
  .select('id, slug, profile:profiles(first_name, last_name, avatar_url)')
  .eq('is_active', true)
  .order('chair_number')
```

**Post-fix verification**
```bash
grep -rn "from('barbers')" src/app/(public)/ src/components/
# Every public-facing query must include `.eq('is_active', true)`.
```

```sql
-- invariants.md #6 — test barber accounts inactive
SELECT b.id, b.is_active, p.email
FROM barbers b
JOIN profiles p ON p.id = b.profile_id
WHERE b.id IN (
  'b0020000-0000-0000-0000-000000000002',
  'b0030000-0000-0000-0000-000000000003',
  'b0040000-0000-0000-0000-000000000004'
);
-- Expected: 3 rows, all is_active=false. If any is true → flip it via the owner dashboard.
```

---

## Pattern 8 — Barber invite cascade missing fallback `invite_url`

**When:** `src/app/api/auth/create-barber/route.ts` does not return the magic link in the response, so when Resend fails the owner has no way to deliver the invite manually. Per `incidents.md` → "Barber Invite Email Never Arrived" and `invariants.md` C9 [HIGH].

**Symptom:** Owner clicks "Add Barber", response is `{ success: true }`, barber never gets the email, owner has no recovery path.

**Before**
```ts
// src/app/api/auth/create-barber/route.ts
await sendBarberInviteEmail(email, magicLink)
return NextResponse.json({ success: true, barberId: barber.id })
// WRONG — no email_sent flag, no invite_url fallback
```

**After**
```ts
let emailSent = false
try {
  await sendBarberInviteEmail(email, magicLink)
  emailSent = true
} catch (err) {
  console.error('[create-barber] Resend send failed', err)
}

return NextResponse.json({
  success: true,
  barberId: barber.id,
  email_sent: emailSent,
  invite_url: emailSent ? undefined : magicLink, // fallback for owner to copy/send manually
})
```

**Post-fix verification**
```bash
grep -n "email_sent\|invite_url" src/app/api/auth/create-barber/route.ts
# Expected: ≥2 matches (the flag + the fallback URL).
```

```sql
-- Sanity check — new barber got the full cascade
SELECT
  p.id, p.email, p.role,
  b.id AS barber_id, b.is_active, b.onboarding_step,
  (SELECT COUNT(*) FROM barber_schedules WHERE barber_id = b.id) AS schedule_rows,
  (SELECT COUNT(*) FROM staff_status WHERE barber_id = b.id) AS staff_status_rows
FROM profiles p
JOIN barbers b ON b.profile_id = p.id
WHERE p.email = '<new barber email>';
-- Expected: 1 row, role='barber', schedule_rows=7 (one per day), staff_status_rows=1.
```

---

## Cross-pattern rules

1. **Never log raw passwords, service role keys, or session tokens.** Redact or hash before logging.
2. **Never use admin client for `auth.getUser()`.** Pattern 1 is absolute — if you need the current user, use the user client.
3. **Never skip the lockout check.** 10 attempts / 5 min is the rule. No exceptions per environment.
4. **Never add dev bypass branches to auth code.** Dev owner uses real auth with a real account.
5. **Always wrap Supabase fetch with `cache: 'no-store'`.** Applies to every client factory and every inline client.
6. **Always filter `is_active = true` on public barber queries.** Test barbers are inactive by design.

---

## When adding a NEW auth-adjacent route

Checklist:
1. Uses `createClient()` (user client) for `auth.getUser()` — not admin client (Pattern 1)?
2. Role check via profiles table after `getUser()` (Pattern 1 flow)?
3. Cache `no-store` wrapper present on any inline Supabase client (Pattern 5)?
4. No dev bypass branches (Pattern 6)?
5. If it touches lockout/session state, order of ops matches Patterns 3 + 4?
6. If it exposes barber data publicly, `is_active = true` filter present (Pattern 7)?

If any of these is "no," stop and fix before handoff to `bulletproof-ship`.
