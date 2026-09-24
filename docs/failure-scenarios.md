# Failure scenarios

What happens when things break at each point of the job-worker flow. "Covered" means the pattern handles it without a person; "visible" means it ends somewhere a person will see it.

| # | Failure | What happens | Result |
|---|---|---|---|
| 1 | Sender retries a webhook | `enqueue_job()` finds the key; response is 200 with `duplicate: true` | Covered |
| 2 | Webhook has no usable key | 400; nothing stored | Visible to sender |
| 3 | Postgres briefly unavailable at intake | Postgres node retries (3 tries, 2 s apart); then the execution fails and the Error Trigger records it | Covered, then visible |
| 4 | Two workers poll at once | `FOR UPDATE SKIP LOCKED` gives each a different job | Covered |
| 5 | API returns 503 or times out | `fail_job(transient)`: rescheduled with backoff | Covered |
| 6 | API returns 429 with `Retry-After` | rescheduled no sooner than `Retry-After` | Covered |
| 7 | API returns 422 | `fail_job(permanent)`: dead, dead letter opened | Visible |
| 8 | Transient failures exhaust `max_attempts` | dead, dead letter opened | Visible |
| 9 | Execution crashes after claiming, before calling the API | job stays `processing` until the lock times out, then `reclaim_stale_jobs()` returns it | Covered, delayed |
| 10 | Execution crashes after the API call succeeded, before `complete_job()` | job is reclaimed and runs again; the downstream call repeats | At-least-once; safe only if the API honors the idempotency key |
| 11 | Slow job outlives its lock; another worker reclaims it | both call the API; the first worker's late `complete_job()` is rejected | At-least-once; fencing keeps state consistent |
| 12 | `complete_job()` itself fails | Postgres node retries; if it still fails, case 10 applies | At-least-once |
| 13 | LLM returns malformed output | parser returns `valid: false`; dead letter with reasons | Visible |
| 14 | Alert webhook is down (guardrail) | alert error output goes to the DLQ; state was already saved, so no re-alert loop | Visible |
| 15 | Alert webhook is down (SQL delta gate) | alert job retries with backoff, then dead-letters | Covered, then visible |
| 16 | Replay of something still broken | job dies again; the same dead letter reopens with `occurrences` + 1; after 3 replays it is skipped | Visible |
| 17 | The error workflow's own insert fails | the failure is lost apart from n8n's execution log | Not covered; needs a second alert channel |
| 18 | Postgres is down for a long time | nothing can claim or record; executions fail | Not covered by these patterns |

The last rows matter as much as the first. Rows 10 and 11 are why [idempotency](patterns/idempotency.md) at the downstream call is not optional. Rows 17 and 18 are why state in Postgres needs the same backup, monitoring, and failover as any other production database.
