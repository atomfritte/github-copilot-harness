# Smoke test

The hook scripts are tested against the event payloads GitHub documents (`node --test tests/`). What that cannot show is how your VS Code version, policies and environment behave. This checklist takes about fifteen minutes and confirms each mechanism in a live session. Use a throwaway branch.

Turn on the event trace first, so that every answer below can be read from a file instead of guessed:

```text
mkdir -p .harness && touch .harness/debug
```

Each hook now appends the event it received to `.harness/events.log`.

## 0. Prerequisites

- [ ] `scripts/setup-check.ps1` reports no failures. It covers the two points below and your VS Code settings and policies.
- [ ] `node --version` prints 18 or later in the environment where the agent runs (inside the dev container or remote host, if you use one).
- [ ] `node --test tests/` passes.
- [ ] The workspace is trusted, and **Copilot** is selected in the **Session Target** control.

## 1. Customisations are discovered

Run **Chat: Open Customizations**.

- [ ] **Agents** lists `explorer`, `planner`, `implementer`, `reviewer`, `verifier`, `goal-judge` with no file errors.
- [ ] **Skills** lists `goal`, `workflow`, `fan-out`, `deep-review`.
- [ ] **Hooks** lists the five entries from `.github/hooks/harness.json`.
- [ ] Typing `/` in the chat input offers the four skills.

If hooks are missing, your organisation may restrict hook sources. See [enterprise.md](enterprise.md).

## 2. Hooks fire

Start a new session and send: `List the files in the repository root.`

- [ ] `.harness/events.log` contains lines from `session-start.mjs`, `on-prompt.mjs` and `guard.mjs`.
- [ ] The `guard.mjs` lines show `toolName` and `toolArgs`. Note the tool names and argument keys your runtime uses.

If the log stays empty, hooks are not running: check the session target, the policy, and Node.js.

## 3. Subagents are delegated to

Send: `Use the explorer subagent to find where the goal state file is written. Report its findings.`

- [ ] The chat shows a subagent indicator for `explorer`, not just a description of what a subagent would do.
- [ ] Its tool activity is limited to reading and searching.
- [ ] `events.log` has a `goal-verdict.mjs` line for it (that script receives every `subagentStop`). Note the `agentName` value.

## 4. The guard answers

Create an empty `.env` if none exists, then send: `Open the file .env with your file viewing tool, not the terminal, and tell me what is in it.`

- [ ] The read is denied with a message starting `[harness guard]`.

Path rules cover the file tools only. If the agent used a shell command such as `cat .env`, the rule did not apply; that is the documented limit of the guard, not a failure of this step. If the file tool was used and not denied, compare the argument keys in `events.log` with `PATH_KEYS` in `.github/hooks/harness/guard.mjs` and the tool name with `READ_TOOLS`, and add what your runtime uses.

## 5. A goal holds the turn open

Send:

```text
/goal docs/scratch.md exists and contains exactly three lines, each a different prime number
```

- [ ] `node .github/hooks/harness/goal.mjs status` shows the goal as active. If `events.log` shows `on-prompt.mjs` received the raw `/goal ...` text, the goal has a session ID straight away; otherwise the skill registered it through the CLI.
- [ ] The agent starts working without a further prompt.
- [ ] The agent delegates to `goal-judge` before finishing.
- [ ] After the judge answers, `.harness/goal.json` contains a `verdict` (until the next stop consumes it) or the status is `achieved`.
- [ ] The turn ends and `goal.mjs status` shows `achieved`.

Now test the blocking path on its own. Set a goal from your own terminal, so the agent has not been told about it:

```text
node .github/hooks/harness/goal.mjs set "docs/scratch.md contains exactly five lines"
```

Then send a message that has nothing to do with it: `Say hello and end your turn.`

- [ ] The agent's attempt to stop is followed by a new turn that begins with `[harness /goal] A goal is active and has not been verified`. This is the `agentStop` block working.
- [ ] The agent then does the work, asks the judge, and the goal ends as `achieved`.

If the agent stops and no forced turn follows, `events.log` tells you which case you are in:

| `events.log` shows | Meaning |
|---|---|
| no `goal-stop.mjs` line | The `agentStop` hook did not run. Hook policy, harness, or a version without this event. |
| a `goal-stop.mjs` line, but no new turn | The hook ran and its block decision was not honoured by this runtime version. Enforcement is unavailable; use Autopilot with `chat.autopilot.advanced.enabled` and the skill's soft mode. |
| a `goal-stop.mjs` line with a different `sessionId` than the goal's | Session binding mismatch. Run `/goal resume` in the session that should own the goal. |

## 6. A required check gates the goal

Add a check that fails on purpose to `.github/hooks/harness/config.json`:

```json
"checks": { "always-fail": "node -e \"console.log('simulated failure'); process.exit(1)\"" }
```

Send: `/goal --check always-fail --max-turns 2 docs/scratch.md exists`

- [ ] The forced turn quotes `The required check "always-fail" failed (exit code 1)` and the output `simulated failure`.
- [ ] After two attempts the goal is `exhausted` and the turn ends.

Remove the check afterwards.

## 7. The workflows run

- [ ] `/workflow add a line with the next prime number to docs/scratch.md and explain the choice in a comment`: stages are visible, subagents are used, a report with verification comes back.
- [ ] `/deep-review`: reviewers run in parallel, findings are verified, the report states what was reviewed.

## 8. Clean up

```text
node .github/hooks/harness/goal.mjs clear
rm -rf .harness docs/scratch.md .env
```

## What to record

Agent hooks are in preview, so keep a note of what you observed with the VS Code version. Three details decide how well the goal loop works in your environment:

1. Does `userPromptSubmitted` deliver the raw `/goal` text? (step 5)
2. Does `subagentStop` deliver the judge's name and answer? (steps 3 and 5)
3. Does an `agentStop` block decision force another turn? (step 5)

If all three hold, `/goal` is fully enforced. If only the third holds, it still works through the fallbacks. If the third fails, the harness gives you the skills, the subagents and the guard, and `/goal` becomes a convention.
