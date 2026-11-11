#!/usr/bin/env python3
"""scenario-coverage: is each scenario of a change shown by a test at its declared level?

  scenario-coverage.py [--main] [--manual FILE] [--into SENSORS_MD] <clone> [<surefire report dir>...]

Scenarios come from the change's spec deltas (openspec/changes/<change>/specs/**/
spec.md, ADDED and MODIFIED requirements). With --main they come from the main specs
instead (openspec/specs/**/spec.md, every requirement): the check for drift between
the specs a team keeps and its tests, run on a schedule. Each scenario declares the lowest level
at which its outcome can be observed, in a line "- **CHECKED AT** <level>":

  unit < form < database < mysql-postgres < concurrency < manual

A test shows a scenario by its name alone: the scenario's title in lowerCamelCase,
apostrophes and other punctuation dropped, compared without case; more words may
follow, and the longest matching title wins. A test's levels come from its class:
@WebMvcTest is form; @SpringBootTest or @DataJpaTest is database, and also form if
it drives MockMvc or HTTP; Testcontainers or Docker Compose is mysql-postgres;
threads against a running app are concurrency; none of these is unit. A manual
scenario needs "manual: <reason>" and a record "### <title>" in the --manual file.

Statuses: PRESENT (a test at the declared level ran and passed), ABOVE (shown only
by tests above its level: tested higher than it needs to be; informational),
FAILED (its test at the level failed), UNTESTED (no test at its level ran and
passed), NO LEVEL (no CHECKED AT line). Presence is not adequacy: whether a named
test can fail is the reviewer's question, and mutation testing's.

With --into, the section is appended to step 5's sensors.md and a row is added
to its summary table; otherwise it is printed.

Output: markdown, with a findings block for triage (one line per UNTESTED,
FAILED or NO LEVEL scenario) and the pyramid's shape. Exit 0: every scenario
PRESENT or ABOVE; 1: findings; 2: usage.
"""

import os
import re
import sys
import xml.etree.ElementTree as ET

LEVELS = ["unit", "form", "database", "mysql-postgres", "concurrency", "manual"]
TEST_ANNOTATION = re.compile(r"^\s*@(Test|ParameterizedTest|RepeatedTest|TestFactory|TestTemplate)\b")
METHOD = re.compile(r"\bvoid\s+(\w+)\s*\(")
CHECKED_AT = re.compile(r"^-\s+\*\*CHECKED AT\*\*\s+([\w-]+)(?:\s*:\s*(.*))?$")


def camel(title):
    words = re.findall(r"[A-Za-z0-9]+", title.replace("'", "").replace("’", ""))
    return (words[0].lower() + "".join(w[0].upper() + w[1:] for w in words[1:])) if words else ""


def scenarios(clone, main=False):
    out = []
    root = os.path.join(clone, "openspec", "specs" if main else "changes")
    for dirpath, dirs, files in sorted(os.walk(root)):
        # Archived changes are history. (Pruning dirs here would do nothing: sorted() has
        # already walked the whole tree.)
        if not main and "archive" in os.path.relpath(dirpath, root).split(os.sep):
            continue
        if "spec.md" not in files:
            continue
        section, req, cur = ("ADDED" if main else None), None, None
        for line in open(os.path.join(dirpath, "spec.md"), encoding="utf-8"):
            line = line.rstrip("\n")
            h = re.match(r"^## (ADDED|MODIFIED|REMOVED|RENAMED) Requirements", line)
            if h:
                section = h.group(1)
                continue
            r = re.match(r"^### Requirement: (.*)", line)
            if r:
                req = r.group(1).strip()
                continue
            sc = re.match(r"^#### Scenario: (.*)", line)
            if sc and section in ("ADDED", "MODIFIED"):
                cur = {"title": sc.group(1).strip(), "requirement": req, "capability": os.path.basename(dirpath),
                       "level": None, "reason": None}
                out.append(cur)
                continue
            if sc:
                cur = None
                continue
            c = CHECKED_AT.match(line.strip())
            if c and cur is not None:
                cur["level"], cur["reason"] = c.group(1).lower(), (c.group(2) or "").strip() or None
    return out


