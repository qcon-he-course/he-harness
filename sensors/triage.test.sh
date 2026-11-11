#!/usr/bin/env bash
# Tests for triage.py. Run: ./triage.test.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
triage="$here/triage.py"
fails=0
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT

inputs() {
  rm -rf "$t/run"; mkdir -p "$t/run/inputs"; cd "$t/run"
  cat > inputs/review-step6-a.md <<'R'
## Findings

**C1: DISCUSS.** A new repository departs from the baseline.
- claim
**C2: AUTO-FIX+REVERIFY.** Two scenarios are tested only in the validator.
R
  cat > inputs/review-step6-b.md <<'R'
**C1 — BLOCK — Unrecorded departure from the repository boundary**
**C2 — INFORMATIONAL — A comment is misleading**
R
  cat > inputs/sensors.md <<'R'
| Sensor | Result |
|---|---|
| Risk floor | **critical** (see below) |
| Full test suite (17 s) | 10 run, 0 failures, 0 errors, 1 skipped |

## Test-delta audit

```
src/test/X.java:3: skip added: @Disabled
summary: tests in changed files 1 -> 2; findings 1
```

## Full test suite

Not run (no Docker): XTests (1 skipped). Not run is not passed.
R
  python3 "$triage" prepare inputs > /dev/null
}
reply() { printf '```json\n%s\n```\n' "$1" > reply.md; }
expect() { # expect <name> <exit> <grep pattern on packet.md or ->
  local name="$1" want="$2" pat="$3" code=0
  python3 "$triage" check inputs reply.md > out.txt 2>&1 || code=$?
  if [ "$code" != "$want" ]; then echo "FAIL $name: exit $code, wanted $want"; cat out.txt packet.md 2> /dev/null | head -20; fails=$((fails + 1)); return; fi
  if [ "$pat" != "-" ] && ! grep -qE "$pat" packet.md; then echo "FAIL $name: no match for $pat"; cat packet.md; fails=$((fails + 1)); return; fi
  echo "ok   $name"
}
GOOD='{"findings": [
 {"id": "T1", "title": "Repository departs from the baseline", "sources": ["review-step6-a:C1", "review-step6-b:C1"], "disposition": "BLOCK", "consequence": "question", "question": "Accept it or route through the owner?"},
 {"id": "T2", "title": "Validator-only tests", "sources": ["review-step6-a:C2"], "disposition": "AUTO-FIX+REVERIFY", "consequence": "fix", "fix": "Add form-level tests"},
 {"id": "T3", "title": "Comment", "sources": ["review-step6-b:C2"], "disposition": "INFORMATIONAL", "consequence": "logged"},
 {"id": "T4", "title": "Skip in a new test", "sources": ["sensors:S1"], "disposition": "INFORMATIONAL", "consequence": "logged", "reason": "matches the existing Docker tests"}],
 "unverified": ["XTests: no Docker"], "known_defects": ["PC-302"]}'

