// sessionStart hook: tells a new or resumed session about a goal that is still open,
// so a goal survives restarts, resumes and context compaction.
import { GOAL_CLI, describeGoal, emit, isActive, isForeign, loadGoal, readEvent, runHook } from './lib.mjs';

runHook(() => {
  const ev = readEvent();
  const goal = loadGoal();
  if (!goal) return emit({});

  if (isActive(goal) && !isForeign(goal, ev.sessionId)) {
    return emit({
      additionalContext: [
        '[harness] A goal is active in this workspace. Keep working toward it; the turn cannot end until the goal-judge subagent confirms it.',
        describeGoal(goal),
        `The user can clear it with /goal clear (or: ${GOAL_CLI} clear).`,
      ].join('\n'),
    });
  }

  if (isActive(goal) || goal.status === 'exhausted') {
    return emit({
      additionalContext: [
        `[harness] An unfinished goal from an earlier session exists (${goal.status}). It does not bind this session.`,
        describeGoal(goal),
        'Mention it once if it looks related to what the user asks. The user can adopt it with /goal resume or drop it with /goal clear.',
      ].join('\n'),
    });
  }

  emit({});
});
