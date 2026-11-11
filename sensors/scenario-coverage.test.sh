#!/usr/bin/env bash
# Tests for scenario-coverage.py. Run: ./scenario-coverage.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
fails=0
c="$t/clone"; mkdir -p "$c/openspec/changes/pc-1/specs/pets" "$c/src/test/java/p" "$t/reports"
cat > "$c/openspec/changes/pc-1/specs/pets/spec.md" <<'S'
## ADDED Requirements

### Requirement: Numbers

#### Scenario: Dashes are not removed

- **WHEN** a dash
- **THEN** rejected
- **CHECKED AT** unit

#### Scenario: A number held by another owner's pet

- **THEN** in use
- **CHECKED AT** form

#### Scenario: Spaces are removed

- **CHECKED AT** unit

#### Scenario: The field is cleared

- **CHECKED AT** database

#### Scenario: Two errors on the edit form

- **CHECKED AT** form

#### Scenario: Two errors on the edit form, one on the microchip number

- **CHECKED AT** form

#### Scenario: Nothing tests this

- **CHECKED AT** unit

#### Scenario: A level was forgotten

- **THEN** nothing

#### Scenario: Where the label sits

- **CHECKED AT** manual: layout, no assertion can see it

#### Scenario: Colours look right

- **CHECKED AT** manual

#### Scenario: A failing one

- **CHECKED AT** unit

#### Scenario: A test that did not run

- **CHECKED AT** unit

## REMOVED Requirements

### Requirement: Old

#### Scenario: Removed scenarios are not counted

- **CHECKED AT** unit
S
cat > "$c/src/test/java/p/PetValidatorTests.java" <<'J'
package p;
class PetValidatorTests {
	@Test
	void dashesAreNotRemoved() {}
	@ParameterizedTest
	@ValueSource(strings = { "a" })
	void aFailingOne(String s) {}
	@Test
	void aTestThatDidNotRun() {}
	@Test
	void theFieldIsCleared() {}
}
J
cat > "$c/src/test/java/p/PetControllerTests.java" <<'J'
package p;
@WebMvcTest
class PetControllerTests {
	@Test
	void aNumberHeldByAnotherOwnersPet() {}
	@Test
	void spacesAreRemovedOnTheAddForm() {}
	@Nested
	class Errors {
		@Test
		void twoErrorsOnTheEditFormOneOnTheMicrochipNumber() {}
	}
}
J
cat > "$t/reports/TEST-p.PetValidatorTests.xml" <<'X'
<testsuite><testcase classname="p.PetValidatorTests" name="dashesAreNotRemoved"/><testcase classname="p.PetValidatorTests" name="aFailingOne(String)[1]"><failure/></testcase><testcase classname="p.PetValidatorTests" name="theFieldIsCleared"/></testsuite>
X
cat > "$t/reports/TEST-p.PetControllerTests.xml" <<'X'
<testsuite><testcase classname="p.PetControllerTests" name="aNumberHeldByAnotherOwnersPet"/><testcase classname="p.PetControllerTests" name="spacesAreRemovedOnTheAddForm"/><testcase classname="p.PetControllerTests$Errors" name="twoErrorsOnTheEditFormOneOnTheMicrochipNumber"/></testsuite>
X
printf '### Where the label sits\n\nSteps, observation, screenshot.\n' > "$t/manual.md"
python3 -B "$here/scenario-coverage.py" --manual "$t/manual.md" "$c" "$t/reports" > "$t/out"; code=$?
row() { grep -E "^\| $1 \|" "$t/out"; }
expect() { # expect <name> <pattern on the scenario's row, or on the whole output when row is ->> <row title or ->
  local text; if [ "$3" = - ]; then text="$(cat "$t/out")"; else text="$(row "$3")"; fi
  if printf '%s' "$text" | grep -qE -- "$2"; then echo "ok   $1"; else echo "FAIL $1: no match for $2 in: $text"; fails=$((fails + 1)); fi
}
expect "a test at the declared level that passed is present" '\| unit \| PRESENT \|' "Dashes are not removed"
expect "an apostrophe is dropped from the name" '\| form \| PRESENT \| `PetControllerTests.aNumberHeldByAnotherOwnersPet`' "A number held by another owner's pet"
expect "a test only above the level is ABOVE" '\| unit \| ABOVE \|' "Spaces are removed"
expect "a test only below the level is untested" 'UNTESTED: only tests below its level' "The field is cleared"
expect "the longest title wins" '\| form \| UNTESTED: no test is named for it \| none \|' "Two errors on the edit form"
expect "a nested class's test counts" 'PRESENT \| `PetControllerTests\$Errors.twoErrorsOnTheEditFormOneOnTheMicrochipNumber`' "Two errors on the edit form, one on the microchip number"
expect "no test named for it" 'UNTESTED: no test is named for it' "Nothing tests this"
expect "no CHECKED AT line" '\| - \| NO LEVEL: no CHECKED AT line' "A level was forgotten"
expect "manual with a reason and a record is present" '\| manual \| PRESENT: manual record' "Where the label sits"
expect "manual without a reason is untested" 'UNTESTED: manual, with no recorded reason' "Colours look right"
expect "a failed parameterised test" '\| unit \| FAILED: its test at this level failed' "A failing one"
expect "a test with no result did not run" 'UNTESTED: its test at this level did not run \(not run\)' "A test that did not run"
expect "REMOVED requirements are not counted" '^12 scenarios:' -
expect "the shape counts declared levels" 'Shape, by declared level: unit 5, form 3, database 1, mysql-postgres 0, concurrency 0, manual 2\.' -
expect "the findings block for triage" '^scenario pets: Nothing tests this: UNTESTED at unit: no test is named for it$' -
expect "ABOVE is informational, not a finding" 'Tested above their level \(informational\): Spaces are removed\.' -
if grep -q '^scenario pets: Spaces are removed' "$t/out"; then echo "FAIL ABOVE listed as a finding"; fails=$((fails + 1)); else echo "ok   ABOVE is not in the findings block"; fi
if [ "$code" = 1 ]; then echo "ok   exit 1 with findings"; else echo "FAIL exit $code, wanted 1"; fails=$((fails + 1)); fi
python3 -B "$here/scenario-coverage.py" "$t/nope" > /dev/null 2>&1; [ $? = 2 ] && echo "ok   a missing clone is a usage error" || { echo "FAIL usage"; fails=$((fails + 1)); }
# Across reports: a pass on the host beats a skip in the container; a failure anywhere wins.
mkdir -p "$t/host"
printf '<testsuite><testcase classname="p.PetValidatorTests" name="aTestThatDidNotRun"><skipped/></testcase></testsuite>\n' > "$t/reports/TEST-skip.xml"
printf '<testsuite><testcase classname="p.PetValidatorTests" name="aTestThatDidNotRun"/><testcase classname="p.PetValidatorTests" name="dashesAreNotRemoved"><failure/></testcase></testsuite>\n' > "$t/host/TEST-p.PetValidatorTests.xml"
python3 -B "$here/scenario-coverage.py" --manual "$t/manual.md" "$c" "$t/reports" "$t/host" > "$t/out"
expect "a skip in one place and a pass in another is a pass" '\| unit \| PRESENT \|' "A test that did not run"
expect "a failure in any report is a failure" '\| unit \| FAILED' "Dashes are not removed"
# --into appends the section and adds a row to the summary table.
printf '# Step 5\n\n| Sensor | Result |\n|---|---|\n| Risk floor | **material** |\n| Mutation testing | 1 mutant |\n\n## Risk floor\n\nx\n' > "$t/sensors.md"
python3 -B "$here/scenario-coverage.py" --manual "$t/manual.md" --into "$t/sensors.md" "$c" "$t/reports" > /dev/null
if sed -n 7p "$t/sensors.md" | grep -q '^| Scenario coverage (by test name and level) | 4 of 12 present'; then echo "ok   --into adds a row after the table"; else echo "FAIL --into row"; sed -n 1,9p "$t/sensors.md"; fails=$((fails + 1)); fi
if tail -n +9 "$t/sensors.md" | grep -q '^## Scenario coverage'; then echo "ok   --into appends the section"; else echo "FAIL --into section"; fails=$((fails + 1)); fi