inputs; grep -q '`sensors:S1`' inputs/sources.md && grep -q '`review-step6-b:C1` | BLOCK' inputs/sources.md && echo "ok   prepare lists review and sensor findings" || { echo "FAIL prepare"; fails=$((fails + 1)); }
inputs; reply "$GOOD"; expect "a complete merge: not eligible while a BLOCK is open" 0 'Eligible to merge \| \*\*no\*\*: 1 open BLOCK'
inputs; reply "$GOOD"; expect "the floor sets the sign-off" 0 'critical\*\*; sign-off: a named owner'
inputs; reply "$GOOD"; expect "questions and fixes reach the packet" 0 'Accept it or route through the owner\?'
inputs; reply "$GOOD"; expect "doubt-theater count" 0 'Doubt theater \| 2 of 2 substantial'
inputs; reply "$GOOD"; expect "the audit passes" 0 'Every one of the 5 reported findings is accounted for'
inputs; reply "${GOOD/\"review-step6-b:C2\"/}"; expect "a dropped source fails the audit" 1 '`review-step6-b:C2` .* is in no merged finding'
inputs; reply "${GOOD/\"review-step6-a:C1\", \"review-step6-b:C1\"/\"review-step6-a:C1\", \"review-step6-b:C9\"}"; expect "an invented source fails the audit" 1 'names `review-step6-b:C9`'
inputs; reply "${GOOD/\"disposition\": \"BLOCK\"/\"disposition\": \"DISCUSS\"}"; expect "a lowered disposition is raised back" 0 'T1: the clerk gave DISCUSS; raised to BLOCK'
inputs; reply "${GOOD/\"consequence\": \"fix\", \"fix\": \"Add form-level tests\"/\"consequence\": \"overruled\"}"; expect "overruled without a reason fails" 1 'overruled without a recorded reason'
inputs; reply "${GOOD/, \"reason\": \"matches the existing Docker tests\"/}"; expect "a sensor finding logged without a reason fails" 1 'T4: INFORMATIONAL logged without a recorded reason'
inputs; reply "${GOOD/\"consequence\": \"logged\", \"reason\"/\"consequence\": \"task\", \"reason\"}"; expect "a task is listed as carried elsewhere" 0 '## Carried elsewhere'
inputs; reply "$(printf '%s' "$GOOD" | sed 's/"Comment", "sources": \["review-step6-b:C2"\], "disposition": "INFORMATIONAL", "consequence": "logged"/"Comment", "sources": ["review-step6-b:C2"], "disposition": "INFORMATIONAL", "consequence": "ignored"/')"; expect "a finding the packet cannot show fails" 1 'no consequence the packet can show: T3'
inputs; echo "no json here" > reply.md; expect "an unreadable reply fails" 1 'could not be read'
inputs; reply '{"findings": [{"id": "T1", "sources": ["review-step6-a:C1", "review-step6-b:C1", "review-step6-a:C2", "review-step6-b:C2", "sensors:S1"], "disposition": "INFORMATIONAL", "consequence": "logged", "reason": "x"}]}'
expect "merging everything into one INFORMATIONAL is raised to BLOCK" 0 'raised to BLOCK'

# Policy on the build: no merge on a red suite or a red host run; host passes leave "Not run".
clean() { # clean <suite row> <failed line or -> <host section file or ->
  rm -rf "$t/run"; mkdir -p "$t/run/inputs"; cd "$t/run"
  printf '**C1: AUTO-FIX+REVERIFY.** A test cannot fail.\n' > inputs/review-step6-a.md
  { printf '| Sensor | Result |\n|---|---|\n| Risk floor | **material** (see below) |\n| Full test suite (17 s) | %s |\n\n## Test-delta audit\n\n```\nsummary: findings 0\n```\n\n## Full test suite\n\n' "$1"
    [ "$2" != - ] && printf 'Failed: %s\n\n' "$2"
    printf 'Not run (no Docker): PgTests (0 run), MyTests (1 skipped). Not run is not passed.\n'
    [ "$3" != - ] && cat "$3"; } > inputs/sensors.md
  python3 "$triage" prepare inputs > /dev/null
  reply '{"findings": [{"id": "T1", "title": "Test cannot fail", "sources": ["review-step6-a:C1"], "disposition": "AUTO-FIX+REVERIFY", "consequence": "fix", "fix": "make it fail"}]}'
}
host() { # host <failed count for PgTests in the first order>
  printf '\n## Docker tests (host)\n\n**alphabetical** (30 s, build exit 0). Order run: MyTests → PgTests.\n\n| Class | Run | Passed | Failed | Skipped |\n|---|---|---|---|---|\n| MyTests | 1 | 1 | 0 | 0 |\n| PgTests | 1 | %s | %s | 0 |\n\n**reversealphabetical** (30 s, build exit 0). Order run: PgTests → MyTests.\n\n| Class | Run | Passed | Failed | Skipped |\n|---|---|---|---|---|\n| MyTests | 1 | 1 | 0 | 0 |\n| PgTests | 1 | 1 | 0 | 0 |\n' "$((1 - $1))" "$1" > "$t/host.md"
}
clean "10 run, 0 failures, 0 errors, 1 skipped" - -; expect "green suite, no BLOCK: eligible" 0 '^\| Eligible to merge \| \*\*yes\*\* \|'
clean "10 run, 1 failures, 0 errors, 1 skipped: BUILD FAILED" "\`XTests.race\`" -; expect "a failing suite is not eligible" 0 'Eligible to merge \| \*\*no\*\*: failing: `XTests.race`'
host 0; clean "10 run, 0 failures, 0 errors, 1 skipped" - "$t/host.md"; expect "classes passed on the host in every order leave Not run" 0 '^\| Not run \| nothing \|'
host 0; clean "10 run, 0 failures, 0 errors, 1 skipped" - "$t/host.md"; expect "the host run shows in the suite row" 0 '2 classes passed on the host in 2 test orders'
host 1; clean "10 run, 0 failures, 0 errors, 1 skipped" - "$t/host.md"; expect "a failure on the host in one order is not eligible" 0 'Eligible to merge \| \*\*no\*\*: failing: PgTests'
host 1; clean "10 run, 0 failures, 0 errors, 1 skipped" - "$t/host.md"; expect "a class that failed on the host is reported as failing, not as not run" 0 '^\| Not run \| nothing \|'

