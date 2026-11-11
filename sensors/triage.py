#!/usr/bin/env python3
"""triage: the policy half of step 7. Models discover risk; this decides what it permits.

  triage.py prepare <inputs>                 list every finding the clerk must account for
  triage.py check <inputs> <clerk reply>     audit the clerk's merge, apply the policy, write the packet
  triage.py auto <inputs>                    no clerk: each finding stands alone with its reviewer's
                                             disposition (step 8 scores one review at a time)

<inputs> holds the reviews (review-*.md), the step 5 results (sensors.md) and,
after prepare, sources.md. A finding in a review is a bold line that starts with
its id (R1, C2, ...) or a heading that does (### C1 — BLOCK — ...), read from the
review's Findings section when it has one. Its disposition is on that line, on a
Disposition line, or leads one of its first lines. A finding whose disposition cannot
be read fails the audit: the policy does not guess what a reviewer meant. A sensor
finding is a line of the test-delta audit, numbered S1, S2, ... in order.

The clerk (an agent with the triage-findings skill) merges findings that say the
same thing and ends its reply with one JSON block:

  {"findings": [{"id": "T1", "title": "...", "sources": ["review-step6-x:C2", "sensors:S4"],
                 "disposition": "BLOCK", "consequence": "question|fix|task|logged|overruled",
                 "question": "...", "fix": "...", "reason": "...", "evidence": "..."}],
   "unverified": ["..."], "known_defects": ["..."]}

check refuses a merge that drops a source or names one that does not exist, and
never lets a merged finding sit below the strictest disposition of its sources.
It computes eligibility (no open BLOCK and no failing test, in the suite or in the
harness's MySQL and Postgres run on the host; the known-defect lane is shown and
not counted), the sign-off the risk floor needs, the
doubt-theater count, and the rung (step 8b): a change merges without a person only
when its risk floor is bounded or lower, it is eligible, no question reaches the person,
nothing goes back to the author and nothing was left unrun or unverified. It writes
<inputs>/../packet.md, titled with W3_TICKET (default pc-301). Exit 0: written; 1: the
merge failed the audit (the packet says why); 2: usage.
"""

import json
import os
import re
import sys

ORDER = ["INFORMATIONAL", "AUTO-FIX+REVERIFY", "DISCUSS", "BLOCK"]
FINDING = re.compile(r"^(?:\*\*|#{2,4}\s+(?:\*\*)?)([RC]\d+)\b(.*)$")
DISPOSITION = re.compile(r"BLOCK|AUTO-FIX\+REVERIFY|AUTO-FIX|DISCUSS|INFORMATIONAL")
FINDINGS_HEAD = re.compile(r"^(#{1,3})\s+(?:\d+\.\s*)?Findings\b", re.I)
DISP_LABEL = re.compile(r"^[\s>*-]*(?:\*\*)?Disposition(?:\*\*)?\s*:?\s*(?:\*\*)?\s*(BLOCK|AUTO-FIX\+REVERIFY|AUTO-FIX|DISCUSS|INFORMATIONAL)\b")
DISP_LEAD = re.compile(r"^[\s>*-]*(?:\*\*)?\s*(BLOCK|AUTO-FIX\+REVERIFY|AUTO-FIX|DISCUSS|INFORMATIONAL)\b")
CLAIM = re.compile(r"^[\s>*-]*(?:\*\*)?Claim\b[^:]*:\s*(?:\*\*)?\s*(.+)$")
SIGN_OFF = {"critical": "a named owner of each critical surface", "material": "the component owner",
            "bounded": "repository policy", "mechanical": "none", "none": "none"}


def norm_disp(d):
    return "AUTO-FIX+REVERIFY" if d == "AUTO-FIX" else d


def _clean(t):
    t = re.sub(r"^[\s.:—–·|-]+", "", t.replace("**", ""))
    t = re.sub(r"^(BLOCK|AUTO-FIX\+REVERIFY|AUTO-FIX|DISCUSS|INFORMATIONAL)(\s*\([^)]*\))?", "", t)
    return t.strip(" .:—–·|-")


