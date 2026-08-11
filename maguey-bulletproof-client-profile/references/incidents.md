# Client Profile — Known Incidents & Fix Patterns

---

## Incident: "2FA keeps failing / I can only log in with backup codes" (CRITICAL)
**Symptom:** Customer set up 2FA with Google Authenticator. The 6-digit codes never work. Only backup codes let them in.
**Root cause:** `useAuthMethods.ts verify2FA(code)` only compares against `profiles.backup_codes`. TOTP is never validated against `profiles.two_factor_secret`.
**Current state:** KNOWN GAP. Flag to user every audit until fixed.
**Fix pattern (requires approval):**
```typescript
// Pseudocode — useAuthMethods.ts verify2FA()
import { TOTP } from 'otpauth';

const { data: profile } = await supabase.from('profiles')
  .select('two_factor_secret, backup_codes')
  .eq('id', user.id).single();

// 1. Try TOTP validation (±30s window)
const totp = new TOTP({ secret: profile.two_factor_secret });
const valid = totp.validate({ token: code, window: 1 }) !== null;
if (valid) return { success: true, method: 'totp' };

// 2. Fallback: backup code (atomic consume via SQL UPDATE with array removal)
const { data: consumed } = await supabase.rpc('consume_backup_code', {
  p_user_id: user.id,
  p_code: code
});
if (consumed) return { success: true, method: 'backup' };

return { success: false };
```
Plus: rate-limit at 3 attempts/5min per user_id.

---

## Incident: "I was charged but refunded, ticket still shows in my account"
**Symptom:** Customer was refunded after a cancellation, but ticket still appears under "Upcoming Events."
**Root cause:** `user-tickets.ts` fetch doesn't exclude refunded/cancelled statuses. KNOWN GAP.
**Fix (requires approval):** one line in `user-tickets.ts`:
```typescript
.not('status', 'in', '("refunded","cancelled")')
```
Add before the `.order(...)` call.
**Verify:** audit query #8 should return 0 rows post-fix.

---

## Incident: "My new avatar doesn't show up"
**Symptom:** Customer uploaded new avatar. Profile page still shows old one.
**Root cause options:**
1. Browser cached the old `avatar_url` (most common)
2. `avatar_url` in profiles was not updated (upload succeeded, DB write failed)
3. New URL is same as old URL (timestamp collision — rare)

**Debug:**
```sql
SELECT avatar_url, updated_at FROM profiles WHERE id = '<uid>';
```
If URL changed but customer sees old: browser cache issue → customer hard-refreshes (Cmd+Shift+R) or you add cache-busting (`?v={timestamp}`).
If URL did not change: upload failed to write DB. Check network tab. Re-upload.

**Note:** old avatar file is NOT deleted from Storage (KNOWN GAP). Both files coexist in bucket. Audit query #9 tracks orphans.

---

## Incident: "I updated my email but old one still shows"
**Symptom:** Customer changed email in Profile. Old email still displayed on Account page.
**Root cause:** `updateEmail()` fires Supabase confirmation flow. Email is NOT swapped in `auth.users` until customer clicks the link in the new email. Display cache shows old email until session refresh.
**Fix:** tell customer to check new email inbox for confirmation link. After clicking, log out and back in (or wait for next session refresh ~1h).
**UX improvement (requires approval):** show pending-state UI: "Email change to NEW@...pending confirmation." Display original email until confirmed.

---

## Incident: "Delete my account" doesn't work
**Symptom:** Customer clicked "Delete Account" → saw an error toast.
**Root cause:** `handleDeleteAccount()` in `AccountSettings.tsx` is a stub: `toast.error("Account deletion is not yet implemented")`. KNOWN GAP.
**GDPR risk:** customers have a legal right to deletion. Operating without it in EU/CA market is non-compliant.
**Fix pattern (requires approval + careful rollout):**
1. Edge Function `delete-account` — soft-delete: set `profiles.deleted_at`, anonymize name/phone/dob, keep orders for audit trail (replace `purchaser_email` with hash).
2. Delete `avatars/{user.id}/*` from Storage.
3. Revoke all sessions (`supabase.auth.admin.signOut(user.id)`).
4. Email confirmation before deletion (30-day grace period recommended).
5. Purge `magic_links`, `user_devices`, `login_activity` for this user.
6. Update `CustomerManagement.tsx` to hide soft-deleted customers or mark them "[Deleted]".

---

## Incident: "Customer stats show wrong lifetime value"
**Symptom:** Staff dashboard shows customer with $2000 spent, but their Stripe history shows $3000.
**Root cause options:**
1. `customer_stats` view aggregates `orders.total` only for `status IN ('paid','completed')` — refunded orders excluded by design (LTV = net revenue)
2. View keys on LOWER(email) — multiple emails per person not merged
3. Some orders have NULL purchaser_email (anonymous guest checkout)

**Debug:**
```sql
SELECT status, COUNT(*), SUM(total)
FROM orders WHERE LOWER(purchaser_email) = '<email>'
GROUP BY status;
```
If `refunded` + `paid` together match expectation, the view is correct — "LTV" is net.

