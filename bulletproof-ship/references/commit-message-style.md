# MT Barbershop Commit Message Style

Derived from `git log --oneline -50`. Match this style exactly.

---

## Format

```
<type>(<scope>): <subject>

<optional body: WHY, not what>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Types (observed in this repo)

| Type | Use for |
|---|---|
| `fix` | Bug fix. Something broke, this fixes it. |
| `feat` | New feature or capability. |
| `chore` | Maintenance, cleanup, no user-visible change. |
| `docs` | Documentation-only (CLAUDE.md, MEMORY.md, .claude/rules/). |
| `ci` | GitHub Actions, CI pipeline, deploy infra. |
| `merge` | Rarely used — prefer `git merge --no-ff <branch>` which produces `Merge branch 'x'` automatically. |

---

## Scopes (observed, use these or close matches)

- `queue` — walk-in queue
- `schedule` — barber schedules, availability
- `booking` — bookings, availability API, reschedule
- `dashboard` — owner dashboard generally
- `dashboard/calendar` — owner calendar specifically
- `sw` — service worker (PWA)
- `notifications` — SMS, email, push notifications
- `commissions` — fee/commission system
- `alerts` — owner_alerts table / alert logic
- `locations` — locations table / cross-location logic
- `auth` — authentication, middleware, roles
- `payments` — PaymentCollectionModal, Stripe
- `loyalty` — customer_loyalty, gift cards
- `referrals` — barber_referrals

Don't invent new scopes unless the existing ones don't fit.

---

## Subject rules

- Lowercase (except proper names: `Vercel`, `Stripe`, `Booksy`, `Edwardsville`)
- Imperative: "fix X" not "fixed X" or "fixes X"
- No trailing period
- Describe the outcome, not the files: `fix(queue): prevent double-assignment` not `fix(queue): update route.ts`
- Use `+` to join multiple related improvements: `fix(sw): bump cache key + network-first for dashboard shells`

---

## Good examples (from real log)

```
fix(queue): make walk-in Call/Skip reachable from anywhere + replay-on-mount
feat(notifications): notify barber by email + SMS on every new booking
fix(booking): chronological guard prevents calling later booking while earlier is still confirmed past its time
fix(schedule): preserve per-day location_id; only fallback for brand-new days
feat(queue): add per-barber queue control mode (auto/manual/paused)
fix(dashboard/calendar): support all-barbers + all-locations mode
fix(sw): bump cache key + network-first for dashboard shells
feat(locations): add Edwardsville PA as 4th location
fix(alerts): add payment_skipped to owner_alerts type constraint
docs: update CLAUDE.md for 4th location (Edwardsville PA)
```

---

## Bad examples (do not do this)

```
Fix the queue bug                        # no type/scope
fix: things                              # no scope, vague subject
fix(queue): updated route.ts             # describes file, not change
Fixed queue double-assignment.           # past tense, capitalized, period
update                                   # useless
WIP                                      # don't commit WIP
```

---

## Body (optional)

Only include a body when the WHY isn't obvious. Bullet style matches CLAUDE.md tone: plain, direct.

Good body:

```
fix(queue): preserve calledClientIdRef across realtime updates

The boolean calledBySelfRef was cleared by the reset useEffect that
fires when Supabase realtime delivers the 'called' status — BEFORE
the 60s auto-start timer. Storing the client ID survives the race
with zero need for a reset effect.

Incident: 2026-04-11 — auto-started Latoya Green for Brayan without
his consent.
```

Skip the body when the subject is self-explanatory (most `fix` and `feat` commits).

---

## Always end with

```
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Special cases

### Merge commits
Let `git merge --no-ff <branch>` generate the message automatically. Don't override.

### Revert commits
`git revert <sha>` generates `Revert "<original subject>"`. Leave that subject, add a body explaining WHY the revert was needed.

### Docs-only to main
`docs:` (no scope) is observed in the log for CLAUDE.md updates. Consistent with pattern:
```
docs: update CLAUDE.md for 4th location (Edwardsville PA)
```
