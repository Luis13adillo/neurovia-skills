#!/usr/bin/env node
/**
 * Reports Claude Code session activity to the RUBRIC dashboard.
 *
 * Wired into ~/.claude/settings.json for SessionStart, UserPromptSubmit,
 * Notification, Stop and SessionEnd. Works out which business the session
 * belongs to, then posts a status update.
 *
 * Safe by design: never blocks, never fails a session, never prints anything.
 * If the dashboard isn't running the request is refused instantly and this
 * exits 0. Sessions that don't belong to a business are ignored.
 */
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

const PORT = process.env.RUBRIC_PORT || 5050;
const TOKEN = process.env.RUBRIC_TOKEN || '';
const DEADLINE_MS = 400;

// Repository folder name -> Rubric agent id. Matched on the folder name rather
// than one fixed absolute path, so a repo still resolves after it is moved or
// cloned to a second location.
const BUSINESSES = [
  ['MT-Barbershop-Systems', 'mt-barbershop'],
  ['elis-dulce-tradicion', 'elis-bakery'],
  ['Maguey-Nightclub-Live', 'maguey-nightclub'],
  ['Amigos-bakery-systema', 'amigos-bakery'],
];

const ACTIVE_EVENTS = new Set(['SessionStart', 'UserPromptSubmit']);
const AGENT_ID_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;

function bail() { process.exit(0); }

// Walk up looking for a repository root. Pure fs, so the hook never pays to
// spawn git on every prompt. `.git` is a directory in a normal clone and a
// file inside a worktree; both count.
function findGitRoot(startDir) {
  let dir = path.resolve(startDir);
  for (let i = 0; i < 40; i++) {
    if (fs.existsSync(path.join(dir, '.git'))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
  return null;
}

// Explicit setting wins, then the repository the session is actually in, then
// the directory path. Returns null when the session belongs to no business —
// working on Rubric itself is not working on a client.
function resolveAgent(cwd) {
  const explicit = (process.env.RUBRIC_AGENT || '').trim();
  // An explicit setting that is malformed reports nothing rather than falling
  // through: guessing would attribute the work to the wrong business.
  if (explicit) return AGENT_ID_RE.test(explicit) ? explicit : null;

  const root = findGitRoot(cwd);
  if (root) {
    const name = path.basename(root);
    const byRepo = BUSINESSES.find(([dir]) => dir === name);
    if (byRepo) return byRepo[1];
  }

  const byPath = BUSINESSES.find(([dir]) => cwd.includes(dir));
  return byPath ? byPath[1] : null;
}

// Returns null for events that are not a status change, so they leave the
// current status alone.
function statusFor(event, payload) {
  if (ACTIVE_EVENTS.has(event)) return { status: 'active', task: 'working' };

  if (event === 'Notification') {
    // Claude Code notifies on two things that both mean the session has
    // stopped and is waiting on a human: a permission prompt, and an idle
    // wait for input.
    const msg = String(payload.message || '');
    if (/permission/i.test(msg)) return { status: 'waiting', task: 'waiting for approval' };
    if (/waiting for your input/i.test(msg)) return { status: 'waiting', task: 'waiting for input' };
    return null;
  }

  return { status: 'idle', task: 'session idle' };
}

let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => { raw += chunk; });
process.stdin.on('end', () => {
  let payload = {};
  try { payload = JSON.parse(raw); } catch { return bail(); }

  const cwd = payload.cwd || process.cwd();
  const agent = resolveAgent(cwd);
  if (!agent) return bail();

  const next = statusFor(payload.hook_event_name || '', payload);
  if (!next) return bail();

  const body = JSON.stringify({ agent, status: next.status, task: next.task });

  const headers = { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) };
  if (TOKEN) headers['x-rubric-token'] = TOKEN;

  const req = http.request(
    { host: '127.0.0.1', port: PORT, path: '/api/agent-status', method: 'POST', headers },
    res => { res.resume(); res.on('end', bail); }
  );
  req.on('error', bail);
  req.setTimeout(DEADLINE_MS, () => { req.destroy(); bail(); });
  req.end(body);
});
process.stdin.on('error', bail);
setTimeout(bail, DEADLINE_MS + 100).unref();
