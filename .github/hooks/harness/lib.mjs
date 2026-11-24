// Shared helpers for the harness hooks. No dependencies; needs Node.js 18+.
//
// Hook contract (GitHub Copilot hooks reference):
//   - the event arrives as one JSON object on stdin
//   - the hook answers with exactly one JSON object on stdout
//   - diagnostics go to stderr only, because stray stdout text invalidates the answer
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const HARNESS_DIR = path.dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = path.resolve(HARNESS_DIR, '..', '..', '..');
export const STATE_DIR = process.env.HARNESS_STATE_DIR || path.join(REPO_ROOT, '.harness');
export const GOAL_FILE = path.join(STATE_DIR, 'goal.json');
export const CONFIG_FILE = process.env.HARNESS_CONFIG || path.join(HARNESS_DIR, 'config.json');
export const GOAL_CLI = 'node .github/hooks/harness/goal.mjs';

export const MAX_CONDITION_CHARS = 4000;
const CLEAR_WORDS = new Set(['clear', 'stop', 'off', 'reset', 'none', 'cancel']);

const DEFAULT_CONFIG = {
  goal: {
    maxTurns: 20,
    judgeAgent: 'goal-judge',
    relayAfterMissingVerdicts: 2,
    checkTimeoutSec: 300,
    checks: {},
  },
  guard: { enabled: true, commands: [], paths: [] },
};

export function loadConfig() {
  let file = {};
  try {
    file = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));
  } catch (err) {
    if (err.code !== 'ENOENT') log(`config ignored (${CONFIG_FILE}): ${err.message}`);
  }
  const goal = { ...DEFAULT_CONFIG.goal, ...(file.goal ?? {}) };
  // Keys starting with "$" are comments, not checks.
  goal.checks = Object.fromEntries(
    Object.entries(goal.checks ?? {}).filter(([k, v]) => !k.startsWith('$') && typeof v === 'string'),
  );
  const guard = { ...DEFAULT_CONFIG.guard, ...(file.guard ?? {}) };
  return { goal, guard };
}

/** Read the hook event from stdin and normalise camelCase and snake_case payloads. */
export function readEvent() {
  let raw = '';
  try {
    if (!process.stdin.isTTY) raw = fs.readFileSync(0, 'utf8');
  } catch {
    // No stdin: treat as an empty event.
  }
  let e = {};
  try {
    if (raw.trim()) e = JSON.parse(raw);
  } catch {
    log('event ignored: stdin was not valid JSON');
  }
  if (e === null || typeof e !== 'object') e = {};
  debugLog(e);
  let toolArgs = e.toolArgs ?? e.tool_input;
  if (typeof toolArgs === 'string') {
    try {
      toolArgs = JSON.parse(toolArgs);
    } catch {
      // Keep the plain string, for example a raw patch.
    }
  }
  return {
    sessionId: e.sessionId ?? e.session_id ?? null,
    cwd: e.cwd ?? process.cwd(),
    source: e.source,
    prompt: e.prompt,
    toolName: e.toolName ?? e.tool_name,
    toolArgs,
    agentName: e.agentName ?? e.agent_name,
    agentDisplayName: e.agentDisplayName ?? e.agent_display_name,
    agentType: e.agentType ?? e.agent_type,
    response: e.response ?? e.last_assistant_message,
    stopHookActive: e.stop_hook_active === true,
  };
}

/**
 * Opt-in event trace for checking what the runtime really sends: create the file `.harness/debug`
 * and every hook appends its event to `.harness/events.log`, with long strings shortened.
 * The log can contain parts of prompts and tool arguments. It stays local and is gitignored.
 */
function debugLog(event) {
  try {
    if (!fs.existsSync(path.join(STATE_DIR, 'debug'))) return;
    const shorten = (_key, value) => (typeof value === 'string' && value.length > 200 ? `${value.slice(0, 200)}…` : value);
    const line = JSON.stringify({ at: new Date().toISOString(), hook: path.basename(process.argv[1] ?? ''), event }, shorten);
    fs.appendFileSync(path.join(STATE_DIR, 'events.log'), `${line}\n`);
  } catch {
    // Tracing must never break a hook.
  }
}

/** Write the single final hook answer. */
export function emit(output = {}) {
  process.stdout.write(JSON.stringify(output));
}

export function log(message) {
  process.stderr.write(`[harness] ${message}\n`);
}

/** Run a hook body so that an unexpected error never turns into a blocked tool call or a broken turn. */
export function runHook(body) {
  try {
    body();
  } catch (err) {
    log(`hook error: ${err?.stack ?? err}`);
    emit({});
  }
}

export function loadGoal() {
  try {
    const goal = JSON.parse(fs.readFileSync(GOAL_FILE, 'utf8'));
    return goal && typeof goal === 'object' && typeof goal.condition === 'string' ? goal : null;
  } catch {
    return null;
  }
}

export function saveGoal(goal) {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  goal.updatedAt = new Date().toISOString();
  const tmp = `${GOAL_FILE}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(goal, null, 2)}\n`);
  fs.renameSync(tmp, GOAL_FILE);
}

export function clearGoal() {
  fs.rmSync(GOAL_FILE, { force: true });
}

export function isActive(goal) {
  return Boolean(goal) && goal.status === 'active';
}

/** True when the goal belongs to another session and this one must leave it alone. */
export function isForeign(goal, sessionId) {
  return Boolean(goal.sessionId && sessionId && goal.sessionId !== sessionId);
}

/**
 * Parse the text after `/goal`.
 * Returns { action: 'status' | 'clear' | 'resume' } or
 * { action: 'set', condition, checks, maxTurns, judge }.
 */
