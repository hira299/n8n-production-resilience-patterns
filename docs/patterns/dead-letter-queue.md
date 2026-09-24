# PostgreSQL-backed dead-letter queue

## The failure

A failure is handled, meaning it no longer crashes anything, but the work it represents is gone. The retry budget ran out, or the error was permanent, and the item fell off the end of the workflow. Weeks later someone asks why an order never synced.

## The pattern

A dead-letter queue (DLQ) is where work goes when the system has stopped trying. It turns "it failed" into a row someone can find, understand, and act on.

In this repository it is the `resilience.dead_letters` table. Rows arrive from three places:

| Source | How | Example |
|---|---|---|
| A node's error output | `onError: continueErrorOutput`, then `record_dead_letter()` | [guardrail](../../examples/state-machine/guardrail-delta-gate.json), [retry](../../examples/retry/http-retry-with-backoff.json) |
| A failed execution | Error Trigger workflow, then `record_dead_letter()` | [global error handler](../../examples/error-trigger/global-error-handler.json) |
| A job out of attempts, or failed permanently | `fail_job()` calls `_kill_job()` | [job worker](../../examples/state-machine/job-worker.json) |

## Where this comes from

In my own workflows the DLQ started simple. The [Financial Profitability Guardrail](https://github.com/hira299/Financial-Profitability-Guardrail) routes the source API node's error output straight into an `INSERT` into a failures table, and the Competitor Intelligence pipeline does the same for blocked scrapes. That already beats losing the failure, and it is the shape of the [guardrail example](../../examples/state-machine/guardrail-delta-gate.json).

Those early tables had one problem in common: they were append-only logs. A source that failed every 15 minutes produced a new row every 15 minutes, nothing tracked whether a failure had been dealt with, and replaying meant reading raw error bodies. The schema here addresses that.

## Schema highlights

- **Status lifecycle:** `open` to `replaying` to `resolved`, or `open` to `discarded`. A DLQ with no resolution state only grows.
- **Deduplication:** a partial unique index on `(source_workflow, idempotency_key)` for active rows. The same failing item increments `occurrences` and updates `last_seen_at` instead of adding rows.
- **Classification:** `error_class` is `transient`, `permanent`, or `unknown`, so triage and replay can filter.
- **Link to the work:** `job_id` points to the job that died, which holds the payload. Only these rows are automatically replayable.
- **Bounded text:** messages are truncated to 4,000 characters, so a huge error body cannot bloat the table.

## Operating it

- **Look at it.** The [dead-letter digest](../../examples/dlq/dead-letter-digest.json) groups open rows by source and class every morning. A DLQ nobody reads is a slower way to lose data.
- **Decide on each group:** fix and [replay](replay.md), discard with a note (`discard_dead_letter()`), or change the classifier if the class was wrong.
- **Watch the trend, not only the count.** A steady trickle of transient dead letters from one source usually means its retry budget is too small or the dependency is unhealthy.

Useful queries:

```sql
-- What is failing right now?
SELECT source_workflow, error_class, count(*), sum(occurrences), min(first_seen_at)
FROM resilience.dead_letters WHERE status = 'open'
GROUP BY 1, 2 ORDER BY 3 DESC;

-- Which items keep failing after replay?
SELECT id, source_workflow, replay_count, error_message
FROM resilience.dead_letters WHERE replay_count > 0 AND status = 'open';
```

## Tradeoffs

- The DLQ holds whatever payload you give it. Keep personal and secret data out, or restrict access to the table accordingly (see [security](../security.md)).
- Deduplication needs an idempotency key. Failures without one (for example from the Error Trigger) are stored individually.
- A DLQ in the same database as your state shares its failure modes. If Postgres is down, the DLQ is down too, and the error handler's alert channel is your fallback.
