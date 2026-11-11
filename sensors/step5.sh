#!/usr/bin/env bash
# Week 3, step 5: run every sensor on a change, before any model reviews its code.
#
#   step5.sh <clone> <out dir>
#
# Compares the clone's working tree with its HEAD (the change is uncommitted, as the
# coding agent leaves it). Writes <out>/sensors.md, a summary for the reviewer in
# step 6 and for triage in step 7, plus one log per sensor. Run by the local ladder and by the pull-request workflow in
# the container; the sensors are copied next to this script.
#
# The sensors, cheapest first:
#   risk-floor.py    the change's lowest possible tier, from what it touches
#   test-delta.py    deleted tests, removed assertions, skips, protected checks
#   glossary-check   avoided words in the lines the change adds
#   ArchitectureTests the frozen rule
#   ./mvnw validate  the build's own checks (B1's formatter and nohttp, the Java version, and
#                    whatever else the pom binds to validate); on a failure, the formatter and
#                    nohttp run on their own so each problem is reported. The runs below skip them
#   ./mvnw test      the whole suite (MySQL and Postgres tests skip without Docker), without
#                    the tests in known-defect-tests.txt
#   known-defect lane those tests, run on their own with their whole class, KNOWN_DEFECT_RUNS
#                    times (default 3); shown, not counted (plan, 1 November)
#   PIT              mutation testing on the production classes the change touches, named on
#                    the command line, so the build file holds no class list; the score on
#                    them must reach MUTATION_THRESHOLD (default 80) per cent
set -uo pipefail

clone="${1:?usage: step5.sh <clone> <out dir>}"
out="${2:?usage: step5.sh <clone> <out dir>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$out"
cd "$clone" || exit 2
log() { echo "step5: $*" >&2; }
mvn_flags=(-B -Dspring-javaformat.skip=true -Dcheckstyle.skip=true)

log "risk floor"
python3 "$here/risk-floor.py" > "$out/risk-floor.txt" 2>&1
tier="$(python3 "$here/risk-floor.py" --tier 2> /dev/null)"

log "test delta"
python3 "$here/test-delta.py" > "$out/test-delta.txt" 2>&1
delta_exit=$?

log "glossary check"
bash "$here/glossary-check.sh" > "$out/glossary.txt" 2>&1
glossary_exit=$?

log "architecture rule"
./mvnw "${mvn_flags[@]}" -q test -Dtest=ArchitectureTests -Dsurefire.failIfNoSpecifiedTests=false > "$out/architecture.log" 2>&1
arch_exit=$?

log "build checks: ./mvnw validate"
./mvnw -B validate > "$out/validate.log" 2>&1
validate_exit=$?
fmt_exit=0
nohttp_exit=0
if [ "$validate_exit" != 0 ]; then
  # validate stops at its first failure; run B1's two checks on their own so both report.
  ./mvnw -B spring-javaformat:validate > "$out/formatting.log" 2>&1
  fmt_exit=$?
  ./mvnw -B checkstyle:check@nohttp-checkstyle-validation > "$out/nohttp.log" 2>&1
  nohttp_exit=$?
fi

# Tests tied to an open known-defect ticket: out of the suite, into a lane of their own.
# The caller checks the list (known-defects.py) and puts the valid entries next to this script.
known="$here/known-defect-tests.txt"
: > "$out/known-excludes.txt"
# The entries whose test exists in this code (a test can be listed under an old and a new name).
: > "$out/known-defect-tests.txt"
known_classes=""
if [ -s "$known" ]; then
  while read -r test ticket; do
    cls="${test%%#*}"; method="${test#*#}"
    file="$(find src/test/java -name "$cls.java" | head -1)"
    [ -n "$file" ] || { echo "$test $ticket: no test class $cls" >> "$out/known-missing.txt"; continue; }
    grep -qE "void[[:space:]]+$method[[:space:]]*\(" "$file" || continue
    echo "$test $ticket" >> "$out/known-defect-tests.txt"
    rel="${file#src/test/java/}"
    echo "${rel%.java}.class#$method" >> "$out/known-excludes.txt"
    fqcn="$(echo "${rel%.java}" | tr / .)"
    case ",$known_classes," in *",$fqcn,"*) ;; *) known_classes="${known_classes:+$known_classes,}$fqcn" ;; esac
  done < "$known"
fi
excludes=()
[ -s "$out/known-excludes.txt" ] && excludes=(-Dsurefire.excludesFile="$out/known-excludes.txt")