def finding_blocks(text):
    """The findings of a review, in order: [{"id", "disposition", "title", "text"}].
    The disposition is None when it cannot be read. score.py reads findings with this too."""
    lines = text.splitlines()
    start, end = 0, len(lines)
    for i, l in enumerate(lines):
        h = FINDINGS_HEAD.match(l.strip())
        if h:
            start = i + 1
            for j in range(i + 1, len(lines)):
                k = re.match(r"^(#{1,6})\s", lines[j].strip())
                if k and len(k.group(1)) <= len(h.group(1)):
                    end = j
                    break
            break
    raw, cur = [], None
    for l in lines[start:end]:
        m = FINDING.match(l.strip())
        if m:
            if cur:
                raw.append(cur)
            cur = [m.group(1), m.group(2), [l.strip()]]
        elif cur is not None:
            if re.match(r"^#{1,6}\s", l.strip()):
                raw.append(cur)
                cur = None
            else:
                cur[2].append(l)
    if cur:
        raw.append(cur)
    out = []
    for fid, rest, ls in raw:
        body = ls[1:]
        d = DISPOSITION.search(rest)
        disp = d.group(0) if d else None
        if not disp:
            disp = next((m.group(1) for m in map(DISP_LABEL.match, body) if m), None)
        if not disp:
            disp = next((m.group(1) for m in map(DISP_LEAD.match, [b for b in body if b.strip()][:2]) if m), None)
        title = _clean(rest)
        if not title or re.match(r"(?i)where\b", title):
            claim = next((m.group(1) for m in map(CLAIM.match, body) if m), None)
            if claim:
                title = _clean(re.split(r"(?<=[.!?])\s", claim.replace("**", ""), maxsplit=1)[0])
        if not title:
            first = next((b.strip() for b in body if b.strip() and not DISP_LABEL.match(b)), "")
            title = _clean(re.sub(r"^[\s>*-]*(?:\*\*)?[A-Z][\w ]{0,20}?(?:\*\*)?:(?:\*\*)?\s*", "", first))
        out.append({"id": fid, "disposition": norm_disp(disp) if disp else None, "title": title[:160], "text": "\n".join(ls)})
    return out


def review_findings(path):
    out = {}
    for f in finding_blocks(open(path, encoding="utf-8").read()):
        out.setdefault(f["id"], {"disposition": f["disposition"], "title": f["title"]})
    return out


def unreadable(path, found):
    """Audit problems for a review the policy cannot read: it fails closed."""
    name = os.path.basename(path)[:-3]
    probs = [f"`{name}:{fid}` has no disposition the policy can read; the review must give it one"
             for fid, v in found.items() if not v["disposition"]]
    if not found and DISPOSITION.search(open(path, encoding="utf-8").read()):
        probs.append(f"`{name}`: no finding could be read, though the review names a disposition")
    return probs


