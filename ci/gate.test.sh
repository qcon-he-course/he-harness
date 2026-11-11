#!/usr/bin/env bash
# Tests for ci/gate.sh. Run: ci/gate.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
fails=0
sensors() { # sensors <floor> <mutation result>
  printf '# Step 5\n\n| Sensor | Result |\n|---|---|\n| Risk floor | **%s** (see below) |\n| Full test suite (17 s) | 10 run, 0 failures, 0 errors, 0 skipped |\n| Mutation score on changed classes (threshold 80%%) | %s |\n\n## Test-delta audit\n\n```\nsummary: findings 0\n```\n\n## Full test suite\n\n' "$1" "$2"
}
review() { printf '# Code review\n\n## Scenarios\n\n| Scenario | Verdict | Evidence |\n|---|---|---|\n| A | MET | t |\n\n## Findings\n\n%s\n\n## For the person\n\nNothing needs a person.\n' "$1"; }
setup() { rm -rf "$t/run"; mkdir -p "$t/run/inputs"; echo pc-9 > "$t/run/inputs/change.txt"; }
check() { # check <name> <expected exit> <expected eligible> <expected rung> <pattern in packet or ->
  local o code; o="$(bash "$here/gate.sh" "$t/run/inputs" 2>&1)"; code=$?
  local ok=1
  [ "$code" = "$2" ] || ok=0
  echo "$o" | grep -qx "eligible=$3" || ok=0
  echo "$o" | grep -qx "rung=$4" || ok=0
  [ "$5" = - ] || grep -qE -- "$5" "$t/run/packet.md" || ok=0
  if [ "$ok" = 1 ]; then echo "ok   $1"; else echo "FAIL $1 (exit $code): $o"; sed -n 1,8p "$t/run/packet.md" 2> /dev/null; fails=$((fails + 1)); fi
}
none='No findings.'
setup; sensors bounded 'pass: 90% (9 of 10 mutants detected)' > "$t/run/inputs/sensors.md"; review "$none" > "$t/run/inputs/review-step6-claude.md"; review "$none" > "$t/run/inputs/review-step6-codex.md"
check "a bounded change with two clean reviews is eligible and merges with no person" 0 yes yes -
setup; sensors material 'pass: 90% (9 of 10 mutants detected)' > "$t/run/inputs/sensors.md"; review "$none" > "$t/run/inputs/review-step6-claude.md"; review "$none" > "$t/run/inputs/review-step6-codex.md"
check "a material change is eligible and still needs a person" 0 yes no 'risk floor material'
setup; sensors bounded 'pass: 90% (9 of 10 mutants detected)' > "$t/run/inputs/sensors.md"; review '**C1: BLOCK.** The birthday is a day late.' > "$t/run/inputs/review-step6-claude.md"; review "$none" > "$t/run/inputs/review-step6-codex.md"
check "one reviewer's BLOCK makes the change not eligible" 1 no no '1 open BLOCK'
setup; sensors bounded 'FAIL: 60% (6 of 10 mutants detected)' > "$t/run/inputs/sensors.md"; review "$none" > "$t/run/inputs/review-step6-claude.md"; review "$none" > "$t/run/inputs/review-step6-codex.md"
check "a mutation score below the threshold is not eligible" 1 no no 'the mutation threshold on changed classes'
setup; sensors bounded 'pass: 90% (9 of 10 mutants detected)' > "$t/run/inputs/sensors.md"; review "$none" > "$t/run/inputs/review-step6-claude.md"
check "a missing review is a failed check" 1 no no 'no review from: codex'
setup; sensors bounded 'pass: 90% (9 of 10 mutants detected)' > "$t/run/inputs/sensors.md"; review "$none" > "$t/run/inputs/review-step6-claude.md"; : > "$t/run/inputs/review-step6-codex.md"
check "an empty review file is a failed check" 1 no no 'no review from: codex'
setup; review "$none" > "$t/run/inputs/review-step6-claude.md"; review "$none" > "$t/run/inputs/review-step6-codex.md"
check "no sensor result is a failed check" 1 no no 'the sensors left no result'
setup; sensors bounded 'pass: 90% (9 of 10 mutants detected)' > "$t/run/inputs/sensors.md"; review '**C1: DISCUSS.** Should the label be translated?' > "$t/run/inputs/review-step6-claude.md"; review "$none" > "$t/run/inputs/review-step6-codex.md"
check "a question for a person holds the check until it is answered" 1 no no 'yes, once the questions are answered'
if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
