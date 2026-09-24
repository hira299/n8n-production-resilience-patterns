# Observability

n8n's execution list answers "did this execution fail?". Production questions are usually different: which work is stuck, which dependency is degrading, how many items failed this week, and whether retries are hiding a problem. Explicit state makes those answerable with SQL.

## What to watch

| Question | Query |
|---|---|
| What is in flight, and for how long? | `SELECT locked_by, count(*), min(locked_at) FROM resilience.jobs WHERE status = 'processing' GROUP BY 1;` |
| Is anything stuck past the lock timeout? | `SELECT id, job_type, locked_by, locked_at FROM resilience.jobs WHERE status = 'processing' AND locked_at < now() - interval '15 minutes';` |
| How deep is the backlog? | `SELECT job_type, status, count(*) FROM resilience.jobs WHERE status IN ('pending','failed') GROUP BY 1, 2;` |
| Which jobs need retries to succeed? | `SELECT job_type, avg(attempts), max(attempts) FROM resilience.jobs WHERE status = 'succeeded' AND completed_at > now() - interval '1 day' GROUP BY 1;` |
| What is failing, grouped? | see the [dead-letter digest](../../examples/dlq/dead-letter-digest.json) |
| What happened to one job? | `SELECT * FROM resilience.job_events WHERE job_id = $1 ORDER BY created_at;` |

Average attempts on successful jobs is the early warning: it rises while the success rate still looks fine.

## Alerting

Alert on conditions a person should act on, and only once per condition:

- open dead letters above a threshold, or any from a critical workflow
- jobs stuck in `processing` past the lock timeout (the worker itself may be down)
- backlog growing across several runs
- the error handler failing to write (alert through a channel that does not depend on the database)

The delta-gate pattern in [explicit state](explicit-state.md#delta-gated-transitions) applies to monitoring too: alert on transitions, not on every check.

## Logs and execution data

- Keep `EXECUTIONS_DATA_SAVE_ON_ERROR=all` so failed executions keep their data for debugging, and prune with `EXECUTIONS_DATA_MAX_AGE`. The tables here are the long-term record; the execution log is short-term detail.
- Do not log secrets or full payloads into dead letters or events. Store identifiers and a truncated error.
- Record which worker did what (`locked_by`, `job_events.detail`). When two executions interfere, that is how you find out.

## Health checks

n8n exposes `/healthz` (the process is up) and `/healthz/readiness` (database connected and migrated). Use readiness for load balancers and startup ordering. Neither tells you whether workflows are succeeding, so pair them with the queries above.