def sensors(path):
    text = open(path, encoding="utf-8").read()
    floor = re.search(r"\| Risk floor \| \*\*(\w+)\*\*", text)
    block = re.search(r"## Test-delta audit\s+```\n(.*?)```", text, re.S)
    lines = [l for l in (block.group(1).splitlines() if block else []) if l and not l.startswith("summary:")]
    # Scenario coverage (scenario-coverage.py): each UNTESTED, FAILED or no-level scenario is a sensor finding.
    cov = re.search(r"^## Scenario coverage\n(.*?)(?=^## |\Z)", text, re.S | re.M)
    if cov:
        cb = re.search(r"```\n(.*?)```", cov.group(1), re.S)
        lines += [l for l in (cb.group(1).splitlines() if cb else []) if l.startswith("scenario ")]
    cov_row = re.search(r"^\| Scenario coverage[^|]*\| ([^|]+) \|", text, re.M)
    suite = re.search(r"\| Full test suite[^|]*\| ([^|]+) \|", text)
    not_run = re.search(r"Not run \(no Docker\): (.*?)\. Not run is not passed", text)
    failed = re.search(r"^Failed: (.*)$", text, re.M)
    # The harness's Docker run on the host (step5-docker.sh): one table per test order.
    host = {}  # class -> [(run, passed, failed)] per order
    orders = 0
    docker = re.search(r"^## Docker tests \(host\)\n(.*)", text, re.S | re.M)
    if docker:
        orders = len(re.findall(r"^\*\*\w+\*\* \(", docker.group(1), re.M))
        for c, r, p, f, _ in re.findall(r"^\| (\w+) \| (\d+) \| (\d+) \| (\d+) \| (\d+) \|$", docker.group(1), re.M):
            host.setdefault(c, []).append((int(r), int(p), int(f)))
    host_passed = {c for c, rs in host.items() if len(rs) == orders and all(r > 0 and p == r and f == 0 for r, p, f in rs)}
    host_failed = sorted(c for c, rs in host.items() if any(f > 0 for _, _, f in rs))
    # A class the host ran is no longer "not run": it passed in every order, or it is reported as failing.
    items = [i for i in (not_run.group(1).split(", ") if not_run else []) if i.split(" ")[0] not in host_passed | set(host_failed)]
    # The known-defect lane (step5.sh): tests tied to an open ticket, shown and not counted.
    lane = []
    sec = re.search(r"^## Known-defect tests\n(.*?)(?=^## |\Z)", text, re.S | re.M)
    if sec:
        for t, k, n, f, p, m in re.findall(r"^\| `([^`]+)` \| (\S+) \| (\d+) \| (\d+) \| (\d+) \| (\d+) \|$", sec.group(1), re.M):
            lane.append({"test": t, "ticket": k, "runs": int(n), "failed": int(f), "passed": int(p), "missing": int(m)})
    b1 = re.search(r"^\| Build checks[^|]*\| ([^|]+) \|", text, re.M)
    return {"floor": floor.group(1) if floor else "none",
            "b1_failed": bool(b1 and "FAIL" in b1.group(1)),
            "coverage": cov_row.group(1).strip() if cov_row else "",
            "lane": lane,
            "host": (f"{len(host_passed)} class{'es' if len(host_passed) != 1 else ''} passed on the host in {orders} test orders" if host_passed else "")
                    + (("; " if host_passed else "") + "failed on the host: " + ", ".join(host_failed) if host_failed else ""),
            "host_failed": host_failed,
            "findings": {f"S{i}": {"disposition": None, "title": l} for i, l in enumerate(lines, 1)},
            "suite": suite.group(1).strip() if suite else "unknown",
            "not_run": ", ".join(items),
            "failed": failed.group(1) if failed else ""}


def load_sources(inputs):
    src, unread = {}, []
    for f in sorted(os.listdir(inputs)):
        if f.startswith("review-") and f.endswith(".md"):
            found = review_findings(os.path.join(inputs, f))
            unread += unreadable(os.path.join(inputs, f), found)
            for fid, v in found.items():
                src[f"{f[:-3]}:{fid}"] = v
    sens = sensors(os.path.join(inputs, "sensors.md"))
    sens["unread"] = unread
    for sid, v in sens["findings"].items():
        src[f"sensors:{sid}"] = v
    return src, sens


def prepare(inputs):
    src, sens = load_sources(inputs)
    L = ["# Every finding to account for", "",
         "Each id below must appear in the `sources` of exactly one merged finding. A disposition shown here is the reviewer's; a merged finding may not go below the strictest of its sources. Sensor findings have none: give each one, with a reason.", "",
         "| Source | Disposition | Title |", "|---|---|---|"]
    for k, v in src.items():
        L.append(f"| `{k}` | {v['disposition'] or '(sensor)'} | {v['title'].replace('|', '/')} |")
    L += ["", f"Risk floor: {sens['floor']}. Suite: {sens['suite']}." + (f" Not run: {sens['not_run']}." if sens["not_run"] else "")]
    if sens["unread"]:
        L += ["", "Unreadable, so the packet will fail its audit until the review is corrected:"] + [f"- {u}" for u in sens["unread"]]
    open(os.path.join(inputs, "sources.md"), "w", encoding="utf-8").write("\n".join(L) + "\n")
    print(f"triage: {len(src)} findings to account for, listed in {os.path.join(inputs, 'sources.md')}")
    return 0


def clerk_json(path):
    text = open(path, encoding="utf-8").read()
    blocks = re.findall(r"```json\s*\n(.*?)```", text, re.S)
    if not blocks:
        raise ValueError("no ```json block in the clerk's reply")
    return json.loads(blocks[-1])


