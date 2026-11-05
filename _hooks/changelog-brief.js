#!/usr/bin/env node
/**
 * SessionStart hook: brings the session's repo up to date and prints its most
 * recent changelog entries, so Claude Code starts a session knowing what the
 * team changed.
 *
 * Wired into ~/.claude/settings.json under SessionStart (see settings.hooks.json).
 * Claude Code adds SessionStart stdout to the session context.
 *
 * 1. Finds the git repo of the session cwd (from the hook's stdin JSON).
 * 2. Only if the working tree is clean AND the branch has an upstream:
 *    `git pull --ff-only` (5 s timeout, no prompts). Never merges, rebases,
 *    stashes or touches a dirty tree.
 * 3. Prints the last 5 `## ` entries of docs/CHANGELOG.md (or CHANGELOG.md).
 *
 * Safe by design: every failure is swallowed, it always exits 0, and a repo
 * without a changelog prints nothing.
 */
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const MAX_ENTRIES = 5;
const MAX_LINES_PER_ENTRY = 6;

function git(cwd, args, timeout = 3000) {
  return execFileSync('git', args, {
    cwd, timeout, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
    env: { ...process.env, GIT_TERMINAL_PROMPT: '0', GIT_ASKPASS: 'echo' },
  }).trim();
}

function readStdin() {
  try { return fs.readFileSync(0, 'utf8'); } catch { return ''; }
}

function main() {
  let cwd = process.cwd();
  try { const j = JSON.parse(readStdin() || '{}'); if (j.cwd) cwd = j.cwd; } catch {}

  let root;
  try { root = git(cwd, ['rev-parse', '--show-toplevel']); } catch { return; }

  const file = ['docs/CHANGELOG.md', 'CHANGELOG.md'].map(f => path.join(root, f)).find(f => fs.existsSync(f));
  if (!file) return;

  let note = '';
  try {
    const dirty = git(root, ['status', '--porcelain']);
    let upstream = '';
    try { upstream = git(root, ['rev-parse', '--abbrev-ref', '@{u}']); } catch {}
    if (dirty) note = 'not pulled: working tree has changes';
    else if (!upstream) note = 'not pulled: branch has no upstream';
    else {
      const before = git(root, ['rev-parse', 'HEAD']);
      git(root, ['pull', '--ff-only', '--quiet'], 5000);
      note = git(root, ['rev-parse', 'HEAD']) === before ? `up to date with ${upstream}` : `pulled ${upstream} (fast-forward)`;
    }
  } catch { note = 'pull skipped or failed (offline, diverged, or slow); showing local copy'; }

  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch { return; }
  const entries = [];
  let cur = null;
  for (const line of text.split('\n')) {
    if (/^## \d{4}-\d{2}-\d{2}/.test(line)) { if (entries.length >= MAX_ENTRIES) break; cur = [line]; entries.push(cur); }
    else if (cur && line.trim() && cur.length < MAX_LINES_PER_ENTRY && !/^#/.test(line)) cur.push(line);
    else if (/^#{1,2} /.test(line) || /^```/.test(line)) cur = null;
  }
  // Skip entries inside the format example (fenced code) by requiring a date.
  const real = entries.filter(e => /^## \d{4}-\d{2}-\d{2}/.test(e[0]));
  if (!real.length) return;

  const rel = path.relative(root, file);
  console.log(`Recent changes in ${path.basename(root)} (${rel}; ${note}):`);
  for (const e of real) console.log(e.join('\n'));
  console.log(`Full log: ${rel}. Add an entry in any PR that changes behavior.`);
}

try { main(); } catch {}
process.exit(0);
