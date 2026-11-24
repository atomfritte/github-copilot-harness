// preToolUse hook: deny or escalate risky shell commands and file access, by rule.
//
// Rules live in config.json (guard.commands, guard.paths). This is the hook-level counterpart of
// Claude Code's permission deny/ask rules. It is a seat belt, not a security boundary: command
// matching is best effort, and enforced limits belong in enterprise-managed settings and sandboxing.
//
// A crashing preToolUse hook denies the tool call (fail closed), so every path through this file
// ends in a valid answer; anything unrecognised gets `{}`, which means "no decision".
import path from 'node:path';
import { REPO_ROOT, emit, globToRegExp, loadConfig, readEvent, runHook } from './lib.mjs';

const SHELL_TOOLS = new Set(['bash', 'powershell', 'shell', 'execute', 'run_in_terminal']);
const WRITE_TOOLS = new Set(['create', 'edit', 'str_replace_editor', 'apply_patch', 'write', 'multiedit']);
const READ_TOOLS = new Set(['view', 'read']);
const COMMAND_KEYS = ['command', 'cmd', 'script', 'commandLine'];
const PATH_KEYS = ['path', 'file_path', 'filePath', 'file', 'filename', 'target_file'];

function commandOf(args) {
  if (typeof args === 'string') return args;
  if (!args || typeof args !== 'object') return null;
  for (const key of COMMAND_KEYS) if (typeof args[key] === 'string') return args[key];
  return null;
}

function pathsOf(args) {
  const found = [];
  const patchPaths = (text) => {
    for (const m of text.matchAll(/^\*\*\* (?:Add|Update|Delete) File: (.+)$/gm)) found.push(m[1].trim());
  };
  if (typeof args === 'string') patchPaths(args);
  else if (args && typeof args === 'object') {
    for (const key of PATH_KEYS) if (typeof args[key] === 'string') found.push(args[key]);
    if (Array.isArray(args.paths)) found.push(...args.paths.filter((p) => typeof p === 'string'));
    for (const key of ['patch', 'input', 'diff']) if (typeof args[key] === 'string') patchPaths(args[key]);
  }
  return found.map((p) => {
    const rel = path.relative(REPO_ROOT, path.resolve(REPO_ROOT, p));
    return rel.split(path.sep).join('/');
  });
}

function answer(rule, subject) {
  const decision = rule.decision === 'ask' ? 'ask' : 'deny';
  return emit({
    permissionDecision: decision,
    permissionDecisionReason: `[harness guard] ${rule.reason ?? 'Blocked by a guard rule.'} (${subject})`,
  });
}

runHook(() => {
  const ev = readEvent();
  const cfg = loadConfig().guard;
  const tool = String(ev.toolName ?? '').toLowerCase();
  if (!cfg.enabled || !tool) return emit({});

  if (SHELL_TOOLS.has(tool)) {
    const command = commandOf(ev.toolArgs);
    if (!command) return emit({});
    for (const rule of cfg.commands ?? []) {
      let re;
      try {
        re = new RegExp(rule.pattern);
      } catch {
        continue; // A broken rule must not block every command.
      }
      if (re.test(command)) return answer(rule, 'shell command');
    }
    return emit({});
  }

  const access = WRITE_TOOLS.has(tool) ? 'write' : READ_TOOLS.has(tool) ? 'read' : null;
  if (!access) return emit({});
  for (const file of pathsOf(ev.toolArgs)) {
    for (const rule of cfg.paths ?? []) {
      if (rule.access !== 'any' && rule.access !== access) continue;
      if ((rule.except ?? []).some((g) => globToRegExp(g).test(file))) continue;
      if (globToRegExp(rule.glob).test(file)) return answer(rule, file);
    }
  }
  emit({});
});
