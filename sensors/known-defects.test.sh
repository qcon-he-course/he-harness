#!/usr/bin/env bash
# Tests for known-defects.py. Run: ./known-defects.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
fails=0
run() { python3 -B "$here/known-defects.py" check "$t/list.txt" "$t" > "$t/out" 2> "$t/err"; echo $?; }
expect() { # expect <name> <exit> <grep pattern on stdout+stderr or ->
  local code; code="$(run)"
  if [ "$code" != "$2" ]; then echo "FAIL $1: exit $code, wanted $2"; cat "$t/out" "$t/err"; fails=$((fails + 1)); return; fi
  if [ "$3" != - ] && ! grep -qE "$3" "$t/out" "$t/err"; then echo "FAIL $1: no match for $3"; cat "$t/out" "$t/err"; fails=$((fails + 1)); return; fi
  echo "ok   $1"
}
printf '**Status:** open\n' > "$t/PC-1.md"
printf '**Status:** closed\n' > "$t/PC-2.md"
printf 'no status here\n' > "$t/PC-3.md"
printf '# comment\n\nATests#race PC-1\n' > "$t/list.txt"; expect "an entry with an open ticket is printed" 0 '^ATests#race PC-1$'
printf '# only comments\n' > "$t/list.txt"; expect "an empty list is valid" 0 -
printf 'ATests#race PC-2\n' > "$t/list.txt"; expect "a closed ticket sends the test back into the build" 1 'PC-2 is closed, so the test goes back into the build'
printf 'ATests#race PC-9\n' > "$t/list.txt"; expect "a missing ticket fails" 1 'no ticket file PC-9.md'
printf 'ATests#race PC-3\n' > "$t/list.txt"; expect "a ticket with no status fails" 1 'has no "\*\*Status:\*\*" line'
printf 'ATests race PC-1\n' > "$t/list.txt"; expect "a malformed line fails" 1 'line 1: not'
printf 'ATests#race\n' > "$t/list.txt"; expect "an entry without a ticket fails" 1 'line 1: not'
printf 'ATests#race PC-1\nBTests#slow PC-2\n' > "$t/list.txt"; expect "one bad entry fails the whole list" 1 'BTests#slow: PC-2 is closed'
if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