# An archived change is history: its scenarios are not counted.
mkdir -p "$c/openspec/changes/archive/2026-01-01-old/specs/pets"
printf '## ADDED Requirements\n\n### Requirement: Old\n\n#### Scenario: An archived scenario\n\n- **THEN** x\n' > "$c/openspec/changes/archive/2026-01-01-old/specs/pets/spec.md"
python3 -B "$here/scenario-coverage.py" --manual "$t/manual.md" "$c" "$t/reports" > "$t/out"
if grep -q 'An archived scenario' "$t/out"; then echo "FAIL an archived change is counted"; fails=$((fails + 1)); else echo "ok   an archived change is not counted"; fi

# --main reads the main specs (openspec/specs/**/spec.md): every requirement counts, with no
# ADDED or MODIFIED section, and the changes are ignored.
mkdir -p "$c/openspec/specs/pets"
cat > "$c/openspec/specs/pets/spec.md" <<'S'
# pets Specification

## Requirements

### Requirement: Numbers

#### Scenario: Dashes are not removed

- **THEN** rejected
- **CHECKED AT** unit

#### Scenario: Nobody wrote a test for this

- **THEN** something
- **CHECKED AT** form
S
python3 -B "$here/scenario-coverage.py" --main "$c" "$t/reports" > "$t/out"; code=$?
expect "--main counts the main spec's scenarios only" '^2 scenarios: 1 present' -
expect "--main reports a scenario with no test" '^scenario pets: Nobody wrote a test for this: UNTESTED at form: no test is named for it$' -
if [ "$code" = 1 ]; then echo "ok   --main exits 1 on a finding"; else echo "FAIL --main exit $code"; fails=$((fails + 1)); fi
expect "--main names the main specs in its heading" '^## Scenario coverage of the main specs' -

if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
