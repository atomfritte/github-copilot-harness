---
name: Tests
description: Rules for writing and changing automated tests
applyTo: "**/*.test.*,**/*.spec.*,**/tests/**,**/test/**,**/__tests__/**"
---
<!-- Example of a path-scoped instruction file. It applies only when the agent works on files matching applyTo. Adapt the globs and rules, and add one file per area (API, database migrations, UI, infrastructure). -->

- A test must be able to fail. After writing one, check that it fails when the behaviour it covers is broken.
- Test behaviour through the public interface. Do not assert on private state or on how often an internal function was called unless that is the behaviour.
- Cover the edges the code has to handle: empty input, boundaries, invalid input, and the error path, not just the expected case.
- Keep each test independent: no reliance on execution order, shared mutable state, the real clock, or the network.
- Name a test after the behaviour it checks, so a failure reads as a sentence about what broke.
- When a test fails, fix the cause. Changing an assertion to match wrong output, or skipping the test, is not a fix.
- Follow the structure and helpers of the neighbouring tests instead of introducing a new style.
