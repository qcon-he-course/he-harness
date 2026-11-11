#!/usr/bin/env bash
# Tests for risk-floor.py. Run: ./risk-floor.test.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
floor="$here/risk-floor.py"
fails=0
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT

repo() {
  rm -rf "$t/r"; mkdir -p "$t/r"; cd "$t/r"
  git init -q; git config user.email t@t; git config user.name t
  mkdir -p src/main/java/p src/test/java/p src/main/resources/db/h2 src/test/resources/archunit_store .github/workflows
  echo "class Pet { String name; }" > src/main/java/p/Pet.java
  echo "class PetTests {}" > src/test/java/p/PetTests.java
  echo "class ArchitectureTests {}" > src/test/java/p/ArchitectureTests.java
  echo "frozen" > src/test/resources/archunit_store/stored.rules
  echo "CREATE TABLE pets (id INTEGER);" > src/main/resources/db/h2/schema.sql
  echo "# PetClinic" > README.md
  echo "on: push" > .github/workflows/ci.yml
  cat > pom.xml <<'P'
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <dependencies>
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-web</artifactId></dependency>
  </dependencies>
  <build><plugins>
    <plugin><groupId>org.springframework.boot</groupId><artifactId>spring-boot-maven-plugin</artifactId></plugin>
  </plugins></build>
</project>
P
  git add -A; git commit -qm base
}

expect() { # expect <name> <tier> <grep pattern or -> [args...]; runs in $t/r
  local name="$1" want="$2" pat="$3" out; shift 3
  out="$("$floor" "$@" 2>&1)" || { echo "FAIL $name: exit $?"; echo "$out"; fails=$((fails + 1)); return; }
  if ! grep -q "^risk floor: $want$" <<< "$out"; then echo "FAIL $name: wanted $want"; echo "$out"; fails=$((fails + 1)); return; fi
  if [ "$pat" != "-" ] && ! grep -qE "$pat" <<< "$out"; then echo "FAIL $name: no match for $pat"; echo "$out"; fails=$((fails + 1)); return; fi
  echo "ok   $name"
}

repo; expect "no change" none "no changes"
repo; echo "more" >> README.md; expect "docs only is mechanical" mechanical "mechanical +docs +README.md"
repo; echo "class Pet { String name; int age; }" > src/main/java/p/Pet.java; expect "production code is bounded" bounded "bounded +production-code"
repo; echo "class Owner {}" > src/main/java/p/Owner.java; expect "an untracked file counts" bounded "src/main/java/p/Owner.java"
repo; echo "x" > k9.cfg; expect "an unknown path is bounded" bounded "bounded +other +k9.cfg"
repo; echo "ALTER TABLE pets ADD x INT;" >> src/main/resources/db/h2/schema.sql; expect "schema is material" material "material +schema"
repo; printf 'class Pet {\n  @Column(name = "x")\n  String x;\n}\n' > src/main/java/p/Pet.java; expect "an added @Column is persistence" material 'persistence +src/main/java/p/Pet.java:2'
repo; printf '# Design\nAdd an @Column to Pet.\n' > NOTES.md; expect "@Column in a markdown file is not persistence" mechanical -
repo; printf 'class Pet {\n  synchronized void save() {}\n}\n' > src/main/java/p/Pet.java; expect "synchronized is concurrency" material "concurrency"
repo; python3 -c 'import sys; p="pom.xml"; s=open(p).read(); open(p,"w").write(s.replace("</dependencies>", "  <dependency><groupId>com.acme</groupId><artifactId>left-pad</artifactId><version>1.0</version></dependency>\n  </dependencies>"))'
expect "a new dependency is material" material "new dependency com.acme:left-pad 1.0"
repo; echo "class ArchitectureTests { int x; }" > src/test/java/p/ArchitectureTests.java; expect "the architecture test is critical" critical "critical +protected-check +src/test/java/p/ArchitectureTests.java"
repo; rm src/test/resources/archunit_store/stored.rules; expect "deleting the freeze store is critical" critical "stored.rules \(deleted\)"
repo; echo "permissions: write-all" >> .github/workflows/ci.yml; expect "CI is critical" critical "critical +ci"
repo; echo "more" >> README.md; echo "ALTER TABLE pets ADD x INT;" >> src/main/resources/db/h2/schema.sql; expect "the floor is the highest tier" material "touches: schema, docs"
repo; echo "class PetTests { int x; }" > src/test/java/p/PetTests.java; git commit -qam two
expect "a commit range" bounded "bounded +tests" HEAD~1 HEAD
repo; echo "ALTER TABLE pets ADD x INT;" >> src/main/resources/db/h2/schema.sql
out="$("$floor" --tier)"; if [ "$out" = material ]; then echo "ok   --tier prints the floor alone"; else echo "FAIL --tier: $out"; fails=$((fails + 1)); fi
repo; if "$floor" nosuchcommit > /dev/null 2>&1; then echo "FAIL unknown base"; fails=$((fails + 1)); else [ $? = 2 ] && echo "ok   unknown base is a usage error" || { echo "FAIL unknown base exit"; fails=$((fails + 1)); }; fi

if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
