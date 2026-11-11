# Sensors

Deterministic checks that run before any model reviews a change, and whose results the reviewers receive. Each works on the working tree against a base commit (default `HEAD`, untracked files included) or on a commit range `base head`. Each has a test script; run it after any change. The header of each file says what it reads and what its exit codes mean.

| File | What it reports |
|---|---|
| `risk-floor.py` | The change's lowest possible risk tier (mechanical, bounded, material, critical) and what triggered it. A model may raise the tier; nothing lowers it |
| `test-delta.py` | Deleted tests, renamed tests, removed assertions, skips, broad catches, changed protected checks, test configuration in the build file |
| `glossary-check.sh` | Words `GLOSSARY.md` says to avoid, in added lines |
| `scenario-coverage.py` | Whether each scenario of a change is shown by a test at its declared level (`- **CHECKED AT** <level>`), by the test's name. `--main` checks the main specs instead: the drift check between specs and tests |
| `known-defects.py` | Checks the known-defect list before the pipeline uses it: each test names a ticket, and each ticket is open |
| `step5.sh` | All of the above with the architecture rule, the build's own checks, the full suite without the known-defect tests, the known-defect lane and mutation testing, summarised in `sensors.md` |
| `step5-docker.sh` | The tests that need Docker (MySQL, Postgres), run twice in opposite class orders |
| `triage.py` | The policy. It reads the reviews and `sensors.md`, audits a clerk's merge of the findings when there is one, computes whether the change is eligible to merge and whether it may merge with no person, and writes `packet.md`. It fails closed: a finding with no readable disposition, or a review it cannot read, fails the audit |
| `risk-rules.txt` | Which paths and patterns give which tier, and which files are protected checks |
| `changes.py` | Shared: how the tools read a change from git |
