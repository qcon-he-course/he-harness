#!/usr/bin/env bash
# The drift check, run on a schedule from the protected branch: does every scenario in the
# main specs still have a test at its declared level that runs and passes? No model, no key.
#
#   ci/drift.sh <checkout of the protected branch> <out dir>
#
# Runs the suite (the known-defect tests in a lane of their own, once), then
# sensors/scenario-coverage.py --main --known. Writes <out>/drift.md.
# Exit 0: no drift. Exit 1: drift, or the check could not run (no result is drift).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
harness="$(dirname "$here")"
[ $# = 2 ] || { sed -n '5p' "$0" >&2; exit 2; }
clone="$(cd "$1" && pwd)"; mkdir -p "$2"; out="$(cd "$2" && pwd)"
known="$out/known-defect-tests.txt"
python3 -B "$harness/sensors/known-defects.py" check "$harness/known-defects/known-defect-tests.txt" "$harness/known-defects" \
  > "$known" || { echo "drift: the known-defect list is not valid" >&2; exit 1; }

cd "$clone" || exit 1
: > "$out/excludes.txt"; classes=""
while read -r test _; do
  [ -n "$test" ] || continue
  cls="${test%%#*}"; method="${test#*#}"
  file="$(find src/test/java -name "$cls.java" | head -1)"
  [ -n "$file" ] || continue
  rel="${file#src/test/java/}"
  echo "${rel%.java}.class#$method" >> "$out/excludes.txt"
  fqcn="$(echo "${rel%.java}" | tr / .)"
  case ",$classes," in *",$fqcn,"*) ;; *) classes="${classes:+$classes,}$fqcn" ;; esac
done < "$known"
flags=(-B -Dspring-javaformat.skip=true -Dcheckstyle.skip=true)
excludes=(); [ -s "$out/excludes.txt" ] && excludes=(-Dsurefire.excludesFile="$out/excludes.txt")

rm -rf target/surefire-reports
./mvnw "${flags[@]}" test "${excludes[@]}" > "$out/tests.log" 2>&1; suite=$?
rm -rf "$out/suite-reports"; cp -R target/surefire-reports "$out/suite-reports" 2> /dev/null
if [ -n "$classes" ]; then
  for c in ${classes//,/ }; do rm -f "target/surefire-reports/TEST-$c.xml"; done
  ./mvnw "${flags[@]}" test -Dtest="$classes" -Dsurefire.failIfNoSpecifiedTests=false > "$out/known.log" 2>&1
  mkdir -p "$out/known-reports"; cp target/surefire-reports/TEST-*.xml "$out/known-reports/" 2> /dev/null
fi

{
  echo "# Drift check: the main specs against the tests"
  echo
  echo "Commit $(git log --oneline -1). Suite exit $suite."
  echo
  python3 -B "$harness/sensors/scenario-coverage.py" --main --known "$known" "$clone" "$out/suite-reports" "$out/known-reports"
} > "$out/drift.md"
code=$?
[ -d "$out/suite-reports" ] || { echo "drift: the suite left no reports" >&2; exit 1; }
cat "$out/drift.md"
[ "$code" = 0 ] && [ "$suite" = 0 ]
