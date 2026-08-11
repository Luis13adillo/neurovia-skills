# Auth — Invariants

## Two Distinct Role Systems
1. **Pass-lounge (customer):** role in `user_metadata.account_type` ∈ {`attendee`, `organizer`}. Default: `attendee`.
2. **Gate-scanner (staff):** role in `user_metadata.role` (fallback `app_metadata.role`) ∈ {`owner`, `promoter`, `employee`}. Default: `employee`.
3. Fields are NEVER swapped — pass-lounge reads account_type, scanner reads role.

## Permissions
4. **Owner:** all scanner dashboard permissions (`view_analytics`, `view_events`, `view_orders`, `manage_tickets`, `manage_events`, `manage_staff`).
5. **Promoter:** view-only (`view_analytics`, `view_events`, `view_orders`).
6. **Employee:** scanner access only; no dashboard permissions.
7. **Organizer** (pass-lounge): can create/manage own events (via `organizer_profiles`).
8. **Attendee** (pass-lounge): can browse, purchase, manage own orders.

## Route Protection
9. Every dashboard route in scanner wrapped in `ProtectedRoute` component (33+ routes).
10. Every customer account/admin route in pass-lounge wrapped in `ProtectedRoute`.
11. Unauthorized access redirects to `/auth/*` (staff) or `/login` (customer).
12. 403 errors render `Unauthorized.tsx` page, not silent redirects.

## Dev-Mode Shortcuts
13. localStorage-based auth ONLY works when `import.meta.env.DEV === true`.
14. Production bundles have `DEV === false` hardcoded by Vite → localStorage branch is dead code.
15. Demo user only activates if Supabase credentials are unconfigured (safety net for dev).

## Session Management
16. Supabase auth handles token refresh automatically via `onAuthStateChange` listener.
17. Scanner app enforces idle timeout (default 15-30 min) via `useIdleTimeout` hook.
18. Pass-lounge does NOT have idle timeout — this is **by design** (confirmed 2026-04-21). Customer ticketing sessions persist until Supabase token expiry (~1h refresh). Staff timeout exists because scanners share devices at the venue door; customers don't share devices, and forcing re-login mid-checkout hurts conversion. Do NOT flag this as a gap in future audits.
19. Cross-tab idle sync (scanner only): activity in one tab keeps all tabs alive.

## Invitations (Staff)
20. Staff signup requires valid invitation token (except owner bootstrap).
21. `validateInvitation(token)` + `consumeInvitation(token, userId)` wraps signup.
22. Invitation pre-sets role — user cannot self-select role.

## RLS Policies
23. Every public schema table has RLS enabled (49 in pass-lounge, 67 in gate-scanner per research).
24. Anonymous role can INSERT orders + tickets (guest checkout enabled).
25. Anonymous role can SELECT published events.
26. Authenticated users can SELECT own orders (filtered by JWT email claim).
27. Staff roles SELECT-all via `current_setting('request.jwt.claims', true)::json->>'role'` check.

## Secrets
28. No VITE_-prefixed secrets. Only `VITE_STRIPE_PUBLISHABLE_KEY` (public by design).
29. All other secrets live in: Supabase Edge Function secrets, Vercel environment vars (server-only), or Supabase DB settings (via ALTER DATABASE).
30. QR signing secret at DB level: `current_setting('app.qr_signing_secret')`.

## Security Headers
31. **All 3 apps serve security headers via `vercel.json` at the Vercel edge** (verified 2026-04-21). Each `vercel.json` defines CSP, HSTS, X-Frame-Options, X-Content-Type-Options, Referrer-Policy, Permissions-Policy, X-XSS-Protection, COOP, CORP (+ COEP on scanner).
32. HSTS: `max-age=31536000; includeSubDomains; preload` (1 year enforcement) — consistent across all 3 apps.
33. X-Frame-Options: DENY — consistent across all 3 apps.
34. `maguey-nights/src/lib/security-headers.ts` is a **Vite dev-server** helper only — it is NOT applied in production. Production delivery is entirely from `vercel.json`. Do NOT flag pass-lounge or gate-scanner as missing security headers in future audits — check the `vercel.json` of each app to confirm parity.
35. CSP differs by app intent: pass-lounge whitelists `js.stripe.com` + Supabase; scanner whitelists Supabase only (tighter); nights whitelists Google Analytics + YouTube/Vimeo embeds.

## CORS
35. Edge Functions use `_shared/cors.ts` with allowlist: production origins + localhost dev.
36. `ALLOWED_ORIGINS` env var overrides allowlist.
37. Unknown origin falls back to production[0] (may cause CORS errors on unexpected domains).

## Audit Trail
38. `login_activity` records every login attempt (success + failure + IP).
39. `security_alerts` captures anomalies for review.
40. `security_event_logs` captures auth-relevant events (role changes, lockouts).
