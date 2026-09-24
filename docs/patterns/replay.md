# Safe replay

## The failure

Something failed, the cause is fixed, and now the failed work has to run again. The tempting approaches all cause trouble: re-running whole executions from the n8n UI repeats the steps that had succeeded; re-running a workflow over "everything since Tuesday" redoes finished work; replaying from a raw error log means reconstructing inputs by hand.

## What makes replay safe

1. **Only replay what you can identify.** A replayable unit has a stored payload and an idempotency key. In this schema that means a dead letter linked to a job.
2. **Replay through the normal path.** A replayed job goes back to `pending` and is picked up by the same worker, with the same classification, backoff, and dead-lettering as the first time.
3. **Keep the history.** `replay_count` goes up; `job_events` records the `dead` to `pending` transition; a successful run marks the dead letter `resolved`, and a failed one reopens the same dead letter rather than creating a new one.
4. **Stop replay loops.** `replay_dead_letters()` skips anything already replayed `p_max_replays` times (default 3). Something that fails three times after being "fixed" needs a person, not a fourth attempt.
5. **Fix first.** Replay only helps if the cause is gone. For a permanent failure (a 422, a schema mismatch), change the payload, the code, or the downstream configuration before replaying.

## Replaying jobs

The [replay workflow](../../examples/replay/replay-dead-jobs.json) takes a list of dead-letter IDs, or, with an empty list, an error class and a limit:

```sql
SELECT * FROM resilience.replay_dead_letters(
  p_ids         => '{41,42}',   -- or NULL to select by class
  p_error_class => NULL,        -- e.g. 'transient'; ignored when ids are given
  p_limit       => 20,
  p_max_replays => 3,
  p_note        => 'replayed after fixing webhook signature'
);
```

Each row returns an action: `requeued`, `skipped_no_job` (for example an Error Trigger entry with no stored payload), `skipped_replay_limit`, or `skipped_job_not_dead`. The workflow summarizes the counts, and the job worker does the rest.

## Replaying checks: errors as data

The second replay example comes from my cloud security audit platform, reduced to five mock checks.

The original audit engine ran a list of AWS checks. Rather than letting a failed API call stop the run, each call was set to continue on error, and a single classifier node (called SWITCHBOARD in the original) turned every response into one of three verdicts:

- **PASS** or **FAIL** when the response actually answered the question. An expected "not found" counts as an answer: no password policy configured is a FAIL, not a system error.
- **MANUAL_REVIEW** for anything else: a crashed call, an unparseable response, or a check with no evaluation logic yet. A broken dependency can never be reported as compliant.

All verdicts were saved. A separate DLQ workflow later selected only the `MANUAL_REVIEW` rows and re-ran them.

The part worth copying is how that replay decided what to execute. The stored row supplied only a check name. The command to run always came from a static map inside the replay workflow, so nothing written to the table could choose what got executed. In the [reduced version](../../examples/replay/replay-manual-review.json), the map points at mock endpoints instead of AWS CLI commands, and a check whose name is not in the map is skipped.

Run the [checks workflow](../../examples/replay/checks-errors-as-data.json), then the replay: the flaky dependency recovers to PASS, the broken one stays in MANUAL_REVIEW with its attempt count increased, and settled checks are not touched.

## Tradeoffs

- Replay resets the attempt budget. That is intended after a fix; it is wasteful if nothing was fixed. The replay limit bounds the damage.
- Replay is at-least-once. A job that had partly succeeded before dying will repeat that part. Idempotent downstream calls make that harmless; see [idempotency](idempotency.md).
- Bulk replay by class can stampede a dependency that has just recovered. Use `p_limit`, and let the worker's rate limit and backoff pace the requeued jobs.
