#!/usr/bin/env bash
# One headless review of a coded change, by Claude Code or Codex, checked and written
# as review.md, or failed closed.
#
#   review-headless.sh <clone> <change> <inputs dir> <out dir>
#
# <inputs dir> holds what the reviewer is given besides the clone: sensors.md and, when
# the clone has none, project-baseline.md. This script adds change.diff (the change
# against REVIEW_BASE, default HEAD, new files included) and files.txt (every file in
# the checkout). <out dir> gets prompt.txt, result.json, stderr.txt and, only when the
# output passes review-check.py, review.md.
#
# REVIEWER=claude (default) or codex. REVIEW_MODEL (Claude: claude-sonnet-5-5, the model
# the subagent form of this reviewer runs on; Codex: gpt-6.1-sol), REVIEW_MAX_TURNS (60),
# REVIEW_BUDGET_USD (2), REVIEW_TIME_CAP in seconds (900).
#
# Claude runs with --bare: no hooks, no MCP servers and no CLAUDE.md from the
# repository under review, and no sign-in from the machine. It needs ANTHROPIC_API_KEY.
# Codex needs CODEX_API_KEY and runs in its read-only sandbox. Not closed for Codex: the
# commands it runs inherit its environment, the key included; its sandbox is what stands
# between a command and the network. To check in the first CI run.
#
# The reviewer holds an API key and reads a change nobody has vetted, so it gets no
# shell: it runs no build and no test (the sensors ran them, in a job with no key), and
# no command at all. Every command a keyed agent runs can read the key from its
# environment (verified, Claude Code 2.1.281), and a build or a test runs the change's
# own code. The reviewer reads files; the harness hands it the diff.
#
# REVIEW_SHELL=1 gives Claude a read-only shell (git status, diff, log, show; ls, cat,
# grep) and sets CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1, which keeps credentials out of
# those commands and needs bubblewrap and socat. Where the sandbox cannot start (inside
# a Docker container, for one), every command fails and the review goes on with reads.
# Exit 0: review.md written. Exit 1: no review. The caller counts 1 as a failed check.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ $# = 4 ] || { sed -n '2,5p' "$0" >&2; exit 2; }
clone="$(cd "$1" && pwd)"; change="$2"; inputs="$(cd "$3" && pwd)"; mkdir -p "$4"; out="$(cd "$4" && pwd)"
reviewer="${REVIEWER:-claude}"
skill="$here/../skills/review-code/SKILL.md"
schema="$here/review.schema.json"
rm -f "$out/result.json" "$out/review.md"

baseline="docs/project-baseline.md"; [ -f "$clone/$baseline" ] || baseline="$inputs/project-baseline.md"
cat > "$out/prompt.txt" <<P
Review the code that implements the OpenSpec change $change before a person sees it. The change, with its decisions log, is in openspec/changes/$change/. The code change is the diff in $inputs/change.diff, against ${REVIEW_BASE:-HEAD}; every file of this checkout is listed in $inputs/files.txt. You have no shell here: read the diff, then read the files you need by path. The deterministic sensors have run the build, the tests and mutation testing; their results are in $inputs/sensors.md. The project's architecture and conventions are in $baseline. Return the review as the structured output: one verdict for every scenario, then every finding.
P

# The diff and the file list, made here, where no model and no key are involved.
{
  git -C "$clone" diff "${REVIEW_BASE:-HEAD}"
  git -C "$clone" ls-files --others --exclude-standard | while IFS= read -r f; do
    git -C "$clone" diff --no-index -- /dev/null "$f" || true
  done
} > "$inputs/change.diff"
{ git -C "$clone" ls-files; git -C "$clone" ls-files --others --exclude-standard; } | sort > "$inputs/files.txt"
[ -s "$inputs/change.diff" ] || { echo "review-headless: no change against ${REVIEW_BASE:-HEAD}: nothing to review" >&2; exit 1; }

cd "$clone" || exit 1
case "$reviewer" in
  claude)
    [ -n "${ANTHROPIC_API_KEY:-}" ] || { echo "review-headless: ANTHROPIC_API_KEY is not set; --bare reads no other sign-in" >&2; exit 1; }
    if [ "${REVIEW_SHELL:-0}" = 1 ]; then
      export CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1
      tools=(--allowedTools "Bash(git status:*)" "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)" "Bash(ls:*)" "Bash(cat:*)" "Bash(grep:*)"
             --disallowedTools "Edit" "Write" "MultiEdit" "NotebookEdit")
    else
      tools=(--disallowedTools "Bash" "Edit" "Write" "MultiEdit" "NotebookEdit")
    fi
    timeout "${REVIEW_TIME_CAP:-900}" claude -p "$(cat "$out/prompt.txt")" \
      --bare \
      --model "${REVIEW_MODEL:-claude-sonnet-5-5}" \
      --append-system-prompt-file "$skill" \
      --add-dir "$inputs" \
      --permission-mode dontAsk \
      "${tools[@]}" \
      --output-format json \
      --json-schema "$(cat "$schema")" \
      --max-turns "${REVIEW_MAX_TURNS:-60}" \
      --max-budget-usd "${REVIEW_BUDGET_USD:-2}" \
      < /dev/null > "$out/result.json" 2> "$out/stderr.txt"
    echo "review-headless: claude exit $?" >&2
    ;;
  codex)
    [ -n "${CODEX_API_KEY:-}" ] || { echo "review-headless: CODEX_API_KEY is not set" >&2; exit 1; }
    # The skill opens with "---": after "--" it is the prompt, not an option.
    timeout "${REVIEW_TIME_CAP:-900}" codex exec \
      --model "${REVIEW_MODEL:-gpt-6.1-sol}" \
      --sandbox read-only \
      --skip-git-repo-check \
      --output-schema "$schema" \
      -o "$out/result.json" \
      -- "$(cat "$skill"; echo; cat "$out/prompt.txt")" \
      < /dev/null > "$out/stdout.txt" 2> "$out/stderr.txt"
    echo "review-headless: codex exit $?" >&2
    ;;
  *) echo "review-headless: REVIEWER is claude or codex" >&2; exit 2 ;;
esac
# The agent's exit code decides nothing: only an output that passes the check is a review.
python3 -B "$here/review-check.py" "$out/result.json" "$out/review.md" --reviewer "$reviewer"
