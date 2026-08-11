# Auth Invariants

All SQL is SELECT-only. Run via `mcp__supabase-mt__execute_sql`.

---

## Data-level

### 1. Every profile has a valid role [CRITICAL]
```sql
SELECT id, email, role
FROM profiles
WHERE role IS NULL
   OR role NOT IN ('owner', 'barber', 'student', 'client');
-- Expected: 0 rows
```

### 2. Every barber row has matching profile with role='barber' or 'owner' [CRITICAL]
```sql
SELECT b.id AS barber_id, b.profile_id, p.role
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE p.id IS NULL
   OR p.role NOT IN ('barber', 'owner');
-- Expected: 0 rows
```

### 3. Every auth.users user has a matching profile [HIGH]
```sql
SELECT u.id, u.email
FROM auth.users u
LEFT JOIN profiles p ON p.id = u.id
WHERE p.id IS NULL;
-- Expected: 0 rows (every auth user should have been given a profile row)
```

### 4. Owner account exists and is linked to barbers [CRITICAL]
```sql
SELECT p.id, p.email, p.role, b.id AS barber_id, b.is_active
FROM profiles p
LEFT JOIN barbers b ON b.profile_id = p.id
WHERE p.email = 'info@mtbarbershop.com';
-- Expected: 1 row, role='owner', linked to barbers.id = 'b0010000...'
```

### 5. Dev owner exists and is linked to barbers [HIGH]
```sql
SELECT p.id, p.email, p.role, b.id AS barber_id
FROM profiles p
LEFT JOIN barbers b ON b.profile_id = p.id
WHERE p.email = 'dev@mtbarbershop.com';
-- Expected: 1 row, role='owner', linked to barbers.id = 'a274e1cf-955a-46f1-bc4c-dcd06a0510af'
```

### 6. Test barber accounts are correctly inactive [HIGH]
```sql
SELECT b.id, b.is_active, p.email, p.role
FROM barbers b
JOIN profiles p ON p.id = b.profile_id
WHERE b.id IN (
  'b0020000-0000-0000-0000-000000000002',
  'b0030000-0000-0000-0000-000000000003',
  'b0040000-0000-0000-0000-000000000004'
);
-- Expected: 3 rows, all is_active=false, role='barber'
```

### 7. No duplicate emails in profiles [CRITICAL]
```sql
SELECT email, COUNT(*) AS n
FROM profiles
WHERE email IS NOT NULL
GROUP BY email
HAVING COUNT(*) > 1;
-- Expected: 0 rows
```

### 8. auth_lockouts.locked_until is future-tense or null [HIGH]
```sql
-- Currently locked accounts should have locked_until > now
-- Expired locks should be cleared (either deleted or locked_until = NULL)
SELECT id, profile_id, failed_attempts, locked_until, locked_at
FROM auth_lockouts
WHERE locked_until < now() - interval '1 hour';
-- Expected: few rows (old locks not cleaned), not a bug per se but hygiene signal
```

### 9. Active sessions not expired [MEDIUM]
```sql
SELECT COUNT(*) AS stale_sessions
FROM active_sessions
WHERE expires_at < now();
-- Expected: 0 (cleanup cron should remove these)
```

### 10. Single active session per barber (concurrent login enforcement) [HIGH]
```sql
SELECT profile_id, COUNT(*) AS active_count
FROM active_sessions
WHERE expires_at > now()
GROUP BY profile_id
HAVING COUNT(*) > 1;
-- Expected: 0 rows (or only owner profile may legitimately have multi)
```

### 11. auth_events event_type values in expected set [MEDIUM]
```sql
SELECT event_type, COUNT(*) AS n
FROM auth_events
WHERE created_at > now() - interval '30 days'
GROUP BY event_type
ORDER BY n DESC;
-- Expected: subset of login_success, login_failed, password_reset_requested,
--           password_changed, email_verified, lockout, unlock, force_logout,
--           session_expired
```

### 12. barber first_login_completed coherence [MEDIUM]
```sql
-- Barbers with first_login_completed = true should have at least one auth_event
SELECT p.id, p.email, p.first_login_completed,
       COUNT(ae.id) AS login_events
FROM profiles p
LEFT JOIN auth_events ae ON ae.profile_id = p.id AND ae.event_type = 'login_success'
WHERE p.role = 'barber'
  AND p.first_login_completed = true
GROUP BY p.id, p.email, p.first_login_completed
HAVING COUNT(ae.id) = 0;
-- Expected: 0 rows (or very few edge cases)
```

### 13. Grace period dates are reasonable [LOW]
```sql
SELECT id, slug, grace_period_ends_at
FROM barbers
WHERE grace_period_ends_at < '2025-01-01'
   OR grace_period_ends_at > now() + interval '1 year';
-- Expected: 0 rows (grace should be within a year of creation)
-- Exception: test barbers may have sentinel dates like 2025-01-01
```

---

## Code-level

### C1. 3-tier role resolution intact [CRITICAL]
- File: `src/middleware.ts` lines 19-67.
- Cookie cache includes user-ID prefix: `${user.id}:${role}`.
- Tier order: cookie (with user-ID check) → JWT metadata → profiles query.

### C2. Service role key server-only [CRITICAL]
```bash
grep -rn "NEXT_PUBLIC_SUPABASE_SERVICE_ROLE" src/
```
Expected: 0 matches.

```bash
grep -rn "SUPABASE_SERVICE_ROLE_KEY" src/
```
Expected: matches in server files only; no `'use client'` file contains this.

### C3. No dev mock / bypass in auth [CRITICAL]
```bash
grep -rEn "NODE_ENV.*development.*(bypass|mock|skip.*auth)" src/app/api/auth/ src/middleware.ts
```
Expected: 0 matches (removed 2026-03-05).

### C4. Lockout check before password validation [HIGH]
- File: `src/app/api/auth/login/route.ts`
- Flow order: `checkLockout` → `signInWithPassword` → (on fail) `incrementFailedAttempts` / (on success) `resetLockout`.

### C5. HMAC client session isolation [HIGH]
- File: `src/lib/auth/client-session.ts`
- Cookie: `mt-client-session`. Separate from Supabase cookies.
- Uses `timingSafeEqual` for signature verification.

### C6. Admin client NOT used for user fetches [CRITICAL]
- File: `src/lib/supabase/admin.ts`
- Comments/guards should indicate admin client is for admin ops only.
- `grep -rn "createAdminClient" src/app/api/` — each match must be for bypass-RLS admin operations.

### C7. Supabase clients wrap fetch with `cache: 'no-store'` [CRITICAL]
- Files: `src/lib/supabase/admin.ts`, `src/lib/supabase/server.ts`.
- Shared rule with bulletproof-queue.

### C8. Concurrent login invalidation [HIGH]
- File: `src/app/api/auth/login/route.ts`
- After successful login, calls `invalidateOldSessions(profileId, newSessionToken)`.

### C9. Barber invite flow integrity [HIGH]
- File: `src/app/api/auth/create-barber/route.ts`
- Owner-only gate (role check).
- 8-step cascade: auth user → profile → barber → schedules → staff_status → magic link → email → response with `invite_url` fallback.

### C10. Hardcoded role strings [MEDIUM]
- `grep -rEn "=== ?'owner'|=== ?\"owner\"" src/` — should be limited, ideally using a ROLES constant.
