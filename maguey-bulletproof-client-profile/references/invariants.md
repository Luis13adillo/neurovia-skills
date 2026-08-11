# Client Profile — Invariants

## Profile Table
1. `profiles.id` FK to `auth.users.id` with ON DELETE CASCADE — no orphan profiles.
2. `profiles.referral_code` UNIQUE.
3. `profiles.updated_at` auto-maintained by trigger on every UPDATE.
4. Row exists iff user signed up (created via trigger or first login hook).

## Profile Write Flow
5. All profile writes from app code go through `useAuthProfile.updateProfile()` — NOT direct `supabase.from('profiles')` calls in components.
6. `auth.users.user_metadata` is kept in sync with `profiles.first_name / last_name` BY the same hook.
7. **GAP:** those two writes are NOT transactional — drift is possible. Invariant #12 (audit query) catches it.

## Avatar
8. Uploads go to `avatars/{user.id}/{timestamp}.{ext}` bucket.
9. Max size: 5MB. Formats: image/*.
10. Cropping + resize to 400px + JPEG 90% done client-side before upload.
11. `profiles.avatar_url` stores public URL.
12. **GAP:** old avatar files are not deleted on replace — orphan bloat over time.

## 2FA
13. When `profiles.two_factor_enabled = true`, both `two_factor_secret` AND `backup_codes` are populated.
14. **GAP:** `two_factor_secret` is stored plaintext. Should be encrypted (Supabase Vault or KMS).
15. **GAP:** `backup_codes` stored as plaintext TEXT[]. Should be bcrypt/argon2 hashes.
16. **CRITICAL GAP:** `verify2FA(code)` ONLY checks against backup_codes. TOTP from authenticator app is NOT validated against the secret. Effectively: any valid backup code unlocks 2FA.
17. No rate limiting on verification attempts — 6-digit brute-forceable.

## Email Verification
18. `auth.users.email_confirmed_at` is the source of truth.
19. **GAP:** `VerifyEmail.tsx` only reads this column — does not server-side validate a consumed token. Manual DB edits bypass.
20. Email change triggers Supabase Auth verification link; user clicks → email swapped.

## Session & Device
21. `user_devices` stores WebAuthn credentials (public_key, credential_id UNIQUE).
22. `is_trusted` flag gates biometric login.
23. `login_activity` records every login attempt (success + failure, IP, user_agent, method).
24. Retention: no automatic purge — review periodically.

## Ticket History
25. `user-tickets.ts` queries `tickets` table directly (bypassing orders RLS by design).
26. Filter: `attendee_email = <JWT email>` — RLS-enforced.
27. Join: events (name/date), ticket_types (category).
28. Sort: `issued_at` DESC.
29. **GAP:** no `status != 'refunded'` filter — refunded tickets leak into upcoming list.
30. No pagination — loads all tickets for user.

## Ticket Transfer
31. `transferTicket` Edge Function: regenerates QR (new token + signature), issues new ticket to recipient, invalidates old.
32. Transfer email enqueued for both parties (email_type: ticket_transfer_sent / ticket_transfer_received).
33. **GAP:** client removes ticket from local state BEFORE server confirms. Race on network failure.

## Loyalty
34. `user_loyalty` keyed by EITHER user_id OR email (supports guest checkout pre-signup).
35. UNIQUE(user_id) and UNIQUE(email) — 1:1 mapping per identity.
36. Tier trigger recalculates `membership_tier` on `total_spent` change.
37. Tier bands (verify in migration): bronze < $500 < silver < $2000 < gold < $5000 < platinum. (Adjust audit query #4 to match actual thresholds.)

## Referrals
38. UNIQUE(referrer_id, referee_id) — one reward pair per user combo.
39. `reward_status`: pending → claimed → expired.
40. `profiles.referral_code` is the public-facing code shareable via link.

## Customer Stats View (staff-facing)
41. Regular VIEW (not materialized) — recalculated on each SELECT.
42. Exposed via RLS GRANT SELECT to authenticated role.
43. Joins orders + events + aggregates tickets per email (lowercase normalized).
44. **GAP:** no pagination in `CustomerManagement.tsx`; at 10k+ rows, browser OOMs.

## Security Definer RPCs
45. `get_customer_visit_count(email)` runs as postgres (bypasses orders RLS).
46. Purpose: scanner staff see "Welcome back (N-th visit)" banner without full orders access.
47. **Audit requirement:** function body must do ONE thing (count by email) with no dynamic SQL. Re-review every time profile-related migrations change.

## Privacy / GDPR
48. **CRITICAL GAP:** account deletion is NOT implemented. Handler is a no-op toast-error.
49. **GAP:** no data export endpoint.
50. **GAP:** no newsletter subscription management on pass-lounge (newsletter_subscribers table lives in scanner scope).
51. Login activity retention: no automatic purge (invariant #24 + audit query #13).

## Data Minimization
52. `profiles` surface for client API responses MUST exclude `two_factor_secret` and `backup_codes`. Those are server-only.
53. Any SELECT query from client code on `profiles` must explicitly list columns — never `select('*')`.

## Role + Route Gating
54. Every profile page (`/profile`, `/account`, `/settings`, `/2fa/setup`, `/verify-email`) is wrapped in `<ProtectedRoute>`.
55. `CustomerManagement.tsx` on scanner: explicit owner-only role check + RLS-backed SELECT on customer_stats.