# The known-defect lane: shown in the packet, never counted toward eligibility.
lane() { # lane <failed> <passed>
  printf '\n## Known-defect tests\n\nTests tied to an open ticket.\n\n| Test | Ticket | Runs | Failed | Passed | Not found |\n|---|---|---|---|---|---|\n| `XTests#race` | PC-9 | 3 | %s | %s | 0 |\n' "$1" "$2" > "$t/lane.md"
}
lane 1 2; clean "10 run, 0 failures, 0 errors, 1 skipped" - "$t/lane.md"; expect "a failing known-defect test does not block" 0 '^\| Eligible to merge \| \*\*yes\*\* \|'
lane 1 2; clean "10 run, 0 failures, 0 errors, 1 skipped" - "$t/lane.md"; expect "the lane is in the summary table" 0 'Known-defect tests \(shown, not counted\) \| PC-9: failed 1 of 3 runs'
lane 1 2; clean "10 run, 0 failures, 0 errors, 1 skipped" - "$t/lane.md"; expect "the lane is under Known defects" 0 '`XTests#race` \(PC-9\) runs in the known-defect lane, outside the build: failed 1 of 3 runs'
lane 0 3; clean "10 run, 0 failures, 0 errors, 1 skipped" - "$t/lane.md"; expect "a lane that passed every run says timing may hide it" 0 'passed in every run of the lane, which may mean only that the timing hid it'

# The build's own checks (./mvnw validate, B1) fail the build, as ./mvnw verify would.
printf '| Build checks (`./mvnw validate`, B1) | formatting FAILS (1 file) |\n' > "$t/b1.md"
clean "10 run, 0 failures, 0 errors, 1 skipped" - "$t/b1.md"; expect "a B1 failure is not eligible" 0 'Eligible to merge \| \*\*no\*\*: failing: the build checks'
printf '| Build checks (`./mvnw validate`, B1) | pass (formatting, `http://` URLs, Java version) |\n' > "$t/b1.md"
clean "10 run, 0 failures, 0 errors, 1 skipped" - "$t/b1.md"; expect "B1 passing leaves eligibility alone" 0 '^\| Eligible to merge \| \*\*yes\*\* \|'

clean "no summary found (exit 1)" - -; expect "a suite with no result is not eligible" 0 'Eligible to merge \| \*\*no\*\*: failing: the test suite has no result'

# A change to a protected check always reaches the person.
rm -rf "$t/run"; mkdir -p "$t/run/inputs"; cd "$t/run"
printf '| Sensor | Result |\n|---|---|\n| Risk floor | **critical** (see below) |\n| Full test suite (17 s) | 10 run, 0 failures, 0 errors, 0 skipped |\n\n## Test-delta audit\n\n```\nsrc/test/XCharacterizationTests.java:79: protected check: modified, 3 lines added, 0 removed\nsummary: findings 1\n```\n' > inputs/sensors.md
python3 "$triage" prepare inputs > /dev/null
reply '{"findings": [{"id": "T1", "title": "Approved wiring line", "sources": ["sensors:S1"], "disposition": "INFORMATIONAL", "consequence": "logged", "reason": "only the approved mock line"}]}'
expect "a logged protected-check change is put to the person" 0 'Confirm the change to a protected check, which changes only with its owner.s approval: src/test/XCharacterizationTests.java:79'
expect "the packet says the policy raised it" 0 'T1: the clerk gave logged; a change to a protected check is put to the person'

