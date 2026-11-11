#!/usr/bin/env python3
"""red: is the build red, by the sensors alone?

  ci/red.py <sensors.md>

Reads the summary table of sensors.md. Red means one of: the test suite failed or
left no result, the build's own checks failed, the architecture rule failed, the
mutation score on the changed classes is below its threshold or has no report.
Prints one reason per line. Exit 0: green. Exit 1: red. Exit 2: usage or no file.

The workflow runs no reviewer on a red build (deterministic before semantic: no
model is paid to learn that the build fails), and the policy refuses on this alone.
"""
import re
import sys


def reasons(text):
    def row(name):
        m = re.search(r"^\| " + name + r"[^|]*\| ([^|]+) \|", text, re.M)
        return m.group(1).strip() if m else None

    out = []
    suite = row("Full test suite")
    if suite is None:
        out.append("the test suite (no result)")
    elif "BUILD FAILED" in suite or not re.match(r"\d+ run, 0 failures, 0 errors", suite):
        out.append(f"the test suite ({suite})")
    checks = row("Build checks")
    if checks and "FAIL" in checks:
        out.append(f"the build checks ({checks})")
    arch = row("Architecture rule")
    if arch and not arch.startswith("passes"):
        out.append(f"the architecture rule ({arch})")
    mutation = row("Mutation score on changed classes")
    if mutation and "FAIL" in mutation:
        out.append(f"the mutation score ({mutation})")
    return out


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        sys.exit(2)
    try:
        found = reasons(open(sys.argv[1], encoding="utf-8").read())
    except OSError as e:
        print(f"red: {e}", file=sys.stderr)
        sys.exit(2)
    print("\n".join(found))
    sys.exit(1 if found else 0)
