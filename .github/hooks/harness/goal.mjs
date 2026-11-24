#!/usr/bin/env node
// Command line for the goal state. Used by the /goal skill and by people.
//
//   node .github/hooks/harness/goal.mjs status
//   node .github/hooks/harness/goal.mjs set [--check <name>]... [--max-turns <n>] [--no-judge] <condition>
//   node .github/hooks/harness/goal.mjs clear
//   node .github/hooks/harness/goal.mjs resume
//   node .github/hooks/harness/goal.mjs verdict <MET|NOT_MET|IMPOSSIBLE> <reason>
import {
  clearGoal,
  describeGoal,
  isActive,
  loadConfig,
  loadGoal,
  newGoal,
  parseGoalRequest,
  record,
  sameGoal,
  saveGoal,
  validateGoalRequest,
} from './lib.mjs';

const [command = 'status', ...args] = process.argv.slice(2);
const cfg = loadConfig();
const goal = loadGoal();

function fail(message) {
  console.error(message);
  process.exit(1);
}

switch (command) {
  case 'status': {
    if (!goal) console.log('No goal is set.');
    else console.log(describeGoal(goal));
    break;
  }

  case 'set': {
    const req = parseGoalRequest(args.join(' '));
    if (req.action !== 'set') fail('Usage: goal.mjs set [--check <name>]... [--max-turns <n>] [--no-judge] <condition>');
    const error = validateGoalRequest(req, cfg);
    if (error) fail(error);
    if (sameGoal(goal, req)) {
      console.log(`Goal already active.\n${describeGoal(goal)}`);
      break;
    }
    const next = newGoal(req, cfg);
    record(next, 'set', next.condition);
    saveGoal(next);
    console.log(`Goal set.\n${describeGoal(next)}`);
    break;
  }

  case 'clear': {
    if (!goal) console.log('No goal is set.');
    else {
      clearGoal();
      console.log(`Goal cleared (was ${goal.status}): ${goal.condition}`);
    }
    break;
  }

  case 'resume': {
    if (!goal) fail('No goal to resume.');
    goal.status = 'active';
    goal.sessionId = null; // Bound again by the next session that reaches a stop.
    goal.turns = 0;
    goal.blocks = 0;
    goal.missingVerdicts = 0;
    goal.verdict = null;
    record(goal, 'resume', 'turn budget reset');
    saveGoal(goal);
    console.log(`Goal resumed.\n${describeGoal(goal)}`);
    break;
  }

  case 'verdict': {
    if (!isActive(goal)) fail('No active goal.');
    if (!goal.allowRelay) {
      fail('Verdicts are recorded automatically when the goal-judge subagent finishes. Delegate to goal-judge instead of recording a verdict yourself.');
    }
    const result = String(args[0] ?? '').toUpperCase().replace(/[\s-]+/g, '_');
    if (!['MET', 'NOT_MET', 'IMPOSSIBLE'].includes(result)) fail('Usage: goal.mjs verdict <MET|NOT_MET|IMPOSSIBLE> <reason>');
    const reason = args.slice(1).join(' ').trim();
    if (!reason) fail('Give the judge\'s reason, verbatim.');
    goal.verdict = { result, reason, at: new Date().toISOString(), source: 'relayed' };
    record(goal, 'verdict-relayed', `${result}: ${reason}`);
    saveGoal(goal);
    console.log(`Recorded ${result}.`);
    break;
  }

  default:
    fail(`Unknown command "${command}". Use status, set, clear, resume or verdict.`);
}
