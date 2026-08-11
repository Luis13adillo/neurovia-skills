# Push Notifications Incident Registry

---

## Expired Subscription Not Cleaned Up

**Symptom:**
- Barber stops getting walk-in alerts on their phone
- Their `push_subscriptions` row still exists in the DB (so the code thinks they're subscribed)
- Each attempted send fails with HTTP 410 Gone silently

**Root cause:**
Subscriber disabled notifications on their device, uninstalled the PWA, or cleared browser storage. The endpoint is dead. But if the 410 handler doesn't delete the row, `sendPushToMany()` keeps trying.

**Correct pattern (in `src/lib/push/server.ts`):**
```typescript
// When web-push returns HTTP 410 or 404:
if (err.statusCode === 410 || err.statusCode === 404) {
  return { success: false, error: 'subscription_expired', endpoint };
}
// Caller collects all expired endpoints and DELETEs them in one batch.
```

**Diagnose checklist:**
1. Query: does the barber have a `push_subscriptions` row? `SELECT * FROM push_subscriptions WHERE user_id = '<profile_id>'`.
2. If yes, try sending a test notification (via dev tools, NOT production).
3. If 410 response: the cleanup handler didn't run. Grep: `grep -rn "subscription_expired\|statusCode.*410" src/` — verify the cleanup path exists.
4. If no subscription row: barber needs to re-enable notifications. The `/api/push/subscribe` POST must be called.

---

## VAPID Key Rotation Broke All Notifications

**Symptom:**
- One day, ALL pushes stop working simultaneously
- No errors in logs; sends just silently fail
- `web-push` library returns 401/403 Unauthorized

**Root cause:**
`VAPID_PRIVATE_KEY` was rotated in production. All existing subscriptions were signed with the OLD public key. The new private key can't sign messages that match the old subscription's public key context.

**Correct procedure for VAPID rotation:**
1. Generate new key pair (`npx web-push generate-vapid-keys`).
2. Keep the OLD keys active during a transition period.
3. Deploy new public key as `NEXT_PUBLIC_VAPID_PUBLIC_KEY`.
4. Force all users to re-subscribe (show a banner, or detect mismatch and prompt).
5. Once most users have re-subscribed, rotate the private key.
6. Clean up old subscriptions (they'll 410 anyway).

**Diagnose:**
1. Check Vercel env var history: was `VAPID_PRIVATE_KEY` changed recently?
2. If yes: that's the root cause. Roll back to the previous private key, notify team, plan proper rotation.

---

## Service Worker Not Registered

**Symptom:**
- User enables notifications (browser prompt appears, they click Allow)
- `push_subscriptions` row is created successfully
- But pushes never reach the device

**Root cause:**
Service worker isn't active on the user's device. Possible causes:
- `navigator.serviceWorker.register('/sw.js')` never called
- SW file has a syntax error and failed to install
- Browser is in incognito mode (some browsers block SW in private mode)
- Previous SW version uninstalled and new one never installed

**Diagnose:**
1. User opens DevTools on their device → Application → Service Workers.
2. Is `/sw.js` listed? Is its status "activated and running"?
3. If not, grep `src/lib/push/client.ts` for the `registerServiceWorker()` function — is it called in the app boot sequence?

---

## Orphaned Subscription Rows (user_id AND queue_token both null)

**Symptom:**
- `push_subscriptions` has rows where both `user_id` and `queue_token` are NULL
- These rows can never receive notifications (no way to find them)

**Root cause:**
A subscribe flow started before the user was identified (not logged in, no queue entry yet), then didn't complete the association.

**Correct pattern:**
POST to `/api/push/subscribe` should require EITHER:
- Authenticated session (server derives `user_id`), OR
- `queue_token` in request body (for anonymous queue customers)

If neither is present → 400 reject. Don't create an orphaned row.

**Diagnose:**
1. Query: `SELECT id, endpoint, created_at FROM push_subscriptions WHERE user_id IS NULL AND queue_token IS NULL`.
2. If rows exist, check `src/app/api/push/subscribe/route.ts` POST handler — does it reject when both are absent?
3. Clean up orphans: the user would need to explicitly approve a cleanup DELETE.

---

## iOS Safari Subscription Doesn't Work

**Symptom:**
- Barber on iPhone enables notifications
- No browser prompt appears, OR prompt appears but subscription fails
- Android/Chrome users work fine

**Root cause:**
iOS 16.4+ supports web push ONLY for installed PWAs (not regular Safari tabs).

**Correct onboarding for iOS:**
1. Open MT website in Safari.
2. Tap Share → "Add to Home Screen".
3. Open the MT app from Home Screen (NOT from Safari).
4. From the installed PWA, enable notifications.
5. This creates a valid subscription.

**Diagnose:**
1. Ask: are they using iOS? iPhone?
2. Did they add MT to their Home Screen?
3. Are they opening MT from the Home Screen icon or from Safari?

This is a user education / onboarding issue, not a code bug. But flag it prominently in barber onboarding docs.

---

## Push Fires But Notification Doesn't Display

**Symptom:**
- Server logs show `sendPushNotification` returned success
- Device never shows the notification

**Possible root causes:**
1. Device in Do Not Disturb mode
2. Notification permission revoked after subscription created (subscription still valid but OS blocks display)
3. Service worker's `push` event handler errored silently
4. Payload malformed (missing `title` or `body`)

**Diagnose:**
1. Check device's notification settings for the MT app/PWA.
2. On device: DevTools → Console → look for SW errors when a push arrives.
3. Inspect the push payload — does it have required fields?

---

## Notification Click Opens Wrong Page

**Symptom:**
- Barber taps "Call" action on the walk-in alert
- App opens but lands on the homepage, not `/barber/walk-ins`

**Root cause:**
`/public/sw.js` `notificationclick` handler logic mismatched. Either:
- Action name ('call') didn't match case-sensitive check
- `event.notification.data.url` wasn't set by the sender
- `clients.openWindow()` was called with wrong URL

**Correct pattern (in `public/sw.js`):**
```javascript
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const action = event.action;
  const data = event.notification.data || {};
  let url = '/';

  if (action === 'call' || action === 'skip' || action === 'complete') {
    url = '/barber/walk-ins';
  } else if (data.url) {
    url = data.url;
  }

  event.waitUntil(
    self.clients.matchAll({ type: 'window' }).then((clientList) => {
      for (const client of clientList) {
        if (client.url.includes(url) && 'focus' in client) {
          return client.focus();
        }
      }
      return self.clients.openWindow(url);
    })
  );
});
```

**Diagnose:**
1. Read `/public/sw.js` `notificationclick` handler.
2. Verify action-to-URL routing matches the payloads being sent.
3. Ensure push payload senders include `data.url` for non-action notifications.

---

## Subscription Duplicates per Endpoint

**Symptom:**
- Two or more `push_subscriptions` rows with the same `endpoint`
- User gets duplicate pushes (same message twice)

**Root cause:**
POST to `/api/push/subscribe` doesn't check for existing endpoint — just INSERTs.

**Correct pattern:**
```typescript
// In POST handler:
const { data: existing } = await admin
  .from('push_subscriptions')
  .select('id')
  .eq('endpoint', subscription.endpoint)
  .maybeSingle();

if (existing) {
  await admin.from('push_subscriptions')
    .update({ p256dh, auth, user_id, queue_token, updated_at: new Date() })
    .eq('id', existing.id);
} else {
  await admin.from('push_subscriptions').insert({ endpoint, p256dh, auth, user_id, queue_token });
}
```

**Diagnose:**
1. Query: `SELECT endpoint, COUNT(*) FROM push_subscriptions GROUP BY endpoint HAVING COUNT(*) > 1`.
2. If any row > 1, the upsert logic is broken.

---

## Quick Match Table

| Symptom | Likely incident | First file to read |
|---|---|---|
| Subscription exists but no pushes | Expired endpoint not cleaned | `src/lib/push/server.ts` 410 handler |
| All pushes stopped overnight | VAPID key rotation | env var history |
| SW not in DevTools list | Service worker not registered | `src/lib/push/client.ts` |
| Orphaned rows (user_id + queue_token both null) | POST handler doesn't reject | `src/app/api/push/subscribe/route.ts` |
| iOS doesn't work | PWA not installed from Home Screen | user onboarding — not code |
| Push sends succeed but no display | OS / SW handler error | DevTools on device |
| Wrong page on click | `notificationclick` handler routing | `/public/sw.js` |
| Duplicate pushes | Missing upsert logic | `/api/push/subscribe` POST |
