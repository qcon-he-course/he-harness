#!/usr/bin/env python3
"""test-delta: how a change alters the tests and the checks that judge it.

  test-delta.py [--rules FILE] [base [head]]

Compares the working tree with base (default HEAD), untracked files included, or
the commits base..head. Reports what a person should look at before trusting
green tests:

  test deleted         a test file, or a @Test method, that is gone
  test renamed         a @Test method under a new name with the same body (the
                       naming rule for scenarios renames tests; a rename that
                       also changes the body is a deletion and an addition)
  assertion removed    an assertion line that is gone and not re-added anywhere
                       in the same file (a moved line is not reported)
  skip added           @Disabled, @Ignore, an assumption, a commented-out @Test
  broad catch added    catch (Exception|Throwable|RuntimeException) in a test, or
                       assertThrows(Exception.class / Throwable.class)
  protected check      a file the rules list as protected-check, changed
  test configuration   a build-file line that skips, excludes or retargets tests,
                       or changes a mutation or coverage threshold

Tests are files under src/test/ whose name ends in Test.java, Tests.java or IT.java.
The protected list comes from the rules file (default: risk-rules.txt next to this
script), surface "protected-check".

Output: one line per finding, <file>:<line>: <kind>: <text>, then a summary of
tests and assertions added and removed. Exit 0: nothing to report. Exit 1:
findings. Exit 2: usage error.
"""

import os
import re
import sys
from collections import Counter

sys.dont_write_bytecode = True  # no __pycache__ next to the sensors
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import changes  # noqa: E402

TEST_FILE = re.compile(r"^(?:.*/)?src/test/.*(?:Test|Tests|IT)\.java$")
ASSERTION = re.compile(
    r"\b(assert[A-Z]\w*|assertThat|assertThrows|assertDoesNotThrow|verify|fail|andExpect|expect[A-Z]?\w*)\s*\("
    r"|^\s*\.(is|has|contains|doesNot|startsWith|endsWith|matches|satisfies|extracting|allMatch|anyMatch|noneMatch)\w*\s*\("
)
TEST_ANNOTATION = re.compile(r"^\s*@(Test|ParameterizedTest|RepeatedTest|TestFactory|TestTemplate|ArchTest)\b")
METHOD = re.compile(r"\b(?:void|[A-Z]\w*(?:<[^>]*>)?)\s+(\w+)\s*[(=]")  # a method, or an @ArchTest field
SKIP = re.compile(
    r"^\s*@(Disabled|Ignore|DisabledIf\w*|EnabledIf\w*|DisabledOn\w*|EnabledOn\w*)\b"
    r"|\bassume(True|False|That)\s*\(|\bassumingThat\s*\(|\bAssumptions\.\w+\s*\("
    r"|^\s*//\s*@(Test|ParameterizedTest)\b"
    r"|disabledWithoutDocker\s*=\s*true"
)
BROAD_CATCH = re.compile(r"catch\s*\(\s*(final\s+)?(Exception|Throwable|RuntimeException)\s+\w+\s*\)"
                         r"|assertThrows\s*\(\s*(Exception|Throwable|RuntimeException)\.class")
BUILD_FILE = re.compile(r"^(?:.*/)?(pom\.xml|build\.gradle(\.kts)?)$")
TEST_CONFIG = re.compile(
    r"skipTests|maven\.test\.skip|testFailureIgnore|failIfNoTests|<skip>|<excludes?>|<exclude>|excludedGroups|"
    r"excludedTestClasses|excludedClasses|targetTests|targetClasses|mutationThreshold|coverageThreshold|"
    r"mutationUnitSize|<threshold|haltOnFailure|failOnViolation|exclude\s*[('\"]|enabled\s*=\s*false"
)

CLOSING_TAG = re.compile(r"^\s*</[^>]+>\s*$")


def norm(text):
    return re.sub(r"\s+", " ", text.strip())


def test_methods(text):
    """Names of test methods: the first method declared after a test annotation."""
    names, pending = [], False
    for line in text.splitlines():
        if TEST_ANNOTATION.search(line):
            pending = True
            continue
        if pending:
            m = METHOD.search(line)
            if m:
                names.append(m.group(1))
                pending = False
    return names


def test_bodies(text):
    """{name: body} for each test method, the body normalised and without the name."""
    lines, out, i = text.splitlines(), {}, 0
    while i < len(lines):
        if TEST_ANNOTATION.search(lines[i]):
            j = i + 1
            while j < len(lines) and not METHOD.search(lines[j]):
                j += 1
            if j >= len(lines):
                break
            name = METHOD.search(lines[j]).group(1)
            depth, k, seen, body = 0, j, False, []
            while k < len(lines):
                body.append(lines[k])
                depth += lines[k].count("{") - lines[k].count("}")
                seen = seen or "{" in lines[k]
                if seen and depth <= 0:
                    break
                k += 1
            out[name] = norm(re.sub(r"\b" + re.escape(name) + r"\b", "_", "\n".join(body), count=1))
            i = k
        i += 1
    return out


