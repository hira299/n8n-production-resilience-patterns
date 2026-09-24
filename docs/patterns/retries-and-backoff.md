# Retries and exponential backoff

## The failure

An HTTP call fails. Sometimes the failure is temporary (a timeout, a 503 during a deploy, a 429 because you are over a rate limit), and the same request would succeed a few seconds later. Sometimes it is permanent (a 400 for a malformed body, a 401 for a revoked key, a 422 for invalid data), and sending it again only repeats the failure.

A workflow without a retry strategy loses the first kind. A workflow that retries everything the same way wastes calls on the second kind, and, if many executions fail together, retries in lockstep and hits the recovering service all at once.

## Two levels of retry in n8n

**Node-level: Retry On Fail.** Every node has a Retry On Fail setting with Max Tries and Wait Between Tries. It is the right tool for short blips in your own infrastructure, which is why the Postgres nodes in these examples use `maxTries: 3, waitBetweenTries: 2000`. Its limits:

- the wait is fixed, with no growth and no jitter
- it retries every error the same way, including permanent ones
- the n8n editor caps the values (at the time of writing, 5 tries and 5,000 ms), so it cannot ride out an outage longer than a few seconds
- the retries happen inside one execution, so a crash loses them

**Workflow-level: classify, back off, and loop.** The [retry example](../../examples/retry/http-retry-with-backoff.json) handles the response itself:

1. The HTTP Request node uses **Never Error** and **Full Response**, so every HTTP status arrives as data, and **Continue (using error output)**, so network errors and timeouts arrive on a second output instead of stopping the workflow.
2. A Code node classifies the outcome and decides whether to retry.
3. A Wait node backs off; its output loops back into the HTTP node.
4. When retries run out, or the failure is permanent, the item is written to the dead-letter queue.

The attempt number comes from `$runIndex`, which counts how many times the Code node has run in this execution, so no counter has to be carried through the loop.

## Classifying failures

| Signal | Class | Retry? |
|---|---|---|
| 2xx | success | no |
| Network error, timeout, connection reset | transient | yes |
| 408 Request Timeout, 425 Too Early, 429 Too Many Requests | transient | yes, honoring `Retry-After` |
| 5xx | transient | yes |
| Other 4xx (400, 401, 403, 404, 409, 422) | permanent | no, dead-letter it |

This table is a default, not a law. Some APIs return 409 for a conflict that resolves itself, or 500 for a validation error. Adjust the classifier to the APIs you call, and look at your dead letters to see whether the classification holds up.

## The backoff formula

```
delay = min(cap, base * 2^(attempt - 1))
wait  = delay / 2 + random() * delay / 2          # "equal jitter"
wait  = max(wait, Retry-After)                     # never retry earlier than the server asked
```

With a 30-second base and a one-hour cap, attempts wait roughly 15-30 s, 30-60 s, 60-120 s, and so on. The fixed half keeps a floor under the delay; the random half spreads out retries from many jobs that failed together. The same formula is implemented in SQL as `resilience.backoff_delay()` and used by the job queue.

## In-execution loop or durable queue?

The Wait-and-loop approach keeps the execution alive while it waits. That is fine for a few short retries. For anything longer, use the [job queue](explicit-state.md): `fail_job()` stores the next attempt time in Postgres, the execution ends, and a later worker run picks the job up. A crash or restart between attempts loses nothing.

Note that n8n offloads waits longer than about 65 seconds to the database and resumes the execution later. That survives restarts, but the state of the retry still lives inside one paused execution, which is harder to inspect and replay than a row in a table.

## Tradeoffs

- More retries mean more load on a struggling service. Cap attempts, and use the dead-letter queue as the end state rather than retrying forever.
- Retrying a non-idempotent call can duplicate its effect. Pair retries with an [idempotency key](idempotency.md).
- A retry that succeeds hides a flaky dependency. Record attempt counts (the job queue does, in `job_events`) so flakiness shows up somewhere.
