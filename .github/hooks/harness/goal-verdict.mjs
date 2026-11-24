// subagentStop hook: captures the goal-judge subagent's verdict.
//
// The verdict is taken from the judge's own final answer, not from anything the working agent
// writes, so the agent doing the work is not the one deciding that the work is done.
// The judge must end its answer with:
//   GOAL_VERDICT: MET | NOT_MET | IMPOSSIBLE
//   REASON: <one or two sentences>
import { emit, isActive, isForeign, loadConfig, loadGoal, parseVerdict, readEvent, record, runHook, saveGoal, slug } from './lib.mjs';

runHook(() => {
  const ev = readEvent();
  const goal = loadGoal();
  if (!isActive(goal) || isForeign(goal, ev.sessionId)) return emit({});

  const cfg = loadConfig();
  const judge = slug(cfg.goal.judgeAgent);
  const names = [ev.agentName, ev.agentDisplayName, ev.agentType].map(slug);
  if (!names.includes(judge)) return emit({});

  const verdict = parseVerdict(ev.response);
  if (!verdict) {
    // Send the judge back once more rather than losing its work.
    return emit({
      decision: 'block',
      reason:
        'Your answer has no verdict. End it with exactly these two lines:\nGOAL_VERDICT: MET | NOT_MET | IMPOSSIBLE\nREASON: <one or two sentences naming the evidence or what is missing>',
    });
  }

  if (!goal.sessionId) goal.sessionId = ev.sessionId;
  goal.verdict = { ...verdict, at: new Date().toISOString(), source: 'judge' };
  record(goal, 'verdict', `${verdict.result}: ${verdict.reason}`);
  saveGoal(goal);
  emit({});
});
