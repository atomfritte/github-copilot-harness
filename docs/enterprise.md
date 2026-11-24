# Enterprise guide

How this skeleton interacts with the controls an organisation on Copilot Business or Enterprise is likely to have, and how to roll it out. It reflects the documentation as of November 2026. Policy names and behaviour change; check the linked references before making a decision that depends on one.

## Three layers of control

| Layer | Managed by | Typical content |
|---|---|---|
| **Copilot enterprise-managed settings** | GitHub enterprise administrators, delivered from GitHub, by MDM or as files | Permission levels, shell permission rules, sandbox, MCP allowlist, plugins, allowed harnesses |
| **VS Code device policies** | IT, through Group Policy (Windows), configuration profiles (macOS) or `/etc/vscode/policy.json` (Linux) | Whether agents are available at all, global auto-approve, hook and plugin restrictions, extension allowlist |
| **GitHub organisation and enterprise settings** | Organisation owners | Copilot access, models, content exclusions, organisation instructions and agents, MCP registry policy |

When a device policy and an enterprise-managed setting configure the same control, the enterprise-managed setting wins. Developers can check what applies to them with **Developer: Policy Diagnostics**.

Reference: [Manage AI settings in enterprise environments](https://code.visualstudio.com/docs/enterprise/manage-ai-settings).

## Will the skeleton work under our policies?

| If this is set | Effect on the skeleton |
|---|---|
| `ChatAgentMode` = `false` | Agents are off. Nothing here applies. |
| `ChatAllowManagedHooksOnly` (or managed `allowManagedHooksOnly: true`) | Repository hooks do not run. Skills, agents and instructions still work. `/goal` loses enforcement and the guard hook is inactive. Distribute the hooks as a managed plugin (below) to restore them. |
| `ChatStrictPluginOnlyCustomization` (or managed `strictPluginOnlyCustomization`) | Standalone repository skills, agents, instructions and MCP servers are blocked. The whole skeleton has to ship as a managed plugin. |
| `ChatToolsAutoApprove` = `false` | No global auto-approve; saved approvals are not applied. The skeleton works, with more confirmation prompts. Hook-enforced goals still continue across turns, but each tool call may wait for approval. |
| `permissions.disableBypassPermissionsMode` = `"disable"` | **Allow all** is unavailable. Fine: the skeleton does not need it. |
| Managed `permissions.deny` / `ask` rules | Apply before and independently of the guard hook. Prefer these over the guard hook for anything that must hold. |
| Managed `sandbox` settings | In a sandboxed session, repository hooks are documented (for Copilot CLI) to run inside the sandbox with the agent's access. Goal checks that need the network or paths outside the workspace may fail there; test them in your session type. |
| Any enterprise-managed setting present | The Claude and Codex harnesses are disabled unless `vscode.allowedHarnesses` lists them. Irrelevant to this skeleton, which uses the Copilot harness. |
| MCP allowlist or registry-only policy | Servers in `.mcp.json` that are not allowed are blocked. The skeleton ships no MCP server. |
| `vscode.temporaryDefaultToLocalHarness` | Sessions default to the deprecated Local harness. Developers must select **Copilot** as the session target for the hooks and the `task`-based delegation described here. |

## Rolling it out

### Per repository (the default)

Commit the files to each repository. Simple, reviewable, versioned with the code, and each team can adapt agents and checks. Protect the executable parts:

```text
# CODEOWNERS
/.github/hooks/               @your-org/platform-engineering
/.github/agents/              @your-org/platform-engineering
/.github/skills/              @your-org/platform-engineering
/.github/copilot-instructions.md  @your-org/platform-engineering
```

Hook configuration and scripts are code that runs on developer machines without a per-command approval. Treat changes to them like changes to CI.

### Per developer

The same files work from the user-level locations of the Copilot harness: `~/.copilot/agents/`, `~/.copilot/skills/`, `~/.copilot/hooks/`, and `~/.copilot/copilot-instructions.md`. User-level hook commands need absolute paths to their scripts. Useful for trying the harness without touching a shared repository.

### Organisation-wide agents and instructions

Custom agents can be defined for a whole organisation or enterprise in a `.github-private` repository, and organisation custom instructions are configured on GitHub. VS Code shows such agents automatically (`github.copilot.chat.organizationCustomAgents.enabled`, on by default). On GitHub.com the agent format ignores some VS Code fields, and agent-scoped hooks do not run for organisation-hosted definitions.

This covers the six agents and the working rules. It does not cover skills or hooks.

Reference: [Custom agents configuration](https://docs.github.com/en/copilot/reference/custom-agents-configuration), [Prepare for custom agents](https://docs.github.com/en/copilot/how-tos/administer-copilot/manage-for-enterprise/manage-agents/prepare-for-custom-agents).

### As a managed agent plugin

An agent plugin packages skills, agents, hooks and MCP servers behind a `plugin.json` manifest and is installed from a marketplace, which is a Git repository. Administrators can restrict installation to approved marketplaces and force-enable specific plugins (`ChatEnabledPlugins`, `ChatStrictMarketplaces`, or `enabledPlugins` in enterprise-managed settings). Hooks from a force-enabled plugin still run when hooks are otherwise restricted to managed sources.

This is the route when your policy blocks repository hooks, or when you want one centrally versioned harness instead of a copy per repository. Converting this skeleton means moving `agents/`, `skills/` and the hook configuration and scripts into the plugin layout and changing the script paths in the hook commands to the plugin's own directory. The goal state should then live in the plugin's data directory or stay in the workspace's `.harness/` folder.

Reference: [Agent plugins](https://code.visualstudio.com/docs/agent-customization/agent-plugins), [plugin authoring reference](https://code.visualstudio.com/docs/agents/reference/agent-plugin-reference).

## Recommended settings

### Permissions

For unattended goal runs the agent needs to act without a prompt per step, and the organisation needs that to be bounded. A workable combination:

- Enterprise-managed settings: default to **Assisted permissions** (a model reviews each proposed action) and disable **Allow all**.

  ```json
  {
    "permissions": {
      "defaultMode": "assisted",
      "disableBypassPermissionsMode": "disable",
      "ask": ["Shell(/^git\\s+(push|pull)\\b/)"]
    }
  }
  ```

- For developers without managed settings: allow the commands the harness itself needs in **User** settings. For Copilot sessions, terminal auto-approve rules are read from User settings, not from the workspace.

  ```json
  {
    "chat.tools.terminal.autoApprove": {
      "/^node \\.github\\/hooks\\/harness\\/goal\\.mjs (status|set)\\b/": true,
      "npm test": true,
      "npm run lint": true
    }
  }
  ```

  The goal rule covers `status` and `set` only. `clear` and `verdict` stay behind a prompt, so an agent cannot release its own goal without you seeing it. `scripts/setup-check.ps1` offers to add this rule.

- Keep protected files out of automatic edits:

  ```json
  {
    "chat.tools.edits.autoApprove": {
      "**/.github/hooks/**": false,
      "**/.env": false
    }
  }
  ```

The guard hook (`.github/hooks/harness/guard.mjs`) adds repository-specific deny and ask rules on top. It is best effort by design: it cannot see what a script does internally, and a shell command can touch a file that a path rule protects from the edit tool. In Autopilot mode an `ask` decision is treated as a denial, because there is nobody to ask.

### Auditing

For organisation-wide logging or validation, use **policy hooks**: hook files deployed by IT to `/etc/github-copilot/policy.d/` (Linux, macOS) or `C:\ProgramData\GitHub\Copilot\policy.d\` (Windows). They load before all other hooks, cannot be disabled by users, and run for Copilot harness sessions only. The documentation describes them for Copilot CLI and says they apply to Copilot harness sessions in VS Code; verify coverage in the session type your developers use.

Telemetry export through OpenTelemetry is available as a separate managed setting.

### MCP

Share servers through a workspace-root `.mcp.json` (see `.mcp.json.example`) and reference secrets as `${ENV_VAR}`; the file format has no input prompts and literal credentials must not be committed. Pin versions for `npx`-style servers. Under a managed allowlist, only matching servers start, and workspace definitions cannot widen the allowlist.

Reference: [MCP management](https://docs.github.com/en/copilot/concepts/mcp-management), [MCP configuration reference](https://code.visualstudio.com/docs/agents/reference/mcp-configuration).

## Security notes specific to this skeleton

- **Hooks run with the developer's rights.** Review `.github/hooks/` before you grant Workspace Trust to a repository that contains it, the same way you would review its tasks and MCP commands.
- **Goal checks are named, not supplied by the agent.** The stop hook executes only commands listed under `goal.checks` in `config.json`. See [goal.md](goal.md#why-checks-are-named-not-free-text).
- **The goal state is local.** `.harness/` is gitignored and contains the condition, turn counts and the judge's reasons. The optional debug trace (`.harness/debug`) logs shortened prompts and tool arguments; do not leave it enabled.
- **Instructions are guidance, not enforcement.** The working rules tell agents not to push, not to weaken tests and to treat tool output as data. Controls that must hold belong in managed permissions, sandboxing and branch protection.
- **Node.js is a dependency of the hooks.** In dev containers and remote hosts it must exist where the agent runtime runs, not only on the client.
- **Content exclusion.** Whether your content exclusion rules apply to agent sessions is not stated in the documentation used for this guide. Confirm it with GitHub before relying on it for sensitive paths; the guard hook's path rules are a supplement, not a replacement.

## Version notes

| Version | Relevant change |
|---|---|
| 1.142, 1.143 | Managed settings to keep or allow the Local harness temporarily |
| 1.145 | Managed MCP allowlist takes precedence over registry-only access |
| 1.147 | `vscode.allowedHarnesses` to permit Claude or Codex under managed settings |
| February 2027 | Planned removal of the Local harness, and with it prompt files and handoffs |
