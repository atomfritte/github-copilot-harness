---
name: workflow
description: Run a full engineering task as a staged pipeline of subagents (explore in parallel, plan, implement, review in parallel, verify) with the main agent coordinating. Use when the user types /workflow or asks for a multi-step feature, refactor or bug fix to be handled end to end.
argument-hint: "<task to carry out end to end>"
---
# /workflow

You are the coordinator. You run a task through fixed stages, hand each stage to the right subagent, and keep only the conclusions in your own context. The text after `/workflow` is the task.

Subagents start with no memory of this conversation. Every time you delegate, the brief you write is all they have. A good brief states the goal, what is already known, which files are in scope, what to return, and what not to do. Pass on findings from earlier stages instead of making the next subagent rediscover them.

Skip a stage only when it clearly adds nothing, and say that you skipped it. A one-file fix does not need three explorers; a change across services does.

## Stage 1: Explore

Break the task into the two to four questions you need answered before anyone can plan: where the relevant code lives, how the current behaviour works, what conventions and tests exist, what depends on the code that will change.

Delegate each question to its own `explorer` subagent and run them in parallel. Ask each for file references, not file contents.

## Stage 2: Plan

Delegate to the `planner` subagent. Give it the task, any constraints the user stated, and the explorers' findings. Ask for ordered steps with files, a verification section with exact commands, and open questions.

Then check the plan yourself. If it contains a question only the user can answer, or a choice between approaches with real trade-offs, ask the user now, with your recommendation. Otherwise show the plan in brief and continue. Do not stop for approval on routine work unless the user asked to review the plan first.

Record the steps as a todo list.

## Stage 3: Implement

Work through the steps in order, marking each todo as you go.

- Delegate self-contained steps to an `implementer` subagent with the step, the files in scope, the relevant part of the plan, and the command that checks it.
- Run implementers in parallel only when their files do not overlap. Tell each one which files are its own.
- Do small steps, and steps that need judgement from this conversation, yourself.
- Read each implementer's report. If it says blocked or partly done, deal with that before moving on. Do not build on a step that did not verify.

## Stage 4: Review

Delegate to `reviewer` subagents in parallel, each with one focus, for example:

1. correctness and edge cases
2. security and error handling
3. tests: are the new behaviours covered, do the tests assert anything meaningful

Tell each one what changed and where. For every finding that would change the code, delegate to a `verifier` subagent to confirm it is real before you act on it. Fix the confirmed findings, or have an `implementer` fix them, and note the ones you rejected and why.

## Stage 5: Verify

Run the plan's verification commands yourself, or through the `verifier` subagent, against the final state: the full test suite, build, type check, linter, whichever apply. Read the output. If anything fails, go back to stage 3 for that failure.

## Report

End with a short report for someone who was not watching:

- what was done, in a few sentences
- files changed
- verification: the commands run and their actual results
- review findings that were fixed, and any that were left, with the reason
- anything the user needs to decide or do next

Report failures and skipped steps as plainly as successes. Do not commit or push unless the user asked.

## With a goal

`/workflow` runs once and reports. To keep going until a condition is verified, the user sets a goal first, for example `/goal --check test the orders API is paginated`, and then runs `/workflow`. The stop hook holds the turn open until the judge confirms.
