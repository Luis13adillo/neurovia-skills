# Auth Scale Anti-Patterns

Report-only. Run in `scale-check` mode.

---

## 1. Role enum expansion readiness

Current roles: `owner`, `barber`, `student`, `client`.

If adding a new role (`manager`, `trainee`, `instructor`, etc.):

### DB
- `profiles.role` is VARCHAR — no schema change needed.
- But: verify there's no CHECK constraint limiting the enum:
```sql
SELECT conname, pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conrelid = 'profiles'::regclass
  AND contype = 'c';
```

### Code
- `src/lib/auth/context.tsx` — add to `UserRole` TypeScript union.
- `src/middleware.ts` — add route mapping for the new role (otherwise defaults to `/profile` or similar).
- Booleans like `isOwner`, `isBarber`, `isClient` — add `isManager` etc. to context.

### Recommendation for scale
Move role strings to a constants file:
```ts
// src/lib/constants/roles.ts
export const ROLES = { OWNER: 'owner', BARBER: 'barber', ... } as const
```
Flag this as a refactor candidate.

---

## 2. Hardcoded role strings

```bash
grep -rEn "=== ?'owner'|=== ?\"owner\"|=== ?'barber'|=== ?\"barber\"|=== ?'student'|=== ?\"student\"|=== ?'client'|=== ?\"client\"" src/
```

Every match is a site-of-change when roles expand. Recommend constants refactor.

---

## 3. Middleware routing strategy

- File: `src/middleware.ts`
- Current: if/else chain for each role's home page. Works for 4 roles.
- At N=10 roles, consider a route map:
```ts
const ROLE_HOME: Record<UserRole, string> = {
  owner: '/dashboard',
  barber: '/barber',
  student: '/student',
  client: '/profile',
}
```
Cleaner; flag as refactor before adding more roles.

---

## 4. `active_sessions` cleanup cron

Sessions accumulate. Even with invalidation on login, a barber who doesn't log out explicitly may leave stale rows.

Verify cleanup is running:
```sql
SELECT COUNT(*) FILTER (WHERE expires_at < now()) AS stale,
       COUNT(*) FILTER (WHERE expires_at >= now()) AS active,
       MAX(created_at) AS latest_session,
       MIN(created_at) AS oldest_session
FROM active_sessions;
```

If `stale > active`, cleanup isn't firing. Flag.

---

## 5. `auth_events` growth

At ~5 logins/barber/day × 100 barbers = 500 events/day ≈ 180k rows/year.

Current performance OK. At 10k barbers, consider:
- Partitioning by month
- Archival policy (events older than 1 year → cold storage)

Query for volume:
```sql
SELECT DATE_TRUNC('month', created_at) AS month, COUNT(*) AS events
FROM auth_events
WHERE created_at > now() - interval '6 months'
GROUP BY month
ORDER BY month;
```

---

## 6. Barber invite email sender identity

As locations scale, barbers may want invites to appear "from" their location-specific support email.

- File: `src/app/api/auth/create-barber/route.ts`
- Currently uses a global `RESEND_FROM_EMAIL`. Adding per-location senders requires either a DNS setup per domain OR a single inbox with clear location branding in subject.
- Flag as a decision point, not a bug.

---

## 7. Lockout window vs distributed brute force

Current: 10 attempts / 5-minute lock per email.

Weakness at scale:
- Attacker can cycle through many emails (different accounts) at a slow pace.
- Per-IP lockout doesn't exist.
- Consider adding rate limiting by IP via `src/lib/rate-limit/` if abuse is observed.

---

## 8. Staff/Client session collision

Both sessions coexist in the same browser. This is by design but can surprise users at scale:
- A staff member who is also a client can be logged into both simultaneously.
- Logging out of one does NOT log out of the other.

Document this behavior clearly for support. Not a code fix — a UX/docs concern.

---

## 9. Session keepalive load

- Endpoint: `/api/auth/session/keepalive`
- Called periodically by client to extend `last_active`.
- At 100 barbers × keepalive every 5 min = 12 calls/barber/hour = 1200 DB writes/hour.

Scale concerns appear at ~1000 barbers. Monitor. Flag if frequency becomes an issue.

---

## 10. Test account isolation guarantee

Critical for scale. Every new production feature must NOT accidentally surface test barbers.

Run after any new public-facing barber query:
```sql
SELECT id, is_active
FROM barbers
WHERE id LIKE 'b00%' OR id = 'a274e1cf-955a-46f1-bc4c-dcd06a0510af';
-- Expected: all is_active = false (except dev owner if actively testing)
```

Verify all public queries filter `is_active = true`. This is the line of defense that keeps test data out of customer-facing UIs.

---

## Output verdict template

```
## Auth Scale Readiness

### Ready
- [green items]

### Must fix / decide before adding role N+1 or barber count 10x
1. [item + reason]

### Recommended (not blocking)
- [suggestions — ROLES constant, route map refactor, session partitioning]

### Verdict
[READY / BLOCKED BY N ITEMS]
```
