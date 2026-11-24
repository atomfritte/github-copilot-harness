---
name: fan-out
description: Apply one instruction to many independent items in parallel using subagents, then merge the results into a single answer. Use when the user types /fan-out or asks for the same operation across many files, modules, packages, services or questions.
argument-hint: "<instruction> for <the set of items>"
---
# /fan-out

One instruction, many items, done in parallel by subagents, merged by you. The text after `/fan-out` names the instruction and the set of items, for example "add input validation to every handler under `src/api`" or "summarise what each package in `packages/` exports".

## 1. Build the item list

Find the actual items first: list the directory, search for the pattern, or read the list the user gave. Write the list down as todos. If the set is larger than about 20 items or is ambiguous, show the user the list and the plan in a few lines before starting, because a fan-out multiplies cost as well as speed.

## 2. Check the items are independent

Fan-out only works when no item needs another item's result and no two items edit the same file.

- If items share a file, group them so one subagent owns that file.
- If there is shared groundwork (a helper everyone needs, a type everyone imports), do that part yourself first, then fan out.
- If the items are really a sequence, do not fan out. Say so and do them in order.

## 3. Write one brief and reuse it

Every subagent starts with no memory of this conversation, so the brief must stand alone. Write it once, as a template, with:

- the instruction, stated completely
- the one item this subagent owns, and the files it may touch
- the conventions to follow, with a pointer to an example in the repository if one exists
- how to check the result (the command to run)
- the exact shape of the answer you want back, the same for every item, so you can merge them

Pick the subagent by the kind of work: `explorer` for read-only questions, `implementer` for changes, `reviewer` for audits.

## 4. Run in batches

Delegate in parallel, a batch at a time: about five subagents per batch for edits, more for read-only work. After each batch, read the reports and update the todos before starting the next. If the first batch shows the brief was wrong or unclear, fix the brief before spending the rest.

## 5. Merge and check

Collect the results into one answer:

- items done, items that failed, items skipped, with a reason for each that is not done
- for edits: run the project-wide checks once at the end (build, tests, linter), because parallel changes can each pass alone and still conflict together
- retry failed items once with a corrected brief; report the ones that fail again instead of retrying indefinitely

Give the user the merged result, not the individual reports. Say plainly how many items succeeded out of how many.
