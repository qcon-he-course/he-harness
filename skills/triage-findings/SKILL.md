---
name: triage-findings
description: Merge the findings of several reviews and the sensor results of one change into a single list for the person who decides, without dropping a finding or softening one. Use as the clerk in step 7, before the policy script applies the rules and writes the packet.
---

# Triage the findings of a change

You are the clerk, not a judge. Reviewers and sensors have reported findings; a policy script will decide what they permit, and a person will answer the questions. Your job is to turn many reports into one list a person can act on.

## What to read

- `sources.md` in the inputs you are given: every finding you must account for, with its id, the reviewer's disposition and its title.
- The reviews and `sensors.md` next to it: the full text of each finding, its evidence and its falsification line.
- The project baseline, the change (`openspec/changes/<change>/`) and the code, to check that two findings really say the same thing.

## What you do

1. **Merge findings that say the same thing**, across reviewers and steps: the same defect at the same place, whatever the wording. Keep them apart if they differ in cause, place or fix. When unsure, keep them apart.
2. **Account for every source exactly once.** Every id in `sources.md` goes into the `sources` of exactly one merged finding. Never drop one; a finding you think is wrong is still listed, with `consequence: "overruled"` and a `reason` a person can check against the file.
3. **Disposition:** the strictest of the sources' dispositions (BLOCK, then DISCUSS, then AUTO-FIX+REVERIFY, then INFORMATIONAL). Never lower it. A sensor finding has no disposition: give it one, and a reason.
4. **Consequence**, one of:
   - `question`: it needs a person's decision. Write the question, with the evidence needed to answer it.
   - `fix`: a mechanical fix the author makes and a check confirms. Write the fix.
   - `task`: already carried as a task or decision elsewhere; say where.
   - `logged`: true, changes nothing here (INFORMATIONAL, or a sensor finding with a reason).
   - `overruled`: you checked it and it does not hold. Give the reason, quoting the file.
5. **Scenario coverage.** A sensor finding "scenario …: UNTESTED at <level>" comes from the test names and levels. Check the tests: if a test at that level shows the scenario under another name, the fix is a rename (AUTO-FIX+REVERIFY); if none does, the fix is a test, at that level; if the declared level looks wrong, it is a question for the person, who decides levels.
6. **Unverified and known defects.** List what nobody could verify (tests that did not run) and the known defects the baseline names. A test in the sensors' known-defect lane is neither a finding nor unverified: leave it out of the findings and of `unverified`. The policy reports its result from `sensors.md`; the defect itself still goes under `known_defects`.

## Reply

Explain briefly which findings you merged and why, then end your reply with one JSON block, nothing after it:

```json
{"findings": [{"id": "T1", "title": "one line", "sources": ["review-step6-x:C2", "review-step6-y:C1"],
               "disposition": "BLOCK", "consequence": "question",
               "question": "...", "fix": "", "reason": "", "evidence": "file:line"}],
 "unverified": ["..."], "known_defects": ["..."]}
```