---

## Incident: "I transferred a ticket but my friend never got it"
**Symptom:** Customer clicked Transfer. Ticket disappeared from their list. Friend received no email.
**Root cause:** client-side optimistic update removed ticket from state BEFORE Edge Function confirmed. Network dropped mid-request. KNOWN GAP.
**Immediate recovery:**
```sql
SELECT * FROM ticket_transfers WHERE from_email = '<sender>'
ORDER BY created_at DESC LIMIT 5;
SELECT * FROM tickets WHERE id = '<original_ticket_id>';
```
- If `ticket_transfers` row exists with status='completed' → transfer actually succeeded; recipient didn't get email (escalate to `maguey-bulletproof-email`)
- If no row → transfer never happened; original ticket was wrongly removed from UI. Run `SELECT * FROM tickets WHERE attendee_email = '<sender>'` — if ticket still exists in DB, customer just needs to refresh to see it again.

**Fix (requires approval):**
```typescript
// In Account.tsx transfer handler:
try {
  const result = await transferTicket(ticketId, recipient);
  if (!result.success) throw new Error(result.error);
  // ONLY THEN remove from state:
  setTickets(prev => prev.filter(t => t.id !== ticketId));
  setTransferredTickets(prev => [result.newTransfer, ...prev]);
} catch (err) {
  toast.error("Transfer failed. Please try again.");
  // Do NOT remove from state.
}
```

---

## Incident: "Staff customer page loads forever / crashes browser"
**Symptom:** Owner opens CustomerManagement, browser hangs or shows "page unresponsive."
**Root cause:** loads ALL `customer_stats` rows at once. KNOWN GAP (no pagination).
**Immediate workaround:** use Supabase Studio with SQL queries instead of the UI.
**Fix (requires approval):** add `.range(offset, offset + 99)` pagination + infinite scroll or explicit pages. Cache per-page results client-side.

---

## Incident: "Customer can see another customer's profile"
**Symptom:** CRITICAL. A user sees another user's first_name / last_name / avatar.
**Root cause options:**
1. RLS policy on profiles regressed (audit query #10)
2. Component uses a client query without RLS enforcement
3. `customer_stats` view exposed in customer-facing UI by mistake

**Debug:**
```sql
SELECT policyname, qual FROM pg_policies WHERE tablename = 'profiles';
```
Expected: SELECT policy `auth.uid() = id` (owner-only).

If policy is correct, check browser network tab — which component sent a query returning multiple user rows? That's the bug.

**Recovery:** if RLS is broken, restore policy immediately (WRITE — requires approval). Rotate sessions (force logout all users).

---

## Incident: "Pending referral reward never processed"
**Symptom:** Friend signed up with referral code. Weeks later, referrer still shows "pending" reward.
**Root cause:** referral reward processing is manual — no cron that flips pending → claimed.
**Debug:** audit query #16 lists stale pending referrals.
**Fix options:**
1. Manual: staff reviews and marks claimed via admin tool (if one exists)
2. Automated: Edge Function that processes pending referrals where referee has ≥1 paid order

---

## Incident: "I see a 2FA backup code on my screen after setup, is that okay?"
**Symptom:** Customer concerned about backup codes being visible.
**Current UX:** codes displayed in a 2-column grid after 2FA setup (`TwoFactorSetup.tsx` lines 184-203).
**UX improvement (optional):** show codes in "reveal on hover" mode, auto-hide after 10 seconds, blur on screenshot attempt (JS APIs exist). But codes must still be copyable.

---

## Incident: Profile/auth metadata drift detected
**Symptom:** audit query #12 returns rows — `profiles.first_name` differs from `auth.users.user_metadata.first_name`.
**Root cause:** `updateProfile()` writes to both locations but not transactionally. One write succeeded, the other failed (or retried with different value).
**Fix pattern:**
```typescript
// Pick a source of truth. Recommendation: profiles table.
// Always READ from profiles.
// On update: write to profiles first; update auth metadata ONLY for OAuth compatibility.
// Accept that auth.users.user_metadata may be stale — do not rely on it for display.
```
**Data cleanup:** one-time script to backfill `auth.users.user_metadata` from `profiles` (WRITE, requires approval + downtime window).

---

## Pattern: 2FA migration plan (when fixing the TOTP gap)
Don't just switch logic — will lock out active users.
1. **Phase 1:** add TOTP library + validation. Accept EITHER TOTP OR backup code (current behavior preserved). Deploy.
2. **Phase 2:** migrate secrets to encrypted storage (new column `two_factor_secret_encrypted`). Dual-read during transition.
3. **Phase 3:** hash backup codes with bcrypt. Accept either hashed or plaintext during transition.
4. **Phase 4:** after 30 days (migration window), flip to encrypted/hashed-only. Drop old plaintext columns.
5. **Phase 5:** remove backup-code-as-primary path; TOTP becomes primary, backup codes truly fallback.

Customer comms required at each phase. Security-sensitive — pair-review.