# Scenario coverage: each UNTESTED scenario is a sensor finding the clerk accounts for; the row reaches the packet.
rm -rf "$t/run"; mkdir -p "$t/run/inputs"; cd "$t/run"
printf '| Sensor | Result |\n|---|---|\n| Risk floor | **bounded** (see below) |\n| Full test suite (17 s) | 10 run, 0 failures, 0 errors, 0 skipped |\n| Scenario coverage (by test name and level) | 1 of 2 present, 0 above their level, 0 failed, 1 untested, 0 with no level; shape: unit 1, form 1 |\n\n## Test-delta audit\n\n```\nsummary: findings 0\n```\n\n## Scenario coverage\n\n```\nscenario pets: Three errors on the add form: UNTESTED at form: no test is named for it\n```\n' > inputs/sensors.md
python3 "$triage" prepare inputs > /dev/null
if grep -q '`sensors:S1` | (sensor) | scenario pets: Three errors on the add form: UNTESTED' inputs/sources.md; then echo "ok   an untested scenario is a sensor finding to account for"; else echo "FAIL scenario finding"; cat inputs/sources.md; fails=$((fails + 1)); fi
reply '{"findings": [{"id": "T1", "title": "Untested combination", "sources": ["sensors:S1"], "disposition": "AUTO-FIX+REVERIFY", "consequence": "fix", "fix": "add the test"}]}'
expect "the coverage row reaches the packet" 0 '^\| Scenario coverage \| 1 of 2 present, 0 above their level, 0 failed, 1 untested, 0 with no level; shape: unit 1, form 1 \|'
reply '{"findings": []}'
expect "an untested scenario left out of the merge fails the audit" 1 '`sensors:S1` .* is in no merged finding'

# auto: no clerk; each finding alone at its reviewer's disposition, the same policy.
inputs; rm -f packet.md; python3 "$triage" auto inputs > out.txt 2>&1; code=$?
if [ "$code" = 0 ] && grep -q 'Eligible to merge | \*\*no\*\*: 1 open BLOCK' packet.md && grep -q 'Every one of the 5 reported findings is accounted for' packet.md; then echo "ok   auto: one finding per source, the BLOCK blocks"; else echo "FAIL auto"; cat out.txt packet.md 2> /dev/null | head; fails=$((fails + 1)); fi

