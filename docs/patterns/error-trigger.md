# Global error handling with Error Trigger

## The failure

When a node throws and nothing catches it, the execution stops and is marked failed. The only record is the execution log, which is usually pruned after a few days, and which nobody reads unless they already know something is wrong.

## The pattern

n8n lets any workflow name an **Error Workflow** in its settings. When an execution of that workflow fails, n8n starts the error workflow with an **Error Trigger** node, passing details about the failure.

The [global error handler](../../examples/error-trigger/global-error-handler.json) does three things:

1. **Normalizes** the payload into workflow name, failing node, execution ID, message, and a coarse error class.
2. **Stores** it with `resilience.record_dead_letter()`, so the failure outlives execution pruning and can be counted, grouped, and reviewed.
3. **Alerts** (disabled until you set a webhook URL). The alert node continues on error, so a broken alert channel does not fail the error handler itself.

One error workflow can serve every workflow in an instance. The examples in this repository reference it by the fixed ID `RPerrorHandler01`.

## The payload

For a normal failure the trigger receives `execution` (with `id`, `url`, `lastNodeExecuted`, `mode`, `error.message`, and `retryOf` for retried runs) and `workflow` (`id`, `name`). When the trigger node itself fails, for example a webhook that cannot start, the payload has `trigger` instead of `execution`. The handler accepts both shapes.

## What it deliberately does not store

The handler stores metadata only. It does not copy the failing item's input data or the error stack. Input data can contain personal information, tokens, or payment details, and the dead-letter table is typically readable by more people than the systems the data came from. If you need the payload to replay the work, use the [job queue](explicit-state.md), where the payload is stored once, under your control, and linked to the dead letter.

## Things that surprise people

- **In n8n 2.x the error workflow must be published.** Production executions run the published version of the error workflow. An unpublished handler is simply not run, with no warning in the failing workflow. The end-to-end test failed on this exact point until the handler was published.
- **Manual executions do not trigger the error workflow.** Running a workflow from the editor, or with `n8n execute` from the CLI, will not start it. Test the handler with a trigger-started execution: the [failing demo](../../examples/error-trigger/failing-workflow-demo.json) has a webhook for this. The end-to-end test checks both behaviors.
- **Errors you catch are not errors.** Nodes set to Continue, or Continue (using error output), do not fail the execution, so the error workflow never hears about them. Handle those branches explicitly, usually by writing to the dead-letter queue.
- **The error workflow can fail too.** If its database insert fails, the failure is lost. The Postgres node here uses Retry On Fail for short blips; for anything stricter, send alerts through a second channel.
- **Classification by message text is coarse.** Error messages differ between nodes and n8n versions. Treat `error_class` from the handler as a hint for triage, not as input to automatic replay.

## When not to rely on it alone

The error workflow tells you that an execution failed. It does not tell you which business records were affected or leave them in a state you can resume from. For work that must complete, combine it with [explicit state](explicit-state.md), so the record of what is done lives in the database rather than in the failed execution.
