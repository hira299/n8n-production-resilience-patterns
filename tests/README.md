# Tests

Three levels, from fast and narrow to slow and complete.

## SQL behavior tests

`tests/sql/test_schema.sql` checks every state-transition function with `ASSERT` statements inside a transaction that is rolled back, so it leaves no data behind. It covers idempotent enqueue, claim and fencing, backoff bounds, `Retry-After`, dead-lettering and DLQ deduplication, replay guards, stale-lock recovery, the rate-limit ceiling, and the delta gate with its outbox job.

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f sql/schema.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/sql/test_schema.sql
```

Use a scratch database. A failure stops with the assertion message.

## Concurrency test

`tests/sql/test_concurrent_claims.sh` enqueues 200 jobs, runs 8 parallel `psql` workers that claim batches until the queue is empty, and checks that every job was claimed exactly once.

```bash
DATABASE_URL=postgres://user:pass@127.0.0.1:5432/scratch bash tests/sql/test_concurrent_claims.sh
```

## End-to-end run

`tests/e2e/e2e.py` starts an isolated copy of the Docker stack (compose project `rp-e2e`, ports 55433 and 55678, throwaway values from `tests/e2e/e2e.env`), imports every example into n8n, runs them, and checks database rows and the mock API's counters. It removes the stack and its volumes at the end; pass `--keep` to leave it running for inspection.

```bash
python3 tests/e2e/e2e.py
```

Requirements: Docker with Compose v2 and Python 3.10+. It takes a few minutes, mostly waiting for n8n to start and for backoff and rate-limit windows.

Things the run relies on, which are also useful to know when running n8n from scripts:

- Workflows are started with `n8n execute --id=... --rawOutput`. CLI runs count as manual, so they do **not** trigger error workflows. The error-handler check therefore uses a webhook-triggered execution.
- CLI commands run inside the n8n container need `N8N_RUNNERS_BROKER_PORT` set to a free port, because the server already holds the default task-broker port.
- Webhook and error-workflow checks publish the workflows, including the error handler itself, (`n8n publish:workflow` in 2.x) and restart n8n before calling the webhooks.

The run was last executed against n8n 2.10.3 and PostgreSQL 16. Node type versions and CLI commands differ in other n8n versions.
