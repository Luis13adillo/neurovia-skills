# Auth — Known Incidents & Fix Patterns

---

## Incident: User logs in but gets kicked out immediately / redirect loop
**Symptom:** User enters credentials, sees dashboard for a second, then redirected back to login.
**Root cause options:**
1. `ProtectedRoute` runs before AuthContext finishes loading user → renders `Unauthorized` on first paint
2. Role fetch timing race: session exists but user_metadata not yet populated
3. Stale JWT in localStorage — user logged out server-side but client still has token

**Fix pattern:**
- AuthContext should expose `loading` state
- ProtectedRoute checks `if (loading) return <Spinner />` before checking role
- Grep: `grep -n "loading\|isLoading" src/contexts/AuthContext.tsx src/components/ProtectedRoute.tsx`

---

## Incident: Customer hits /auth/owner on pass-lounge, gets organizer login
**Symptom:** Confusion — customer used wrong link and saw staff-looking login page.
**Root cause:** Pass-lounge has `/auth/owner` for organizers (event organizers, not Maguey staff). Different from gate-scanner's `/auth/owner` (Maguey owners).
**Fix:** visual differentiation — add branding/labels that clearly say "Organizer Portal" (pass-lounge) vs "Maguey Owner Dashboard" (scanner). Current state: similar-looking pages cause confusion.

---

## Incident: Role change not effective until logout/login
**Symptom:** Owner promotes an employee to promoter. Employee doesn't see new permissions until they log out and back in.
**Root cause:** `user_metadata` is cached in the JWT. Token refresh (every ~1h) pulls fresh metadata, but until then stale role persists.
**Fix options:**
1. After role change, call `supabase.auth.admin.updateUserById()` then send a server-sent signal to force re-login (complex)
2. Document: "Role changes take effect on next login or within 1 hour"
3. Implement client-side `refreshSession()` button in staff management UI

---

## Incident: Magic link not working
**Symptom:** User clicks magic link email, sees "invalid or expired" error.
**Root cause options:**
1. Link expired (default 1 hour TTL)
2. Email client pre-fetched the link (Outlook, some webmail), consuming it before user clicked
3. Supabase `redirect_to` URL mismatch with allowed redirects in Supabase Dashboard → Auth settings

**Fix:**
- Extend magic link TTL in Supabase Dashboard
- Add `?redirect_to=<origin>` param and whitelist in Dashboard
- For pre-fetch issue: use OTP codes instead of direct links (requires auth flow rewrite)

---

## Incident: Dev-mode localStorage auth leaked to production
**Symptom:** Opening production site on a test device, staff sees a fake user logged in without entering credentials.
**Root cause:** `import.meta.env.DEV` guard missing on the localStorage auth branch — OR Vite build mode wasn't set correctly.
**Debug:**
- View production JS bundle (Sources tab) → search for `maguey_user` or `localStorageService` — should NOT appear in prod bundle (Vite strips DEV-gated code)
- If it appears, the guard is missing or placed wrong

**Fix:** ensure every `localStorageService` call is wrapped:
```typescript
if (import.meta.env.DEV) {
  const mockUser = localStorageService.getUser();
  // ...
}
```

---

## Incident: RLS blocks legitimate staff query
**Symptom:** Scanner staff can't view all orders on dashboard despite owner role.
**Root cause:** RLS policy check is `current_setting('request.jwt.claims', true)::json->>'role' = 'admin'` but Maguey's roles are owner/promoter/employee. `admin` is a MT-Barbershop-era leftover.
**Fix (requires migration approval):** update RLS policy to reference actual Maguey roles:
```sql
CREATE POLICY "Staff can view orders"
ON orders FOR SELECT
USING (
  auth.role() = 'service_role'
  OR current_setting('request.jwt.claims', true)::json->>'role' IN ('owner', 'promoter')
);
```

---

## Incident: Idle timeout fires during a real event
**Symptom:** Scanner staff mid-event suddenly logged out, panic ensues.
**Root cause:** `useIdleTimeout` activity listeners not catching camera activity (QR scan doesn't fire mousemove/keydown).
**Fix:** add a custom activity reset when scanner records a scan:
```typescript
const onScanSuccess = () => {
  resetIdleTimer();
  // ... existing scan logic
};
```
Or increase idle timeout to event duration for scanner accounts.

---

## Incident: Anonymous user can't create order (RLS blocks)
**Symptom:** Guest checkout returns 403 on INSERT to orders or tickets.
**Root cause:** `20250115000003_fix_rls_for_public_purchases.sql` granted anon INSERT, but a newer migration may have tightened it.
**Debug:**
```sql
SELECT * FROM pg_policies WHERE tablename IN ('orders', 'tickets') ORDER BY policyname;
```
Must include anon INSERT policies. If missing, restore.

---

## Incident: OAuth callback loops on pass-lounge
**Symptom:** User clicks "Sign in with Google", redirects to Google, returns to Maguey, redirects to Google again.
**Root cause:** Supabase Dashboard → Auth → URL Configuration — `Site URL` doesn't match the actual site, OR the redirect URL isn't in the allowlist.
**Fix:** Supabase Dashboard → Authentication → URL Configuration:
- Site URL: `https://tickets.magueynightclub.com`
- Redirect URLs: add `https://tickets.magueynightclub.com/**` and `http://localhost:3016/**` for dev

---

## Incident: Stripe keys in test mode after going live
**Symptom:** Customer clicks "Checkout", Stripe page says "Test mode" in big red banner.
**Root cause:** `VITE_STRIPE_PUBLISHABLE_KEY` on Vercel still `pk_test_*` after switching secret key.
**Fix:** update Vercel env var → `pk_live_*` → redeploy pass-lounge. Coordinate with Supabase Edge Function `STRIPE_SECRET_KEY` to avoid publishable/secret mismatch (see `maguey-bulletproof-payments`).

---

## Pattern: Mixing role systems across apps
If code in scanner tries to read `account_type` or pass-lounge tries to read `role`, subtle auth bugs appear:
- User gains unexpected access (field is null, defaults kick in wrong way)
- Page shows as "no access" despite correct role

**Fix:** always use the app-local `src/lib/auth.ts` helpers. Never directly access `user.user_metadata.X` in components.
