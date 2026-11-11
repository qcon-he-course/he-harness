#!/usr/bin/env bash
# Tests for review-check.py. Run: ./review-check.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
fails=0
good='{"change":"pc-303","scenarios":[{"title":"A pet of three years","verdict":"MET","evidence":"PetAgeTests.aPetOfThreeYears asserts \"3 years\""}],"findings":[{"id":"C2","disposition":"INFORMATIONAL","title":"A note","where":"Pet.java:40","claim":"c","evidence":"e","falsification":"f","confidence":"low"},{"id":"C1","disposition":"BLOCK","title":"The birthday is a day late","where":"PetAge.java:31","claim":"c","evidence":"e","falsification":"f","confidence":"high"}],"for_the_person":[],"overall":"Not ready."}'
wrap() { printf '{"type":"result","subtype":"%s","is_error":%s,"result":"text","structured_output":%s}' "$1" "$2" "$3"; }
check() { # check <name> <expected exit> <pattern in stderr+stdout, or -> <pattern in review.md, or ->
  python3 -B "$here/review-check.py" "$t/in.json" "$t/review.md" --reviewer claude > "$t/out" 2>&1; local code=$?
  local ok=1
  [ "$code" = "$2" ] || ok=0
  [ "$3" = - ] || grep -qE -- "$3" "$t/out" || ok=0
  if [ "$4" != - ]; then grep -qE -- "$4" "$t/review.md" 2> /dev/null || ok=0; fi
  if [ "$2" != 0 ] && [ -e "$t/review.md" ]; then ok=0; fi
  if [ "$ok" = 1 ]; then echo "ok   $1"; else echo "FAIL $1 (exit $code): $(cat "$t/out")"; fails=$((fails + 1)); fi
}
wrap success false "$good" > "$t/in.json"
check "a valid Claude Code result is written" 0 '1 scenarios, 2 findings, 1 BLOCK' '^\*\*C1: BLOCK\.\*\* The birthday is a day late$'
check "findings are ordered most severe first" 0 - '^\*\*C2: INFORMATIONAL\.\*\* A note$'
if [ "$(grep -n '^\*\*C' "$t/review.md" | head -1 | cut -d: -f2 | cut -c3-4)" = C1 ]; then echo "ok   BLOCK comes before INFORMATIONAL"; else echo "FAIL order"; fails=$((fails + 1)); fi
printf '%s' "$good" > "$t/in.json"
check "a bare review (Codex's file) is written" 0 'review written' '^## Scenarios$'
echo stale > "$t/review.md"; : > "$t/in.json"
check "an empty file is no review, and the stale review is removed" 1 'missing, empty or not JSON' -
rm -f "$t/in.json"
check "a missing file is no review" 1 'missing, empty or not JSON' -
printf 'I could not finish the review.' > "$t/in.json"
check "prose instead of JSON is no review" 1 'not JSON' -
wrap success false null > "$t/in.json"
check "a result with no structured_output is no review" 1 'returned no structured_output' -
wrap error_max_turns true "$good" > "$t/in.json"
check "a run that hit its turn limit is no review, whatever it holds" 1 "did not succeed: subtype 'error_max_turns'" -
wrap error_max_budget_usd true null > "$t/in.json"
check "a run that hit its budget is no review" 1 'did not succeed' -
wrap success false '{"change":"pc-303","scenarios":[],"findings":[],"for_the_person":[],"overall":"Fine."}' > "$t/in.json"
check "a review with no scenario verdicts is refused" 1 'no scenario verdicts' -
wrap success false "$(printf '%s' "$good" | sed 's/"BLOCK"/"MAJOR"/')" > "$t/in.json"
check "an unknown disposition is refused" 1 "unknown disposition 'MAJOR'" -
wrap success false "$(printf '%s' "$good" | sed 's/"id":"C2"/"id":"C1"/')" > "$t/in.json"
check "a finding id used twice is refused" 1 'id C1 used twice' -
wrap success false "$(printf '%s' "$good" | sed 's/,"overall":"Not ready."//')" > "$t/in.json"
check "a missing key is refused" 1 'missing key: overall' -
wrap success false "$(printf '%s' "$good" | sed 's/"overall":/"approved":true,"overall":/')" > "$t/in.json"
check "an extra key is refused" 1 'unknown key: approved' -
wrap success false "$(printf '%s' "$good" | sed 's/"verdict":"MET"/"verdict":"PASS"/')" > "$t/in.json"
check "an unknown verdict is refused" 1 "unknown verdict 'PASS'" -
if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