def class_levels(text, name):
    levels = set()
    if re.search(r"@Testcontainers\b|\bMySQLContainer\b|\bPostgreSQLContainer\b|spring\.docker\.compose|DockerComposeProperties|JdbcConnectionDetails", text):
        levels.add("mysql-postgres")
    spring = re.search(r"@SpringBootTest\b|@DataJpaTest\b", text)
    if spring:
        levels.add("database")
        if re.search(r"\bMockMvc\b|@AutoConfigureMockMvc|RestTemplate|TestRestTemplate|HttpClient|WebTestClient|RestClient", text):
            levels.add("form")
        if re.search(r"\bExecutorService\b|\bCountDownLatch\b|new Thread\(|CompletableFuture", text):
            levels.add("concurrency")
    if re.search(r"@WebMvcTest\b", text):
        levels.add("form")
    return levels or {"unit"}


def tests(clone):
    """[(class name as Surefire reports it, method, levels)] for every test method."""
    out = []
    root = os.path.join(clone, "src", "test", "java")
    for dirpath, _, files in os.walk(root):
        for f in files:
            if not f.endswith(".java"):
                continue
            path = os.path.join(dirpath, f)
            text = open(path, encoding="utf-8", errors="replace").read()
            pkg = re.search(r"^package\s+([\w.]+);", text, re.M)
            outer = (pkg.group(1) + "." if pkg else "") + f[:-5]
            levels = class_levels(text, f[:-5])
            # Nested classes: Surefire reports Outer$Nested. Track class declarations by brace depth.
            stack, depth, pending = [], 0, False
            for line in text.splitlines():
                m = re.search(r"\bclass\s+(\w+)", line)
                if m and m.group(1) != f[:-5] and "{" in line:
                    stack.append((m.group(1), depth))
                if TEST_ANNOTATION.search(line):
                    pending = True
                elif pending:
                    mm = METHOD.search(line)
                    if mm:
                        cls = outer + "".join("$" + n for n, _ in stack)
                        out.append((cls, mm.group(1), levels))
                        pending = False
                depth += line.count("{") - line.count("}")
                while stack and depth <= stack[-1][1]:
                    stack.pop()
    return out


def results(dirs):
    """{(classname, method): 'passed'|'failed'|'skipped'} across reports: a failure anywhere is a
    failure; a pass anywhere beats a skip (skipped in the container, run on the host)."""
    rank = {"skipped": 0, "passed": 1, "failed": 2}
    out = {}
    for d in dirs:
        if not os.path.isdir(d):
            continue
        for dirpath, _, files in os.walk(d):
            for f in files:
                if not (f.startswith("TEST-") and f.endswith(".xml")):
                    continue
                try:
                    root = ET.parse(os.path.join(dirpath, f)).getroot()
                except ET.ParseError:
                    continue
                for tc in root.iter("testcase"):
                    name = re.split(r"[(\[]", tc.get("name", ""))[0].strip()
                    st = "failed" if tc.find("failure") is not None or tc.find("error") is not None else "skipped" if tc.find("skipped") is not None else "passed"
                    key = (tc.get("classname", ""), name)
                    if key not in out or rank[st] > rank[out[key]]:
                        out[key] = st
    return out


def manual_records(path):
    if not path or not os.path.exists(path):
        return set()
    return {m.group(1).strip().lower() for m in re.finditer(r"^### (.+)$", open(path, encoding="utf-8").read(), re.M)}


def assess(scs, tts, res, manual):
    keys = {s["title"]: camel(s["title"]).lower() for s in scs}
    by_scenario = {s["title"]: [] for s in scs}
    for cls, method, levels in tts:
        ml = method.lower()
        match = max((t for t, k in keys.items() if k and ml.startswith(k)), key=lambda t: len(keys[t]), default=None)
        if match:
            by_scenario[match].append((cls, method, levels, res.get((cls, method), "not run")))
    rows = []
    for s in scs:
        found = by_scenario[s["title"]]
        lvl = s["level"]
        if lvl not in LEVELS:
            status = "NO LEVEL" if lvl is None else "NO LEVEL"
            detail = "no CHECKED AT line" if lvl is None else f"unknown level {lvl}"
        elif lvl == "manual":
            if not s["reason"]:
                status, detail = "UNTESTED", "manual, with no recorded reason"
            elif s["title"].lower() in manual:
                status, detail = "PRESENT", "manual record"
            else:
                status, detail = "UNTESTED", "manual, with no record"
        else:
            at = [x for x in found if lvl in x[2]]
            above = [x for x in found if lvl not in x[2] and min(LEVELS.index(l) for l in x[2]) > LEVELS.index(lvl)]
            if any(x[3] == "passed" for x in at):
                status, detail = "PRESENT", ""
            elif any(x[3] == "failed" for x in at):
                status, detail = "FAILED", "its test at this level failed"
            elif at:
                status, detail = "UNTESTED", f"its test at this level did not run ({', '.join(sorted(set(x[3] for x in at)))})"
            elif any(x[3] == "passed" for x in above):
                status, detail = "ABOVE", "shown only above its level: tested higher than it needs to be"
            elif found:
                status, detail = "UNTESTED", "only tests below its level, or tests that did not pass"
            else:
                status, detail = "UNTESTED", "no test is named for it"
        rows.append((s, status, detail, found))
    return rows


