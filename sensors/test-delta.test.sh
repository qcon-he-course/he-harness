#!/usr/bin/env bash
# Tests for test-delta.py. Run: ./test-delta.test.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
delta="$here/test-delta.py"
fails=0
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT

repo() {
  rm -rf "$t/r"; mkdir -p "$t/r"; cd "$t/r"
  git init -q; git config user.email t@t; git config user.name t
  mkdir -p src/main/java/p src/test/java/p src/test/resources/archunit_store
  echo "class Pet {}" > src/main/java/p/Pet.java
  cat > src/test/java/p/PetTests.java <<'J'
class PetTests {

	@Test
	void savesAName() {
		assertThat(pet.getName()).isEqualTo("Leo");
		assertEquals(1, pets.size());
	}

	@Test
	void rejectsAnEmptyName() {
		mockMvc.perform(post("/pets/new"))
			.andExpect(status().isOk())
			.andExpect(model().attributeHasFieldErrors("pet", "name"));
	}

}
J
  echo "class ArchitectureTests {}" > src/test/java/p/ArchitectureTests.java
  echo "frozen" > src/test/resources/archunit_store/stored.rules
  printf '<project>\n  <build>\n  </build>\n</project>\n' > pom.xml
  git add -A; git commit -qm base
}

expect() { # expect <name> <exit> <grep pattern or -> [args...]; runs in $t/r
  local name="$1" want="$2" pat="$3" out code=0; shift 3
  out="$("$delta" "$@" 2>&1)" || code=$?
  if [ "$code" != "$want" ]; then echo "FAIL $name: exit $code, wanted $want"; echo "$out"; fails=$((fails + 1)); return; fi
  if [ "$pat" != "-" ] && ! grep -qE "$pat" <<< "$out"; then echo "FAIL $name: no match for $pat"; echo "$out"; fails=$((fails + 1)); return; fi
  echo "ok   $name"
}
cat > "$t/edit.py" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
assert old in s, old
open(p, "w").write(s.replace(old, new, 1))
PY
ed() { python3 "$t/edit.py" "$@"; }  # ed <file> <old> <new>: replace one occurrence

repo; expect "no change" 0 "findings 0"
repo; echo "class Pet { int age; }" > src/main/java/p/Pet.java; expect "production code only" 0 "findings 0"
repo; ed src/test/java/p/PetTests.java "	}

}" "	}

	@Test
	void savesAnAge() {
		assertEquals(3, pet.getAge());
	}

}"
expect "a new test with an assertion" 0 "tests in changed files 2 -> 3; assertion lines added 1, removed 0"
repo; ed src/test/java/p/PetTests.java '		assertEquals(1, pets.size());
' ''
expect "a removed assertion" 1 'PetTests.java:6: assertion removed: assertEquals\(1, pets.size\(\)\);'
repo; ed src/test/java/p/PetTests.java '		assertEquals(1, pets.size());
' '' && ed src/test/java/p/PetTests.java '			.andExpect(status().isOk())' '			.andExpect(status().isOk())
		assertEquals(1, pets.size());'
expect "a moved assertion is not reported" 0 "moved 1"
repo; ed src/test/java/p/PetTests.java 'assertThat(pet.getName()).isEqualTo("Leo");' 'assertNotNull(pet.getName());'
expect "a weakened assertion shows as removed" 1 'assertion removed: assertThat\(pet.getName\(\)\).isEqualTo\("Leo"\);'
repo; ed src/test/java/p/PetTests.java '			.andExpect(model().attributeHasFieldErrors("pet", "name"));' '			;'
expect "a removed chained andExpect" 1 'assertion removed: .andExpect\(model\(\).attributeHasFieldErrors'
repo; ed src/test/java/p/PetTests.java '	@Test
	void rejectsAnEmptyName() {' '	@Disabled
	@Test
	void rejectsAnEmptyName() {'
expect "@Disabled added" 1 "skip added: @Disabled"
repo; ed src/test/java/p/PetTests.java '	@Test
	void savesAName() {' '	// @Test
	void savesAName() {'
expect "a commented-out @Test" 1 "skip added: // @Test"
repo; ed src/test/java/p/PetTests.java '	void savesAName() {
' '	void savesAName() {
		assumeTrue(dockerAvailable());
'
expect "an assumption added" 1 "skip added: assumeTrue"
repo; python3 - src/test/java/p/PetTests.java <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
start = s.index("	@Test\n	void rejectsAnEmptyName"); end = s.index("	}\n", start) + 3
open(p, "w").write(s[:start] + s[end:])
PY
expect "a deleted test method" 1 "test deleted: rejectsAnEmptyName"
repo; ed src/test/java/p/PetTests.java '	void savesAName() {' '	void aPetIsSavedWithItsName() {'
expect "a renamed test, body unchanged" 1 "PetTests.java:4: test renamed: savesAName -> aPetIsSavedWithItsName, body unchanged"
repo; ed src/test/java/p/PetTests.java '	void savesAName() {' '	void aPetIsSavedWithItsName() {'
expect "a rename is not a deletion" 1 "summary: tests in changed files 2 -> 2; renamed 1"
repo; python3 - src/test/java/p/PetTests.java <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("	void savesAName() {", "	void aPetIsSavedWithItsName() {").replace('		assertEquals(1, pets.size());\n', '')
open(p, "w").write(s)
PY
expect "a rename that changes the body is a deletion" 1 "test deleted: savesAName"
repo; rm src/test/java/p/PetTests.java; expect "a deleted test file" 1 "PetTests.java:0: test deleted: the whole file, 2 tests"
repo; ed src/test/java/p/PetTests.java '		assertEquals(1, pets.size());' '		try { save(); } catch (Exception e) { }'
expect "a broad catch added" 1 "broad catch added"
repo; echo "class ArchitectureTests { int x; }" > src/test/java/p/ArchitectureTests.java; expect "the architecture test changed" 1 "ArchitectureTests.java:1: protected check: modified"
repo; echo "frozen again" >> src/test/resources/archunit_store/stored.rules; expect "the freeze store changed" 1 "stored.rules:2: protected check: modified, 1 lines added, 0 removed"
repo; ed pom.xml '  <build>' '  <build>
    <skipTests>true</skipTests>'
expect "skipTests in the pom" 1 "pom.xml:3: test configuration: added: <skipTests>true</skipTests>"
repo; ed pom.xml '  <build>' '  <build>
    <mutationThreshold>80</mutationThreshold>'
git commit -qam threshold; ed pom.xml '<mutationThreshold>80</mutationThreshold>' '<mutationThreshold>10</mutationThreshold>'
expect "a mutation threshold lowered" 1 "removed: <mutationThreshold>80</mutationThreshold>"
repo; ed src/test/java/p/PetTests.java '		assertEquals(1, pets.size());
' ''; git commit -qam drop
expect "a commit range" 1 "assertion removed" HEAD~1 HEAD
repo; mkdir -p src/test/java/q; printf 'class OwnerTests {\n\t@Test\n\tvoid x() {\n\t\tassertTrue(ok);\n\t}\n}\n' > src/test/java/q/OwnerTests.java
expect "an untracked test file counts" 0 "tests in changed files 0 -> 1; assertion lines added 1"
repo; if "$delta" nosuchcommit > /dev/null 2>&1; then echo "FAIL unknown base"; fails=$((fails + 1)); else [ $? = 2 ] && echo "ok   unknown base is a usage error" || { echo "FAIL unknown base exit"; fails=$((fails + 1)); }; fi

if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
