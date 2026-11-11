---
name: review-code
description: Review the code that implements an OpenSpec change, as an independent reviewer, after the deterministic sensors have run. Gives a verdict on every scenario in the change before any overall view, checks the code against the decisions log and the design, and reports structured findings with a disposition each, ending with the questions only a person can answer. Use when asked to review the code or the implementation of a change.
---

# Review the code of a change

You did not write this code. Treat it, its tests and its task list as claims to check. You produce findings; you do not edit anything.

## What to read

- The change: `openspec/changes/<change>/`: decisions log, spec deltas, design, tasks.
- The baseline specs the change touches, in `openspec/specs/`, and `GLOSSARY.md` if it exists.
- The project baseline: the architecture and conventions every change is held to, beyond the slice's spec. It is in the repository, or given to you with the request.
- The code change: `git status` and `git diff` against `HEAD`, including new files.
- The sensor results you are given (step 5): risk floor, test-delta audit, glossary check, architecture rule, test suite, mutation testing.
- The architecture rules and any test the change names.

The files and the sensor results are the evidence. Do not look for, or rely on, the author's own account of its work.

## Checks, in this order

Give a verdict on each item before forming an overall view.

1. **Every scenario.** For each scenario in the spec deltas, ADDED and MODIFIED, one verdict:
   - **MET**: a test shows it. Name the test, and say which assertion shows each THEN. A test counts only for what it asserts, and only if it can fail: a check against a mock that returns the expected answer by default shows nothing.
   - **PARTLY**: a test exists, but some THEN is not asserted, or the test cannot fail.
   - **UNTESTED**: no test. Read the code and say whether it does what the scenario says (INFERRED).
   - **NOT MET**: the code does something else. Quote it.
   - **UNKNOWN**: cannot be shown here (a test that needs Docker, for example). Say what would show it.
2. **Each decision, and the project baseline.** For every decision in the log that the code must carry: CARRIED (where), SOFTENED or MISSING. For every line of the project baseline: does the code depart from it, and does a decision in the log say so? Then list anything in the code that no decision, task or necessity supports.
3. **The sensors.** When `sensors.md` has a scenario-coverage section, start check 1 from it: it shows, by test name and declared level, which scenarios a test that ran and passed is named for. PRESENT there means only that such a test exists and passed: whether it shows the scenario, and can fail, is still yours to judge. UNTESTED there is a fact about names and levels: say whether a differently named test shows the scenario after all. For each sensor finding: does it matter for this change, and why? A finding you dismiss needs a reason a person can check against the file. Do not re-run what the sensors ran unless you need a different answer from it.
4. **The design against the code.** The code follows the design's decisions; every ticked task is done; nothing is done that the tasks and the design do not ask for.
5. **What tests cannot show.** Read what no test here exercises: scripts that run only elsewhere (migrations), concurrency, deployment order. Check them against the code and the design by reading.
6. **The words.** Names and messages use the glossary's terms.

## Findings

A finding has:

- **id**: C1, C2, ...
- **disposition**: BLOCK (the code contradicts a scenario, a decision, the baseline or a rule the build enforces); AUTO-FIX+REVERIFY (a mechanical fix a check can confirm); DISCUSS (needs a person); INFORMATIONAL (true, but changes nothing here).
- **where**: file and line, or the scenario's name.
- **claim**: one or two sentences.
- **evidence**: a quote with file and line, or a command and its output.
- **falsification**: "This finding is wrong if ...".
- **confidence**: high, medium or low.

Start each finding with one bold line that holds its id, its disposition and a short title, then the other fields as a list:

```
**C1: BLOCK.** The architecture rule no longer checks PetController.
- **Where:** ...
```

The triage policy reads that line. A finding whose disposition it cannot read stops the packet, so the work comes back.

"Looks risky" is not a finding. Judge severity by consequence, not by how the finding sounds.

## Report

Put the whole review in your final reply, in this order:

1. **Scenarios**: the table from check 1, one row per scenario.
2. **Decisions and baseline**: the tables from check 2.
3. **Sensors**: one line per sensor finding, from check 3.
4. **Findings**: every finding, most severe first.
5. **For the person**: only the DISCUSS findings and the BLOCK findings whose fix needs a decision, each as a question with its evidence. If there are none, say so.
6. **Overall**: one paragraph, after everything above.
