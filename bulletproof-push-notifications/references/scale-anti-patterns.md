# Push Notifications Scale Anti-Patterns

Report-only.

Context: 40 barbers × 4 locations = 40+ barber devices + owner devices + customer queue subscribers. Growing.

---

## 1. Subscription coverage per barber

```sql
SELECT
  COUNT(DISTINCT b.id) FILTER (WHERE ps.id IS NOT NULL) AS barbers_with_subscription,
  COUNT(DISTINCT b.id) AS total_active_barbers,
  ROUND(100.0 * COUNT(DISTINCT b.id) FILTER (WHERE ps.id IS NOT NULL)
        / NULLIF(COUNT(DISTINCT b.id), 0), 1) AS coverage_pct
FROM barbers b
JOIN profiles p ON p.id = b.profile_id
LEFT JOIN push_subscriptions ps ON ps.user_id = p.id
WHERE b.is_active = true;
```

Target: 100%. Any barber without a subscription misses walk-in alerts when their dashboard isn't open. At 40 barbers, even 90% coverage = 4 barbers missing assignments silently.

---

## 2. Devices per barber (operational redundancy)

```sql
SELECT b.slug, COUNT(ps.id) AS devices
FROM barbers b
JOIN profiles p ON p.id = b.profile_id
LEFT JOIN push_subscriptions ps ON ps.user_id = p.id
WHERE b.is_active = true
GROUP BY b.slug
HAVING COUNT(ps.id) > 2
ORDER BY devices DESC;
```

1-2 devices per barber is normal (phone + shop tablet). 5+ devices means old subscriptions weren't cleaned up properly.

---

## 3. Cleanup lag

Without automated cleanup, dead endpoints pile up. Each dead endpoint = wasted Twilio/web-push attempt.

```sql
-- Rows that haven't been touched in 6 months (candidates for cleanup)
SELECT COUNT(*) AS probably_dead
FROM push_subscriptions
WHERE updated_at < now() - interval '6 months';
```

At 160 active subs + 100 stale, sends take longer + more network errors. Recommend: periodic cleanup cron that proactively prunes.

---

## 4. iOS barber onboarding friction

iOS 16.4+ requires PWA install (Add to Home Screen) before web push works. At 40 barbers, many on iOS:
- Write a simple 3-step onboarding doc for iOS users
- Include in barber onboarding (`/barber/setup` wizard)
- Verify via audit query: what % of iOS-user-agent barbers have subscriptions?

Not directly queryable without user-agent tracking. Flag as onboarding coverage gap.

---

## 5. VAPID key rotation readiness

Document a clear procedure BEFORE you need to rotate:

1. Generate new key pair with `npx web-push generate-vapid-keys`.
2. Add new public key alongside existing (update `NEXT_PUBLIC_VAPID_PUBLIC_KEY`).
3. Force re-subscribe by clearing localStorage flag on next login.
4. After majority re-subscribe, rotate private key.

Without this plan, any rotation breaks all notifications. At 40 barbers this means 40 calls to the owner before they realize.

---

## 6. Payload size

Web-push has a 4096-byte limit per payload. `QueuePush.sendCalledNotification()` payloads are small (~200 bytes).

Don't include full client profiles or base64 images. Grep:
```bash
grep -rn "sendPushNotification\|sendPushToMany" src/
```
Verify payloads are compact objects.

---

## 7. Broadcast scale

`/api/communications/send-blast` sends to ALL subscribed users with `user_id IS NOT NULL`. At 160+ subscriptions:
- Twilio equivalent would be sequential (rate-limited).
- Web-push is parallel by default, but each send is an HTTPS call.
- Expect ~5-10 seconds for a 200-recipient blast.

Flag as scale issue at 10k subscriptions (not current concern).

---

## 8. Subscription endpoint freshness

Browser push endpoints change unpredictably (browser updates, GCM → FCM migration history). A subscription created a year ago may silently 410 today.

**Recommendation:** Expose a "re-subscribe" prompt in the barber dashboard when:
- A push delivery fails with 410 for this barber recently, OR
- `updated_at` is older than 60 days

This is a future feature; flag it in scale-check report.

---

## 9. Action definitions match SW handler

When adding a new push action:
- Add the action to the payload in the trigger point.
- Add the handler in `/public/sw.js` `notificationclick` event.
- Test both: what happens if the payload has an action the SW doesn't know?

Scale risk: at 40 barbers, small drifts surface fast.

---

## 10. Owner broadcast reaching all owners

If MT has multiple owner accounts (real + dev owner), broadcasts should target only the real owner. Verify:
```sql
SELECT p.email, COUNT(ps.id) AS device_count
FROM profiles p
LEFT JOIN push_subscriptions ps ON ps.user_id = p.id
WHERE p.role = 'owner'
GROUP BY p.email;
```

---

## Output verdict template

```
## Push Notifications Scale Readiness

### Ready
- [green items]

### Must fix before scaling (new barber cohort, new location, key rotation)
1. [item + reason]

### Recommended
- [items — proactive cleanup cron, iOS onboarding doc, VAPID rotation plan]

### Verdict
[READY / BLOCKED BY N ITEMS]

### Device-level disclaimer
"This audit covers data + code. Actual device delivery requires real-device testing."
```
