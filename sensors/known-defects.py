#!/usr/bin/env python3
"""known-defects: check the list of tests tied to a known defect, before step 5 uses it.

  known-defects.py check <list> <ticket dir>

The list (known-defects/known-defect-tests.txt) has one test per line,
"<test class>#<test method> <ticket>", and comments starting with #. Each ticket
must be a file <ticket dir>/<ticket>.md with a line "**Status:** open". A test
with no open ticket goes back into the build: the list is no place to hide a
failure.

Prints the valid entries, one per line, for step5.sh. Exit 0: every entry is
valid (an empty list is valid); 1: an entry is malformed or its ticket is missing
or closed, with the reasons on stderr; 2: usage.
"""

import os
import re
import sys

ENTRY = re.compile(r"^([A-Za-z_]\w*)#([A-Za-z_]\w*)\s+([A-Z]+-\d+)$")
STATUS = re.compile(r"^\*\*Status:\*\*\s*(\w+)", re.M)


def check(list_path, ticket_dir):
    entries, problems = [], []
    for n, raw in enumerate(open(list_path, encoding="utf-8"), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = ENTRY.match(line)
        if not m:
            problems.append(f"line {n}: not \"<test class>#<test method> <ticket>\": {line}")
            continue
        cls, method, ticket = m.groups()
        ticket_file = os.path.join(ticket_dir, ticket + ".md")
        if not os.path.exists(ticket_file):
            problems.append(f"line {n}: {cls}#{method}: no ticket file {ticket}.md")
            continue
        status = STATUS.search(open(ticket_file, encoding="utf-8").read())
        if not status:
            problems.append(f"line {n}: {cls}#{method}: {ticket}.md has no \"**Status:**\" line")
        elif status.group(1).lower() != "open":
            problems.append(f"line {n}: {cls}#{method}: {ticket} is {status.group(1)}, so the test goes back into the build")
        else:
            entries.append(f"{cls}#{method} {ticket}")
    return entries, problems


def main(argv):
    if len(argv) != 3 or argv[0] != "check":
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    try:
        entries, problems = check(argv[1], argv[2])
    except OSError as e:
        print(f"known-defects: {e}", file=sys.stderr)
        return 2
    for p in problems:
        print(f"known-defects: {p}", file=sys.stderr)
    if problems:
        return 1
    for e in entries:
        print(e)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
