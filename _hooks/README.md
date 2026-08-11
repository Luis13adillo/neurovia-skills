# `_hooks/` — Claude Code hooks that Neurovia owns

Hooks Claude Code runs on session events. They live here, under version control,
rather than in `~/.claude/hooks/`, which is inside no repository.

| File | What it is |
|---|---|
| `rubric-status.js` | Reports Claude Code session activity to the Rubric console. The **only** writer of agent telemetry. |
| `settings.hooks.json` | Reference copy of the `hooks` block from `settings.json`. Documentation, not configuration — nothing reads it at runtime. |

## Why the hook is here and not in `~/.claude/hooks/`

`~/.claude/hooks/` is not in any repository — verified with
`git -C ~/.claude/hooks rev-parse --show-toplevel`. Nothing versioned the hook,
so a bad edit or an accidental delete would have taken agent status down with no
way back, silently: the console would have kept serving stale statuses and shown
no error.

`~/.claude/settings.json` is not in any repository either, and can't simply be
moved here — Claude Code owns that file and rewrites it on `/config` changes and
permission approvals. That is what `settings.hooks.json` is for: the wiring is
reproduced here so it can be rebuilt by hand after a reset.

## This directory is a live checkout — do not branch it

`~/.claude/skills` **is** the neurovia-skills working tree, and Claude Code loads
`rubric-status.js` from this path at runtime. A hook that exists only on a
feature branch is deleted from disk by the next `git checkout main`, which kills
telemetry with no error anywhere. Everything in `_hooks/` belongs on `main`.

## Rebuilding the wiring after a settings.json reset

1. Open `~/.claude/settings.json`.
2. Replace its `hooks` key with the `hooks` object from `settings.hooks.json`
   (drop the `_comment` key — it is a note to the reader, not a setting).
3. Restart Claude Code. Hooks are read at session start; an already-running
   session keeps the wiring it booted with.

Verify without waiting for a real session — this posts a live status, so use an
agent id you don't mind touching:

```bash
echo '{"hook_event_name":"SessionStart","cwd":"'"$HOME"'/Desktop/MT-Barbershop-Systems"}' \
  | node ~/.claude/skills/_hooks/rubric-status.js
curl -s -X POST localhost:5050/api/agent-status \
  -H 'Content-Type: application/json' -d '{}'
```

The agent should read `active`. Send `{"hook_event_name":"Stop", ...}` to put it
back to `idle`.

## The one invariant that matters

`ACTIVE_EVENTS` in `rubric-status.js` and the event registration in
`settings.json` must agree. `statusFor()` treats **any event it does not
recognise as `idle`**, so registering an event in `settings.json` without adding
it to `ACTIVE_EVENTS` marks the agent idle every time that event fires. For
`PostToolUse` that means idle after every single tool call — strictly worse than
no hook at all.
