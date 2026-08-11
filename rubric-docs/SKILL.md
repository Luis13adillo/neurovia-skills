---
name: rubric-docs
description: Read and act on the comments Luis leaves in RUBRIC Docs, and read or edit the markdown docs across his four client repos. Use when he says "check the docs comments", "what did I leave in the docs", references a doc by name, or asks you to update project documentation.
---

# RUBRIC Docs

A file browser and comment layer over Luis's client documentation, running as the
**Docs** tab of the RUBRIC console at **http://localhost:5050**.

The point of it: he highlights text in a document, leaves a note, and you read that
note here. Comments are how he hands you instructions inside the docs.

## What the Docs tab is looking at

Docs root is `~/Desktop/rubric/docs/` — a hub of shortcuts, not copies. Editing a
file through this API edits the real file in the real repo.

| Folder | Points at |
|---|---|
| `mt-barbershop/` | `~/Desktop/MT-Barbershop-Systems` — `docs/` plus top-level markdown |
| `elis/` | `~/Desktop/elis-dulce-tradicion` — `docs/` plus top-level markdown |
| `maguey/` | `~/Desktop/Maguey-Nightclub-Live` — `docs/` plus top-level markdown |
| `amigos/` | `~/Desktop/Amigos-bakery-systema` — `docs/` plus top-level markdown |
| `shared/` | A real folder, not a shortcut. Cross-client notes. |

If the console is not running: `~/Desktop/rubric/start.sh`. The Docs server starts
automatically as a child of it on port 5055 — do not start it separately.

## Checking comments

There is no automatic pickup by design. Check when Luis asks, or before editing a
doc he has been reviewing.

```bash
# Plain-text summary of unresolved comments on one document
curl -s "http://localhost:5050/api/doc-comments/summary?path=mt-barbershop/docs/TEST_CHECKLIST.md"

# Full JSON, including already-resolved ones
curl -s "http://localhost:5050/api/doc-comments?path=mt-barbershop/docs/TEST_CHECKLIST.md"
```

Summary output looks like:

```
Comments on TEST_CHECKLIST.md:
Line 12: "old instruction" → "Should we update this?"
```

With none: `No comments on TEST_CHECKLIST.md`

**Sweeping every document at once.** Comments are stored one JSON file per document
in `~/Desktop/rubric/templates/docs/data/comments/`, named with `/` replaced by `--`.
To find everything unresolved without guessing paths:

```bash
grep -l '"resolved": *false' ~/Desktop/rubric/templates/docs/data/comments/*.json
```

Then convert a filename back to a path (`elis--docs--SETUP.md.json` → `elis/docs/SETUP.md`)
and call the summary endpoint for each.

After acting on a comment, resolve it so it stops reappearing:

```bash
curl -s -X PUT http://localhost:5050/api/doc-comments/<id> \
  -H 'Content-Type: application/json' -d '{"resolved": true}'
```

Get the `<id>` from the JSON endpoint, not the summary one.

## Reading and writing files

Every file operation is a **POST to `/api/docs`** with an `_action` field. There is
no GET or DELETE route for files — the shipped README examples that use them are wrong.

```bash
# Full recursive tree
curl -s -X POST http://localhost:5050/api/docs \
  -H 'Content-Type: application/json' -d '{"_action":"tree"}'

# Read
curl -s -X POST http://localhost:5050/api/docs \
  -H 'Content-Type: application/json' \
  -d '{"_action":"read","path":"elis/docs/SETUP.md"}'

# Overwrite
curl -s -X POST http://localhost:5050/api/docs \
  -H 'Content-Type: application/json' \
  -d '{"_action":"write","path":"shared/notes.md","content":"# Notes\n"}'
```

Other actions: `list` (one directory, with previews), `create`, `mkdir`, `rename`.

**Prefer the normal Read and Edit tools** when you already know the real path on disk.
This API is for when you are working from a comment, or from a path the tab showed him.
Writing through the API replaces the whole file — Edit is safer for partial changes.

## Two things that will bite you

**Delete is off.** `_action: "delete"` returns 403. These files are tracked in git
repos, and the tool's delete moves a file out of its repo into a trash folder. To
remove a doc, use git in the right repo. Re-enable only if Luis asks, by setting
`"allowDelete": true` in `~/Desktop/rubric/templates/docs/config.json`.

**Comments are keyed by path.** Rename or move a document and its comments orphan —
the JSON file stays under the old name and the summary endpoint returns nothing for
the new path. If you rename a doc that has comments, rename its comment file to match.
