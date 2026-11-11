#!/usr/bin/env python3
"""review-check: accept a headless reviewer's output, or fail closed.

  review-check.py <result.json> <review.md> [--reviewer NAME]

<result.json> is what `claude -p --output-format json --json-schema ...` printed
(the review is in its "structured_output"), or the file `codex exec --output-schema
... -o` wrote (the review is the whole object). The review is checked against
review.schema.json by hand, with no library: required keys, no others, the enums,
the finding ids, at least one scenario. A review that passes is written to
<review.md> in the format the triage policy reads: a scenario table, then each
finding on a bold line "**C1: BLOCK.** title".

Exit 0: review written. Exit 1: no review, with the reason on stderr and nothing
written. A run that ended in an error, hit its turn or budget limit, returned no
structured output or returned one that breaks the schema all exit 1. The caller
treats exit 1 as a failed review, never as a review with no findings.
"""
import json
import os
import re
import sys

VERDICTS = ["MET", "PARTLY", "UNTESTED", "NOT MET", "UNKNOWN"]
DISPOSITIONS = ["BLOCK", "AUTO-FIX+REVERIFY", "DISCUSS", "INFORMATIONAL"]
CONFIDENCE = ["high", "medium", "low"]
FINDING_KEYS = ["id", "disposition", "title", "where", "claim", "evidence", "falsification", "confidence"]
TOP_KEYS = ["change", "scenarios", "findings", "for_the_person", "overall"]


def problems(r):
    """Every way the review breaks the schema; an empty list means it is valid."""
    if not isinstance(r, dict):
        return ["the review is not an object"]
    out = [f"missing key: {k}" for k in TOP_KEYS if k not in r]
    out += [f"unknown key: {k}" for k in r if k not in TOP_KEYS]
    if out:
        return out
    if not isinstance(r["change"], str) or not r["change"].strip():
        out.append("change is empty")
    if not isinstance(r["overall"], str) or not r["overall"].strip():
        out.append("overall is empty")
    if not isinstance(r["scenarios"], list) or not r["scenarios"]:
        out.append("no scenario verdicts: a review gives one for every scenario")
    else:
        for i, s in enumerate(r["scenarios"]):
            if not isinstance(s, dict) or sorted(s) != ["evidence", "title", "verdict"]:
                out.append(f"scenario {i + 1}: wrong keys")
            elif s["verdict"] not in VERDICTS:
                out.append(f"scenario {i + 1}: unknown verdict {s['verdict']!r}")
            elif not str(s["title"]).strip() or not str(s["evidence"]).strip():
                out.append(f"scenario {i + 1}: empty title or evidence")
    if not isinstance(r["findings"], list):
        out.append("findings is not a list")
    else:
        seen = set()
        for i, f in enumerate(r["findings"]):
            if not isinstance(f, dict) or sorted(f) != sorted(FINDING_KEYS):
                out.append(f"finding {i + 1}: wrong keys")
                continue
            if not re.fullmatch(r"C[0-9]+", str(f["id"])):
                out.append(f"finding {i + 1}: id {f['id']!r} is not C<number>")
            if f["id"] in seen:
                out.append(f"finding {i + 1}: id {f['id']} used twice")
            seen.add(f["id"])
            if f["disposition"] not in DISPOSITIONS:
                out.append(f"finding {f['id']}: unknown disposition {f['disposition']!r}")
            if f["confidence"] not in CONFIDENCE:
                out.append(f"finding {f['id']}: unknown confidence {f['confidence']!r}")
            for k in ("title", "where", "claim", "evidence", "falsification"):
                if not str(f[k]).strip():
                    out.append(f"finding {f['id']}: empty {k}")
    if not isinstance(r["for_the_person"], list) or any(not isinstance(q, str) for q in r["for_the_person"]):
        out.append("for_the_person is not a list of questions")
    return out


def extract(result):
    """(review, reason it cannot be used). Claude Code wraps the review; Codex writes it bare."""
    if not isinstance(result, dict):
        return None, "the result is not a JSON object"
    if "type" in result and "subtype" in result:  # Claude Code's result message
        if result.get("is_error") or result.get("subtype") != "success":
            return None, f"the run did not succeed: subtype {result.get('subtype')!r}, is_error {result.get('is_error')!r}"
        if result.get("structured_output") is None:
            return None, "the run returned no structured_output"
        return result["structured_output"], None
    return result, None


def cell(text):
    return str(text).replace("|", "\\|").replace("\n", " ").strip()


def render(r, reviewer):
    L = [f"# Code review of {r['change']}" + (f" ({reviewer})" if reviewer else ""), "", "## Scenarios", "",
         "| Scenario | Verdict | Evidence |", "|---|---|---|"]
    L += [f"| {cell(s['title'])} | {s['verdict']} | {cell(s['evidence'])} |" for s in r["scenarios"]]
    L += ["", "## Findings", ""]
    order = {d: i for i, d in enumerate(DISPOSITIONS)}
    for f in sorted(r["findings"], key=lambda f: order[f["disposition"]]):
        L += [f"**{f['id']}: {f['disposition']}.** {f['title'].strip()}",
              f"- **Where:** {f['where'].strip()}", f"- **Claim:** {f['claim'].strip()}",
              f"- **Evidence:** {f['evidence'].strip()}", f"- **Falsification:** {f['falsification'].strip()}",
              f"- **Confidence:** {f['confidence']}", ""]
    if not r["findings"]:
        L += ["No findings.", ""]
    L += ["## For the person", ""]
    L += [f"- {q.strip()}" for q in r["for_the_person"]] or ["Nothing needs a person."]
    L += ["", "## Overall", "", r["overall"].strip(), ""]
    return "\n".join(L)


def run(argv):
    reviewer = None
    if "--reviewer" in argv:
        i = argv.index("--reviewer")
        reviewer, argv = argv[i + 1], argv[:i] + argv[i + 2:]
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    src, dest = argv
    if os.path.exists(dest):
        os.remove(dest)  # a failed check never leaves an earlier review behind
    try:
        result = json.load(open(src, encoding="utf-8"))
    except (OSError, ValueError) as e:
        print(f"review-check: no review: {src} is missing, empty or not JSON ({e.__class__.__name__})", file=sys.stderr)
        return 1
    review, reason = extract(result)
    if reason:
        print(f"review-check: no review: {reason}", file=sys.stderr)
        return 1
    bad = problems(review)
    if bad:
        print("review-check: no review: the output breaks the schema:\n  " + "\n  ".join(bad), file=sys.stderr)
        return 1
    with open(dest, "w", encoding="utf-8") as fh:
        fh.write(render(review, reviewer))
    blocks = sum(1 for f in review["findings"] if f["disposition"] == "BLOCK")
    print(f"review-check: review written: {len(review['scenarios'])} scenarios, {len(review['findings'])} findings, {blocks} BLOCK")
    return 0


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    sys.exit(run(sys.argv[1:]))
