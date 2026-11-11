#!/usr/bin/env bash
# Week 3, step 5, the part that needs Docker: the MySQL and Postgres tests, run on the
# presenter's machine where Docker is, after the container sensors (step5.sh).
#
#   step5-docker.sh <clone> <out dir>
#
# Runs every test class named MySql*Tests or Postgres*Tests with ./mvnw on the host, so
# Testcontainers and Spring Boot's Docker Compose support reach the host's Docker. The
# harness runs this, never the coding agent: the agent's container has no Docker socket.
# Appends a section to <out>/sensors.md and writes <out>/docker-tests.log.
# With colima, Testcontainers needs the socket path inside colima's VM; set here.
set -uo pipefail

clone="${1:?usage: step5-docker.sh <clone> <out dir>}"
out="${2:?usage: step5-docker.sh <clone> <out dir>}"
cd "$clone" || exit 2

if ! docker info > /dev/null 2>&1; then
  printf '\n## Docker tests (host)\n\nNot run: no Docker daemon reachable on this machine.\n' >> "$out/sensors.md"
  echo "step5-docker: no Docker; skipped" >&2; exit 0
fi
case "${DOCKER_HOST:-}$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2> /dev/null)" in
  *colima*) export TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE="${TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE:-/var/run/docker.sock}"
            export DOCKER_HOST="${DOCKER_HOST:-$(docker context inspect --format '{{.Endpoints.docker.Host}}')}" ;;
esac

# Twice, in opposite class orders: a test that depends on running before or after
# another (a shared database left by an earlier class) shows up as a difference.
summary=()
for order in alphabetical reversealphabetical; do
  echo "step5-docker: MySQL and Postgres tests on the host, $order order (the first run pulls images)" >&2
  start=$(date +%s)
  rm -f target/surefire-reports/TEST-*MySql*.xml target/surefire-reports/TEST-*Postgres*.xml
  ./mvnw -B test -Dtest='MySql*Tests,Postgres*Tests' -Dsurefire.failIfNoSpecifiedTests=false \
    -Dsurefire.runOrder="$order" -Dspring-javaformat.skip=true -Dcheckstyle.skip=true > "$out/docker-tests-$order.log" 2>&1
  code=$?
  mkdir -p "$out/docker-reports-$order"
  cp target/surefire-reports/TEST-*MySql*.xml target/surefire-reports/TEST-*Postgres*.xml "$out/docker-reports-$order/" 2> /dev/null
  summary+=("$order:$code:$(( $(date +%s) - start ))")
done

python3 - "$out" "$(java -version 2>&1 | head -1)" "$(docker version --format '{{.Server.Version}}' 2> /dev/null)" "${summary[@]}" <<'PY'
import glob, os, re, sys, xml.etree.ElementTree as ET
out, java, docker, runs = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
L = ["", "## Docker tests (host)", "",
     f"Run on the presenter's machine by the harness, not by an agent; {java}; Docker {docker or 'unknown'}. Twice, in opposite class orders.", ""]
for run in runs:
    order, code, secs = run.split(":")
    log = open(os.path.join(out, f"docker-tests-{order}.log"), encoding="utf-8", errors="replace").read()
    seq = [m.split(".")[-1] for m in re.findall(r"Running (org\.[\w.]+)", log)]
    rows, failed = [], []
    for f in sorted(glob.glob(os.path.join(out, f"docker-reports-{order}", "TEST-*.xml"))):
        name = os.path.basename(f)[5:-4].split(".")[-1]
        r = ET.parse(f).getroot()
        t, fl, e, s = (int(r.get(k, 0)) for k in ("tests", "failures", "errors", "skipped"))
        rows.append(f"| {name} | {t} | {t - fl - e - s} | {fl + e} | {s} |")
        for tc in r.iter("testcase"):
            for bad in list(tc.findall("failure")) + list(tc.findall("error")):
                failed.append(f"- `{name}.{tc.get('name')}`: {(bad.get('message') or '').strip()[:300]}")
    L += [f"**{order}** ({secs} s, build exit {code}). Order run: {' → '.join(seq) or 'none'}.", ""]
    L += (["| Class | Run | Passed | Failed | Skipped |", "|---|---|---|---|---|"] + rows + [""]) if rows else [f"No reports: see `docker-tests-{order}.log`.", ""]
    if failed:
        L += ["Failures:", ""] + failed + [""]
open(os.path.join(out, "sensors.md"), "a", encoding="utf-8").write("\n".join(L))
PY
echo "step5-docker: done" >&2
