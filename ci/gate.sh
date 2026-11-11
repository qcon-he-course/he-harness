#!/usr/bin/env bash
# The triage job of the pull-request workflow: the policy, with no model and no key.
#
#   ci/gate.sh <inputs dir>
#
# <inputs dir> holds sensors.md, change.txt and one review-step6-<reviewer>.md for each
# reviewer in REVIEWERS (default "claude codex"). A red build (ci/red.py) is refused on
# the sensors alone, with or without reviews. A reviewer with no review is a failed
# check: the change is then not eligible, whatever the other review says. The policy
# (sensors/triage.py auto) writes packet.md beside the inputs folder.
# Prints eligible=yes|no and rung=yes|no, also to $GITHUB_OUTPUT, and the packet to
# $GITHUB_STEP_SUMMARY. Exit 0 only when the change is eligible to merge.
# A packet that says "yes, once the questions are answered" is not eligible yet: the
# check stays red until a person's answer is in the change (a new push runs everything
# again) or a person with the right to bypass the ruleset merges it in their own name.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
harness="$(dirname "$here")"
[ $# = 1 ] || { sed -n '4p' "$0" >&2; exit 2; }
inputs="$(cd "$1" && pwd)"
packet="$(dirname "$inputs")/packet.md"
rm -f "$packet"
refuse() {  # refuse <reason>: no packet from the policy, so say why in one
  printf '# For the person\n\n| | |\n|---|---|\n| Eligible to merge | **no**: %s |\n| Merges without a person | **no**: not eligible |\n' "$1" > "$packet"
}

missing=""
for r in ${REVIEWERS:-claude codex}; do
  [ -s "$inputs/review-step6-$r.md" ] || missing="${missing:+$missing, }$r"
done
red=""
[ -s "$inputs/sensors.md" ] && red="$(python3 -B "$here/red.py" "$inputs/sensors.md" | paste -sd';' - | sed 's/;/; /g')"
if [ ! -s "$inputs/sensors.md" ] || [ ! -s "$inputs/change.txt" ]; then
  refuse "the sensors left no result"
elif [ -n "$red" ]; then
  refuse "the build is red: $red. No reviewer runs on a red build"
elif [ -n "$missing" ]; then
  refuse "no review from: $missing (a missing or malformed review is a failed check)"
else
  W3_TICKET="$(cat "$inputs/change.txt")" python3 -B "$harness/sensors/triage.py" auto "$inputs" > /dev/null \
    || echo "gate: the policy's audit failed; the packet says why" >&2
  [ -s "$packet" ] || refuse "the policy wrote no packet"
fi

row() { grep -m1 "^| $1 |" "$packet" | grep -q '\*\*yes\*\*' && echo yes || echo no; }
eligible="$(row 'Eligible to merge')"
rung="$(row 'Merges without a person')"
[ "$eligible" = yes ] || rung=no
echo "eligible=$eligible"; echo "rung=$rung"
if [ -n "${GITHUB_OUTPUT:-}" ]; then { echo "eligible=$eligible"; echo "rung=$rung"; } >> "$GITHUB_OUTPUT"; fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat "$packet" >> "$GITHUB_STEP_SUMMARY"; fi
[ "$eligible" = yes ]