def run(argv):
    rules_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "risk-rules.txt")
    revs, args = [], list(argv)
    while args:
        a = args.pop(0)
        if a == "--rules":
            if not args:
                raise changes.Usage("--rules needs a file")
            rules_path = args.pop(0)
        elif a.startswith("-"):
            raise changes.Usage(f"unknown option {a}")
        else:
            revs.append(a)
    if len(revs) > 2:
        raise changes.Usage("usage: test-delta.py [--rules FILE] [base [head]]")
    protected = [r for r in changes.read_rules(rules_path) if r.surface == "protected-check" and r.kind == "path"]
    _, files = changes.read_change(revs[0] if revs else "HEAD", revs[1] if len(revs) > 1 else None)

    findings = []  # (file, line, kind, text)
    counts = Counter()
    for fc in files:
        is_protected = any(r.regex.match(fc.path) or r.regex.match(fc.old_path) for r in protected)
        if is_protected:
            what = {"A": "added", "D": "deleted", "R": "renamed from " + fc.old_path}.get(fc.status, "modified")
            first = (fc.added or fc.removed or [(0, "")])[0][0]
            findings.append((fc.path, first, "protected check", f"{what}, {len(fc.added)} lines added, {len(fc.removed)} removed"))

        if BUILD_FILE.match(fc.path):
            for ln, text in fc.added:
                if TEST_CONFIG.search(text) and not CLOSING_TAG.match(text):
                    findings.append((fc.path, ln, "test configuration", "added: " + norm(text)))
            for ln, text in fc.removed:
                if TEST_CONFIG.search(text) and not CLOSING_TAG.match(text):
                    findings.append((fc.path, ln, "test configuration", "removed: " + norm(text)))

        if not (TEST_FILE.match(fc.path) or TEST_FILE.match(fc.old_path)):
            continue
        before_tests, after_tests = test_methods(fc.before), test_methods(fc.after)
        counts["tests before"] += len(before_tests)
        counts["tests after"] += len(after_tests)
        if fc.status == "D":
            findings.append((fc.path, 0, "test deleted", f"the whole file, {len(before_tests)} tests"))
        else:
            gone, new = set(before_tests) - set(after_tests), set(after_tests) - set(before_tests)
            bodies_before, bodies_after = test_bodies(fc.before), test_bodies(fc.after)
            for name in sorted(gone):
                twin = next((n for n in sorted(new) if bodies_after.get(n) is not None and bodies_after.get(n) == bodies_before.get(name)), None)
                if twin:
                    new.discard(twin)
                    ln = next((n for n, t in fc.added if re.search(r"\b" + re.escape(twin) + r"\s*\(", t)), 0)
                    findings.append((fc.path, ln, "test renamed", f"{name} -> {twin}, body unchanged"))
                    counts["renamed"] += 1
                    continue
                ln = next((n for n, t in fc.removed if re.search(r"\b" + re.escape(name) + r"\s*\(", t)), 0)
                findings.append((fc.path, ln, "test deleted", name))

        added_norm = Counter(norm(t) for _, t in fc.added)
        for ln, text in fc.removed:
            if ASSERTION.search(text):
                counts["assertions removed"] += 1
                key = norm(text)
                if added_norm[key] > 0:
                    added_norm[key] -= 1  # moved, not removed
                    counts["assertions moved"] += 1
                elif fc.status != "D":
                    findings.append((fc.path, ln, "assertion removed", key))
        for ln, text in fc.added:
            if ASSERTION.search(text):
                counts["assertions added"] += 1
            if SKIP.search(text):
                findings.append((fc.path, ln, "skip added", norm(text)))
            if BROAD_CATCH.search(text):
                findings.append((fc.path, ln, "broad catch added", norm(text)))

    for f, ln, kind, text in findings:
        print(f"{f}:{ln}: {kind}: {text}")
    tb, ta = counts["tests before"], counts["tests after"]
    moved = counts["assertions moved"]
    renamed = f"; renamed {counts['renamed']}" if counts["renamed"] else ""
    print(f"summary: tests in changed files {tb} -> {ta}{renamed}; assertion lines added {counts['assertions added'] - moved}, "
          f"removed {counts['assertions removed'] - moved}, moved {moved}; findings {len(findings)}")
    return 1 if findings else 0


if __name__ == "__main__":
    changes.main(run)
