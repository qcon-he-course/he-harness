# he-harness

The checks that judge a change to `he-petclinic` in the InfoQ Certified AI-Assisted Engineering Program, Week 4: "CI as the team's harness".

They live here, outside the repository they judge, so that a pull request cannot edit the rules that classify it, the policy that decides on it or the instructions its reviewers follow. The pull-request workflow checks this repository out at a pinned commit.

| Folder | Holds |
|---|---|
| `sensors/` | Deterministic checks that run before any model: risk floor, test-delta audit, glossary check, scenario coverage, the known-defect lane, and `step5.sh`, which runs them with the build, the suite and mutation testing. `triage.py` is the policy: it reads the sensors and the reviews and decides what a change is permitted. Each has a test script |
| `skills/` | What the reviewers are told: `review-code`, `review-change`, `triage-findings` |
| `review/` | The headless reviewer: one script that runs Claude Code or Codex on a change, a schema for its output, and a check that accepts a valid review or fails closed |
| `known-defects/` | Tests tied to an open defect, and their tickets |

## Two rules this layout follows

- **Deterministic checks gate; a model's review advises; the policy decides.** A review that is missing, or that breaks its schema, counts as a failed check, never as a review with no findings.
- **A job that holds a model's API key runs none of the change's code.** The sensors build and test the change in a job with no key. The reviewer reads files and has no shell: any command a keyed agent runs can read the key from its environment.

## Running the tests

```bash
for t in sensors/*.test.sh review/*.test.sh; do bash "$t" | tail -1; done
```

The stack-specific parts are the build commands in `sensors/step5.sh` and the patterns in `sensors/risk-rules.txt`. Everything else reads git, OpenSpec files and test reports.
