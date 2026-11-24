---
name: goal
description: Set, inspect, resume or clear a completion goal that keeps the agent working across turns until an independent judge confirms a condition is met. Use only when the user types /goal or explicitly asks to keep working until some condition holds.
argument-hint: "<completion condition> | clear | resume   [--check <name>] [--max-turns <n>]"
---
# /goal

A goal is a completion condition. While one is active, a stop hook refuses to let the turn end until the condition is verified, so you keep working without the user prompting each step. The hook, not you, decides when the goal is reached: it runs any required checks and takes the verdict from the `goal-judge` subagent.

The goal's state lives in `.harness/goal.json` and is managed with `node .github/hooks/harness/goal.mjs`. Never edit that file directly.

## 1. Work out what the user asked for

Look at the text that came with `/goal`:

| The user wrote | Do this |
|---|---|
| nothing | Run `node .github/hooks/harness/goal.mjs status`, report the result in a sentence or two, and stop. |
| `clear`, `stop`, `off`, `reset`, `none` or `cancel` | Run `... goal.mjs clear`, confirm in one sentence, and stop. |
| `resume` | Run `... goal.mjs status` to confirm it is active again, then continue with step 3. |
| anything else | That text is the completion condition. Continue with step 2. |

## 2. Make sure the goal is registered

A hook normally registers the goal the moment the user submits `/goal ...`. Confirm it:

```
node .github/hooks/harness/goal.mjs status
```

If the status does not show the user's condition as active, register it yourself, passing the user's text unchanged, including any `--check` or `--max-turns` options:

```
node .github/hooks/harness/goal.mjs set <the text after /goal>
```

If `set` fails, for example because a `--check` name is not defined in `.github/hooks/harness/config.json`, tell the user what the error says and stop. Do not invent a check, and do not edit the config to add one unless the user asks.

If the command cannot run at all, or the user tells you hooks are disabled in their organisation, the goal cannot be enforced. Say so in one sentence, then follow steps 3 and 4 anyway on your own discipline.

## 3. Start working immediately

State the goal back in one line, then begin. The condition is your instruction; do not wait for a further prompt.

- For anything beyond a trivial change, write a short plan as a todo list and keep it current.
- Delegate where it helps: `explorer` for finding and tracing code, `planner` for design, `implementer` for scoped changes, `reviewer` and `verifier` for independent checks. Keep work that depends on the conversation with yourself.
- Verify as you go. Run the tests or commands the condition refers to and read their output.
- Do not narrow the goal to make it reachable. If the condition says all tests pass, a skipped or deleted test does not count.

## 4. Finish through the judge

When you believe the condition holds, delegate to the `goal-judge` subagent before you end the turn. Give it:

- the completion condition, word for word
- a short list of what you changed and where the evidence is (files, commands to run)

Do not tell it which verdict to return. Then act on its verdict:

- **MET**: end the turn with a short summary of what was done and how it was verified.
- **NOT_MET**: fix what its reason names, then ask it again.
- **IMPOSSIBLE**: end the turn and tell the user exactly what is blocking and what you need from them.

If you are blocked on something only the user can provide, such as a credential, a decision between real alternatives, or access you do not have, do not loop. Explain the blocker to `goal-judge` so it can return IMPOSSIBLE, then tell the user.

If you end a turn without a verdict, the hook sends you back with instructions. Follow them. If it says the verdict could not be captured automatically and asks you to record it with `goal.mjs verdict`, pass on the judge's verdict and reason exactly as it gave them.

## Limits to keep in mind

- A goal has a turn budget (default 20, or `--max-turns`). When it runs out, the goal is marked exhausted and the turn ends. Say what is done and what remains.
- The Copilot runtime ends a turn after 8 forced continuations in a row. The goal stays active; the user's next message continues it.
- The goal persists across the user's later messages until it is achieved, impossible, exhausted or cleared.