def requirements(clone):
    """ADDED and MODIFIED requirement names from the change's spec deltas: what the change does, from the spec."""
    out = []
    root = os.path.join(clone, "openspec", "changes")
    for dirpath, _, files in os.walk(root):
        if "archive" in dirpath:
            continue
        for f in files:
            if f == "spec.md":
                section = None
                for line in open(os.path.join(dirpath, f), encoding="utf-8"):
                    h = re.match(r"^## (ADDED|MODIFIED|REMOVED) Requirements", line)
                    if h:
                        section = h.group(1)
                    r = re.match(r"^### Requirement: (.*)", line)
                    if r and section:
                        out.append((os.path.basename(dirpath), section, r.group(1).strip()))
    return out


def check(inputs, reply, clone=None):
    src, sens = load_sources(inputs)
    problems, notes = list(sens["unread"]), []
    try:
        data = clerk_json(reply)
        merged = data.get("findings", [])
    except (ValueError, OSError) as e:
        data, merged = {}, []
        problems.append(f"The clerk's reply could not be read: {e}")
    seen = {}
    for t in merged:
        for s in t.get("sources", []):
            if s not in src:
                problems.append(f"{t.get('id')}: names `{s}`, which no review or sensor reported")
            seen.setdefault(s, []).append(t.get("id"))
        strictest = max((src[s]["disposition"] for s in t.get("sources", []) if s in src and src[s]["disposition"]),
                        key=ORDER.index, default=None)
        d = norm_disp(t.get("disposition") or "")
        if d not in ORDER:
            problems.append(f"{t.get('id')}: no valid disposition")
            d = strictest or "DISCUSS"
        if strictest and ORDER.index(d) < ORDER.index(strictest):
            notes.append(f"{t.get('id')}: the clerk gave {d}; raised to {strictest}, the strictest of its sources")
            d = strictest
        t["disposition"] = d
        if t.get("consequence") in ("logged", "overruled") and not t.get("reason") and (
                d != "INFORMATIONAL" or any(s.startswith("sensors:") for s in t.get("sources", []))):
            problems.append(f"{t.get('id')}: {d} {t.get('consequence')} without a recorded reason")
        # A protected check changes only with its owner's approval (approvals.md): a change
        # to one always reaches the person, whatever the clerk decided.
        prot = [src[s]["title"] for s in t.get("sources", []) if s.startswith("sensors:") and s in src and "protected check:" in src[s]["title"]]
        if prot and t.get("consequence") != "question":
            notes.append(f"{t.get('id')}: the clerk gave {t.get('consequence') or 'no consequence'}; a change to a protected check is put to the person")
            t["consequence"] = "question"
            if ORDER.index(t["disposition"]) < ORDER.index("DISCUSS"):
                t["disposition"] = "DISCUSS"
            t["question"] = "Confirm the change to a protected check, which changes only with its owner's approval: " + "; ".join(prot) + (f". The clerk's reading: {t['reason']}" if t.get("reason") else "")
    for s in src:
        if s not in seen:
            problems.append(f"`{s}` ({src[s]['title'][:70]}) is in no merged finding")
        elif len(seen[s]) > 1:
            problems.append(f"`{s}` is in more than one merged finding: {', '.join(seen[s])}")

    floor = sens["floor"]
    blocks = [t for t in merged if t["disposition"] == "BLOCK" and t.get("status", "open") == "open"]
    # No merge on a red build (plan, 1 November): a failing test in the suite or on the host.
    red = [x for x in ([sens["failed"]] if sens["failed"] else []) + sens["host_failed"]]
    if "BUILD FAILED" in sens["suite"] and not red:
        red = ["the build"]
    if not re.match(r"\d+ run", sens["suite"]):
        red.append(f"the test suite has no result ({sens['suite']})")
    if sens["b1_failed"]:
        red.append("the build checks (`./mvnw validate`)")
    why = [f"{len(blocks)} open BLOCK"] if blocks else []
    why += ["failing: " + ", ".join(red)] if red else []
    questions = [t for t in merged if t.get("question") and t["disposition"] in ("BLOCK", "DISCUSS")]
    fixes = [t for t in merged if t.get("fix") and t["disposition"] in ("BLOCK", "AUTO-FIX+REVERIFY")]
    substantial = [t for t in merged if t["disposition"] != "INFORMATIONAL"]
    acted = [t for t in substantial if t.get("consequence") in ("question", "fix", "task")]
    overruled = [t for t in substantial if t.get("consequence") == "overruled"]
    carried = [t for t in merged if t.get("consequence") == "task"]
    logged = [t for t in merged if t.get("consequence") in ("logged", "overruled")]
    shown = set(id(t) for t in questions + fixes + carried + logged)
    lost = [t for t in merged if id(t) not in shown]
    if lost:
        problems.append("findings with no consequence the packet can show: " + ", ".join(str(t.get("id")) for t in lost))
    # A packet that fails its audit cannot be trusted to say what is safe: it is not eligible.
    if problems:
        why.append("the packet failed its audit")

    # The rung (step 8b): who has to look at this change before it merges.
    person = []
    if floor not in ("bounded", "mechanical", "none"):
        person.append(f"risk floor {floor}")
    if blocks or red or problems:
        person.append("not eligible")
    if questions:
        person.append(f"{len(questions)} question{'s' if len(questions) != 1 else ''} for the person")
    if fixes:
        person.append(f"{len(fixes)} fix{'es' if len(fixes) != 1 else ''} go{'' if len(fixes) != 1 else 'es'} back to the author first")
    if sens["not_run"]:
        person.append(f"not run: {sens['not_run']}")
    if data.get("unverified"):
        person.append("nobody could verify everything")
    rung = "| Merges without a person | " + ("**yes**: the floor is " + floor + ", the packet is clean" if not person else "**no**: " + "; ".join(person)) + " |"

    ticket = os.environ.get("W3_TICKET", "pc-301").upper()
    L = [f"# For the person: {ticket}, triage", ""]
    if problems:
        L += ["**The merge failed the audit. This packet is not ready; fix the merge and run triage again.**", ""]
        L += [f"- {p}" for p in problems] + [""]
    L += ["| | |", "|---|---|",
          f"| Eligible to merge | **{'no' if blocks or red or problems else 'yes, once the questions are answered' if questions else 'yes'}**" + (": " + "; ".join(why) if why else "") + " |",
          rung,
          f"| Risk floor | **{floor}**; sign-off: {SIGN_OFF.get(floor, floor)} |",
          f"| Test suite | {sens['suite']}" + (f"; failed: {sens['failed']}" if sens["failed"] else "") + (f"; {sens['host']}" if sens["host"] else "") + " |",
          f"| Not run | {sens['not_run'] or 'nothing'} |",
          *([f"| Scenario coverage | {sens['coverage']} |"] if sens["coverage"] else []),
          *([f"| Known-defect tests (shown, not counted) | " + "; ".join(f"{d['ticket']}: failed {d['failed']} of {d['runs']} runs" + (f", not found in {d['missing']}" if d["missing"] else "") for d in sens["lane"]) + " |"] if sens["lane"] else []),
          f"| Findings | {len(src)} reported, merged into {len(merged)}: " + ", ".join(f"{sum(1 for t in merged if t['disposition'] == d)} {d}" for d in reversed(ORDER)) + " |",
          f"| Doubt theater | {len(acted)} of {len(substantial)} substantial findings lead to a question, a fix or a task; {len(overruled)} overruled with a reason |", ""]
    if clone:
        reqs = requirements(clone)
        if reqs:
            L += ["## What the change does, from its spec", ""]
            L += [f"- {cap}: {sec.lower()} \"{name}\"" for cap, sec, name in reqs] + [""]
    if questions:
        L += ["## Questions for you", ""]
        for t in questions:
            L += [f"**{t['id']}. {t.get('title', '')}** ({t['disposition']}; {', '.join(t.get('sources', []))})", "",
                  t["question"], ""]
            if t.get("evidence"):
                L += [f"Evidence: {t['evidence']}", ""]
    if fixes:
        L += ["## Going back to the author, then re-checked", ""]
        L += [f"- **{t['id']}** ({t['disposition']}): {t['fix']}" for t in fixes] + [""]
    if blocks:
        L += ["## Blocking", ""] + [f"- **{t['id']}** {t.get('title', '')}" for t in blocks] + [""]
    if data.get("unverified"):
        L += ["## Nobody could verify", ""] + [f"- {u}" for u in data["unverified"]] + [""]
    if data.get("known_defects") or sens["lane"]:
        L += ["## Known defects", ""] + [f"- {k}" for k in data.get("known_defects") or []]
        for d in sens["lane"]:
            note = ("it failed in this run's lane" if d["failed"] else "it passed in every run of the lane, which may mean only that the timing hid it" if d["passed"] == d["runs"] else "it was not found in every run")
            L += [f"- `{d['test']}` ({d['ticket']}) runs in the known-defect lane, outside the build: failed {d['failed']} of {d['runs']} runs; {note}. It does not count toward eligibility while {d['ticket']} is open."]
        L += [""]
    if carried:
        L += ["## Carried elsewhere", ""] + [f"- {t['id']} ({t['disposition']}): {t.get('title', '')}" + (f". {t['reason']}" if t.get("reason") else "") for t in carried] + [""]
    if logged:
        L += ["## Logged", ""] + [f"- {t['id']} ({t['disposition']}, {t.get('consequence')}): {t.get('title', '')}" + (f". Reason: {t['reason']}" if t.get("reason") else "") for t in logged] + [""]
    if notes:
        L += ["## Policy notes", ""] + [f"- {n}" for n in notes] + [""]
    if problems and not L[2].startswith("**The merge failed"):
        L[2:2] = ["**The merge failed the audit. This packet is not ready; fix the merge and run triage again.**", ""] + [f"- {p}" for p in problems] + [""]
    L += ["## Audit", "", f"Every one of the {len(src)} reported findings is accounted for, and every merged finding appears above." if not problems else f"{len(problems)} problems, listed at the top.", ""]
    out = os.path.join(os.path.dirname(os.path.abspath(inputs)), "packet.md")
    open(out, "w", encoding="utf-8").write("\n".join(L))
    print(f"triage: packet written to {out}" + (f"; {len(problems)} audit problems" if problems else ""))
    return 1 if problems else 0


