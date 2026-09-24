# Troubleshooting

Symptoms first, then likely causes and checks. Several entries come from bugs I found in my own workflows; they are marked "seen in real workflows".

## Jobs and state

**Jobs stay in `processing` forever**
- The worker execution crashed or was stopped after claiming. Is `reclaim_stale_jobs()` running at the start of the worker? Check `locked_at` against your lock timeout.
- A node after the claim failed for some items without recording a failure. In one test run, the Record failure query failed for jobs that had a `Retry-After` value because `NULLIF($5, '')` compared a number with a string. Cast explicitly (`NULLIF($5::text, '')`) and pass strings for optional parameters.

**The same work runs twice**
- The idempotency key changes between attempts (built from time, execution ID, or a random value). See [idempotency](../patterns/idempotency.md).
- The side effect happens before the state change that marks it done. *Seen in real workflows:* "send, then mark as sent" and "reply, then mark as read" both duplicate on a failure between the two steps. Claim first.
- The lock timeout is shorter than the job's real duration, so a second worker reclaims a job that is still running.

**Replay selects nothing**
- The dead letters are not `open` (already `replaying`, `resolved`, or `discarded`).
- A class filter is excluding them. The replay example ignores the class when explicit IDs are given.
- They have no `job_id` (Error Trigger entries), so there is no stored payload to replay. Those need a manual fix.

## Workflow structure

**Rows overwrite each other in an upsert** (*seen in real workflows*)
- The upsert matches on a mutable column such as `status`. Match on a stable identity (`job_id`, `external_id`). In Google Sheets this is the "Column to match on" setting of Append or Update.

**A scheduled workflow reprocesses everything each run** (*seen in real workflows*)
- The read step lost its state filter (for example `status = New`) in an edit. The filter is the pipeline's correctness; review it whenever the read node changes.

**A connection points to a node that does not exist** (*seen in real workflows*)
- A node was renamed in JSON, or the workflow was assembled from pieces, and the `connections` object still uses the old name. The editor drops the link silently. Search the JSON for the old name, or reconnect the node in the editor.

**A request body breaks on some inputs** (*seen in real workflows*)
- The JSON body is built by string interpolation, such as `{"cmd": "{{ $json.cmd }}"}`. Any value containing a quote or backslash produces invalid JSON. Build bodies with `={{ JSON.stringify({ ... }) }}`.

**An IF node fails with a JSON parse error** (*seen in real workflows*)
- The condition calls `JSON.parse()` on model output. Expressions cannot catch errors. Parse and validate in a Code node first; see [AI output validation](../patterns/ai-output-validation.md).

## n8n behavior

**The error workflow never runs**
- In n8n 2.x, the error workflow has not been published. Production executions run its published version only.
- The failing execution was manual (editor or `n8n execute`). Error workflows run only for trigger-started executions.
- The failure was caught by Continue or an error output, so the execution did not fail.
- The Error Workflow setting points to a workflow ID that does not exist in this instance (IDs change if you import without them).

**A webhook returns 404 after activating from the CLI**
- CLI activation takes effect after a restart, and webhooks register a moment after the instance reports ready. Wait for "Activated workflow" in the logs.
- In n8n 2.x, activate with `publish:workflow`; `update:workflow` is deprecated.

**`n8n execute` fails with "Task Broker's port 5679 is already in use"**
- The CLI started a second task broker inside a container where n8n is already running. Run it with a different port: `-e N8N_RUNNERS_BROKER_PORT=5690`.

**CLI import fails during migrations**
- The CLI ran while the server was still migrating the database. Wait for `/healthz/readiness` to return 200 before running CLI commands.

**Wait node resumes much later than expected**
- Waits longer than about 65 seconds are offloaded to the database and resumed by the main process. If n8n was down at the resume time, the wait completes when it comes back.

## Database

**`relation "resilience.jobs" does not exist`**
- The Postgres credential points at the wrong database (for example `n8n` instead of `resilience`), or the init script did not run because the volume already existed. Apply `sql/schema.sql` manually.

**Rate limiter always denies**
- The limit is lower than the number of callers per window, or the window is long. Check `SELECT * FROM resilience.rate_limit_windows ORDER BY window_start DESC LIMIT 5;`.
