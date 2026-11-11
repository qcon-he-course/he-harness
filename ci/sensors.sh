#!/usr/bin/env bash
# The sensor job of the pull-request workflow: every deterministic check on a change,
# in a job that holds no model key.
#
#   ci/sensors.sh <checkout of the pull request's head> <base commit> <out dir>
#
# Writes <out>/sensors.md and <out>/change.txt (the OpenSpec change the pull request
# carries). The sensors read a change as an uncommitted difference, so the checkout is
# reset to the merge base first: the files stay as the head has them, HEAD is the base.
# Exit 0: sensors.md written (its content, not this exit code, says what passed).
# Exit 1: the sensors could not run; the policy then has nothing to read and refuses.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
harness="$(dirname "$here")"
[ $# = 3 ] || { sed -n '5p' "$0" >&2; exit 2; }
change_dir="$(cd "$1" && pwd)"; base="$2"; mkdir -p "$3"; out="$(cd "$3" && pwd)"

cd "$change_dir" || exit 1
mb="$(git merge-base "$base" HEAD)" || { echo "sensors: no merge base with $base" >&2; exit 1; }
git reset --quiet --mixed "$mb"
echo "sensors: base $(git log --oneline -1), $(git status --porcelain | wc -l | tr -d ' ') changed files"

# A pull request carries exactly one OpenSpec change: the reviewers check the code against it.
changes="$(find openspec/changes -mindepth 1 -maxdepth 1 -type d ! -name archive -exec basename {} \; 2> /dev/null | sort)"
if [ "$(printf '%s\n' "$changes" | grep -c .)" != 1 ]; then
  echo "sensors: the pull request must carry exactly one OpenSpec change in openspec/changes/; found: ${changes:-none}" >&2
  exit 1
fi
# The name goes into a reviewer's prompt: letters, digits and hyphens only.
case "$changes" in
  *[!a-z0-9-]*|-*) echo "sensors: the change's folder name must be lower-case letters, digits and hyphens" >&2; exit 1 ;;
esac
echo "$changes" > "$out/change.txt"

# The sensors run from a copy beside the known-defect list, which is checked first:
# a closed or missing ticket stops the run, so the list cannot hide a failure.
mkdir -p "$out/sensors"
cp "$harness/sensors/"*.py "$harness/sensors/"*.sh "$harness/sensors/risk-rules.txt" "$out/sensors/"
rm -f "$out/sensors/"*.test.sh
python3 -B "$harness/sensors/known-defects.py" check "$harness/known-defects/known-defect-tests.txt" "$harness/known-defects" \
  > "$out/sensors/known-defect-tests.txt" || { echo "sensors: the known-defect list is not valid" >&2; exit 1; }

bash "$out/sensors/step5.sh" "$change_dir" "$out"
[ -f "$out/sensors.md" ] || { echo "sensors: step 5 wrote no summary" >&2; exit 1; }
bash "$out/sensors/step5-docker.sh" "$change_dir" "$out"
# Scenario coverage last, so it reads the suite's, the lane's and the Docker tests' reports.
python3 -B "$harness/sensors/scenario-coverage.py" --into "$out/sensors.md" "$change_dir" \
  "$out/suite-reports" "$out"/known-reports-* "$out"/docker-reports-* || true
echo "sensors: wrote $out/sensors.md for change $changes"
