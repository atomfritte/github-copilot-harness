# GitHub Copilot Harness

A repository skeleton that gives GitHub Copilot in VS Code the working model people like in Claude Code: a `/goal` that keeps the agent working until a condition is verified, specialised subagents, staged multi-agent workflows, permission guard rails, and a written set of working rules.

Everything is plain files under `.github/`. There is no extension to install and no service to run. It targets the **Copilot harness**, the agent runtime that VS Code, the GitHub Copilot app and GitHub Copilot CLI share, so the same files work in all three.

> **Status.** Written against the VS Code and GitHub documentation as of November 2026 (VS Code 1.147). The hook scripts are covered by automated tests that feed them the documented event payloads. They have not yet been run inside a live Copilot session, and agent hooks are a preview feature. Run the [smoke test](docs/smoke-test.md) once in your environment before you rely on it.

## What you get

| Claude Code | In this skeleton | Where |
|---|---|---|
| `/goal <condition>` | `/goal` skill plus a stop hook that blocks the end of the turn until required checks pass and a judge subagent returns MET | [`.github/skills/goal`](.github/skills/goal/SKILL.md), [`.github/hooks`](.github/hooks) |
| Subagents | Six custom agents: `explorer`, `planner`, `implementer`, `reviewer`, `verifier`, `goal-judge` | [`.github/agents`](.github/agents) |
| Workflows (multi-agent orchestration) | `/workflow` (explore, plan, implement, review, verify), `/fan-out` (one instruction over many items in parallel), `/deep-review` (parallel review with verified findings) | [`.github/skills`](.github/skills) |
| System prompt behaviour | Working rules: read before editing, smallest change, verify, report honestly, when to delegate | [`.github/copilot-instructions.md`](.github/copilot-instructions.md) |
| `CLAUDE.md` | `AGENTS.md` for project facts, path-scoped `*.instructions.md` for rules by file type | [`AGENTS.md`](AGENTS.md), [`.github/instructions`](.github/instructions) |
| Permission deny/ask rules | `preToolUse` guard hook with configurable command and path rules | [`.github/hooks/harness/config.json`](.github/hooks/harness/config.json) |
| Hooks | `sessionStart`, `userPromptSubmitted`, `preToolUse`, `subagentStop`, `agentStop` | [`.github/hooks/harness.json`](.github/hooks/harness.json) |
| MCP servers | Template for a workspace `.mcp.json` | [`.mcp.json.example`](.mcp.json.example) |

The full mapping, including what Copilot already has built in and what has no equivalent, is in [docs/claude-code-to-copilot.md](docs/claude-code-to-copilot.md).

## Requirements

- A current VS Code with GitHub Copilot. The skeleton was written against VS Code 1.147; the documentation states no minimum version for skills, custom agents or hooks. Copilot Business or Enterprise is needed for the governance features.
- The **Copilot** harness selected in the **Session Target** control of the Chat view or Agents window. The older Local harness is deprecated and is not what this skeleton targets.
- Node.js 18 or later on the machine where the agent runs (your laptop, the dev container or the remote host). The hooks are Node scripts with no dependencies.
- An organisation policy that allows repository hooks. If hooks are restricted to managed sources, see [docs/enterprise.md](docs/enterprise.md).

## Quick start

1. **Copy the skeleton into your repository.** Take the `.github/` folder (`agents`, `skills`, `hooks`, `instructions`, `copilot-instructions.md`), `AGENTS.md`, and the entries from `.gitignore`. Optionally take `.vscode/settings.json`.
2. **Describe your project.** Fill in `AGENTS.md`: what the system is, its layout, and the build, test and lint commands.
3. **Register your checks.** In `.github/hooks/harness/config.json`, add the commands a goal may require:

   ```json
   "checks": {
     "test": "npm test",
     "lint": "npm run lint"
   }
   ```