export function parseGoalRequest(text) {
  let rest = String(text ?? '').trim();
  const checks = [];
  let maxTurns = null;
  let judge = true;
  for (;;) {
    let m;
    if ((m = /^--check(?:=|\s+)([A-Za-z0-9_.-]+)\s*/.exec(rest))) checks.push(m[1]);
    else if ((m = /^--max-turns(?:=|\s+)(\d+)\s*/.exec(rest))) maxTurns = Number(m[1]);
    else if ((m = /^--no-judge\b\s*/.exec(rest))) judge = false;
    else break;
    rest = rest.slice(m[0].length);
  }
  const condition = rest.trim().replace(/^(["'])([\s\S]*)\1$/, '$2').trim();
  const word = condition.toLowerCase();
  if (!checks.length && maxTurns === null && judge) {
    if (!condition) return { action: 'status' };
    if (CLEAR_WORDS.has(word)) return { action: 'clear' };
    if (word === 'resume') return { action: 'resume' };
  }
  return { action: 'set', condition, checks, maxTurns, judge };
}

/** Validate a set request. Returns an error message, or null when it is acceptable. */
export function validateGoalRequest(req, cfg) {
  const known = Object.keys(cfg.goal.checks);
  const unknown = req.checks.filter((c) => !known.includes(c));
  if (unknown.length) {
    return `Unknown check(s): ${unknown.join(', ')}. Checks are defined in .github/hooks/harness/config.json (goal.checks). Available: ${known.join(', ') || 'none yet'}.`;
  }
  if (!req.condition && !req.checks.length) return 'A goal needs a completion condition.';
  if (!req.judge && !req.checks.length) return '--no-judge needs at least one --check, otherwise nothing verifies the goal.';
  if (req.condition.length > MAX_CONDITION_CHARS) return `The condition is longer than ${MAX_CONDITION_CHARS} characters.`;
  if (req.maxTurns !== null && (req.maxTurns < 1 || req.maxTurns > 200)) return '--max-turns must be between 1 and 200.';
  return null;
}

export function newGoal(req, cfg, sessionId = null) {
  const now = new Date().toISOString();
  return {
    version: 1,
    condition: req.condition || `All required checks pass: ${req.checks.join(', ')}`,
    checks: req.checks,
    judge: req.judge,
    maxTurns: req.maxTurns ?? cfg.goal.maxTurns,
    status: 'active',
    sessionId,
    createdAt: now,
    updatedAt: now,
    turns: 0,
    blocks: 0,
    missingVerdicts: 0,
    allowRelay: false,
    verdict: null,
    lastReason: null,
    history: [],
  };
}

export function sameGoal(goal, req) {
  return (
    isActive(goal) &&
    goal.condition === (req.condition || goal.condition) &&
    JSON.stringify(goal.checks) === JSON.stringify(req.checks) &&
    goal.judge === req.judge
  );
}

export function record(goal, event, detail) {
  goal.history.push({ at: new Date().toISOString(), turn: goal.turns, event, detail: clip(detail, 500) });
  if (goal.history.length > 50) goal.history.splice(0, goal.history.length - 50);
}

export function describeGoal(goal) {
  const lines = [
    `Goal: ${goal.condition}`,
    `Status: ${goal.status} (turn ${goal.turns} of ${goal.maxTurns}, ${goal.blocks} forced continuation(s))`,
  ];
  if (goal.checks.length) lines.push(`Required checks: ${goal.checks.join(', ')}`);
  lines.push(`Verified by: ${goal.judge ? 'goal-judge subagent' : 'checks only'}`);
  if (goal.lastReason) lines.push(`Last result: ${goal.lastReason}`);
  return lines.join('\n');
}

/** Extract the last `GOAL_VERDICT:` line and its `REASON:` from a judge answer. */
export function parseVerdict(text) {
  const answer = String(text ?? '');
  // The verdict word must end its line, so an echoed template ("MET | NOT_MET | IMPOSSIBLE") is not a verdict.
  const last = [...answer.matchAll(/GOAL_VERDICT:[ \t*`]*(NOT[_ -]?MET|MET|IMPOSSIBLE)[ \t*`.]*$/gim)].at(-1);
  if (!last) return null;
  const word = last[1].toUpperCase();
  const result = word.startsWith('NOT') ? 'NOT_MET' : word;
  const after = answer.slice(last.index + last[0].length);
  const reason = /REASON:[\s*`]*([\s\S]+)/i.exec(after)?.[1]?.trim() ?? '';
  return { result, reason: clip(reason || 'No reason given.', 1500) };
}

/** Convert a glob (`**`, `*`, `?`) into an anchored RegExp for forward-slash paths. */
export function globToRegExp(glob) {
  let re = '';
  for (let i = 0; i < glob.length; i += 1) {
    const c = glob[i];
    if (c === '*') {
      if (glob[i + 1] === '*') {
        i += 1;
        if (glob[i + 1] === '/') {
          i += 1;
          re += '(?:.*/)?';
        } else {
          re += '.*';
        }
      } else {
        re += '[^/]*';
      }
    } else if (c === '?') {
      re += '[^/]';
    } else {
      re += c.replace(/[.+^${}()|[\]\\]/g, '\\$&');
    }
  }
  return new RegExp(`^${re}$`);
}

export function clip(text, max) {
  const s = String(text ?? '');
  return s.length <= max ? s : `${s.slice(0, max - 1)}…`;
}

/** Keep the end of long command output, which is where failures are reported. */
export function tail(text, maxChars = 4000, maxLines = 60) {
  const lines = String(text ?? '').trimEnd().split(/\r?\n/).slice(-maxLines);
  const out = lines.join('\n');
  return out.length <= maxChars ? out : `…${out.slice(-maxChars)}`;
}

export function slug(name) {
  return String(name ?? '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
}
