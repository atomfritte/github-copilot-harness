---
name: deep-review
description: Multi-perspective code review. Several reviewer subagents examine a change in parallel, each with a different focus, and every finding is independently verified before it is reported. Use when the user types /deep-review or asks for a thorough review of a diff, branch or pull request.
argument-hint: "[what to review: a branch, commit range, PR number or paths; defaults to uncommitted changes]"
---
# /deep-review

A review in two passes: independent reviewers find problems, then independent verifiers try to disprove each finding. Only findings that survive are reported. The text after `/deep-review` names what to review; with no text, review the uncommitted changes.

You coordinate and do not edit code during the review.

## 1. Establish the change

Work out the exact diff: `git diff` and `git diff --staged` for uncommitted work, `git diff <base>...<branch>` for a branch, the commit range the user named, or the listed paths. If the diff is empty, say so and stop.

Read the diff yourself, enough to write a three-line summary of what the change does and which areas it touches. You will give that summary to every reviewer.

## 2. Review in parallel

Delegate to `reviewer` subagents in parallel, one focus each. Choose the focuses that fit this change; the usual set is:

1. **Correctness:** logic errors, edge cases, wrong assumptions about inputs, broken behaviour for existing callers
2. **Security and data handling:** injection, authorisation, secrets, validation at trust boundaries
3. **Failure behaviour:** error handling, resource cleanup, concurrency, partial failure
4. **Tests:** whether new and changed behaviour is covered, and whether the tests would actually fail if the code were wrong

For a large change, also split by area so each reviewer has a diff it can read fully.

Give each reviewer: how to obtain the diff (the exact git command or the paths), your summary, its focus, and the instruction to report findings with `path:line`, a concrete failure scenario, and a confidence level. Do not share your own suspicions; they should look with fresh eyes.

## 3. Verify every finding

Merge the findings and remove duplicates. Then, for each finding that remains, delegate to a `verifier` subagent, in parallel:

> Here is a claimed defect: (the finding, with its location and failure scenario). Try to disprove it. Read the code path, check for guards in callers, and where possible run the triggering input or a test. Report confirmed, refuted, or could not determine, with evidence.

Give the verifier the finding, not the reviewer's reasoning. A finding that is refuted with evidence is dropped. One that could not be determined is kept and marked plausible.

## 4. Report

List the surviving findings, most severe first:

- **`path:line`** and a one-line statement of the defect
- how it fails: the input or situation and the wrong result
- verdict: confirmed or plausible, with the verifier's evidence in a sentence
- a suggested fix, when it is short

Then state what was reviewed (the diff and the focuses), how many findings were raised and how many were dropped in verification, so the reader can judge the coverage. If nothing survived, say the review found no defects and what it covered. Do not pad the report with style remarks.

Do not fix anything unless the user asks. If they do, fix the confirmed findings and rerun the affected tests.
