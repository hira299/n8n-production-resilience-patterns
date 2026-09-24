# Rate limiting

## The failure

An API allows 100 requests a minute. One workflow respects that with a Wait node between calls. Then the workflow runs on two schedules, or in queue mode with three workers, or a backfill runs next to the live flow, and together they send 300 requests a minute. The API starts returning 429, retries make it worse, and some providers suspend the key.

A Wait node limits one execution. It knows nothing about the others.

## Options in n8n

| Approach | Scope | Good for |
|---|---|---|
| HTTP Request node **Batching** option (items per batch, interval) | one node in one execution | simple bulk sends |
| Loop Over Items + Wait | one execution | pacing a single run |
| Handling 429 with `Retry-After` (see [retries](retries-and-backoff.md)) | reactive | APIs that tell you when to come back |
| Shared budget in Postgres | every execution and worker | several workflows or workers sharing one API key |

Most real setups combine the last two: stay under the limit proactively, and back off correctly when you are told you did not.

## Shared fixed-window budget

`resilience.try_acquire_rate_limit(bucket, limit, window_seconds)` takes one unit from a budget stored in the `rate_limit_windows` table and returns `allowed` and `retry_after_seconds`:

```sql
INSERT INTO resilience.rate_limit_windows AS w (bucket, window_start, used)
VALUES ($bucket, $window, 1)
ON CONFLICT (bucket, window_start) DO UPDATE
  SET used = w.used + 1
  WHERE w.used < $limit            -- no update, and no row returned, once the budget is spent
RETURNING w.used;
```

The conditional update runs under the row lock Postgres takes for the conflict, so concurrent callers cannot push the counter past the limit. The SQL tests check the ceiling.

The [rate-limited sender](../../examples/rate-limiting/rate-limited-sender.json) processes items one at a time: take a slot, send if allowed, otherwise wait `retry_after_seconds` and try again. Run two copies at once and they share the budget.

In the job queue, a worker that is denied a slot should call `release_job()` rather than `fail_job()`: being throttled is not the job's fault, so it should not spend one of the job's attempts.

## Tradeoffs

- **Fixed windows allow bursts at the edges.** A caller can use the whole budget at the end of one window and again at the start of the next, briefly doubling the rate. If the provider enforces a sliding window, set your limit somewhat below theirs, or implement a token bucket.
- **Every call costs a database round trip.** Fine at tens of requests per second; at higher rates, use an in-memory limiter such as Redis.
- **Old windows accumulate.** Call `resilience.prune_rate_limit_windows()` from a daily workflow.
- **Your limit is a guess about theirs.** Keep handling 429 even with a proactive limiter, because the provider may count requests you cannot see, from other systems using the same key.
