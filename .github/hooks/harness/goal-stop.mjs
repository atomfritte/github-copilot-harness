// agentStop hook: the goal loop.
//
// When the main agent wants to end its turn while a goal is active, this hook decides:
//   1. run the goal's required checks (named commands from config.json); a failure forces another turn
//   2. otherwise require a verdict from the goal-judge subagent, captured by goal-verdict.mjs
//   3. MET or IMPOSSIBLE releases the goal; NOT_MET forces another turn with the judge's reason
//
// {"decision":"block","reason":"..."} forces another turn and `reason` becomes its prompt.
// The Copilot runtime ends the turn anyway after 8 consecutive blocks; the goal then stays
// active and the next stop is evaluated again.
import { spawnSync } from 'node:child_process';
import {
  GOAL_CLI,
  REPO_ROOT,
  emit,
  isActive,
  isForeign,
  loadConfig,
  loadGoal,
  readEvent,
  record,
  runHook,
  saveGoal,
  tail,
} from './lib.mjs';

// Stay below the hook's own timeoutSec (900): a timed-out hook fails open and the agent just stops.
const BUDGET_MS = Number(process.env.HARNESS_STOP_BUDGET_SEC ?? 840) * 1000;
const startedAt = Date.now();

function finish(goal, status, reason) {
  goal.status = status;
  goal.lastReason = reason;
  record(goal, status, reason);
  saveGoal(goal);
  emit({});
}

function block(goal, reason) {
  goal.blocks += 1;
  const lastTurn = goal.turns >= goal.maxTurns;
  const footer = lastTurn
    ? `This is the last forced turn (${goal.turns} of ${goal.maxTurns}). If the goal cannot be finished in it, end by stating plainly what is done, what remains, and what blocked you.`
    : `(goal turn ${goal.turns} of ${goal.maxTurns})`;
  saveGoal(goal);
  emit({ decision: 'block', reason: `${reason}\n\n${footer}` });
}

function runCheck(command, timeoutSec) {
  const remaining = BUDGET_MS - (Date.now() - startedAt);
  if (remaining < 5000) return { ok: false, summary: 'not run: the stop hook ran out of time. Raise timeoutSec in .github/hooks/harness.json or use faster checks.' };
  const result = spawnSync(command, {
    cwd: REPO_ROOT,
    shell: true,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    timeout: Math.min(timeoutSec * 1000, remaining),
    maxBuffer: 32 * 1024 * 1024,
  });
  if (result.error?.code === 'ETIMEDOUT') return { ok: false, summary: `timed out after ${timeoutSec}s` };
  if (result.error) return { ok: false, summary: `could not start: ${result.error.message}` };
  if (result.status === 0) return { ok: true };
  return { ok: false, summary: `exit code ${result.status}`, output: tail(`${result.stdout}\n${result.stderr}`) };
}

runHook(() => {
  const ev = readEvent();
  const goal = loadGoal();
  if (!isActive(goal) || isForeign(goal, ev.sessionId)) return emit({});

  const cfg = loadConfig();
  if (!goal.sessionId) goal.sessionId = ev.sessionId;

  goal.turns += 1;
  if (goal.turns > goal.maxTurns) {
    return finish(goal, 'exhausted', `Turn budget of ${goal.maxTurns} used up without the goal being verified.`);
  }

  // 1. Deterministic checks.
  for (const name of goal.checks) {
    const command = cfg.goal.checks[name];
    if (!command) {
      return finish(goal, 'impossible', `Check "${name}" is no longer defined in .github/hooks/harness/config.json.`);
    }
    const result = runCheck(command, cfg.goal.checkTimeoutSec);
    if (!result.ok) {
      goal.lastReason = `Check "${name}" failed (${result.summary}).`;
      record(goal, 'check-failed', goal.lastReason);
      return block(
        goal,
        [
          `[harness /goal] The required check "${name}" failed (${result.summary}), so the goal is not met and this turn cannot end yet.`,
          `Goal: ${goal.condition}`,
          `Command: ${command}`,
          result.output ? `Last output:\n${result.output}` : null,
          'Find and fix the cause. Do not weaken, skip or delete the check or the tests behind it. Then finish the turn again; the check reruns automatically.',
        ]
          .filter(Boolean)
          .join('\n'),
      );
    }
  }
  if (!goal.judge) return finish(goal, 'achieved', `All required checks passed: ${goal.checks.join(', ')}.`);

  // 2. Verdict from the goal-judge subagent. A verdict is used once.
  const verdict = goal.verdict;
  goal.verdict = null;

  if (!verdict) {
    goal.missingVerdicts += 1;
    if (goal.missingVerdicts >= cfg.goal.relayAfterMissingVerdicts) goal.allowRelay = true;
    record(goal, 'judge-requested', `no verdict yet (${goal.missingVerdicts} in a row)`);
    return block(
      goal,
      [
        '[harness /goal] A goal is active and has not been verified, so this turn cannot end yet.',
        `Goal: ${goal.condition}`,
        goal.checks.length ? `Required checks currently pass: ${goal.checks.join(', ')}.` : null,
        'Do this now:',
        '1. If work remains, keep working toward the goal.',
        `2. When you believe the goal is met, delegate to the \`${cfg.goal.judgeAgent}\` subagent. Give it the goal text verbatim plus a short list of what you changed and where the evidence is. Do not suggest a verdict.`,
        '3. If it answers NOT_MET, fix what it names and ask it again. If you are blocked on something only the user can provide, tell the judge exactly that: an IMPOSSIBLE verdict releases the goal.',
        goal.allowRelay
          ? `The judge's verdict was not captured automatically in this environment. After the judge answers, record its verdict and reason verbatim with: ${GOAL_CLI} verdict <MET|NOT_MET|IMPOSSIBLE> "<reason>"`
          : null,
      ]
        .filter(Boolean)
        .join('\n'),
    );
  }

  goal.missingVerdicts = 0;
  goal.lastReason = `Judge: ${verdict.result}. ${verdict.reason}`;

  if (verdict.result === 'MET') return finish(goal, 'achieved', goal.lastReason);
  if (verdict.result === 'IMPOSSIBLE') return finish(goal, 'impossible', goal.lastReason);

  record(goal, 'not-met', verdict.reason);
  return block(
    goal,
    [
      '[harness /goal] The goal judge found the goal NOT met, so this turn cannot end yet.',
      `Goal: ${goal.condition}`,
      `Judge's reason: ${verdict.reason}`,
      `Address exactly that, then ask the \`${cfg.goal.judgeAgent}\` subagent again before you finish the turn.`,
    ].join('\n'),
  );
});
