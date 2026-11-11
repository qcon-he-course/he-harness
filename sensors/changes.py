"""What a change contains, read from git: the shared part of the Week 3 sensors.

A change is either the working tree against a base commit (untracked files count as
added), or one commit range, base..head. Each changed file comes with its status,
its added and removed lines (with line numbers), and its text before and after.
"""

import os
import re
import subprocess
import sys


class Usage(Exception):
    pass


def git(root, *args, check=True):
    p = subprocess.run(["git", "-C", root, *args], capture_output=True, text=True)
    if check and p.returncode != 0:
        raise Usage(p.stderr.strip() or "git " + " ".join(args) + " failed")
    return p.stdout


def repo_root():
    p = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    if p.returncode != 0:
        raise Usage("not in a git repository")
    return p.stdout.strip()


class FileChange:
    def __init__(self, path, status, old_path=None):
        self.path = path            # the path after the change (before, for a deletion)
        self.status = status        # A, M, D or R
        self.old_path = old_path or path
        self.added = []             # [(line number after, text)]
        self.removed = []           # [(line number before, text)]
        self.before = ""            # whole text before ("" if added)
        self.after = ""             # whole text after ("" if deleted)


def _show(root, rev, path):
    p = subprocess.run(["git", "-C", root, "show", f"{rev}:{path}"], capture_output=True)
    return p.stdout.decode("utf-8", "replace") if p.returncode == 0 else ""


def _read(root, path):
    try:
        with open(os.path.join(root, path), encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def _parse_hunks(diff_text, files):
    cur = None
    old_ln = new_ln = 0
    for line in diff_text.splitlines():
        if line.startswith("diff --git "):
            cur = None
            continue
        if line.startswith("+++ "):
            name = line[4:]
            if name != "/dev/null":
                cur = files.get(name[2:] if name.startswith("b/") else name)
            continue
        if line.startswith("--- "):
            name = line[4:]
            if name != "/dev/null" and cur is None:
                cur = files.get(name[2:] if name.startswith("a/") else name)
            continue
        m = re.match(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@", line)
        if m:
            old_ln, new_ln = int(m.group(1)), int(m.group(2))
            continue
        if cur is None:
            continue
        if line.startswith("+"):
            cur.added.append((new_ln, line[1:]))
            new_ln += 1
        elif line.startswith("-"):
            cur.removed.append((old_ln, line[1:]))
            old_ln += 1
        elif line.startswith(" "):
            old_ln += 1
            new_ln += 1


def read_change(base="HEAD", head=None):
    """The files a change touches. head=None means the working tree, untracked files included."""
    root = repo_root()
    for rev in [base] + ([head] if head else []):
        if subprocess.run(["git", "-C", root, "rev-parse", "--verify", "--quiet", rev + "^{commit}"],
                          capture_output=True).returncode != 0:
            raise Usage(f"unknown commit {rev}")
    span = [base, head] if head else [base]
    files = {}
    for row in git(root, "diff", "--name-status", "-M", "--no-color", *span, "--").splitlines():
        parts = row.split("\t")
        st = parts[0][0]
        if st == "R":
            fc = FileChange(parts[2], "R", parts[1])
        else:
            fc = FileChange(parts[1], st)
        files[fc.path] = fc
    if head is None:
        for path in git(root, "ls-files", "--others", "--exclude-standard").splitlines():
            if path and path not in files:
                files[path] = FileChange(path, "A")
    # Line-level changes. Renamed files are keyed by their new path; deletions by the old.
    _parse_hunks(git(root, "diff", "-M", "--no-color", "--unified=0", *span, "--"), files)
    for fc in files.values():
        if fc.status != "A" or fc.added:
            continue
        text = _show(root, head, fc.path) if head else _read(root, fc.path)
        fc.added = [(i, t) for i, t in enumerate(text.splitlines(), 1)]
    for fc in files.values():
        if fc.status != "A":
            fc.before = _show(root, base, fc.old_path)
        if fc.status != "D":
            fc.after = _show(root, head, fc.path) if head else _read(root, fc.path)
    return root, [files[k] for k in sorted(files)]


def glob_regex(glob):
    """A path glob as a regex: ** crosses directories, * and ? do not."""
    out, i = "", 0
    while i < len(glob):
        if glob.startswith("**/", i):
            out += "(?:.*/)?"
            i += 3
        elif glob.startswith("**", i):
            out += ".*"
            i += 2
        elif glob[i] == "*":
            out += "[^/]*"
            i += 1
        elif glob[i] == "?":
            out += "[^/]"
            i += 1
        else:
            out += re.escape(glob[i])
            i += 1
    return re.compile("^" + out + "$")


TIERS = ["none", "mechanical", "bounded", "material", "critical"]


class Rule:
    def __init__(self, tier, surface, kind, pattern, lineno):
        if tier not in TIERS[1:]:
            raise Usage(f"rules line {lineno}: unknown tier {tier}")
        if kind not in ("path", "added", "pom"):
            raise Usage(f"rules line {lineno}: unknown match {kind}")
        self.tier, self.surface, self.kind, self.pattern = tier, surface, kind, pattern
        self.regex = glob_regex(pattern) if kind == "path" else (re.compile(pattern) if kind == "added" else None)


def read_rules(path):
    """Rules file: one rule per line, '<tier> <surface> <path|added|pom> <pattern>'; # comments."""
    rules = []
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        raise Usage(f"no rules file at {path}")
    for n, line in enumerate(lines, 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 3)
        if len(parts) < 3 or (parts[2] != "pom" and len(parts) < 4):
            raise Usage(f"rules line {n}: expected '<tier> <surface> <match> <pattern>'")
        rules.append(Rule(parts[0], parts[1], parts[2], parts[3] if len(parts) > 3 else "", n))
    return rules


def main(run):
    try:
        sys.exit(run(sys.argv[1:]))
    except Usage as e:
        print(f"{os.path.basename(sys.argv[0])}: {e}", file=sys.stderr)
        sys.exit(2)
