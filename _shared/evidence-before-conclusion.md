# Evidence Before Conclusion — labelling what you actually know

**Applies to:** any system-level claim in a Neurovia investigation — what exists, what is
running, what a service does, what is backed up, where a file lives, whether something is
broken.

**Rule:** a claim is only as strong as the check behind it. Every system-level claim carries
a label, and a negative claim carries the scope of the search that produced it.

**Why this exists:** on 2026-08-11 an investigation concluded "there is no `neurovia-skills`
repo on this machine." The repo existed, was private on GitHub, and was clean. The search had
looked in `~/Desktop` and `~/Downloads` for a *folder named* `neurovia` — but a repo's
identity is its remote URL, not its folder name, and this one's folder is `skills`. The search
could never have found it either way. Worse, an architecture recommendation was then built on
the false negative. The fact was wrong for five minutes; the recommendation derived from it
would have been wrong permanently.

---

## The five labels

Every system-level claim gets exactly one.

| Label | Means |
|---|---|
| `VERIFIED` | A command that directly tests the claim ran, exited 0, and its output is unambiguous. Cite the command. |
| `OBSERVED` | Seen directly in output or file content, but the behaviour was never tested. |
| `INFERRED` | Reasoned from other facts. Name the facts it rests on. |
| `NOT FOUND IN SEARCHED LOCATIONS` | A search returned nothing. State the paths, patterns and depth. **This never collapses into "does not exist."** |
| `UNKNOWN` | Not checked, or the check failed, timed out, or was backgrounded. |

Reading a config value is `OBSERVED`. Running the thing and watching it behave is `VERIFIED`.
The gap between those two is where most confident wrong answers live.

---

## The rules

**1. Name the authority first.**
Before any system-level claim, identify the authoritative source and say what it is:

| Claim about | Authority |
|---|---|
| A running service | The PID, its command, and its working directory (`lsof` + `ps -o command`) |
| Repo membership | `git -C <path> rev-parse --show-toplevel` and `remote -v` |
| A hosted repo | The provider API (`gh repo view <owner>/<name>`) |
| Runtime behaviour | The file the running process actually loads |

A claim citing a file that nothing executes is `OBSERVED` at best — never `VERIFIED`.

**2. Absence carries its scope.**
Write the scope into the claim: "no match in `~/A`, `~/B` at depth 2" — never "no X exists."
If the scope is worth hiding, the claim is worth re-running.

**3. Search by identity, not by expected name.**
Repos: find `.git`, read the remote. Services: enumerate listening ports, resolve each PID.
Config: follow the path the process loaded. Names are hints; they are not identifiers.

**4. Never cite a command you did not see finish.**
Timed out, backgrounded, killed, or non-zero exit ⇒ `UNKNOWN`. Not "probably nothing."
An empty output file from a command that never completed is not evidence of absence.

**5. Exclude yourself from your own search.**
Any check that scans the process table, shell history, or its own logs will match the
checking command. `ps aux | grep -c "foo/server.js"` returns 1 because *your own shell
command line contains that string*. Enumerate by PID and resolve each one instead.

**6. Two trees: say which one runs.**
Where near-identical copies of a codebase exist, state which copy the running process uses
*before* reading or editing either. Editing the inert copy looks exactly like success and
changes nothing.

**7. Live source vs dead source.**
A file existing in a template folder does not mean it executes. Some files are loaded, some
are read only for their data, and some exist purely as existence probes for a feature check.
Establish which, per file, before describing behaviour or changing anything.

**8. A failed guess describes your guess, not the system.**
A 404 from a path you assumed, or an empty read from a property you assumed, means the
assumption was wrong. Re-read the route table or schema before concluding anything about the
service. Against minified or compiled artifacts, never conclude absence from a
delimiter-anchored pattern — strip the quotes and re-test.

**9. Stored is not displayed.**
File contents prove storage behaviour only. Any claim about what the user *sees* requires
checking the render path.

**10. Corrections propagate.**
When a fact is corrected, re-check every recommendation that depended on it. Fixing the fact
and leaving the derived advice standing is the more expensive half of the mistake.

**11. Escalate when the stakes are high.**
Any claim that drives a destructive action, an architecture decision, or a
"does not exist / is not protected / is not backed up" conclusion must be `VERIFIED` — or
carry its weaker label in the same sentence, where the reader cannot miss it.

---

## The shape of an honest negative

> **`NOT FOUND IN SEARCHED LOCATIONS`** — no `.git` with a matching remote under `~/Desktop`
> or `~/Downloads` at depth 2. Not checked: `~/.claude`, `~/Documents`, anything deeper.
> To settle it: `gh repo view <owner>/<name>`.

That version is useful even when it is wrong, because it shows exactly which rock went
unturned. "It does not exist" is not.