# Reading a review: every format the step 8 reviewers used, and failing closed on the rest.
one() { # one <review text>: a green build, one review, auto
  rm -rf "$t/run"; mkdir -p "$t/run/inputs"; cd "$t/run"
  printf '%s\n' "$1" > inputs/review-step6-x.md
  printf '| Sensor | Result |\n|---|---|\n| Risk floor | **bounded** (see below) |\n| Full test suite (17 s) | 10 run, 0 failures, 0 errors, 0 skipped |\n\n## Test-delta audit\n\n```\nsummary: findings 0\n```\n' > inputs/sensors.md
  code=0; python3 "$triage" auto inputs > out.txt 2>&1 || code=$?
}
has() { # has <name> <exit> <pattern> <file>
  if [ "$code" = "$2" ] && grep -qE "$3" "$4"; then echo "ok   $1"; else echo "FAIL $1 (exit $code)"; cat "$4" | head -20; fails=$((fails + 1)); fi
}
one $'## 4. Findings\n\n### C1 \xe2\x80\x94 BLOCK \xe2\x80\x94 Added dependency prevents the build\n\n- **Claim \xe2\x80\x94 VERIFIED:** It cannot resolve.\n\n## 5. For the person\n\n**C1:** Should it go?'
has "a finding under a heading is read, with its BLOCK" 0 'Eligible to merge \| \*\*no\*\*: 1 open BLOCK' packet.md
has "lines after the Findings section are not findings" 0 'Every one of the 1 reported findings is accounted for' packet.md
one $'**C1. The named test cannot fail.**\n- Disposition: AUTO-FIX+REVERIFY\n- Where: X.java'
has "a disposition on its own line is read" 0 '`review-step6-x:C1` \| AUTO-FIX\+REVERIFY \| The named test cannot fail' inputs/sources.md
one $'**C1: BLOCK**\n- **Where:** `ArchitectureTests.java:38`\n- **Claim:** The rule skips PetController. The store was regenerated.'
has "an empty title is taken from the claim" 0 '`review-step6-x:C1` \| BLOCK \| The rule skips PetController \|' inputs/sources.md
one $'**C1: BLOCK.** Where: `pom.xml:41`\n- **Claim:** A dependency that does not exist.'
has "a title that is only Where is taken from the claim" 0 '`review-step6-x:C1` \| BLOCK \| A dependency that does not exist \|' inputs/sources.md
one $'**C1. A test cannot fail.**\n- Where: X.java'
has "a finding with no readable disposition fails the audit" 1 'review-step6-x:C1` has no disposition the policy can read' packet.md
has "a packet that fails its audit is not eligible" 1 'Eligible to merge \| \*\*no\*\*: the packet failed its audit' packet.md
has "an unreadable finding still reaches the person" 1 '^\*\*T1\. A test cannot fail\*\* \(DISCUSS' packet.md
one $'Overall: one BLOCK, on the dependency. C1 is the problem.'
has "a review with a disposition and no readable finding fails the audit" 1 'no finding could be read, though the review names a disposition' packet.md

# The rung (step 8b): a bounded change with a clean packet merges without a person.
rung() { # rung <floor> <review text> [extra sensors.md text]
  rm -rf "$t/run"; mkdir -p "$t/run/inputs"; cd "$t/run"
  printf '%s\n' "$2" > inputs/review-step6-x.md
  printf '| Sensor | Result |\n|---|---|\n| Risk floor | **%s** (see below) |\n| Full test suite (17 s) | 10 run, 0 failures, 0 errors, 0 skipped |\n\n## Test-delta audit\n\n```\nsummary: findings 0\n```\n%s' "$1" "${3:-}" > inputs/sensors.md
  code=0; python3 "$triage" auto inputs > out.txt 2>&1 || code=$?
}
rung bounded '**C1: INFORMATIONAL.** A comment could be clearer.'
has "bounded, clean: merges without a person" 0 '^\| Merges without a person \| \*\*yes\*\*: the floor is bounded, the packet is clean \|' packet.md
rung material '**C1: INFORMATIONAL.** A comment could be clearer.'
has "material: a person signs off" 0 'Merges without a person \| \*\*no\*\*: risk floor material \|' packet.md
rung bounded '**C1: DISCUSS.** Is "under a month" right for a newborn?'
has "a question: a person answers it" 0 'Merges without a person \| \*\*no\*\*: 1 question for the person \|' packet.md
rung bounded '**C1: AUTO-FIX+REVERIFY.** A test cannot fail.'
has "a fix: back to the author first" 0 'Merges without a person \| \*\*no\*\*: 1 fix goes back to the author first \|' packet.md
rung bounded '**C1: BLOCK.** The age is a year out before the birthday.'
has "a BLOCK: not eligible" 0 'Merges without a person \| \*\*no\*\*: not eligible; 1 question for the person \|' packet.md
rung bounded '**C1: INFORMATIONAL.** Fine.' $'\n## Full test suite\n\nNot run (no Docker): PgTests (1 skipped). Not run is not passed.\n'
has "a test not run: a person decides" 0 'Merges without a person \| \*\*no\*\*: not run: PgTests' packet.md
rung bounded '**C1. Fine.**'
has "an unreadable review never merges alone" 1 'Merges without a person \| \*\*no\*\*: not eligible' packet.md
W3_TICKET=pc-303 python3 "$triage" auto inputs > /dev/null 2>&1 || true
if grep -q '^# For the person: PC-303, triage' packet.md; then echo "ok   the packet names the ticket"; else echo "FAIL ticket title"; fails=$((fails + 1)); fi

if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