def run(argv):
    manual, into, main, args = None, None, False, list(argv)
    while args[:1] in (["--manual"], ["--into"], ["--main"]):
        if args[0] == "--main":
            main, args = True, args[1:]
            continue
        if len(args) < 2:
            print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
            return 2
        if args[0] == "--manual":
            manual = args[1]
        else:
            into = args[1]
        args = args[2:]
    if not args or not os.path.isdir(args[0]):
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    clone, dirs = args[0], args[1:]
    scs = scenarios(clone, main)
    rows = assess(scs, tests(clone), results(dirs), manual_records(manual))
    count = lambda st: sum(1 for r in rows if r[1] == st)
    L = ["## Scenario coverage of the main specs" if main else "## Scenario coverage", ""]
    if not scs:
        L += ["No scenario in the main specs." if main else "No scenario in the change's spec deltas.", ""]
        emit(L, into, "no scenario in the main specs" if main else "no scenario in the change")
        return 0
    L.append(f"{len(rows)} scenarios: {count('PRESENT')} present, {count('ABOVE')} tested above their level, "
             f"{count('FAILED')} failed, {count('UNTESTED')} untested, {count('NO LEVEL')} with no level declared. "
             "A test shows a scenario by its name; present is not adequate: whether the test can fail is the reviewer's question.\n")
    shape = [(l, sum(1 for s in scs if s["level"] == l)) for l in LEVELS]
    L.append("Shape, by declared level: " + ", ".join(f"{l} {n}" for l, n in shape) + ".\n")
    L.append("| Scenario | Level | Status | Tests (level: result) |")
    L.append("|---|---|---|---|")
    for s, status, detail, found in rows:
        ts = "; ".join(f"`{c.split('.')[-1]}.{m}` ({'/'.join(l for l in LEVELS if l in lv)}: {r})" for c, m, lv, r in found) or "none"
        L.append(f"| {s['title']} | {s['level'] or '-'} | {status}{(': ' + detail) if detail and status != 'ABOVE' else ''} | {ts} |")
    L.append("")
    flagged = [r for r in rows if r[1] in ("UNTESTED", "FAILED", "NO LEVEL")]
    above = [r for r in rows if r[1] == "ABOVE"]
    if flagged:
        L.append("```")
        for s, status, detail, _ in flagged:
            L.append(f"scenario {s['capability']}: {s['title']}: {status} at {s['level'] or 'no level'}: {detail}")
        L.append("```\n")
    if above:
        L.append("Tested above their level (informational): " + "; ".join(r[0]["title"] for r in above) + ".\n")
    shape_text = ", ".join(f"{l} {n}" for l, n in shape if n)
    emit(L, into, f"{count('PRESENT')} of {len(rows)} present, {count('ABOVE')} above their level, {count('FAILED')} failed, "
                  f"{count('UNTESTED')} untested, {count('NO LEVEL')} with no level; shape: {shape_text}")
    return 1 if flagged else 0


def emit(lines, into, row):
    if not into:
        print("\n".join(lines))
        return
    text = open(into, encoding="utf-8").read()
    table = text.split("\n")
    last = max((i for i, l in enumerate(table) if l.startswith("| ")), default=None)
    first_section = next((i for i, l in enumerate(table) if l.startswith("## ")), len(table))
    rows = [i for i, l in enumerate(table[:first_section]) if l.startswith("| ")]
    if rows:
        table.insert(rows[-1] + 1, f"| Scenario coverage (by test name and level) | {row} |")
    text = "\n".join(table).rstrip("\n") + "\n\n" + "\n".join(lines) + "\n"
    open(into, "w", encoding="utf-8").write(text)


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    sys.exit(run(sys.argv[1:]))
