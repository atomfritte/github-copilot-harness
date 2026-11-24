# Claude Code to GitHub Copilot: the full mapping

This document records what was investigated, what GitHub Copilot in VS Code offers for each Claude Code concept, and which route this skeleton takes. It reflects the documentation as of November 2026 (VS Code 1.147).

## First, the fact that shapes everything: harnesses

VS Code no longer has one Copilot agent implementation. A session runs on a **harness**, chosen in the **Session Target** control:

| Harness | What it is | Status |
|---|---|---|
| **Copilot** | The Copilot SDK runtime, shared by VS Code, the GitHub Copilot app and GitHub Copilot CLI. Sessions continue in the background when the window closes. | Current. This skeleton targets it. |
| **Local** | The original editor-hosted agent. | Deprecated, removal planned for February 2027. |
| **Claude** | Anthropic's Claude Agent SDK integrated into VS Code. | Experimental. Disabled when Copilot enterprise-managed settings apply, unless an administrator permits it. |
| **Codex** | OpenAI's Codex, through its extension or an experimental direct integration. | Experimental. Same enterprise restriction. |
| **Cloud** | The Copilot harness running in managed compute. | Experimental target, not a separate harness. |

Each harness has its own customisation support. A file that works in one does not automatically work in another, even when both read the same folder. Two consequences matter most:

- **Prompt files (`.prompt.md`) and agent `handoffs` are Local-only.** They were the usual way to build slash commands and plan-to-implement buttons. They stop working when Local is removed. Skills replace prompt files.
- **The coordinator field `agents:` (an allowlist of subagents) is Local-only.** In the Copilot harness, delegation goes through the native `task` tool, and a worker opts out with `disable-model-invocation`.

