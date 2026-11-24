# Project guide for agents

<!--
Replace everything in this file with facts about YOUR project. Keep it short: agents read it at the
start of every session. Write what an agent cannot work out quickly from the code, and leave out
what it can. The working rules themselves live in .github/copilot-instructions.md.
-->

## What this is

One or two sentences: what the system does and who uses it.

## Layout

- `src/` ...
- `tests/` ...

## Commands

| Task | Command |
|---|---|
| Install dependencies | `...` |
| Build | `...` |
| Run all tests | `...` |
| Run one test file | `...` |
| Lint / format | `...` |
| Type check | `...` |

Register the ones a goal should be able to require as named checks in `.github/hooks/harness/config.json` (`goal.checks`), for example `"test": "npm test"`. Then `/goal --check test ...` makes the stop hook run them.

## Conventions that are not obvious from the code

- ...

## Things that must not be changed without asking

- ...
