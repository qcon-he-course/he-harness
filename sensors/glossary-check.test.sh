#!/usr/bin/env bash
# Tests for glossary-check.sh. Run: ./glossary-check.test.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check="$here/glossary-check.sh"
fails=0
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT

repo() {
  rm -rf "$t/r"; mkdir -p "$t/r"; cd "$t/r"
  git init -q; git config user.email t@t; git config user.name t
  cat > GLOSSARY.md <<'G'
# Pet clinic

## Language

**Microchip number**:
The identifier read from a pet's implanted chip.
_Avoid_: chip id, transponder

**Pet**:
An animal registered to one owner.
_Avoid_: patient
G
  mkdir -p src; echo "class Pet { String chipId; }" > src/Old.java
  git add -A; git commit -qm base
}

expect() { # expect <name> <exit> <grep pattern or -> ; runs the check in $t/r
  local name="$1" want="$2" pat="$3" out code=0
  out="$("$check" 2>&1)" || code=$?
  if [ "$code" != "$want" ]; then echo "FAIL $name: exit $code, wanted $want"; echo "$out"; fails=$((fails + 1)); return; fi
  if [ "$pat" != "-" ] && ! grep -qE "$pat" <<< "$out"; then echo "FAIL $name: no match for $pat"; echo "$out"; fails=$((fails + 1)); return; fi
  echo "ok   $name"
}

repo; expect "no change, nothing found" 0 -
repo; echo "String note = \"\";" >> src/Old.java; expect "existing chipId is not reported" 0 -
repo; echo "  private String chipId;" > src/New.java; expect "camelCase in an untracked file" 1 'src/New.java:1: "chipId" is avoided; the glossary term is "Microchip number"'
repo; printf 'a\nchip_id VARCHAR(15)\n' > schema.sql; git add schema.sql; expect "snake_case in a staged new file, line 2" 1 'schema.sql:2: "chip_id"'
repo; echo "Scan the Transponder" > notes.md; expect "case is ignored" 1 '"Transponder" is avoided'
repo; echo "the patients list" > a.md; expect "a plural is reported" 1 '"patients" is avoided'
repo; echo "patientia" > a.md; expect "a longer word is not reported" 0 -
repo; echo "outpatient" > a.md; expect "inside a lower-case word is not reported" 0 -
repo; echo "Pet petPatient;" > a.java; expect "identifier part is reported" 1 '"Patient"'
repo; mkdir -p openspec/changes/pc-301; echo "We will not say chip id." > openspec/changes/pc-301/decisions.md; expect "decisions log is skipped" 0 -
repo; printf '\n**Owner**:\nA person.\n_Avoid_: client\n' >> GLOSSARY.md; expect "GLOSSARY.md itself is skipped" 0 -
repo; rm GLOSSARY.md; git commit -qam "no glossary"; expect "no glossary is a usage error" 2 'no GLOSSARY.md'

if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
