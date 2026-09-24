#!/usr/bin/env python3
"""End-to-end test: runs every example workflow in a real n8n instance.

Starts the docker compose stack with throwaway settings, imports a Postgres
credential and all example workflows, executes them through the n8n CLI, and
asserts on the resulting database rows and mock API counters.

Usage:
    python3 tests/e2e/e2e.py            # run and tear down
    python3 tests/e2e/e2e.py --keep     # leave the stack running afterwards
"""

import copy
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.request

REPO = pathlib.Path(__file__).resolve().parents[2]
ENV = REPO / "tests" / "e2e" / "e2e.env"
PROJECT = "rp-e2e"
COMPOSE = ["docker", "compose", "-p", PROJECT, "-f", str(REPO / "docker" / "docker-compose.yml"), "--env-file", str(ENV)]
CRED = {"id": "RPpostgresCred01", "name": "Resilience Postgres"}

env = dict(line.split("=", 1) for line in ENV.read_text().splitlines() if line and not line.startswith("#"))
N8N_URL = f"http://127.0.0.1:{env['N8N_HOST_PORT']}"
failures: list[str] = []


def sh(*args, input_text=None, check=True) -> str:
    res = subprocess.run(args, input=input_text, capture_output=True, text=True)
    if check and res.returncode != 0:
        raise RuntimeError(f"{' '.join(args)}\n{res.stdout}\n{res.stderr}")
    return res.stdout


def compose(*args, **kw) -> str:
    return sh(*COMPOSE, *args, **kw)


def sql(query: str) -> list[list[str]]:
    out = compose("exec", "-T", "postgres", "psql", "-U", env["POSTGRES_USER"], "-d", "resilience",
                  "-qAt", "-F", "\t", "-v", "ON_ERROR_STOP=1", "-c", query)
    return [line.split("\t") for line in out.splitlines() if line]


def mock(path: str, method: str = "GET") -> dict:
    code = f"import urllib.request,sys;r=urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8080{path}',method='{method}'));sys.stdout.write(r.read().decode())"
    return json.loads(compose("exec", "-T", "mock-api", "python", "-c", code))


def execute(workflow_id: str) -> dict:
    out = compose("exec", "-T", "-e", "N8N_RUNNERS_BROKER_PORT=5690", "n8n",
                  "n8n", "execute", f"--id={workflow_id}", "--rawOutput", check=False)
    match = re.search(r"^\{", out, re.M)
    if not match:
        raise RuntimeError(f"execution of {workflow_id} produced no result:\n{out[-2000:]}")
    result, _ = json.JSONDecoder().raw_decode(out[match.start():])
    return result["data"]["resultData"]


def runs(result: dict, node: str) -> list:
    return result["runData"].get(node, [])


def items(result: dict, node: str, output: int = 0, run: int = -1) -> list[dict]:
    r = runs(result, node)
    if not r:
        return []
    main = r[run].get("data", {}).get("main", [])
    return [i["json"] for i in (main[output] if len(main) > output and main[output] else [])]


def check(name: str, condition: bool, detail: str = "") -> None:
    print(("  ok    " if condition else "  FAIL  ") + name + ("" if condition else f"  ({detail})"))
    if not condition:
        failures.append(name)


def load(path: str) -> dict:
    return json.loads((REPO / "examples" / path).read_text())


def with_credentials(wf: dict) -> dict:
    wf = copy.deepcopy(wf)
    for node in wf["nodes"]:
        if node["type"] == "n8n-nodes-base.postgres":
            node["credentials"] = {"postgres": CRED}
    return wf


def import_workflows(workflows: list[dict]) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        for wf in workflows:
            (pathlib.Path(tmp) / f"{wf['id']}.json").write_text(json.dumps(with_credentials(wf)))
        (pathlib.Path(tmp) / "cred.json").write_text(json.dumps([{
            **CRED, "type": "postgres",
            "data": {"host": "postgres", "database": "resilience", "user": env["POSTGRES_USER"],
                     "password": env["POSTGRES_PASSWORD"], "port": 5432, "ssl": "disable"}}]))
        container = compose("ps", "-q", "n8n").strip()
        compose("exec", "-T", "n8n", "rm", "-rf", "/tmp/e2e")
        sh("docker", "cp", tmp + "/.", f"{container}:/tmp/e2e")
    compose("exec", "-T", "n8n", "n8n", "import:credentials", "--input=/tmp/e2e/cred.json")
    compose("exec", "-T", "n8n", "sh", "-c", "rm /tmp/e2e/cred.json && n8n import:workflow --separate --input=/tmp/e2e/")