Source: [Compare agent harnesses](https://code.visualstudio.com/docs/agents/run/agent-harnesses), [Custom agent file reference](https://code.visualstudio.com/docs/agents/reference/custom-agent-file-reference).

## Concept by concept

The status column says Preview or Experimental where the documentation marks a feature that way. An empty cell means the documentation carries no such marker.

| Claude Code | GitHub Copilot (Copilot harness) | Status | In this skeleton |
|---|---|---|---|
| `CLAUDE.md` | `.github/copilot-instructions.md` or `AGENTS.md` at the repository root; nested `AGENTS.md` files for subfolders; user-level `~/.copilot/copilot-instructions.md` | | `AGENTS.md` for project facts, `copilot-instructions.md` for working rules |
| `.claude/rules/*.md` with `paths:` | `.github/instructions/**/*.instructions.md` with `applyTo:` globs | | One example: `tests.instructions.md` |
| Custom slash commands, skills | Agent Skills: `.github/skills/<name>/SKILL.md`, invoked as `/<name>` or loaded automatically by description. Personal: `~/.copilot/skills/` | Forked context is experimental | `/goal`, `/workflow`, `/fan-out`, `/deep-review` |
| Subagents (`.claude/agents/*.md`) | Custom agents: `.github/agents/*.agent.md`, delegated to through the `task` tool. Personal: `~/.copilot/agents/` | | Six agents |
| Subagent tool restrictions | `tools:` list with the aliases `read`, `search`, `edit`, `execute`, `agent`, `web`, `todo`, plus `<mcp server>/*` | | Set per agent |
| Per-agent model | `model:` (one ID or an ordered list), `model-policy`, `reasoning-effort` | | Not set; add IDs from editor completion |
| Parallel subagents | Supported; ask for several or let the agent decide | | Used by all three workflow skills |
| Hooks (`settings.json`) | `.github/hooks/*.json`, `~/.copilot/hooks/`, or an inline `hooks` map in `.github/copilot/settings.json`. Events: `sessionStart`, `sessionEnd`, `userPromptSubmitted`, `preToolUse`, `postToolUse`, `postToolUseFailure`, `preCompact`, `subagentStart`, `subagentStop`, `agentStop`, `errorOccurred` and more | Preview | Five events used |
| Stop hook that blocks | `agentStop` with `{"decision": "block", "reason": "..."}`; the runtime caps this at 8 in a row | Preview | The `/goal` loop |
| `/goal` | No command of that name. Closest built-in: **Autopilot** mode with `chat.autopilot.advanced.enabled`, where a second model checks progress against the request after each turn | Experimental | `/goal` skill, stop hook and judge subagent |
| Plan mode | `/plan` and Plan mode: research, clarifying questions, a reviewable plan, then implement | | Used as is; `planner` subagent for delegation inside workflows |
| Todo list | `todo` tool | | Referenced in the working rules |
| Workflows (scripted multi-agent orchestration) | No deterministic script runner. Orchestration is done by a coordinating agent following a skill | n/a | `/workflow`, `/fan-out`, `/deep-review` |
| Permission rules (allow, ask, deny) | Permission levels (Manual, Assisted, Allow all), `chat.tools.terminal.autoApprove`, `chat.tools.edits.autoApprove`; enterprise-managed `permissions.allow/ask/deny`; `preToolUse` hooks | Hooks are preview | Guard hook; managed settings described in the enterprise guide |
| Auto mode | **Assisted permissions**: a model reviews proposed actions | | Recommended default in the enterprise guide |
| Sandbox | Copilot sandbox, managed `sandbox` settings, network filtering | | Not configured here; organisation decision |
| MCP servers (`.mcp.json`) | Workspace-root `.mcp.json` and `~/.copilot/mcp-config.json`, both with a top-level `mcpServers` object. `.vscode/mcp.json` is the Local-era format | Guided setup for the workspace file is experimental | `.mcp.json.example` |
| Memory | Copilot Memory: cloud-backed repository and user memories, shared with CLI, cloud agent and code review; unused entries expire after 28 days | | Used as is |
| Plugins and marketplaces | Agent plugins: packages of skills, agents, hooks and MCP servers, installed from marketplaces or Git | Preview | Described as the distribution route in the enterprise guide |
| Background and cloud sessions | Copilot sessions keep running after the window closes; cloud sessions; Copilot cloud agent on GitHub.com | Cloud sessions are experimental | Not configured |
| Worktrees | In the Agents window a session can work in the folder or in a separate Git worktree | | Not configured |
| Scheduled runs (`/loop`, routines) | Scheduled chat requests (new in 1.147) and automations | Automations are preview | Not configured |
| `claude -p` (headless) | GitHub Copilot CLI, same harness, reads the same `.github/` files | | Works with this skeleton |
| Managed settings | Copilot enterprise-managed settings, VS Code device policies, GitHub organisation policies | | Enterprise guide |
| Context compaction | Automatic, with a `preCompact` hook event | | `sessionStart` hook re-announces an open goal |

## What has no real equivalent

- **A deterministic workflow engine.** Claude Code can run a script that spawns agents in a fixed order with fixed fan-out. In Copilot the coordinator is a model following written instructions. It usually follows them, but the stages are not guaranteed. `/goal` is the way to add a hard end condition to a workflow.
- **A built-in evaluator model for goals.** Copilot hooks are commands and cannot call the session's model. The harness uses a judge subagent instead, which costs more per check and is better informed, because it reads the repository.
- **Restricting which subagents a coordinator may call.** `agents:` is Local-only. In the Copilot harness any agent can delegate to any custom agent that has not set `disable-model-invocation: true`.
- **Agent `handoffs`.** Local-only. The Plan mode buttons (**Implement Plan**, **Implement with Autopilot**) cover the common case.

## Options that were considered

### 1. Skills, custom agents and hooks on the Copilot harness (chosen)

Plain files in `.github/`, shared through the repository, working in VS Code, the Copilot app and Copilot CLI. Subject to all Copilot enterprise controls. The trade-off is the dependence on hooks, which are in preview, for the goal loop.

### 2. Built-in features only

`/plan`, Autopilot, `chat.autopilot.advanced.enabled`, natural-language subagent requests, Copilot Memory. No files to maintain and nothing that can be blocked by a hook policy. You get no explicit completion condition, no named checks, no specialised subagents and no repeatable workflows. A reasonable starting point for a team that does not want to maintain a harness. This skeleton enables the advanced Autopilot check as well, so both can be used.

### 3. The Claude harness inside VS Code

VS Code can run sessions on Anthropic's Claude Agent SDK, which reads `CLAUDE.md`, `.claude/agents`, `.claude/skills` and Claude-format hooks natively. This is the closest thing to Claude Code inside the editor. For an enterprise it has two problems: it is experimental, and it is disabled whenever Copilot enterprise-managed settings apply unless an administrator lists it in `vscode.allowedHarnesses` (VS Code 1.147 and later). Claude sessions also run outside Copilot's managed permission, sandbox, MCP and plugin controls. Worth asking for if your organisation is open to it; not something to build a team standard on.

### 4. Reusing a `.claude/` directory

The Copilot harness reads `.claude/settings.json` hooks and `.claude/agents` in Claude format. This helps a repository that already has Claude Code configuration. The VS Code documentation is explicit that a shared file location does not mean identical behaviour: event payloads, tool names and output handling differ. For a new setup the native `.github/` locations are the supported path, and they are what this skeleton uses.

### 5. Prompt files and handoffs on the Local harness

This was the standard recipe for custom slash commands and plan-to-implement flows until 2026, and most blog posts still describe it. It is tied to a harness scheduled for removal in February 2027. Not used.

### 6. Organisation-level and plugin distribution

Custom agents can be defined once for a whole organisation or enterprise in a `.github-private` repository, and organisation-level custom instructions are set on GitHub. Skills and hooks are not distributed that way; the route for those is an agent plugin, which administrators can force-enable. This matters when hooks are restricted to managed sources. See the [enterprise guide](enterprise.md).

### 7. Copilot CLI and the cloud agent

Both read the same `.github/` files. The CLI is the headless counterpart of `claude -p`. The cloud agent loads `.github/hooks/*.json` from the cloned repository into an ephemeral Linux sandbox, so the goal state does not survive the job and Node.js must be present in that environment. The skeleton is not tuned for the cloud agent.

## References

VS Code documentation:

- [Agent customization overview](https://code.visualstudio.com/docs/agent-customization/overview)
- [Custom agents](https://code.visualstudio.com/docs/agent-customization/custom-agents) and the [file reference](https://code.visualstudio.com/docs/agents/reference/custom-agent-file-reference)
- [Subagents](https://code.visualstudio.com/docs/agents/run/subagents)
- [Agent Skills](https://code.visualstudio.com/docs/agent-customization/agent-skills)
- [Hooks](https://code.visualstudio.com/docs/agent-customization/hooks)
- [Custom instructions](https://code.visualstudio.com/docs/agent-customization/custom-instructions)
- [Prompt files](https://code.visualstudio.com/docs/agent-customization/prompt-files) (Local harness only)
- [Migrate customizations](https://code.visualstudio.com/docs/agent-customization/migrate-customizations)
- [MCP servers](https://code.visualstudio.com/docs/agent-customization/mcp-servers) and the [configuration reference](https://code.visualstudio.com/docs/agents/reference/mcp-configuration)
- [Agent plugins](https://code.visualstudio.com/docs/agent-customization/agent-plugins)
- [Approvals, permission levels and Autopilot](https://code.visualstudio.com/docs/agents/run/approvals)
- [Planning](https://code.visualstudio.com/docs/agents/run/planning), [Memory](https://code.visualstudio.com/docs/agents/run/memory), [Agent harnesses](https://code.visualstudio.com/docs/agents/run/agent-harnesses)
- [Manage AI settings in enterprise environments](https://code.visualstudio.com/docs/enterprise/manage-ai-settings)

GitHub documentation:

- [Copilot hooks reference](https://docs.github.com/en/copilot/reference/hooks-reference)
- [Custom agents configuration](https://docs.github.com/en/copilot/reference/custom-agents-configuration)
- [MCP management](https://docs.github.com/en/copilot/concepts/mcp-management)

Claude Code documentation:

- [`/goal`](https://code.claude.com/docs/en/goal), [Subagents](https://code.claude.com/docs/en/sub-agents), [Hooks](https://code.claude.com/docs/en/hooks)
