---
name: review-change
description: Review an OpenSpec change before any code is written, as an independent reviewer. Checks the change against the decisions log, the baseline spec, the glossary and the code's own rules, and reports structured findings with a disposition each, ending with the questions only a person can answer. Use when asked to review a change, a proposal, a spec delta or a design.
---

# Review a change before code

You did not write this change. Treat everything in it as a claim to check. You produce findings; you do not edit the change, the specs, the glossary or the code.

## What to read

- The change: `openspec/changes/<change>/` (proposal, spec deltas, design, tasks) and its decisions log, `decisions.md`.
- The ticket, as given in the request.
- The baseline specs of every capability the change touches, in `openspec/specs/`.
- `GLOSSARY.md`, if it exists.
- The project baseline: the architecture and conventions every change is held to, beyond the slice's spec. It is in the repository, or given to you with the request.
- The code, tests and build rules the design names, including architecture tests.

The files are the evidence. Do not look for, or rely on, the author's own account of its work.

## Checks, in this order

Give a verdict on each item before forming an overall view.

1. **Each decision.** For every entry in the log's Decided section: CARRIED (say where), SOFTENED (quote the decision and the change side by side), or MISSING. Then list anything in the change that no decision or recorded fact supports: scope the author added. Before you call something added scope, ask whether a decision or the code makes it necessary: a migration for a new column on a table that already holds data, seed data that must still load, keys a test requires. Necessary work is not added scope. Check whether it is done correctly, and whether its order and its effect on existing data and deployments are stated.
2. **What was not decided.** For every entry in the log's Open section, does the change say how it is handled? Then read the ticket again: list each question it raises that neither the log nor the change answers.
3. **The delta against the baseline.** For every requirement of each baseline spec the change touches: does an ADDED requirement contradict it, or does it need a MODIFIED entry? Run `openspec validate <change> --strict`, and remember that it checks the format, never the meaning. Then, for every line of the project baseline: does the design depart from it? A departure needs a decision in the log that says so; without one it is a finding.
4. **The design against the code.** For every fact the design labels INFERRED, and every claim it makes about a test, a rule or a tool: check it by reading or by running tests, if you can. You may run tests; you may not edit files. If you cannot check a claim that a design decision rests on, that is a finding.
5. **The tasks.** Every requirement has a task that would show it working, and every task has a check.
6. **The words.** The change uses the glossary's terms and none of the words listed under `_Avoid_`.

## Findings

A finding has:

- **id**: R1, R2, ...
- **disposition**: BLOCK (the change contradicts a decision, the baseline, or a rule the build enforces); AUTO-FIX+REVERIFY (a mechanical fix a check can confirm); DISCUSS (needs a person: scope, a trade-off, an unanswered question); INFORMATIONAL (true, but changes nothing here).
- **where**: file and line, or the requirement's name.
- **claim**: one or two sentences.
- **evidence**: a quote with file and line, or a command and its output.
- **falsification**: "This finding is wrong if ...".
- **confidence**: high, medium or low.

"Looks risky" is not a finding. Judge severity by consequence, not by how the finding sounds.

## Report

Put the whole review in your final reply, in this order:

1. **Decisions**: the table from check 1.
2. **Findings**: every finding, in the format above, most severe first.
3. **For the person**: only the DISCUSS findings and the BLOCK findings whose fix needs a decision. Write each as a question, with the evidence needed to answer it. If there are none, say so.
