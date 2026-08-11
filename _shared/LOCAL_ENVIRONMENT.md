# Local Environment Map — Luis's machine

**Purpose:** the confirmed locations of the things Neurovia work touches most, so a session
does not have to rediscover them — or guess wrong. Read this before claiming where something
lives or which copy is running.

Every fact below was re-verified on **2026-08-11**. Labels follow
[`evidence-before-conclusion.md`](./evidence-before-conclusion.md).

---

## The one that bites first: two Rubric trees

| Tree | Path | Status |
|---|---|---|
| **Live workspace** | `/Users/luismiguel/Desktop/rubric` | `VERIFIED` — every running console process has its working directory inside this tree |
| **Reference copy** | `/Users/luismiguel/Downloads/rubric` | `VERIFIED` — not a git repository; nothing runs from it |

**Editing the Downloads copy changes nothing that runs.** It looks like success and is a
silent no-op. All Rubric work happens under `Desktop/rubric`.

Confirm before assuming:

```bash
lsof -nP -iTCP:5050 -sTCP:LISTEN -t | xargs -I{} sh -c 'lsof -a -p {} -d cwd -Fn | tail -1'
```

---

## Repositories

| Repo | Root | Remote | State |
|---|---|---|---|
| **neurovia-command-center** | `/Users/luismiguel/Desktop/rubric` | `github.com/Luis13adillo/neurovia-command-center` | `VERIFIED` — checked out on branch `feat/qa-runs-v1`; `origin/main` at `53cffa9` |
| **neurovia-skills** | `/Users/luismiguel/.claude/skills` | `github.com/Luis13adillo/neurovia-skills` | `VERIFIED` — **private**, branch `main`, baseline `2c18c1d` |

The skills repo root **is the skills folder itself**. There is no wrapper directory, and no
folder anywhere on disk is named `neurovia-skills`. Looking for one by name will fail. Find it
by remote:

```bash
git -C ~/.claude/skills remote -v
```

---

## Claude Code config — outside every repository

| File | Path | Status |
|---|---|---|
| Global hooks | `/Users/luismiguel/.claude/hooks/` | `VERIFIED` — **not in any repo, unversioned** |
| Global settings | `/Users/luismiguel/.claude/settings.json` | `VERIFIED` — **not in any repo, unversioned** |

Both are **siblings** of `~/.claude/skills`, not members of it. The neurovia-skills repo does
not protect either one. `settings.json` is additionally owned and rewritten by Claude Code
itself (`/config`, permission approvals), so it cannot simply be symlinked into a repo.

---

## Live processes and ports

`VERIFIED` — all bound to `127.0.0.1` only.

| Port | Serves | Process working directory |
|---|---|---|
| 5050 | Console / scaffold — **the single address for everything** | `Desktop/rubric/templates/scaffold` |
| 5055 | Docs | `Desktop/rubric/templates/docs` |
| 5058 | Links | `Desktop/rubric/templates/links` |
| 5060 | Sprint | `Desktop/rubric/templates/sprint` |
| 5062 | Health | `Desktop/rubric/templates/health` |
| 5064 | QA Runs | `Desktop/rubric/templates/qa` |
| 5210 | Second Brain | `Desktop/rubric/templates/second-brain` |

The six children are spawned and reverse-proxied by the console. **Start only via
`~/Desktop/rubric/start.sh`** — never launch a child by hand, and never assume a tab is
served by its own port just because its folder has a `server.js`.

---

## Live source vs dead source inside `templates/`

A `server.js` in a template folder does **not** mean that file runs. The scaffold absorbed
several templates, and what remains in those folders is a mix of dead code, live data, and
files that are load-bearing only as existence probes.

| File | Status |
|---|---|
| `templates/flows/server.js` | `VERIFIED` **dead as code** — never executed. But see the probe warning below. |
| `templates/flows/data/workflows.json` | `VERIFIED` **live** — read by the scaffold via `FLOWS_DIR` |
| `templates/flows/workflows/**/SKILL.md` | `VERIFIED` **live** — served by the scaffold's `/api/skill-content` |
| `templates/agents/server.js` | `VERIFIED` **dead** — never executed |
| `templates/agents/config.json` | `VERIFIED` **dead** — the scaffold does **not** read it |
| `templates/scaffold/config.json` | `VERIFIED` **live** — this is the real agent list |
| `templates/scaffold/data/agent-status.json` | `VERIFIED` **live** — this is the real agent status store |

**Correction worth stating plainly:** unlike Flows, the Agents template has **no live data
file at all** — it has no `data/` directory, and its `config.json` is ignored. Everything live
for Agents lives under `templates/scaffold/`.

**Existence-probe warning.** The scaffold decides which tabs to enable with `fs.existsSync`
against one file per template — `flows/server.js` for Flows, `agents/index.html` for Agents.
Those files are never executed, but **deleting them silently removes the tab.** Dead code here
is not the same as unused.

---

## How to re-verify this whole file

```bash
# which tree is actually running, and on what
for p in $(lsof -nP -iTCP -sTCP:LISTEN -t | sort -u); do
  lsof -a -p $p -d cwd -Fn 2>/dev/null | tail -1
done | grep rubric

# repo identity, by remote — never by folder name
git -C ~/Desktop/rubric  remote -v
git -C ~/.claude/skills  remote -v

# is a given path inside any repo at all?
git -C ~/.claude/hooks rev-parse --show-toplevel 2>/dev/null || echo "not in any repo"
```

If any fact here stops matching reality, fix this file in the same session — a stale map is
worse than no map, because it gets trusted.
