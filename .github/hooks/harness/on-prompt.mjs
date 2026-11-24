// userPromptSubmitted hook: registers `/goal ...` deterministically, bound to the session that typed it.
//
// The output of command hooks is dropped for this event, so this hook only updates state.
// The /goal skill reads that state back and reports to the user. If the runtime ever stops
// delivering the raw slash command here, the skill falls back to `goal.mjs set`.
import {
  clearGoal,
  emit,
  loadConfig,
  loadGoal,
  newGoal,
  parseGoalRequest,
  readEvent,
  record,
  runHook,
  sameGoal,
  saveGoal,
  validateGoalRequest,
} from './lib.mjs';

runHook(() => {
  const ev = readEvent();
  const match = /^\s*\/goal(?:\s+([\s\S]*))?$/.exec(ev.prompt ?? '');
  if (!match) return emit({});

  const cfg = loadConfig();
  const goal = loadGoal();
  const req = parseGoalRequest(match[1] ?? '');

  if (req.action === 'clear') {
    clearGoal();
  } else if (req.action === 'resume' && goal) {
    Object.assign(goal, { status: 'active', sessionId: ev.sessionId, turns: 0, blocks: 0, missingVerdicts: 0, verdict: null });
    record(goal, 'resume', 'turn budget reset');
    saveGoal(goal);
  } else if (req.action === 'set' && !validateGoalRequest(req, cfg)) {
    // An invalid request is left for the skill to report through `goal.mjs set`.
    if (sameGoal(goal, req)) {
      if (!goal.sessionId) {
        goal.sessionId = ev.sessionId;
        saveGoal(goal);
      }
    } else {
      const next = newGoal(req, cfg, ev.sessionId);
      record(next, 'set', next.condition);
      saveGoal(next);
    }
  }
  emit({});
});
