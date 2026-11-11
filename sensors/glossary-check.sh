#!/usr/bin/env bash
# glossary-check: report words the glossary says to avoid, in the lines a change adds.
#
#   glossary-check.sh [base]        compare the working tree with base (default: HEAD)
#
# Reads GLOSSARY.md at the repository root. Each term is a line "**Term**:" and its
# avoided words a later line "_Avoid_: word, other word". Only added lines are
# checked, so words already in the codebase are not reported. GLOSSARY.md, decisions
# logs (decisions.md) and ADRs are skipped: they may name an avoided word on purpose.
#
# Matching ignores case. A word of several parts also matches with no separator or
# with "_" or "-", so "chip id" finds chipId, chip_id and chip-id. A single word
# matches only as a whole word or as one part of an identifier (Chip in petChip).
# A plural ending (s, es) is included: "patient" also finds patients.
#
# Exit 0: nothing found. Exit 1: findings, one per line:
#   <file>:<line>: "<found>" is avoided; the glossary term is "<term>"
# Exit 2: usage error, or no GLOSSARY.md.
set -euo pipefail

base="${1:-HEAD}"
root="$(git rev-parse --show-toplevel 2> /dev/null)" || { echo "glossary-check: not in a git repository" >&2; exit 2; }
glossary="$root/GLOSSARY.md"
[ -f "$glossary" ] || { echo "glossary-check: no GLOSSARY.md at $root" >&2; exit 2; }
git -C "$root" rev-parse --verify --quiet "$base^{commit}" > /dev/null || { echo "glossary-check: unknown base $base" >&2; exit 2; }

# term<TAB>avoided word, one pair per line
pairs="$(awk '
  /^\*\*[^*]+\*\*:/ { term = $0; sub(/^\*\*/, "", term); sub(/\*\*:.*$/, "", term); next }
  /^_Avoid_:/ && term != "" {
    line = $0; sub(/^_Avoid_:[[:space:]]*/, "", line)
    n = split(line, words, /,/)
    for (i = 1; i <= n; i++) { w = words[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", w); if (w != "") print term "\t" w }
  }' "$glossary")"
[ -n "$pairs" ] || exit 0

# Added lines of tracked changes and of new untracked files, as <file>\t<line>\t<text>.
added="$(
  {
    git -C "$root" diff --no-color --unified=0 "$base" -- . \
      ':(exclude)GLOSSARY.md' ':(exclude)**/decisions.md' ':(exclude)docs/adr/**'
    git -C "$root" ls-files --others --exclude-standard -- . \
      ':(exclude)GLOSSARY.md' ':(exclude)**/decisions.md' ':(exclude)docs/adr/**' |
      while IFS= read -r f; do git -C "$root" diff --no-color --unified=0 --no-index /dev/null "$f" || true; done
  } | awk '
    /^\+\+\+ / { file = $2; sub(/^b\//, "", file); next }
    /^@@ / { split($3, a, ","); ln = substr(a[1], 2) + 0; next }
    /^\+/ { print file "\t" ln "\t" substr($0, 2); ln++ }'
)"
[ -n "$added" ] || exit 0

found=0
while IFS=$'\t' read -r term word; do
  # Parts of the avoided word, joined by an optional space, "_" or "-".
  pattern="$(printf '%s' "$word" | sed -E 's/[][\.^$*+?(){}|/]/\\&/g; s/[[:space:]_-]+/[ _-]?/g')"
  while IFS=$'\t' read -r file ln text; do
    printf '%s\n' "$text" | grep -qiE "$pattern" || continue
    hit="$(printf '%s\n' "$text" | perl -ne '
      BEGIN { $p = shift @ARGV }
      while (/((?:$p)(?:e?s)?)/gi) {
        my ($m, $s, $e) = ($1, $-[1], $+[1]);
        my $before = $s > 0 ? substr($_, $s - 1, 1) : "";
        my $after = substr($_, $e, 1);
        # Start: nothing alphanumeric before it, or an identifier part (petChip).
        my $start_ok = $before !~ /[[:alnum:]]/ || ($m =~ /^[A-Z]/ && $before =~ /[a-z0-9]/);
        # End: no lower-case letter after it (chipId and chip_id end cleanly; chips does not).
        my $end_ok = $after !~ /[a-z]/;
        if ($start_ok && $end_ok) { print "$m\n"; exit }
      }' "$pattern")" || true
    if [ -n "$hit" ]; then
      printf '%s:%s: "%s" is avoided; the glossary term is "%s"\n' "$file" "$ln" "$hit" "$term"
      found=1
    fi
  done <<< "$added"
done <<< "$pairs"

exit "$found"