def wait_for_n8n(timeout: int = 180) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            # /healthz/readiness only succeeds once the database is connected and migrated.
            urllib.request.urlopen(N8N_URL + "/healthz/readiness", timeout=3)
            time.sleep(2)
            return
        except Exception:
            time.sleep(3)
    raise RuntimeError("n8n did not become healthy")


def variant(wf: dict, new_id: str, name: str, replace: tuple[str, str]) -> dict:
    text = json.dumps(wf).replace(*replace)
    wf = json.loads(text)
    wf["id"], wf["name"] = new_id, name
    return wf


def main() -> int:
    keep = "--keep" in sys.argv
    print("starting stack")
    compose("down", "-v", check=False)
    compose("up", "-d", "--wait")
    wait_for_n8n()

    workflows = [json.loads(p.read_text()) for p in sorted((REPO / "examples").glob("*/*.json"))]
    workflows.append(variant(load("retry/http-retry-with-backoff.json"), "RPretryPermTest1",
                             "Retry test: permanent failure", ("fail_times:2", "permanent")))
    workflows.append(variant(load("state-machine/guardrail-delta-gate.json"), "RPguardrailFail1",
                             "Guardrail test: source down", ("mock-api:8080/tasks", "mock-api:8080/tasks?fail=1")))
    import_workflows(workflows)
    print(f"imported {len(workflows)} workflows")

    print("\nretry with backoff")
    r = execute("RPretryBackoff01")
    attempts = [i["attempt"] for run in range(len(runs(r, "Evaluate attempt"))) for i in items(r, "Evaluate attempt", run=run)]
    check("two transient failures, success on attempt 3", attempts == [1, 2, 3], str(attempts))
    check("success path reached", len(items(r, "Use response")) == 1)
    delivered = mock("/stats")["delivered"]
    check("exactly one delivery", sum(v for k, v in delivered.items() if k.startswith("retry-demo-")) == 1, str(delivered))

    r = execute("RPretryPermTest1")
    check("permanent failure is not retried", len(runs(r, "Call API")) == 1, str(len(runs(r, "Call API"))))
    rows = sql("SELECT error_class FROM resilience.dead_letters WHERE source_workflow = 'Retry test: permanent failure'")
    check("permanent failure dead-lettered", rows == [["permanent"]], str(rows))

    print("\nerror trigger")
    execute("RPfailingDemo001")
    time.sleep(3)
    rows = sql("SELECT source_node, error_class FROM resilience.dead_letters WHERE source_workflow = 'Failing workflow (error handler demo)'")
    check("CLI-started failure did not trigger the error workflow (manual/CLI runs skip it)", rows == [], str(rows))

    print("\nguardrail delta gate (derived from a real workflow)")
    r = execute("RPguardrailDelta")
    alerts = sorted(i["entity_id"] for i in items(r, "Needs alert?", 0))
    bodies = [json.loads(i["body"]) if isinstance(i.get("body"), str) else i for i in items(r, "Send alert")]
    check("alert payload carries the transition", sorted((b.get("key") or "").split(":")[2] for b in bodies) == ["CRITICAL", "WARNING"], str(bodies))
    check("first run alerts only for tasks entering WARNING/CRITICAL", alerts == ["task-b", "task-c"], str(alerts))
    r = execute("RPguardrailDelta")
    check("second run sends no alerts (no state change)", items(r, "Needs alert?", 0) == [])
    states = dict(sql("SELECT entity_id, state FROM resilience.entity_state WHERE entity_id LIKE 'task-%'"))
    check("states persisted", states == {"task-a": "HEALTHY", "task-b": "WARNING", "task-c": "CRITICAL", "task-d": "HEALTHY"}, str(states))
    execute("RPguardrailFail1")
    rows = sql("SELECT source_node FROM resilience.dead_letters WHERE source_workflow = 'Guardrail test: source down'")
    check("source failure goes to the DLQ via the error output", rows == [["Fetch tasks"]], str(rows))

    print("\nSQL delta gate + job worker")
    r = execute("RPdeltaGate00001")
    summary = items(r, "Summary")[0]
    check("two alert jobs enqueued in the same transaction", len(summary["alert_jobs"]) == 2, str(summary))
    sql("""SELECT resilience.enqueue_job('e2e-flaky', 'e2e', '{"simulate":"fail_times:1"}');
           SELECT resilience.enqueue_job('e2e-permanent', 'e2e', '{"simulate":"permanent"}');
           SELECT resilience.enqueue_job('e2e-throttled', 'e2e', '{"simulate":"rate_limit_times:1"}');""")
    execute("RPjobWorker00001")
    status = dict(sql("SELECT idempotency_key, status FROM resilience.jobs WHERE job_type IN ('e2e', 'state_alert')"))
    check("alert jobs delivered", [v for k, v in status.items() if k.startswith("state-alert:")] == ["succeeded", "succeeded"], str(status))
    check("503 rescheduled, 422 dead, 429 rescheduled",
          (status["e2e-flaky"], status["e2e-permanent"], status["e2e-throttled"]) == ("failed", "dead", "failed"), str(status))
    delay = float(sql("SELECT extract(epoch FROM next_attempt_at - updated_at) FROM resilience.jobs WHERE idempotency_key = 'e2e-throttled'")[0][0])
    check("Retry-After respected for 429", delay >= 2, str(delay))

    sql("UPDATE resilience.jobs SET next_attempt_at = now() WHERE status = 'failed'")
    execute("RPjobWorker00001")
    status = dict(sql("SELECT idempotency_key, status FROM resilience.jobs WHERE job_type = 'e2e'"))
    check("transient jobs succeed on the next run", (status["e2e-flaky"], status["e2e-throttled"]) == ("succeeded", "succeeded"), str(status))

    print("\nreplay")
    sql("""UPDATE resilience.jobs SET payload = '{"simulate":"ok"}' WHERE idempotency_key = 'e2e-permanent'""")  # the "fix"
    dl_id = sql("SELECT id FROM resilience.dead_letters WHERE idempotency_key = 'e2e-permanent'")[0][0]
    replay = variant(load("replay/replay-dead-jobs.json"), "RPreplayTest0001", "Replay test",
                     ("ids: [],", f"ids: [{dl_id}],"))
    import_workflows([replay])
    r = execute("RPreplayTest0001")
    check("dead job requeued", items(r, "Summary")[0]["by_action"] == {"requeued": 1}, str(items(r, "Summary")))
    execute("RPjobWorker00001")
    rows = sql(f"SELECT d.status, j.status FROM resilience.dead_letters d JOIN resilience.jobs j ON j.id = d.job_id WHERE d.id = {dl_id}")
    check("successful replay resolves the dead letter", rows == [["resolved", "succeeded"]], str(rows))

    print("\nidempotent webhook intake")
    # n8n 2.x activates workflows with publish:workflow (1.x: update:workflow --active=true).
    # The error workflow must be published too: production executions run its published version.
    for wf_id in ("RPerrorHandler01", "RPidemIntake0001", "RPfailingDemo001"):
        compose("exec", "-T", "n8n", "n8n", "publish:workflow", f"--id={wf_id}")
    compose("restart", "n8n")
    wait_for_n8n()
    for _ in range(30):  # active workflows register their webhooks shortly after readiness
        if "Activated workflow \"Failing workflow" in sh("docker", "logs", "--since", "3m", compose("ps", "-q", "n8n").strip(), check=False) \
                + subprocess.run(["docker", "logs", "--since", "3m", compose("ps", "-q", "n8n").strip()], capture_output=True, text=True).stderr:
            break
        time.sleep(2)
    time.sleep(2)

    def post(headers: dict, body: dict) -> tuple[int, dict]:
        req = urllib.request.Request(N8N_URL + "/webhook/resilience/intake", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json", **headers}, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=15) as res:
                return res.status, json.loads(res.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b"{}")

    first = post({"Idempotency-Key": "order-1001"}, {"amount": 10})
    second = post({"Idempotency-Key": "order-1001"}, {"amount": 10})
    third = post({}, {"source": "shop", "external_id": "A-7"})
    missing = post({}, {"amount": 1})
    check("first call accepted (202)", first[0] == 202 and first[1].get("duplicate") is False, str(first))
    check("repeat call is a duplicate (200)", second[0] == 200 and second[1].get("duplicate") is True
          and second[1].get("job_id") == first[1].get("job_id"), str(second))
    check("business-identity key works without a header", third[0] == 202, str(third))
    check("missing key rejected (400)", missing[0] == 400, str(missing))

    print("\nerror trigger on a production execution")
    req = urllib.request.Request(N8N_URL + "/webhook/resilience/fail-demo", data=b"{}",
                                 headers={"Content-Type": "application/json"}, method="POST")
    try:
        fail_status = urllib.request.urlopen(req, timeout=15).status
    except urllib.error.HTTPError as e:
        fail_status = e.code
    rows = []
    for _ in range(30):
        rows = sql("SELECT source_node, error_class FROM resilience.dead_letters WHERE source_workflow = 'Failing workflow (error handler demo)'")
        if rows:
            break
        time.sleep(1)
    detail = f"webhook HTTP {fail_status}, rows {rows}"
    if not rows:
        n8n_id = compose("ps", "-q", "n8n").strip()
        detail += "\n" + subprocess.run(["docker", "logs", "--tail", "30", n8n_id], capture_output=True, text=True).stdout[-3000:]
    check("error workflow stored a classified dead letter", rows == [["Send invalid payload", "permanent"]], detail)

    print("\nrate limiting")
    started = time.time()
    r = execute("RPrateLimited001")
    elapsed = time.time() - started
    summary = items(r, "Summary")[0]
    check("all six messages sent", summary["sent"] == 6 and set(summary["status_codes"]) == {200}, str(summary))
    peak = int(sql("SELECT max(used) FROM resilience.rate_limit_windows WHERE bucket = 'mock-api'")[0][0])
    check("never more than 3 per window", peak <= 3, str(peak))
    check("had to wait for at least one window", len(runs(r, "Wait for next window")) >= 1, f"elapsed {elapsed:.1f}s")

    print("\nerrors as data + allow-list replay (derived from real workflows)")
    execute("RPconfigChecks01")
    verdicts = dict(sql("SELECT check_name, status FROM resilience.check_results"))
    check("verdicts", verdicts == {"MFA_ENABLED": "PASS", "LOGGING_ENABLED": "FAIL", "PASSWORD_POLICY": "FAIL",
                                   "FLAKY_DEPENDENCY": "MANUAL_REVIEW", "BROKEN_DEPENDENCY": "MANUAL_REVIEW"}, str(verdicts))
    execute("RPreviewReplay01")
    rows = dict((k, (s, a)) for k, s, a in sql("SELECT check_name, status, attempts FROM resilience.check_results"))
    check("flaky dependency recovers on replay", rows["FLAKY_DEPENDENCY"] == ("PASS", "2"), str(rows))
    check("broken dependency stays in review", rows["BROKEN_DEPENDENCY"] == ("MANUAL_REVIEW", "2"), str(rows))
    check("settled checks are not re-run", rows["MFA_ENABLED"][1] == "1", str(rows))

    print("\ndefensive LLM output parsing (derived from a real workflow)")
    r = execute("RPllmOutputParse")
    accepted = sorted(i["case"] for i in items(r, "Valid?", 0))
    rejected = sorted(i["case"] for i in items(r, "Valid?", 1))
    check("clean, fenced, and single-object outputs accepted", accepted == ["clean array", "markdown fence", "single object"], str(accepted))
    check("truncated, prose, and wrong-field outputs rejected", rejected == ["prose only", "truncated", "wrong fields"], str(rejected))
    n = int(sql("SELECT count(*) FROM resilience.dead_letters WHERE source_workflow = 'Defensive LLM JSON parsing'")[0][0])
    check("rejections recorded as dead letters", n == 3, str(n))

    print("\ndead-letter digest")
    r = execute("RPdlqDigest00001")
    digest = items(r, "Build digest")[0]
    check("digest counts open dead letters", digest["total_open"] >= 4, str(digest))

    if not keep:
        compose("down", "-v", check=False)
    print(f"\n{'FAILED: ' + str(len(failures)) + ' check(s)' if failures else 'all end-to-end checks passed'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