def auto(inputs, clone=None):
    """Step 8: a packet for one review with no clerk. Every source is its own merged finding,
    at its reviewer's disposition; a sensor finding is INFORMATIONAL. The policy is the same,
    so a protected-check change is still put to the person and a red build still blocks."""
    src, _ = load_sources(inputs)
    reason = "step 8 scoring: one finding per source, no clerk"
    findings = []
    for i, (k, v) in enumerate(src.items(), 1):
        # A review finding with no readable disposition goes to the person (and fails the audit);
        # a sensor finding has none by design and is INFORMATIONAL.
        d = v["disposition"] or ("INFORMATIONAL" if k.startswith("sensors:") else "DISCUSS")
        f = {"id": f"T{i}", "title": v["title"], "sources": [k], "disposition": d}
        if d in ("BLOCK", "DISCUSS"):
            f.update(consequence="question", question=v["title"] or f"See `{k}` in the review.")
        elif d == "AUTO-FIX+REVERIFY":
            f.update(consequence="fix", fix=v["title"] or f"See `{k}` in the review.")
        else:
            f.update(consequence="logged", reason=reason)
        findings.append(f)
    reply = os.path.join(inputs, "auto-reply.md")
    open(reply, "w", encoding="utf-8").write("```json\n" + json.dumps({"findings": findings}, indent=1) + "\n```\n")
    return check(inputs, reply, clone)


def main(argv):
    if len(argv) >= 2 and argv[0] == "prepare":
        return prepare(argv[1])
    if len(argv) >= 2 and argv[0] == "auto":
        prepare(argv[1])
        return auto(argv[1], argv[2] if len(argv) > 2 else None)
    if len(argv) >= 3 and argv[0] == "check":
        return check(argv[1], argv[2], argv[3] if len(argv) > 3 else None)
    print(__doc__.strip().splitlines()[2], file=sys.stderr)
    print("usage: triage.py prepare <inputs> | check <inputs> <clerk reply> [clone] | auto <inputs> [clone]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