4. **Run the setup check.** It verifies the tools, the harness files, your VS Code user settings and any device policies it can see, then asks before fixing what it can:

   ```text
   powershell -ExecutionPolicy Bypass -File scripts\setup-check.ps1     (Windows PowerShell 5.1)
   pwsh scripts/setup-check.ps1                                         (PowerShell 7, any platform)
   ```

   `-CheckOnly` reports without asking, `-Fix` applies the recommended fixes without asking. See [Setup check](#setup-check).
5. **Open the repository in VS Code**, trust the workspace, and select **Copilot** as the session target. Open **Chat: Open Customizations** and confirm the agents, skills and hooks are listed without errors.
6. **Try it.**

   ```text
   /goal --check test every function in src/utils has a unit test
   ```

Then walk through [docs/smoke-test.md](docs/smoke-test.md) to confirm each mechanism fires in your setup.

## Using it

### `/goal`: keep working until it is verifiably done

```text
/goal <completion condition>
/goal --check test --check lint <completion condition>
/goal --max-turns 40 <completion condition>
/goal --check test --no-judge
/goal                 show the current goal
/goal resume          adopt an unfinished goal in a new session
/goal clear           also: stop, off, reset, none, cancel
```

The condition is the instruction: the agent starts immediately. Each time it tries to end its turn, the stop hook runs the required checks and asks for a verdict from the `goal-judge` subagent, which inspects the repository with fresh context. NOT_MET sends the agent back to work with the judge's reason. MET, IMPOSSIBLE or an exhausted turn budget releases it.

Write conditions that can be checked: "`npm test` exits 0 and no test is skipped" works better than "the tests are in good shape". Details, limits and troubleshooting are in [docs/goal.md](docs/goal.md).

### `/workflow`: one task, end to end

```text
/workflow add cursor pagination to the orders API
```

The main agent coordinates: parallel `explorer` subagents map the code, `planner` writes the plan, `implementer` subagents carry out the steps, parallel `reviewer` subagents examine the result, `verifier` confirms findings and the final state. Combine it with a goal when you want it to keep going until the result is verified.

### `/fan-out`: the same job over many items

```text
/fan-out add input validation to every route handler under src/api
```

Builds the item list, checks the items are independent, briefs one subagent per item, runs them in batches, and merges the results.

### `/deep-review`: a review whose findings are checked

```text
/deep-review
/deep-review the changes on feature/pagination against main
```

Reviewers with different focuses run in parallel. Each finding then goes to a verifier that tries to disprove it. Only what survives is reported.

### Subagents on their own

Ask in plain language: "Use the explorer subagent to find where rate limiting is configured." `planner` and `reviewer` also appear in the agent picker for direct use; the others are hidden from the picker and available for delegation.

### The built-in pieces worth knowing

- **`/plan`** starts Copilot's Plan mode: research, clarifying questions, a plan to review, then **Implement Plan** or **Implement with Autopilot**.
- **Autopilot** keeps the agent working across turns. With `chat.autopilot.advanced.enabled` (experimental, set in `.vscode/settings.json` here) a second model checks progress against your request after each turn. This is the built-in relative of `/goal` and needs no hooks. Use it for everyday "finish this task" work, and `/goal` when the end state has to be proven by a command or has to hold across several prompts. The comparison is in [docs/goal.md](docs/goal.md#autopilots-progress-check-or-goal).

## Setup check

`scripts/setup-check.ps1` answers "is this machine ready?" in four parts:

| Part | What it checks |
|---|---|
| Tools | VS Code version, Node.js 18 or later, Git |
| Repository | all harness files, hook configuration and script paths, skill and agent frontmatter, registered goal checks, `.gitignore`, leftover debug trace, the hook test suite |
| VS Code user settings | agents enabled, sessions not steered to the deprecated Local harness, global auto-approve, the Autopilot progress check, a terminal rule for the goal command |
| Organisation | VS Code device policies (Windows registry, `/etc/vscode/policy.json`, macOS managed preferences), Copilot policy hooks, personal hooks, `disableAllHooks` |

It changes nothing until you confirm. Recommended fixes are offered together; optional ones (the experimental Autopilot check, and auto-approving `goal.mjs status` and `goal.mjs set`) are asked one at a time and default to no. Settings files are edited in place, so comments and formatting survive, and a backup is written next to the file first. The exit code is 1 when a check failed.

What it cannot see: Copilot enterprise-managed settings delivered by GitHub (run **Developer: Policy Diagnostics** in VS Code), named VS Code profiles, workspace trust, and which harness a session actually uses. It was tested with PowerShell 7 on Linux; the Windows registry and macOS policy lookups follow the documented locations and have not been run on those systems yet.

## Layout

```text
AGENTS.md                               project facts (you fill this in)
.github/
  copilot-instructions.md               working rules for every agent
  instructions/tests.instructions.md    example of rules scoped to file patterns
  agents/                               subagents (*.agent.md)
  skills/                               slash commands (<name>/SKILL.md)
  hooks/
    harness.json                        hook configuration (which script runs on which event)
    harness/
      config.json                       goal checks, turn budget, guard rules
      goal.mjs                          goal CLI: status | set | clear | resume | verdict
      on-prompt.mjs                     registers /goal when the prompt is submitted
      goal-stop.mjs                     the loop: checks, judge verdict, block or release
      goal-verdict.mjs                  captures the judge's verdict when it finishes
      session-start.mjs                 tells a new session about an open goal
      guard.mjs                         deny/ask rules for commands and paths
      lib.mjs                           shared helpers
.harness/                               runtime state, gitignored
.mcp.json.example                       template for workspace MCP servers
.vscode/settings.json                   two workspace defaults
scripts/setup-check.ps1                 readiness check with optional fixes
docs/                                   mapping, goal internals, enterprise guide, smoke test
tests/hooks.test.mjs                    hook tests: node --test tests/
```

## Customising

- **Agents.** Edit the Markdown body to change behaviour and the `tools` list to change capabilities. Copilot's tool aliases are `read`, `search`, `edit`, `execute`, `agent`, `web` and `todo`. To pin a model, add a `model:` field using the IDs that editor completion offers in the agent file; none is set here so every agent uses the model selected in the session.
- **Skills.** Each skill is a folder with a `SKILL.md`. The folder name must equal the `name` field. Add your own for release steps, migrations or incident checklists.
- **Guard rules.** `guard.commands` are regular expressions matched against shell commands; `guard.paths` are globs matched against files the agent reads or writes. Each rule answers `deny` or `ask`.
- **Goal defaults.** `goal.maxTurns`, `goal.checkTimeoutSec` and `goal.checks` in `config.json`.

Run `node --test tests/` after changing anything under `.github/hooks/`.

## Limits you should know about

- **Hooks are a preview feature** and their behaviour can change. The goal loop depends on the `agentStop` hook's block decision.
- **The runtime ends a turn after 8 forced continuations in a row.** The goal stays active and continues with your next message. Autopilot mode reduces how often you have to nudge.
- **A subagent's read-only role is set by its tool list, and is only as strict as that list.** `reviewer`, `verifier` and `goal-judge` have the terminal so they can run tests; their instructions tell them not to modify anything.
- **The guard hook is a seat belt.** Command matching is best effort, and anything the agent does through the shell can bypass path rules. Real limits belong in enterprise-managed permissions and sandboxing.
- **Skills replace prompt files.** Prompt files (`.prompt.md`) and agent `handoffs` only work in the deprecated Local harness, which VS Code plans to remove in February 2027. This skeleton does not use them.

## Documentation

- [Claude Code to Copilot: the full mapping and the options considered](docs/claude-code-to-copilot.md)
- [How `/goal` works](docs/goal.md)
- [Enterprise guide: policies, rollout, governance](docs/enterprise.md)
- [Smoke test: verify it in your environment](docs/smoke-test.md)
