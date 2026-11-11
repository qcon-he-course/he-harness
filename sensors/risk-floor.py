#!/usr/bin/env python3
"""risk-floor: the lowest risk tier a change can have, from what it touches.

  risk-floor.py [--tier] [--rules FILE] [base [head]]

Compares the working tree with base (default HEAD), untracked files included, or
the commits base..head. The rules (default: risk-rules.txt next to this script)
map paths, added lines and new pom.xml dependencies to a tier and a surface. The
floor is the highest tier any rule gives; a file that no path rule matches is
bounded. Regex rules on added lines apply only to files above mechanical, so a
spec or a README that mentions @Entity does not count as persistence.

A model may raise the tier after reading the change. Nothing lowers it.

Output: the floor, then each trigger as <tier> <surface> <file>[:<line> <text>].
With --tier, the floor alone. Exit 0, or 2 on a usage error.
"""

import os
import sys
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True  # no __pycache__ next to the sensors
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import changes  # noqa: E402

TIERS = changes.TIERS


def pom_entries(text):
    """{'dependency': {g:a: version}, 'plugin': {g:a: version}} from a pom.xml text."""
    out = {"dependency": {}, "plugin": {}}
    if not text.strip():
        return out
    try:
        root = ET.fromstring(text)
    except ET.ParseError:
        return out
    ns = root.tag[: root.tag.index("}") + 1] if root.tag.startswith("{") else ""
    for kind in ("dependency", "plugin"):
        for el in root.iter(ns + kind):
            g = el.findtext(ns + "groupId", "org.apache.maven.plugins" if kind == "plugin" else "")
            a = el.findtext(ns + "artifactId", "")
            v = el.findtext(ns + "version", "")
            if a:
                out[kind][f"{g.strip()}:{a.strip()}"] = v.strip()
    return out


def triggers_for(fc, rules):
    found = []  # (tier, surface, where)
    path_rules = [r for r in rules if r.kind == "path" and r.regex.match(fc.path)]
    if fc.old_path != fc.path:
        path_rules += [r for r in rules if r.kind == "path" and r.regex.match(fc.old_path) and r not in path_rules]
    # A file counts once, under its highest path tier (a protected test is not also "tests").
    top = max((TIERS.index(r.tier) for r in path_rules), default=0)
    for r in path_rules:
        if TIERS.index(r.tier) == top:  # the first rule of the top tier names the surface
            found.append((r.tier, r.surface, fc.path + (" (deleted)" if fc.status == "D" else "")))
            break
    if not path_rules:
        found.append(("bounded", "other", fc.path + (" (deleted)" if fc.status == "D" else "")))
    path_tier = max((TIERS.index(t) for t, _, _ in found), default=0)
    if path_tier > TIERS.index("mechanical"):
        for r in rules:
            if r.kind != "added":
                continue
            for ln, text in fc.added:
                if r.regex.search(text):
                    found.append((r.tier, r.surface, f"{fc.path}:{ln}  {text.strip()[:100]}"))
                    break
    if os.path.basename(fc.path) == "pom.xml" and any(r.kind == "pom" for r in rules):
        rule = next(r for r in rules if r.kind == "pom")
        before, after = pom_entries(fc.before), pom_entries(fc.after)
        for kind in ("dependency", "plugin"):
            for key, version in sorted(after[kind].items()):
                if key not in before[kind]:
                    found.append((rule.tier, rule.surface, f"{fc.path}  new {kind} {key}" + (f" {version}" if version else "")))
                elif before[kind][key] != version:
                    found.append((rule.tier, rule.surface, f"{fc.path}  {kind} {key} {before[kind][key] or '(managed)'} -> {version or '(managed)'}"))
    return found


def run(argv):
    tier_only = False
    rules_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "risk-rules.txt")
    revs = []
    args = list(argv)
    while args:
        a = args.pop(0)
        if a == "--tier":
            tier_only = True
        elif a == "--rules":
            if not args:
                raise changes.Usage("--rules needs a file")
            rules_path = args.pop(0)
        elif a.startswith("-"):
            raise changes.Usage(f"unknown option {a}")
        else:
            revs.append(a)
    if len(revs) > 2:
        raise changes.Usage("usage: risk-floor.py [--tier] [--rules FILE] [base [head]]")
    rules = changes.read_rules(rules_path)
    _, files = changes.read_change(revs[0] if revs else "HEAD", revs[1] if len(revs) > 1 else None)

    found = []
    for fc in files:
        found += triggers_for(fc, rules)
    floor = max((t for t, _, _ in found), key=TIERS.index, default="none")
    if tier_only:
        print(floor)
        return 0
    print(f"risk floor: {floor}")
    if not found:
        print("no changes")
        return 0
    surfaces = []
    for t, s, _ in sorted(found, key=lambda x: -TIERS.index(x[0])):
        if s not in surfaces:
            surfaces.append(s)
    print("touches: " + ", ".join(surfaces))
    print()
    for t, s, where in sorted(found, key=lambda x: (-TIERS.index(x[0]), x[1], x[2])):
        print(f"{t:<11} {s:<16} {where}")
    return 0


if __name__ == "__main__":
    changes.main(run)
