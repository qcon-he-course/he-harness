#!/usr/bin/env python3
"""drift-issue: the body of the issue the drift check files, from drift.md and nothing else.

  ci/drift-issue.py <drift.md>

The job that files the issue holds a token that can write issues, so it does not copy a
file into the issue. It takes only the finding lines that have the one shape the sensor
writes ("scenario <capability>: <title>: UNTESTED|FAILED|NO LEVEL at <level>: <reason>"),
at most 40 of them and 300 characters each, and builds the body around them.
Exit 0 with the body on stdout: there are findings. Exit 1: none that fit the shape.
"""
import re
import sys

LINE = re.compile(r"^scenario [a-z0-9-]+: [^`\[\]<>]{1,160}: (UNTESTED|FAILED|NO LEVEL) at [a-z -]+: [^`\[\]<>]{1,120}$")


def body(text):
    found = [l.strip() for l in text.splitlines() if LINE.match(l.strip())][:40]
    if not found:
        return None
    return "\n".join([
        "The scheduled drift check found scenarios in the main specs that no test shows at their declared level.",
        "", "```", *[l[:300] for l in found], "```", "",
        "Each line is a scenario, its status and the reason. Fix the test or the spec, in a pull request.",
        "This issue is filed by a job with no model. It is updated on each run that still finds drift.",
    ])


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        sys.exit(2)
    try:
        out = body(open(sys.argv[1], encoding="utf-8").read())
    except OSError as e:
        print(f"drift-issue: {e}", file=sys.stderr)
        sys.exit(1)
    if out is None:
        sys.exit(1)
    print(out)