log "full test suite (a few minutes)"
# No report from an earlier build may stand in for this one: a build that fails before the
# tests run (an unresolvable dependency, e22's F3) must leave no results behind it.
rm -rf target/surefire-reports
start=$(date +%s)
./mvnw "${mvn_flags[@]}" test "${excludes[@]}" > "$out/tests.log" 2>&1
tests_exit=$?
tests_secs=$(( $(date +%s) - start ))
# The suite's reports, before the lane and PIT touch target/: scenario-coverage.py reads them.
rm -rf "$out/suite-reports"
cp -R target/surefire-reports "$out/suite-reports" 2> /dev/null

runs="${KNOWN_DEFECT_RUNS:-3}"
if [ -n "$known_classes" ]; then
  log "known-defect lane: $known_classes, $runs runs"
  for i in $(seq 1 "$runs"); do
    # No report left from an earlier run may stand in for this one.
    for c in ${known_classes//,/ }; do rm -f "target/surefire-reports/TEST-$c.xml"; done
    ./mvnw "${mvn_flags[@]}" test -Dtest="$known_classes" -Dsurefire.failIfNoSpecifiedTests=false > "$out/known-defects-$i.log" 2>&1
    mkdir -p "$out/known-reports-$i"
    cp target/surefire-reports/TEST-*.xml "$out/known-reports-$i/" 2> /dev/null
  done
fi

# The production classes the change touches or adds, as class names.
changed_classes="$(git status --porcelain -uall -- src/main/java | awk '$1 != "D" {print $NF}' | grep '\.java$' \
  | sed 's|^src/main/java/||; s|\.java$||; s|/|.|g' | paste -sd, -)"
echo "$changed_classes" > "$out/changed-classes.txt"
rm -rf target/pit-reports "$out/mutations.xml"
pit_exit=0; pit_secs=0
if [ -n "$changed_classes" ]; then
  log "mutation testing (PIT) on: $changed_classes"
  start=$(date +%s)
  ./mvnw "${mvn_flags[@]}" -DskipTests=false org.pitest:pitest-maven:mutationCoverage \
    -DtargetClasses="$changed_classes" -DoutputFormats=XML,HTML -DtimestampedReports=false \
    -DfailWhenNoMutations=false > "$out/pit.log" 2>&1
  pit_exit=$?
  pit_secs=$(( $(date +%s) - start ))
  [ -f target/pit-reports/mutations.xml ] && cp target/pit-reports/mutations.xml "$out/mutations.xml"
else
  log "mutation testing: the change touches no production class"
fi

export MUTATION_THRESHOLD="${MUTATION_THRESHOLD:-80}" CHANGED_CLASSES="$changed_classes"
python3 - "$here" "$clone" "$out" "$tier" "$delta_exit" "$glossary_exit" "$arch_exit" "$tests_exit" "$tests_secs" "$pit_exit" "$pit_secs" "$validate_exit" "$fmt_exit" "$nohttp_exit" <<'PY'
import os, re, sys, xml.etree.ElementTree as ET
here, clone, out, tier, delta_exit, glossary_exit, arch_exit, tests_exit, tests_secs, pit_exit, pit_secs, validate_exit, fmt_exit, nohttp_exit = sys.argv[1:]
sys.dont_write_bytecode = True
sys.path.insert(0, here)
import changes
os.chdir(clone)
_, files = changes.read_change("HEAD")
added = {fc.path.rsplit("/", 1)[-1]: {ln for ln, _ in fc.added} for fc in files if fc.path.endswith(".java")}
read = lambda f: open(os.path.join(out, f), encoding="utf-8", errors="replace").read() if os.path.exists(os.path.join(out, f)) else ""

# Tests: the last "Tests run:" summary line of the Results section, and the failures.
tests = read("tests.log")
summary = re.findall(r"Tests run: (\d+), Failures: (\d+), Errors: (\d+), Skipped: (\d+)\s*$", tests, re.M)
total = summary[-1] if summary else None
failed = sorted(set(re.findall(r"^\[ERROR\]\s+(\w+\.\w+)(?::\d+)?\s", tests, re.M)))
per_class = re.findall(r"Tests run: (\d+), Failures: (\d+), Errors: (\d+), Skipped: (\d+), Time elapsed: [\d.]+ s(?: <<< FAILURE!)? -+ in ([\w.$]+)", tests)
names = [c for *_, c in per_class]
# A class whose tests all skipped, or that ran none and has no nested classes that ran.
not_run = [c.split(".")[-1] + (f" ({s} skipped)" if s != "0" else " (0 run)") for r, f, e, s, c in per_class
           if "$" not in c and (r != "0" and r == s or r == "0" and not any(n.startswith(c + "$") for n in names))]

# PIT
muts = []
if os.path.exists(os.path.join(out, "mutations.xml")):
    for m in ET.parse(os.path.join(out, "mutations.xml")).getroot():
        muts.append({k: (m.findtext(k) or "") for k in ("mutatedClass", "mutatedMethod", "lineNumber", "mutator", "description")} | {"status": m.get("status")})
by = {}
for m in muts:
    by[m["status"]] = by.get(m["status"], 0) + 1

delta = read("test-delta.txt").strip().splitlines()
glossary = read("glossary.txt").strip()
arch = read("architecture.log")

L = []
L.append("# Step 5: the sensors\n")
L.append("Deterministic checks on the change, run before any model reviews its code. Each line is evidence a reviewer may cite.\n")
L.append("| Sensor | Result |")
L.append("|---|---|")
L.append(f"| Risk floor | **{tier}** (see below) |")
L.append(f"| Test-delta audit | {'nothing to report' if delta_exit == '0' else str(len([l for l in delta if not l.startswith('summary:')])) + ' findings'} |")
if glossary_exit == "0":
    g = "no avoided words"
elif glossary_exit == "1":
    g = f"{len(glossary.splitlines())} findings"
else:
    g = f"did not run (exit {glossary_exit})"
L.append(f"| Glossary check | {g} |")
L.append(f"| Architecture rule | {'passes' if arch_exit == '0' else 'FAILS'} |")
fmt_files = re.findall(r"^\[ERROR\]\s+\* (\S+)", read("formatting.log"), re.M)
nohttp_lines = [l for l in read("nohttp.log").splitlines() if "NoHttp:" in l]
if validate_exit == "0":
    checks = "pass (formatting, `http://` URLs, Java version)"
else:
    b1 = []
    if fmt_exit != "0":
        b1.append(f"formatting FAILS ({len(fmt_files)} file{'s' if len(fmt_files) != 1 else ''})" if fmt_files else "formatting FAILS")
    if nohttp_exit != "0":
        b1.append(f"URLs FAIL ({len(nohttp_lines)} http:// URL{'s' if len(nohttp_lines) != 1 else ''})" if nohttp_lines else "URL check FAILS")
    checks = "; ".join(b1) if b1 else "FAIL (another check; see validate.log)"
L.append(f"| Build checks (`./mvnw validate`, B1) | {checks} |")
if total:
    r, f, e, s = total
    L.append(f"| Full test suite ({tests_secs} s) | {r} run, {f} failures, {e} errors, {s} skipped{'' if tests_exit == '0' else ': BUILD FAILED'} |")
else:
    L.append(f"| Full test suite | no summary found (exit {tests_exit}) |")
changed = os.environ.get("CHANGED_CLASSES", "")
threshold = int(os.environ.get("MUTATION_THRESHOLD", "80"))
score_row = f"| Mutation score on changed classes (threshold {threshold}%) |"
if not changed:
    L.append("| Mutation testing | not run: the change touches no production class |")
elif muts:
    detected = sum(by.get(k, 0) for k in ("KILLED", "TIMED_OUT", "MEMORY_ERROR", "RUN_ERROR"))
    pct = detected * 100 // len(muts)
    L.append(f"| Mutation testing, changed classes ({pit_secs} s) | {len(muts)} mutants: {by.get('KILLED', 0)} killed, {by.get('SURVIVED', 0)} survived, {by.get('NO_COVERAGE', 0)} without coverage, {by.get('TIMED_OUT', 0)} timed out |")
    L.append(f"{score_row} {'pass' if pct >= threshold else 'FAIL'}: {pct}% ({detected} of {len(muts)} mutants detected) |")
elif pit_exit == "0":
    L.append(f"| Mutation testing, changed classes ({pit_secs} s) | no mutants |")
    L.append(f"{score_row} pass: no mutants in the changed classes |")
else:
    # Fail closed: classes changed and PIT gave no report.
    L.append(f"| Mutation testing | no report (exit {pit_exit}) |")
    L.append(f"{score_row} FAIL: no mutation report for the changed classes |")
L.append("")
L.append("## Risk floor\n\n```\n" + read("risk-floor.txt").strip() + "\n```\n")
L.append("## Test-delta audit\n\n```\n" + "\n".join(delta) + "\n```\n")
L.append("## Glossary check\n\n" + ("No avoided word in the added lines.\n" if glossary_exit == "0" else "```\n" + glossary + "\n```\n"))
if validate_exit != "0":
    L.append("## Build checks (`./mvnw validate`)\n")
    if fmt_exit == "0" and nohttp_exit == "0":
        errs = [l for l in read("validate.log").splitlines() if l.startswith("[ERROR]") and l.strip() != "[ERROR]"][:10]
        L.append("Formatting and `http://` URLs pass on their own; `./mvnw validate` failed on another check:\n")
        L.append("```\n" + "\n".join(errs) + "\n```\n")
    if fmt_exit != "0":
        L.append("Unformatted, per `./mvnw spring-javaformat:validate` (the fix is `./mvnw spring-javaformat:apply`):\n")
        L.append("\n".join(f"- `{os.path.relpath(f, clone)}`" for f in fmt_files) or "- see `formatting.log`")
        L.append("")
    if nohttp_exit != "0":
        L.append("`http://` URLs, per the nohttp checkstyle:\n")
        L.append("```\n" + ("\n".join(l.replace("[ERROR] ", "") for l in nohttp_lines) or "see nohttp.log") + "\n```\n")
if arch_exit != "0":
    L.append("## Architecture rule\n\n```\n" + "\n".join(l for l in arch.splitlines() if "violated" in l or l.startswith("Method <"))[:3000] + "\n```\n")
L.append("## Full test suite\n")
if failed:
    L.append("Failed: " + ", ".join(f"`{x}`" for x in failed) + "\n")
if not_run:
    L.append("Not run (no Docker): " + ", ".join(not_run) + ". Not run is not passed.\n")
if muts:
    L.append("## Mutation testing: survivors and mutants without coverage\n")
    L.append("PIT mutated the production classes the change touches: " + ", ".join(f"`{c.split('.')[-1]}`" for c in changed.split(",")) + ".\n")
    new = [m for m in muts if int(m["lineNumber"] or 0) in added.get(m["mutatedClass"].split(".")[-1] + ".java", set())]
    nb = {}
    for m in new:
        nb[m["status"]] = nb.get(m["status"], 0) + 1
    L.append(f"On lines the change adds: {len(new)} mutants, {nb.get('KILLED', 0)} killed, {nb.get('SURVIVED', 0)} survived, {nb.get('NO_COVERAGE', 0)} without coverage.\n")
    L.append("| Status | Class | Method | Line | In the change | Mutation |")
    L.append("|---|---|---|---|---|---|")
    for m in sorted(muts, key=lambda m: (m["status"], m["mutatedClass"], int(m["lineNumber"] or 0))):
        if m["status"] in ("SURVIVED", "NO_COVERAGE"):
            inc = "yes" if m in new else "no"
            L.append(f"| {m['status']} | {m['mutatedClass'].split('.')[-1]} | {m['mutatedMethod']} | {m['lineNumber']} | {inc} | {m['description']} |")
    L.append("")
# Known-defect lane: each listed test's result in each run, from the Surefire reports.
known = []
kpath = os.path.join(out, "known-defect-tests.txt")
if os.path.exists(kpath):
    for line in open(kpath):
        if line.strip():
            test, ticket = line.split()
            cls, method = test.split("#")
            res = {"failed": 0, "passed": 0, "missing": 0}
            i = 1
            while os.path.isdir(os.path.join(out, f"known-reports-{i}")):
                d = os.path.join(out, f"known-reports-{i}")
                found = None
                for f in os.listdir(d):
                    if f.endswith("." + cls + ".xml") or f == f"TEST-{cls}.xml":
                        for tc in ET.parse(os.path.join(d, f)).getroot().iter("testcase"):
                            if tc.get("name") == method:
                                found = "failed" if tc.find("failure") is not None or tc.find("error") is not None else "skipped" if tc.find("skipped") is not None else "passed"
                res["missing" if found in (None, "skipped") else found] += 1
                i += 1
            known.append((test, ticket, res, i - 1))
if known:
    row = "; ".join(f"{t.split('#')[1]} ({k}): failed {r['failed']} of {n}" + (f", not found {r['missing']}" if r["missing"] else "") for t, k, r, n in known)
    idx = next(i for i, l in enumerate(L) if l.startswith("| Full test suite"))
    L[idx] = L[idx].replace("| Full test suite", f"| Full test suite, without {len(known)} known-defect test{'s' if len(known) > 1 else ''}", 1)
    L.insert(idx + 1, f"| Known-defect lane (shown, not counted) | {row} |")
    L.append("## Known-defect tests\n")
    L.append("Tests tied to an open ticket (`known-defect-tests.txt`). They are left out of the full suite above and run here on their own, with their whole class as the suite runs them. Their result is shown here and in the packet; it does not decide the build.\n")
    L.append("| Test | Ticket | Runs | Failed | Passed | Not found |")
    L.append("|---|---|---|---|---|---|")
    for t, k, r, n in known:
        L.append(f"| `{t}` | {k} | {n} | {r['failed']} | {r['passed']} | {r['missing']} |")
    L.append("")
    if any(r["passed"] == n and n > 0 for _, _, r, n in known):
        L.append("A test that passed in every run may mean its defect is fixed, or only that the timing hid it this time. Its ticket closes on evidence, not on one green lane.\n")
open(os.path.join(out, "sensors.md"), "w").write("\n".join(L))
PY
log "done: $out/sensors.md"
